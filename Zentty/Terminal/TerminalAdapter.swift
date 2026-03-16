import AppKit

struct TerminalSessionRequest: Equatable, Sendable {
    var workingDirectory: String?
    var inheritFromPaneID: PaneID?
    var environmentVariables: [String: String]

    init(workingDirectory: String?) {
        self.init(workingDirectory: workingDirectory, inheritFromPaneID: nil)
    }

    init(
        workingDirectory: String? = nil,
        inheritFromPaneID: PaneID? = nil,
        environmentVariables: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.inheritFromPaneID = inheritFromPaneID
        self.environmentVariables = environmentVariables
    }
}

struct TerminalSurfaceActivity: Equatable, Sendable {
    var isVisible: Bool
    var isFocused: Bool

    init(isVisible: Bool = true, isFocused: Bool = false) {
        self.isVisible = isVisible
        self.isFocused = isFocused
    }
}

enum TerminalEvent: Equatable, Sendable {
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
}

@MainActor
protocol TerminalAdapter: AnyObject {
    func makeTerminalView() -> NSView
    func startSession(using request: TerminalSessionRequest) throws
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity)
    var metadataDidChange: ((TerminalMetadata) -> Void)? { get set }
    var eventDidOccur: ((TerminalEvent) -> Void)? { get set }
}

@MainActor
protocol TerminalFocusReporting: AnyObject {
    var onFocusDidChange: ((Bool) -> Void)? { get set }
}

@MainActor
protocol TerminalSessionInheritanceConfiguring: AnyObject {
    func prepareSessionStart(from sourceAdapter: (any TerminalAdapter)?)
}
