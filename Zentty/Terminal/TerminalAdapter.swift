import AppKit

enum TerminalSurfaceContext: Equatable, Sendable {
    case window
    case tab
    case split
}

struct TerminalSessionRequest: Equatable, Sendable {
    var workingDirectory: String?
    var inheritFromPaneID: PaneID?
    var configInheritanceSourcePaneID: PaneID?
    var surfaceContext: TerminalSurfaceContext
    var environmentVariables: [String: String]

    init(workingDirectory: String?) {
        self.init(workingDirectory: workingDirectory, inheritFromPaneID: nil)
    }

    init(
        workingDirectory: String? = nil,
        inheritFromPaneID: PaneID? = nil,
        configInheritanceSourcePaneID: PaneID? = nil,
        surfaceContext: TerminalSurfaceContext = .split,
        environmentVariables: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.inheritFromPaneID = inheritFromPaneID
        self.configInheritanceSourcePaneID = configInheritanceSourcePaneID
        self.surfaceContext = surfaceContext
        self.environmentVariables = environmentVariables
    }
}

struct TerminalSurfaceActivity: Equatable, Sendable {
    var keepsRuntimeLive: Bool
    var isVisible: Bool
    var isFocused: Bool

    init(
        keepsRuntimeLive: Bool = true,
        isVisible: Bool = true,
        isFocused: Bool = false
    ) {
        self.keepsRuntimeLive = keepsRuntimeLive
        self.isVisible = isVisible
        self.isFocused = isFocused
    }
}

struct TerminalProgressReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case remove
        case set
        case error
        case indeterminate
        case pause

        var indicatesActivity: Bool {
            switch self {
            case .remove:
                return false
            case .set, .error, .indeterminate, .pause:
                return true
            }
        }
    }

    var state: State
    var progress: UInt8?
}

struct TerminalDesktopNotification: Equatable, Sendable {
    var title: String?
    var body: String?
}

enum TerminalEvent: Equatable, Sendable {
    case progressReport(TerminalProgressReport)
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
    case desktopNotification(TerminalDesktopNotification)
    case userSubmittedInput
}

@MainActor
protocol TerminalAdapter: AnyObject {
    var hasScrollback: Bool { get }
    var cellWidth: CGFloat { get }
    var cellHeight: CGFloat { get }
    func makeTerminalView() -> NSView
    func startSession(using request: TerminalSessionRequest) throws
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity)
    func close()
    var metadataDidChange: ((TerminalMetadata) -> Void)? { get set }
    var eventDidOccur: ((TerminalEvent) -> Void)? { get set }
}

@MainActor
protocol TerminalFocusReporting: AnyObject {
    var onFocusDidChange: ((Bool) -> Void)? { get set }
}

@MainActor
protocol TerminalFocusTargetProviding: AnyObject {
    var terminalFocusTargetView: NSView { get }
}

@MainActor
protocol TerminalSessionInheritanceConfiguring: AnyObject {
    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    )
}
