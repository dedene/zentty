import Foundation

/// What a quick-action overlay is doing and where, for its sidebar line.
/// Overlays live outside the worklane store, so they keep this state
/// themselves: from the terminal's metadata and events, and from the shell
/// integration's `pane-context` and `shell-state` signals sent under the
/// overlay's own ID.
@MainActor
final class TerminalOverlayActivity {
    private(set) var exitCode: Int?
    var onChange: (() -> Void)?

    private var auxiliaryState = PaneAuxiliaryState()
    private let sessionWorkingDirectory: String?
    private let gitContextResolver: any PaneGitContextResolving
    private var gitContextTask: Task<Void, Never>?
    private var gitContextDirectory: String?
    private var isStopped = false

    init(
        command: String,
        workingDirectory: String?,
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver()
    ) {
        sessionWorkingDirectory = workingDirectory
        self.gitContextResolver = gitContextResolver
        if let command = WorklaneContextFormatter.trimmed(command) {
            auxiliaryState.raw.metadata = TerminalMetadata(title: command, currentWorkingDirectory: workingDirectory)
            auxiliaryState.raw.shellActivityState = .commandRunning
            auxiliaryState.raw.lastRunCommand = command
        }
        refreshPresentation(notify: false)
    }

    var workingDirectory: String? { auxiliaryState.presentation.cwd }
    var branch: String? { auxiliaryState.presentation.branchDisplayText }
    var isRunning: Bool { auxiliaryState.raw.shellActivityState == .commandRunning }
    /// The command running right now: the overlay's own, or one typed into its shell.
    var runningCommand: String? { isRunning ? auxiliaryState.raw.lastRunCommand : nil }

    func start() {
        refreshGitContext()
    }

    func stop() {
        isStopped = true
        gitContextTask?.cancel()
    }

    func observe(metadata: TerminalMetadata) {
        guard !isStopped else { return }
        auxiliaryState.raw.metadata = metadata
        refreshPresentation()
        refreshGitContext()
    }

    func observe(event: TerminalEvent) {
        guard !isStopped else { return }
        switch event {
        case .commandFinished(let code, _):
            exitCode = code
            auxiliaryState.raw.shellActivityState = .promptIdle
            auxiliaryState.raw.hasCommandHistory = true
            refreshGitContext(force: true)
        case .shellReady:
            auxiliaryState.raw.shellActivityState = .promptIdle
        case .userSubmittedInput:
            exitCode = nil
            auxiliaryState.raw.shellActivityState = .commandRunning
        case .progressReport(let progress):
            auxiliaryState.raw.terminalProgress = progress
        default:
            return
        }
        refreshPresentation()
    }

    /// Applies the shell integration's location and activity signals; agent
    /// status is ignored, since overlays carry no agent state.
    func apply(_ payload: AgentStatusPayload) {
        guard !isStopped else { return }
        switch payload.signalKind {
        case .paneContext:
            if payload.clearsPaneContext {
                auxiliaryState.raw.shellContext = nil
            } else if let paneContext = payload.paneContext {
                auxiliaryState.raw.shellContext = paneContext
            } else {
                return
            }
            refreshPresentation()
            refreshGitContext()
        case .shellState:
            guard let state = payload.shellActivityState else { return }
            if state == .commandRunning {
                guard WorklaneStore.shouldRecordShellCommandHistory(payload) else { return }
                auxiliaryState.raw.lastRunCommand = WorklaneStore.trimmedShellCommand(payload.shellCommand)
                auxiliaryState.raw.hasCommandHistory = true
                exitCode = nil
            }
            let finishedCommand = auxiliaryState.raw.shellActivityState == .commandRunning && state != .commandRunning
            auxiliaryState.raw.shellActivityState = state
            refreshPresentation()
            if finishedCommand {
                refreshGitContext(force: true)
            }
        default:
            return
        }
    }

    private func refreshPresentation(notify: Bool = true) {
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "Shell", raw: auxiliaryState.raw, previous: auxiliaryState.presentation,
            sessionRequestWorkingDirectory: sessionWorkingDirectory
        )
        if notify { onChange?() }
    }

    private func refreshGitContext(force: Bool = false) {
        let directory = auxiliaryState.presentation.cwd
        guard force || directory != gitContextDirectory else { return }
        gitContextTask?.cancel()
        gitContextDirectory = directory
        auxiliaryState.raw.gitContext = nil
        guard let directory else { return }
        gitContextTask = Task { [weak self] in
            let context = await self?.gitContextResolver.resolve(for: directory)
            guard !Task.isCancelled, let context, let self, !self.isStopped,
                  self.gitContextDirectory == directory else { return }
            self.auxiliaryState.raw.gitContext = context
            self.refreshPresentation()
        }
    }
}
