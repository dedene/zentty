import Foundation

/// ↩ (primary) jumps to a live session or resumes an ended one in a new worklane; ⌘↩ (secondary)
/// forks a live session or resumes an ended one in a split.
enum AgentHistoryLaunchIntent: Equatable, Sendable {
    case primary
    case secondary
}

/// Counts opens (jump, fork, resume) for ranking. The launcher is the only caller (A-20).
protocol AgentHistoryUsageRecording: Sendable {
    func recordOpen(sessionRowID: Int64, at date: Date)
}

/// One main window as seen by the launcher: where a session can be jumped to, forked from or
/// resumed in, and where its toast shows.
@MainActor
protocol AgentHistoryWindowHost: AnyObject {
    var windowID: WindowID { get }
    var worklaneStore: WorklaneStore { get }
    var menuBarDisplayTitle: String { get }
    func navigateToPane(worklaneID: WorklaneID, paneID: PaneID)
    func forkAgentConversation(
        paneID: PaneID,
        destination: AgentForkDestination?,
        sessionOverride: AgentForkSessionOverride?
    ) throws -> WorklaneStore.AgentForkResult
    func launchInNewWorklane(_ request: PaneLaunchRequest) -> WorklaneStore.LaunchedPane
    func launchInSplitRight(_ request: PaneLaunchRequest) -> WorklaneStore.LaunchedPane?
    func showToast(message: String)
}

enum AgentHistoryLaunchOutcome: Equatable {
    case jumped(LiveAgentSessionLocation)
    case forked(WorklaneStore.AgentForkResult)
    case resumed(WorklaneStore.LaunchedPane)
    /// `git worktree add` is running; the session resumes (or a toast explains why not) later.
    case recreatingWorktree
    case needsFolderChoice(options: [AgentHistoryFolderChoice], defaultChoice: AgentHistoryFolderChoice)
    case failed(message: String, offerCopySessionID: Bool)

    /// The palette closes once the launch happened or is on its way.
    var closesPalette: Bool {
        switch self {
        case .jumped, .forked, .resumed, .recreatingWorktree:
            return true
        case .needsFolderChoice, .failed:
            return false
        }
    }
}

/// Routes an Agent History pick to the right place: a live session is jumped to (or forked) in
/// the window that runs it; an ended one resumes in the presenting window. Every path that
/// would start a process (↩, the folder sheet, a finished worktree recreation) first runs
/// `reroute`, so a session that went live, or that another History launch is still starting,
/// is never started twice (spec goal 3). The launcher alone
/// shows launch toasts and records opens, exactly once per successful launch (A-20). Failures
/// returned synchronously are not toasted: the palette shows them in place. Failures after a
/// worktree recreation are toasted in the window that asked (or any other still open), since
/// the palette has closed by then.
@MainActor
final class AgentHistoryLauncher {
    static let titleLimit = 60
    static let worktreeErrorLimit = 120
    static let splitFailedMessage = "Couldn't open a split here."
    static let noWindowMessage = "Open a Zentty window to resume this session."
    static let folderMissingMessage = "That folder no longer exists."
    static let copyCommandMessage = "Copy the resume command to run it yourself."
    static let recreatingWorktreeMessage = "Recreating worktree…"
    static let worktreeBeingRecreatedMessage = "Worktree is still being recreated."
    static let recreatedFolderMissingMessage = "Couldn't recreate the worktree: its folder is missing."
    static let stillStartingMessage = "This session is still starting. Try again in a moment."

    private let hosts: () -> [any AgentHistoryWindowHost]
    private let presentingHost: () -> (any AgentHistoryWindowHost)?
    private let liveIndex: LiveAgentSessionIndex
    private let usageRecorder: (any AgentHistoryUsageRecording)?
    private let fileSystem: any AgentHistoryFileSystemProbing
    private let worktreeCreator: any AgentHistoryWorktreeCreating
    private let worktreeReservations: AgentHistoryWorktreeReservations
    private let sessionReservations: AgentHistorySessionReservations
    private let homeDirectory: String
    private let now: () -> Date

    init(
        hosts: @escaping () -> [any AgentHistoryWindowHost],
        presentingHost: @escaping () -> (any AgentHistoryWindowHost)?,
        liveIndex: LiveAgentSessionIndex,
        usageRecorder: (any AgentHistoryUsageRecording)?,
        fileSystem: any AgentHistoryFileSystemProbing = LiveAgentHistoryFileSystem(),
        worktreeCreator: any AgentHistoryWorktreeCreating = GitWorktreeCreator(),
        worktreeReservations: AgentHistoryWorktreeReservations? = nil,
        sessionReservations: AgentHistorySessionReservations? = nil,
        homeDirectory: String = NSHomeDirectory(),
        now: @escaping () -> Date = Date.init
    ) {
        self.hosts = hosts
        self.presentingHost = presentingHost
        self.liveIndex = liveIndex
        self.usageRecorder = usageRecorder
        self.fileSystem = fileSystem
        self.worktreeCreator = worktreeCreator
        self.worktreeReservations = worktreeReservations ?? .shared
        self.sessionReservations = sessionReservations ?? .shared
        self.homeDirectory = homeDirectory
        self.now = now
    }

    func resumePlan(for source: AgentHistoryResumeSource) -> AgentHistoryResumeAvailability {
        AgentHistoryResumeCommandBuilder.availability(for: source, homeDirectory: homeDirectory)
    }

    /// The palette's ↩ / ⌘↩ on a row.
    func perform(_ intent: AgentHistoryLaunchIntent, source: AgentHistoryResumeSource) -> AgentHistoryLaunchOutcome {
        if let rerouted = reroute(intent, source: source) {
            return rerouted
        }

        let plan: AgentHistoryResumePlan
        switch resumePlan(for: source) {
        case .available(let available):
            plan = available
        case .unavailable(let reason):
            return .failed(message: reason, offerCopySessionID: true)
        }

        switch AgentHistoryFolderResolver.resolve(source, fileSystem: fileSystem) {
        case .ready(let workingDirectory):
            return launch(plan, source: source, intent: intent, workingDirectory: workingDirectory, in: presentingHost())
        case .folderGone(let options, let defaultChoice):
            return .needsFolderChoice(options: options, defaultChoice: defaultChoice)
        }
    }

    /// Resumes an ended session after the user picked where (its folder is gone).
    /// `.copyResumeCommand` is the palette's own action and never launches here.
    func resume(
        _ source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        folderChoice: AgentHistoryFolderChoice
    ) -> AgentHistoryLaunchOutcome {
        if case .copyResumeCommand = folderChoice {
            return .failed(message: Self.copyCommandMessage, offerCopySessionID: false)
        }
        // The sheet may have been open for a while: the session can have gone live since.
        if let rerouted = reroute(intent, source: source) {
            return rerouted
        }
        let plan: AgentHistoryResumePlan
        switch resumePlan(for: source) {
        case .available(let available):
            plan = available
        case .unavailable(let reason):
            return .failed(message: reason, offerCopySessionID: true)
        }

        switch folderChoice {
        case .repositoryRoot(let directory), .homeFolder(let directory):
            guard fileSystem.isDirectory(directory) else {
                return .failed(message: Self.folderMissingMessage, offerCopySessionID: false)
            }
            return launch(plan, source: source, intent: intent, workingDirectory: directory, in: presentingHost())
        case .recreateWorktree(let recreation):
            return recreateWorktree(recreation, source: source, intent: intent)
        case .copyResumeCommand:
            return .failed(message: Self.copyCommandMessage, offerCopySessionID: false)
        }
    }

    /// At most `titleLimit` characters on one line, with "…" when cut.
    static func truncatedTitle(_ title: String) -> String {
        let singleLine = title
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else {
            return "session"
        }
        guard singleLine.count > titleLimit else {
            return singleLine
        }
        return String(singleLine.prefix(titleLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Live sessions

    /// Checked right before any launch: jumps to (or forks) a session that is live now in any
    /// window, and refuses to start one another History launch is still starting. Nil means no
    /// process runs or is on its way for the session, so launching it is safe.
    private func reroute(
        _ intent: AgentHistoryLaunchIntent,
        source: AgentHistoryResumeSource
    ) -> AgentHistoryLaunchOutcome? {
        liveIndex.refreshNow()
        if let location = liveIndex.snapshot.primaryLocation(for: source.key),
           let host = host(for: location.windowID) {
            sessionReservations.releaseLaunch(source.key)
            switch intent {
            case .primary:
                return jump(to: location, in: host, source: source)
            case .secondary:
                return fork(location, in: host, source: source)
            }
        }

        switch sessionReservations.reservation(for: source.key, now: now()) {
        case nil:
            return nil
        case .recreatingWorktree:
            return .failed(message: Self.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        case .launched(let windowID, let pane, _):
            // The agent exited and its pane closed (or its window did) before it registered.
            guard let host = host(for: windowID),
                  let worklane = host.worklaneStore.worklanes.first(where: { worklane in
                      worklane.paneStripState.panes.contains { $0.id == pane.paneID }
                  })
            else {
                sessionReservations.release(source.key)
                return nil
            }
            switch intent {
            case .primary:
                host.navigateToPane(worklaneID: worklane.id, paneID: pane.paneID)
                host.showToast(message: "Jumped to \(Self.truncatedTitle(source.title))")
                recordOpen(source)
                return .resumed(WorklaneStore.LaunchedPane(worklaneID: worklane.id, paneID: pane.paneID))
            case .secondary:
                // Nothing to fork from until the agent has registered its session.
                return .failed(message: Self.stillStartingMessage, offerCopySessionID: false)
            }
        }
    }

    private func jump(
        to location: LiveAgentSessionLocation,
        in host: any AgentHistoryWindowHost,
        source: AgentHistoryResumeSource
    ) -> AgentHistoryLaunchOutcome {
        host.navigateToPane(worklaneID: location.worklaneID, paneID: location.paneID)
        host.showToast(message: "Jumped to \(Self.truncatedTitle(location.paneDisplayName))")
        recordOpen(source)
        return .jumped(location)
    }

    /// D22: no folder check; a live agent's folder exists by definition. The fork carries the
    /// session's Claude root: its new shell inherits no `CLAUDE_CONFIG_DIR` from the source pane.
    private func fork(
        _ location: LiveAgentSessionLocation,
        in host: any AgentHistoryWindowHost,
        source: AgentHistoryResumeSource
    ) -> AgentHistoryLaunchOutcome {
        let result: WorklaneStore.AgentForkResult
        do {
            result = try host.forkAgentConversation(
                paneID: location.paneID,
                destination: .splitRight,
                sessionOverride: AgentForkSessionOverride(
                    tool: location.tool,
                    sessionID: location.rawSessionID,
                    claudeConfigRoot: location.tool == .claudeCode
                        ? ClaudeConfigRoot(sourceRoot: source.sourceRoot, homeDirectory: homeDirectory)
                        : nil
                )
            )
        } catch {
            return .failed(message: error.localizedDescription, offerCopySessionID: false)
        }
        host.navigateToPane(worklaneID: result.worklaneID, paneID: result.paneID)
        let title = source.title.isEmpty ? location.paneDisplayName : source.title
        host.showToast(message: "Forked \(Self.truncatedTitle(title)) into a split")
        recordOpen(source)
        return .forked(result)
    }

    // MARK: - Ended sessions

    private func launch(
        _ plan: AgentHistoryResumePlan,
        source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        workingDirectory: String,
        in host: (any AgentHistoryWindowHost)?
    ) -> AgentHistoryLaunchOutcome {
        // git is still checking it out (or running its hooks); the recreation launches when done.
        guard !worktreeReservations.isReserved(containing: workingDirectory) else {
            return .failed(message: Self.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        }
        guard let host else {
            return .failed(message: Self.noWindowMessage, offerCopySessionID: false)
        }
        let request = PaneLaunchRequest(
            workingDirectory: workingDirectory,
            command: plan.command,
            environment: plan.environment,
            title: nil
        )
        let launched: WorklaneStore.LaunchedPane
        switch intent {
        case .primary:
            launched = host.launchInNewWorklane(request)
        case .secondary:
            guard let split = host.launchInSplitRight(request) else {
                return .failed(message: Self.splitFailedMessage, offerCopySessionID: false)
            }
            launched = split
        }
        sessionReservations.reserveLaunch(source.key, windowID: host.windowID, pane: launched, now: now())
        host.showToast(message: "Resuming \(Self.truncatedTitle(source.title))")
        recordOpen(source)
        return .resumed(launched)
    }

    private func recreateWorktree(
        _ recreation: AgentHistoryWorktreeRecreation,
        source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent
    ) -> AgentHistoryLaunchOutcome {
        guard let host = presentingHost() else {
            return .failed(message: Self.noWindowMessage, offerCopySessionID: false)
        }
        // Held until `finishRecreation`, so no second resume races git on this checkout.
        guard worktreeReservations.reserve(recreation.worktreePath) else {
            return .failed(message: Self.worktreeBeingRecreatedMessage, offerCopySessionID: false)
        }
        // Held until `finishRecreation` too, so no other folder choice resumes the session meanwhile.
        sessionReservations.reserveRecreation(source.key)
        // Resolved again on completion: the window may have closed while git ran. The launcher
        // stays alive until then (git is bounded by the creator's timeout).
        let windowID = host.windowID
        host.showToast(message: Self.recreatingWorktreeMessage)
        worktreeCreator.recreate(recreation) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishRecreation(
                        result,
                        recreation: recreation,
                        source: source,
                        intent: intent,
                        windowID: windowID
                    )
                }
            }
        }
        return .recreatingWorktree
    }

    private func finishRecreation(
        _ result: Result<Void, AgentHistoryWorktreeError>,
        recreation: AgentHistoryWorktreeRecreation,
        source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        windowID: WindowID
    ) {
        // Released before the launch below, in the same main-actor turn, so nothing slips in between.
        worktreeReservations.release(recreation.worktreePath)
        sessionReservations.release(source.key)
        let host = host(for: windowID) ?? presentingHost()
        switch result {
        case .failure(let error):
            if let exitCode = error.exitCode {
                AgentHistoryLog.indexer.error("Resume worktree recreate failed (git exit \(exitCode, privacy: .public))")
            } else {
                AgentHistoryLog.indexer.error("Resume worktree recreate failed before git finished")
            }
            host?.showToast(message: "Couldn't recreate the worktree: \(Self.firstLine(error.message))")
        case .success:
            // git can run for a while: the session may have gone live (or started) elsewhere.
            let outcome: AgentHistoryLaunchOutcome
            if let rerouted = reroute(intent, source: source) {
                outcome = rerouted
            } else {
                guard fileSystem.isDirectory(recreation.resumeDirectory) else {
                    host?.showToast(message: Self.recreatedFolderMissingMessage)
                    return
                }
                let plan: AgentHistoryResumePlan
                switch resumePlan(for: source) {
                case .available(let available):
                    plan = available
                case .unavailable(let reason):
                    host?.showToast(message: reason)
                    return
                }
                outcome = launch(
                    plan, source: source, intent: intent, workingDirectory: recreation.resumeDirectory, in: host)
            }
            // The palette closed on `.recreatingWorktree`, so a failure here has nowhere else to show.
            if case .failed(let message, _) = outcome {
                if let host {
                    host.showToast(message: message)
                } else {
                    AgentHistoryLog.indexer.info("Recreated a worktree, but no window is left to resume in")
                }
            }
        }
    }

    // MARK: - Helpers

    private func host(for windowID: WindowID) -> (any AgentHistoryWindowHost)? {
        hosts().first { $0.windowID == windowID }
    }

    private func recordOpen(_ source: AgentHistoryResumeSource) {
        guard let rowID = source.sessionRowID else {
            return
        }
        usageRecorder?.recordOpen(sessionRowID: rowID, at: now())
    }

    private static func firstLine(_ message: String) -> String {
        let line = message
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.count > worktreeErrorLimit else {
            return line
        }
        return String(line.prefix(worktreeErrorLimit)) + "…"
    }
}
