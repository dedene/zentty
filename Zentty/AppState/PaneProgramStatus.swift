import Foundation

/// Status a program sets for its own pane by printing the OSC 9;4 progress
/// sequence: no CLI, hooks or manifest. Panes running an agent ignore it,
/// because the agent's own status always wins.
///
/// | OSC 9;4 state       | Program status            |
/// |---------------------|---------------------------|
/// | 0 remove            | cleared                   |
/// | 1 set (with %)      | working, with percentage  |
/// | 2 error             | error                     |
/// | 3 indeterminate     | working                   |
/// | 4 pause             | paused (needs attention)  |
struct PaneProgramStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case working
        case paused
        case error
    }

    /// Pane events that end some or all program states.
    enum ClearTrigger: Equatable, Sendable {
        /// The shell prompt came back: the foreground command is done.
        case commandFinished
        /// The shell started a new command.
        case commandStarted
        /// A fresh shell came up in the pane.
        case shellReady
        /// The user pressed Return in the pane.
        case userSubmittedInput
        /// The user pressed Ctrl+C in the pane.
        case userInterrupted
    }

    /// A working status that sees no new report for this long is dropped,
    /// so a program that dies without a prompt coming back (a remote shell
    /// without shell integration, say) can't leave a spinner behind.
    static let staleInterval: TimeInterval = 5 * 60

    var state: State
    /// 0...100 when the program reported a percentage.
    var percent: UInt8?
    var updatedAt: Date
    /// Set once the prompt came back after this error: the error belongs to
    /// a finished run, so the next command may drop it.
    var outlivedPrompt = false

    init(state: State, percent: UInt8? = nil, updatedAt: Date) {
        self.state = state
        self.percent = percent.map { min($0, 100) }
        self.updatedAt = updatedAt
    }

    /// The status a progress report sets, or nil when it clears the status.
    init?(report: TerminalProgressReport, now: Date) {
        switch report.state {
        case .remove:
            return nil
        case .set:
            self.init(state: .working, percent: report.progress, updatedAt: now)
        case .indeterminate:
            self.init(state: .working, updatedAt: now)
        case .error:
            self.init(state: .error, updatedAt: now)
        case .pause:
            self.init(state: .paused, updatedAt: now)
        }
    }

    /// What is left of this status after `trigger`. An error outlives the
    /// prompt so a failed run stays visible until the next command; a
    /// working status survives Return because programs read input while
    /// they run. A starting command only drops an error that already
    /// outlived a prompt: the shell's "command started" signal can land
    /// after the new program's first report, which may itself be an error.
    func surviving(_ trigger: ClearTrigger) -> PaneProgramStatus? {
        switch trigger {
        case .shellReady, .userInterrupted:
            return nil
        case .commandStarted:
            return state == .error && outlivedPrompt ? nil : self
        case .commandFinished:
            guard state == .error else {
                return nil
            }

            var finished = self
            finished.outlivedPrompt = true
            return finished
        case .userSubmittedInput:
            return state == .working ? self : nil
        }
    }

    func isStale(now: Date) -> Bool {
        state == .working && now.timeIntervalSince(updatedAt) >= Self.staleInterval
    }

    var statusText: String {
        switch state {
        case .working:
            return "Running"
        case .paused:
            return "Paused"
        case .error:
            return "Error"
        }
    }

    /// Status line text while presented. A percentage below 100 rides along
    /// as the suffix the sidebar turns into a progress ring.
    var presentedStatusText: String {
        guard let taskProgress else {
            return statusText
        }

        return statusText + taskProgress.statusSuffix
    }

    var symbolName: String? {
        switch state {
        case .working:
            return nil
        case .paused:
            return "pause.circle"
        case .error:
            return "exclamationmark.circle"
        }
    }

    /// Progress ring for a working status that reported a percentage.
    var taskProgress: PaneAgentTaskProgress? {
        guard state == .working, let percent, percent < 100 else {
            return nil
        }

        return PaneAgentTaskProgress(percent: Int(percent))
    }

    /// Name shown where the status needs an owner, such as the notification
    /// inbox: the foreground program, else the command the shell last ran.
    static func programName(metadata: TerminalMetadata?, lastRunCommand: String?) -> String {
        if let processName = WorklaneContextFormatter.trimmed(metadata?.processName),
           !WorklaneContextFormatter.isGenericShellIdentity(processName) {
            return processName
        }

        if let command = WorklaneContextFormatter.trimmed(lastRunCommand),
           let executable = command.split(whereSeparator: \.isWhitespace).first(where: { !$0.contains("=") }) {
            let name = (String(executable) as NSString).lastPathComponent
            if !name.isEmpty {
                return name
            }
        }

        return "Terminal"
    }
}
