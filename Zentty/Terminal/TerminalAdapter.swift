import AppKit

struct TerminalSessionRequest: Equatable, Sendable {
    var workingDirectory: String?
    var inheritFromPaneID: PaneID?

    init(workingDirectory: String?) {
        self.init(workingDirectory: workingDirectory, inheritFromPaneID: nil)
    }

    init(workingDirectory: String? = nil, inheritFromPaneID: PaneID? = nil) {
        self.workingDirectory = workingDirectory
        self.inheritFromPaneID = inheritFromPaneID
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

@MainActor
protocol TerminalAdapter: AnyObject {
    func makeTerminalView() -> NSView
    func startSession(using request: TerminalSessionRequest) throws
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity)
    var metadataDidChange: ((TerminalMetadata) -> Void)? { get set }
}

@MainActor
protocol TerminalFocusReporting: AnyObject {
    var onFocusDidChange: ((Bool) -> Void)? { get set }
}

@MainActor
protocol TerminalSessionInheritanceConfiguring: AnyObject {
    func prepareSessionStart(from sourceAdapter: (any TerminalAdapter)?)
}
