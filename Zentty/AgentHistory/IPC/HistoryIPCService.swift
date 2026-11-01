import Foundation
import os

/// What the app knows about the pane that ran `zentty history`, captured in one main-thread hop
/// (no I/O there). Everything else happens off main.
struct HistoryIPCCaller: Sendable {
    var paneCWD: String?
    var paneRepoRoot: String?
    var isRemotePane: Bool
    var allowAgentsAllProjects: Bool
    /// Sessions running in a Zentty pane right now.
    var liveKeys: Set<AgentHistorySessionKey>
    var exclusions: AgentHistoryExclusionMatcher
    /// Nil when Agent History was never set up in this app.
    var dataSource: (any HistoryIPCDataSource)?
}

/// User-facing messages the service produces beyond the shared `HistoryIPC` constants.
enum HistoryIPCMessages {
    static let remotePane = "This pane runs on another machine, so its project is unknown."
    static let noDirectory = "Zentty doesn't know this pane's folder, so its project is unknown."
    static let starting = "Agent History is still starting. Try again in a moment."
    static let readFailed = "Agent History can't read its index right now. Try again in a moment."
    static let configUnreadable = "Agent History is paused because Zentty's config.toml can't be read, "
        + "so its excluded folders aren't known. Fix the file to search again."

    static func unavailable(_ reason: AgentHistoryFailureReason) -> String {
        switch reason {
        case .openFailed:
            "Agent History can't open its index. Check Zentty Settings › Agent History."
        case .newerSchema:
            "Agent History's index was made by a newer Zentty. Rebuild it in Zentty Settings › Agent History."
        case .corrupt:
            "Agent History's index is damaged. Rebuild it in Zentty Settings › Agent History."
        case .removalsUnreadable:
            "Agent History stopped indexing because it can't read its list of removed sessions. "
                + "Delete the index in Zentty Settings › Agent History."
        }
    }
}

/// Answers `zentty history search` and `show` for one caller. Pure apart from the data source,
/// so it runs on the IPC thread and tests drive it with a fake.
///
/// Order of checks: no data source or History off → `disabled`; index unreadable →
/// `unavailable`; `--all` without permission → `scopeDenied` (nothing is queried); then the
/// pane's project scope (remote pane or no folder → `scopeUnknown`). Every hit and every `show`
/// candidate is re-checked against the scope and the exclusions, whatever the data source did.
struct HistoryIPCService {
    typealias DeadlineScheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

    static let maxTitleCharacters = 300

    var homeDirectory: String = NSHomeDirectory()
    var identity: @Sendable (String) -> RepositoryIdentity? = { RepositoryIdentityResolver.resolve(directory: $0) }
    var now: @Sendable () -> Date = { Date() }
    var deadlineSeconds: TimeInterval = HistoryIPC.serverQueryDeadlineSeconds
    /// Runs the handler once the interval passes; returns a cancel closure.
    var scheduleDeadline: DeadlineScheduler = HistoryIPCService.dispatchDeadline

    func respond(to command: HistoryIPCCommand, caller: HistoryIPCCaller) throws -> HistoryIPCResult {
        guard let dataSource = caller.dataSource else {
            throw HistoryIPCError.disabled
        }
        let complete: Bool
        switch dataSource.availability() {
        case .disabled:
            throw HistoryIPCError.disabled
        case .unavailable(let message):
            throw HistoryIPCError.unavailable(message)
        case .ready(let isComplete):
            complete = isComplete
        }
        if command.allProjects && !caller.allowAgentsAllProjects {
            throw HistoryIPCError.scopeDenied
        }
        let scope = try resolveScope(allProjects: command.allProjects, caller: caller)

        switch command {
        case .search(let options):
            return HistoryIPCResult(search: try search(
                options, scope: scope, complete: complete, caller: caller, dataSource: dataSource))
        case .show(let options):
            return HistoryIPCResult(show: try show(options, scope: scope, caller: caller, dataSource: dataSource))
        }
    }

    // MARK: - Scope

    private func resolveScope(allProjects: Bool, caller: HistoryIPCCaller) throws -> AgentHistoryScope {
        if allProjects {
            return .all
        }
        return .project(try projectScope(caller))
    }

    private func projectScope(_ caller: HistoryIPCCaller) throws -> AgentHistoryProjectScope {
        do {
            return try AgentHistoryProjectScopeResolver.resolve(
                cwd: caller.paneCWD,
                repoRoot: caller.paneRepoRoot,
                isRemote: caller.isRemotePane,
                homeDirectory: homeDirectory,
                identity: identity
            )
        } catch .remotePane {
            throw HistoryIPCError.scopeUnknown(HistoryIPCMessages.remotePane)
        } catch .noDirectory {
            throw HistoryIPCError.scopeUnknown(HistoryIPCMessages.noDirectory)
        }
    }

    private static func admits(
        _ session: AgentHistorySessionSummary,
        scope: AgentHistoryScope,
        exclusions: AgentHistoryExclusionMatcher
    ) -> (inScope: Bool, excluded: Bool) {
        let inScope: Bool
        switch scope {
        case .all:
            inScope = true
        case .project(let project):
            inScope = project.admits(repoRoot: session.repoRoot, mainRepoRoot: session.mainRepoRoot, cwd: session.cwd)
        }
        return (inScope, exclusions.excludesCanonical(session.cwd))
    }

    // MARK: - Search

    private func search(
        _ options: HistorySearchIPCOptions,
        scope: AgentHistoryScope,
        complete: Bool,
        caller: HistoryIPCCaller,
        dataSource: any HistoryIPCDataSource
    ) throws -> HistorySearchIPCResponse {
        let extraAgents = Set([options.agent].compactMap { $0.flatMap(AgentHistoryAgent.init(rawValue:)) })
        let query = HistoryQueryParser.parse(options.query, extraAgents: extraAgents)
        let boostKey: String? = switch scope {
        case .project(let project): project.key
        case .all: try? projectScope(caller).key
        }
        let context = HistorySearchContext(scope: scope, currentRepositoryKey: boostKey, now: now())

        let cancellation = HistorySearchCancellation()
        let cancelDeadline = scheduleDeadline(deadlineSeconds) { cancellation.cancel() }
        defer { cancelDeadline() }
        let hits = try mapped {
            try dataSource.search(query: query, context: context, limit: options.limit, cancellation: cancellation)
        }

        var outOfScope = 0
        let results = hits.compactMap { hit -> HistorySearchIPCHit? in
            let check = Self.admits(hit.session, scope: scope, exclusions: caller.exclusions)
            guard check.inScope else {
                outOfScope += 1
                return nil
            }
            // Expected while an exclusion's purge is still catching up.
            guard !check.excluded else { return nil }
            return searchHit(hit, caller: caller)
        }
        if outOfScope > 0 {
            AgentHistoryLog.search.fault("IPC search dropped \(outOfScope, privacy: .public) out-of-scope hits")
        }

        let indexedSessions = try mapped { try dataSource.visibleSessionCount(scope: scope) }
        let response = HistorySearchIPCResponse(
            scope: Self.scopeName(scope),
            project: Self.projectKey(scope),
            indexedSessions: indexedSessions,
            complete: complete,
            contentIsUntrusted: true,
            results: Array(results.prefix(options.limit))
        )
        return try response.fittingByteBudget(Self.budget(for: .search(options)))
    }

    private func searchHit(_ hit: HistoryIPCSearchHit, caller: HistoryIPCCaller) -> HistorySearchIPCHit {
        let session = hit.session
        return HistorySearchIPCHit(
            agent: session.agent.rawValue,
            sessionId: session.nativeID,
            title: Self.cappedTitle(session.title),
            cwd: session.cwd,
            branch: session.branch,
            updatedAt: HistoryIPCDates.iso8601(milliseconds: session.updatedAtMs),
            live: caller.liveKeys.contains(session.key),
            match: hit.match.map(Self.cappedMatch),
            resumeCommand: AgentHistoryResumeCommandBuilder.command(for: AgentHistoryResumeSource(summary: session))
        )
    }

    // MARK: - Show

    private func show(
        _ options: HistoryShowIPCOptions,
        scope: AgentHistoryScope,
        caller: HistoryIPCCaller,
        dataSource: any HistoryIPCDataSource
    ) throws -> HistoryShowIPCResponse {
        let agent = options.agent.flatMap(AgentHistoryAgent.init(rawValue:))
        let candidates = try mapped(sessionID: options.sessionID) {
            try dataSource.sessions(nativeID: options.sessionID, agent: agent, scope: scope)
        }
        var outOfScope = 0
        let admitted = candidates.filter { session in
            let check = Self.admits(session, scope: scope, exclusions: caller.exclusions)
            if !check.inScope {
                outOfScope += 1
            }
            return check.inScope && !check.excluded
        }
        if outOfScope > 0 {
            AgentHistoryLog.search.fault("IPC show dropped \(outOfScope, privacy: .public) out-of-scope sessions")
        }
        // The most recently updated duplicate; ties go to the older row.
        guard let session = admitted.max(by: { lhs, rhs in
            lhs.updatedAtMs != rhs.updatedAtMs ? lhs.updatedAtMs < rhs.updatedAtMs : lhs.id > rhs.id
        }) else {
            throw HistoryIPCError.notFound(options.sessionID)
        }

        let page = try mapped(sessionID: options.sessionID) {
            try dataSource.lastTurns(sessionRowID: session.id, limit: options.turns)
        }
        let turns = page.turns.suffix(options.turns).map { record in
            let text = HistoryIPCText.truncateUTF8(record.text, maxBytes: HistoryIPC.maxTurnBytes)
            return HistoryIPCTurn(
                role: record.role.rawValue,
                at: HistoryIPCDates.iso8601(milliseconds: record.atMs),
                text: text.text,
                truncated: text.truncated
            )
        }
        let response = HistoryShowIPCResponse(
            scope: Self.scopeName(scope),
            project: Self.projectKey(scope),
            agent: session.agent.rawValue,
            sessionId: session.nativeID,
            title: Self.cappedTitle(session.title),
            cwd: session.cwd,
            branch: session.branch,
            model: session.model,
            effort: session.effort,
            createdAt: HistoryIPCDates.iso8601(milliseconds: session.createdAtMs),
            updatedAt: HistoryIPCDates.iso8601(milliseconds: session.updatedAtMs),
            live: caller.liveKeys.contains(session.key),
            totalTurns: max(page.total, turns.count),
            omittedTurns: max(0, page.total - turns.count),
            turns: Array(turns),
            resumeCommand: AgentHistoryResumeCommandBuilder.command(for: AgentHistoryResumeSource(summary: session)),
            contentIsUntrusted: true
        )
        return try response.fittingByteBudget(Self.budget(for: .show(options)))
    }

    // MARK: - Helpers

    /// Runs a data-source read and turns its errors into `HistoryIPCError`s.
    private func mapped<T>(sessionID: String? = nil, _ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch let error as HistoryIPCError {
            throw error
        } catch HistorySearchError.cancelled {
            throw HistoryIPCError.timedOut
        } catch HistorySearchError.indexUnavailable(let state) {
            // "off": History was turned off (or its index deleted) after the availability check.
            throw state == "off" ? HistoryIPCError.disabled : HistoryIPCError.unavailable(HistoryIPCMessages.readFailed)
        } catch HistorySearchError.sessionNotFound {
            if let sessionID {
                throw HistoryIPCError.notFound(sessionID)
            }
            throw HistoryIPCError.unavailable(HistoryIPCMessages.readFailed)
        } catch {
            throw HistoryIPCError.unavailable(HistoryIPCMessages.readFailed)
        }
    }

    private static func budget(for command: HistoryIPCCommand) -> Int {
        command.maxResponseBytes - HistoryIPC.responseHeadroomBytes
    }

    private static func scopeName(_ scope: AgentHistoryScope) -> String {
        switch scope {
        case .all: "all"
        case .project: "project"
        }
    }

    private static func projectKey(_ scope: AgentHistoryScope) -> String? {
        switch scope {
        case .all: nil
        case .project(let project): project.key
        }
    }

    private static func cappedTitle(_ title: String) -> String {
        title.count > maxTitleCharacters ? String(title.prefix(maxTitleCharacters - 1)) + "…" : title
    }

    private static func cappedMatch(_ match: HistoryIPCMatch) -> HistoryIPCMatch {
        guard let field = match.field, let value = match.value else {
            return match
        }
        return .metadata(field: field, value: cappedTitle(value))
    }

    static let dispatchDeadline: DeadlineScheduler = { interval, handler in
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return { timer.cancel() }
    }
}
