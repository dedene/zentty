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
    case surfaceClosed
}

enum PaneSearchHUDCorner: String, CaseIterable, Equatable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

struct PaneSearchState: Equatable, Sendable {
    var needle: String
    var selected: Int
    var total: Int
    var hasRememberedSearch: Bool
    var isHUDVisible: Bool
    var hudCorner: PaneSearchHUDCorner

    init(
        needle: String = "",
        selected: Int = -1,
        total: Int = 0,
        hasRememberedSearch: Bool = false,
        isHUDVisible: Bool = false,
        hudCorner: PaneSearchHUDCorner = .topTrailing
    ) {
        self.needle = needle
        self.selected = selected
        self.total = total
        self.hasRememberedSearch = hasRememberedSearch
        self.isHUDVisible = isHUDVisible
        self.hudCorner = hudCorner
    }
}

enum TerminalSearchEvent: Equatable, Sendable {
    case started(needle: String?)
    case ended
    case total(Int)
    case selected(Int)
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
protocol TerminalSearchControlling: AnyObject {
    var searchDidChange: ((TerminalSearchEvent) -> Void)? { get set }
    func showSearch()
    func useSelectionForFind()
    func updateSearch(needle: String)
    func findNext()
    func findPrevious()
    func endSearch()
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
protocol TerminalOverlayHosting: AnyObject {
    var terminalOverlayHostView: NSView { get }
}

@MainActor
protocol TerminalScrollRouting: AnyObject {
    var onScrollWheel: ((NSEvent) -> Bool)? { get set }
}

@MainActor
protocol TerminalMouseInteractionSuppressionControlling: AnyObject {
    func setMouseInteractionSuppressionRects(_ rects: [CGRect])
}

@MainActor
protocol TerminalSessionInheritanceConfiguring: AnyObject {
    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    )
}
