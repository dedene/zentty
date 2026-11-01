import Foundation

/// Whether `zentty history` can read the index right now.
enum HistoryIPCAvailability: Equatable, Sendable {
    /// Agent History is off, or the user never turned it on.
    case disabled
    /// On, but the index can't be read. The reason is the user-facing message.
    case unavailable(String)
    /// `complete` is false while the index is still backfilling.
    case ready(complete: Bool)
}

/// One search row before the service applies its own checks and formatting.
struct HistoryIPCSearchHit: Equatable, Sendable {
    let session: AgentHistorySessionSummary
    let match: HistoryIPCMatch?
}

/// One stored message, as `show` returns it.
struct HistoryIPCTurnRecord: Equatable, Sendable {
    let role: AgentHistoryRole
    let atMs: Int64
    let text: String
}

struct HistoryIPCTurnPage: Equatable, Sendable {
    /// Oldest first, newest last.
    let turns: [HistoryIPCTurnRecord]
    /// Every message the session has.
    let total: Int
}

/// The session `show` picked and its turns, from one read.
struct HistoryIPCShowPage: Equatable, Sendable {
    let session: AgentHistorySessionSummary
    let page: HistoryIPCTurnPage
}

/// The index reads behind `zentty history`. Every method may block on SQLite, so callers stay
/// off the main thread. Errors are `HistorySearchError`s.
protocol HistoryIPCDataSource: Sendable {
    func availability() -> HistoryIPCAvailability
    /// Whether `--all` is allowed right now (Settings › Agent History).
    func allowsAllProjects() -> Bool
    /// The sessions among these that search could still show right now: agent on, folder not
    /// excluded, not removed, row id still theirs. The service asks last, just before a reply
    /// leaves, because the user can narrow access while a request runs.
    func visibleSessionIDs(among sessions: [AgentHistorySessionSummary]) throws -> Set<Int64>
    /// Visible, non-excluded sessions in `scope` (the scope-local `indexedSessions`, D10 D-C).
    func visibleSessionCount(scope: AgentHistoryScope) throws -> Int
    /// Both tiers merged, best first, at most `limit`.
    func search(
        query: HistoryQuery,
        context: HistorySearchContext,
        limit: Int,
        cancellation: HistorySearchCancellation
    ) throws -> [HistoryIPCSearchHit]
    /// Among the visible sessions with this native id in `scope` (newest first), the one
    /// `choose` picks, with its last `limit` messages and its message count. Both come from one
    /// read: a session's row id can be reused by another session once it is deleted. nil when
    /// `choose` picks none.
    func show(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope,
        limit: Int,
        choose: ([AgentHistorySessionSummary]) -> AgentHistorySessionSummary?
    ) throws -> HistoryIPCShowPage?
}

/// `HistoryIPCDataSource` over `AgentHistoryController`. It touches only the controller's
/// `nonisolated` members (`threadSafeStatus`, `searchEngine`), so any thread may use it.
///
/// `@unchecked Sendable`: the stored providers are `@Sendable` and the class has no mutable
/// state.
final class AgentHistoryIPCDataSource: HistoryIPCDataSource, @unchecked Sendable {
    private let status: @Sendable () -> AgentHistoryStatus
    private let engine: @Sendable () -> HistorySearchEngine?
    private let allowsAll: @Sendable () -> Bool

    /// `allowsAllProjects` is the live setting; without one, `--all` is refused.
    init(
        status: @escaping @Sendable () -> AgentHistoryStatus,
        engine: @escaping @Sendable () -> HistorySearchEngine?,
        allowsAllProjects: @escaping @Sendable () -> Bool = { false }
    ) {
        self.status = status
        self.engine = engine
        self.allowsAll = allowsAllProjects
    }

    convenience init(controller: AgentHistoryController) {
        self.init(
            status: { controller.threadSafeStatus },
            engine: { controller.searchEngine },
            allowsAllProjects: { controller.allowsAgentsAllProjects }
        )
    }

    func availability() -> HistoryIPCAvailability {
        let status = status()
        guard status.isEnabled, status.hasConsented else {
            return .disabled
        }
        if case .failed(let reason) = status.state {
            return .unavailable(HistoryIPCMessages.unavailable(reason))
        }
        if case .paused(.configUnreadable, _) = status.state {
            return .unavailable(HistoryIPCMessages.configUnreadable)
        }
        guard engine() != nil else {
            return .unavailable(HistoryIPCMessages.starting)
        }
        return .ready(complete: status.isBackfillComplete)
    }

    func allowsAllProjects() -> Bool {
        allowsAll()
    }

    func visibleSessionIDs(among sessions: [AgentHistorySessionSummary]) throws -> Set<Int64> {
        try requireEngine().visibleSessionIDs(among: sessions)
    }

    func visibleSessionCount(scope: AgentHistoryScope) throws -> Int {
        try requireEngine().visibleSessionCount(scope: scope)
    }

    func search(
        query: HistoryQuery,
        context: HistorySearchContext,
        limit: Int,
        cancellation: HistorySearchCancellation
    ) throws -> [HistoryIPCSearchHit] {
        try requireEngine()
            .searchMerged(query, context: context, limit: limit, cancellation: cancellation)
            .map { HistoryIPCSearchHit(merged: $0, queryHasTerms: !query.terms.isEmpty) }
    }

    func show(
        nativeID: String,
        agent: AgentHistoryAgent?,
        scope: AgentHistoryScope,
        limit: Int,
        choose: ([AgentHistorySessionSummary]) -> AgentHistorySessionSummary?
    ) throws -> HistoryIPCShowPage? {
        let tail = try requireEngine().lastTurns(
            nativeID: nativeID, agent: agent, scope: scope, limit: limit, choose: choose)
        guard let tail else { return nil }
        let turns = tail.turns.map { turn in
            HistoryIPCTurnRecord(
                role: turn.role,
                atMs: Int64((turn.at.timeIntervalSince1970 * 1000).rounded()),
                text: turn.text
            )
        }
        return HistoryIPCShowPage(session: tail.session, page: HistoryIPCTurnPage(turns: turns, total: tail.total))
    }

    /// Without an engine the index is closed: History was turned off, or the storage changed.
    private func requireEngine() throws -> HistorySearchEngine {
        guard let engine = engine() else {
            throw HistorySearchError.indexUnavailable("off")
        }
        return engine
    }
}

extension HistoryIPCSearchHit {
    /// Content hits quote the message (`role`, `at`, `snippet`); artifact hits and metadata hits
    /// name the field that matched (`title`, `branch`, `repo`, `folder`, `path`, `command`,
    /// `commit`, `pr`).
    ///
    /// A metadata hit without a note matched on its title, but only when the query had terms:
    /// a filter-only query (`branch:main`, `agent:claude`) lists sessions by recency and
    /// compares nothing, so its hits carry no match at all.
    init(merged: HistoryMergedResult, queryHasTerms: Bool) {
        let match: HistoryIPCMatch?
        switch merged.match {
        case .content(.artifact(let kind), _, _, let note):
            if case .artifact(_, let value)? = note {
                match = .metadata(field: kind.rawValue, value: value)
            } else {
                match = nil
            }
        case .content(let role, let at, let snippet, _):
            // No quote without the message text (it vanished between the grade and the read):
            // an empty snippet would print a bare `You: ` line.
            if let text = snippet?.text, !text.isEmpty {
                let atMs = Int64((at.timeIntervalSince1970 * 1000).rounded())
                match = .content(
                    role: role == .user ? AgentHistoryRole.user.rawValue : AgentHistoryRole.agent.rawValue,
                    at: HistoryIPCDates.iso8601(milliseconds: atMs),
                    snippet: text
                )
            } else {
                match = nil
            }
        case .metadata(let note?):
            match = Self.metadataMatch(note)
        case .metadata(nil):
            match = queryHasTerms
                ? .metadata(field: HistoryMetadataField.title.rawValue, value: merged.session.title)
                : nil
        }
        self.init(session: merged.session, match: match)
    }

    private static func metadataMatch(_ note: HistoryMatchNote) -> HistoryIPCMatch {
        switch note {
        case .field(let field, let value):
            .metadata(field: field.rawValue, value: value)
        case .artifact(let kind, let value):
            .metadata(field: kind.rawValue, value: value)
        }
    }
}
