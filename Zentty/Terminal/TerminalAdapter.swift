import AppKit
import Carbon.HIToolbox

enum TerminalSurfaceContext: Equatable, Sendable {
    case window
    case tab
    case split
}

struct TerminalSessionRequest: Equatable, Sendable {
    var workingDirectory: String?
    var command: String?
    var nativeCommand: String?
    var waitAfterNativeCommand: Bool
    var isLaunchDeferred: Bool
    var prefillText: String?
    var inheritFromPaneID: PaneID?
    var configInheritanceSourcePaneID: PaneID?
    var surfaceContext: TerminalSurfaceContext
    var environmentVariables: [String: String]

    init(workingDirectory: String?) {
        self.init(workingDirectory: workingDirectory, inheritFromPaneID: nil)
    }

    init(
        workingDirectory: String? = nil,
        command: String? = nil,
        nativeCommand: String? = nil,
        waitAfterNativeCommand: Bool = false,
        isLaunchDeferred: Bool = false,
        prefillText: String? = nil,
        inheritFromPaneID: PaneID? = nil,
        configInheritanceSourcePaneID: PaneID? = nil,
        surfaceContext: TerminalSurfaceContext = .split,
        environmentVariables: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.nativeCommand = nativeCommand
        self.waitAfterNativeCommand = waitAfterNativeCommand
        self.isLaunchDeferred = isLaunchDeferred
        self.prefillText = prefillText
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
    case shellReady
    case progressReport(TerminalProgressReport)
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
    case desktopNotification(TerminalDesktopNotification)
    case userInterrupted
    case userEditedInput
    case userSubmittedInput
    case surfaceClosed
    /// Coalesced "the terminal grid may have changed" pulse, derived from
    /// libghostty's `RENDER` action. Only emitted while a consumer has opted into
    /// content observation (see `LibghosttyContentChangeObservation`); carries no
    /// payload and is safe to ignore.
    case contentChanged
}

enum TerminalInterruptKeyRecognizer {
    static func matchesUserInterrupt(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.control] else {
            return false
        }

        let observedCharacters = [event.characters, event.charactersIgnoringModifiers]
            .compactMap { $0 }
        if observedCharacters.contains("\u{3}") {
            return true
        }

        return event.keyCode == UInt16(kVK_ANSI_C)
    }

    // Bare Escape is only meaningful as an interrupt inside a Kimi session —
    // most other TUIs (vim, fzf, lazygit, …) use Escape for navigation. Callers
    // MUST gate this recognizer on Kimi context before emitting `.userInterrupted`.
    static func matchesKimiInterruptEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.isEmpty && event.keyCode == UInt16(kVK_Escape)
    }
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

enum RemoteImagePasteSource: Equatable, Sendable {
    case keyboard
    case drag
}

@MainActor
protocol TerminalAdapter: AnyObject {
    var hasScrollback: Bool { get }
    var cellWidth: CGFloat { get }
    var cellHeight: CGFloat { get }
    func makeTerminalView() -> NSView
    func startSession(using request: TerminalSessionRequest) throws
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity)
    func sendText(_ text: String)
    func cancelPromptInput()
    func submitCommand(_ command: String)
    func close()
    var metadataDidChange: ((TerminalMetadata) -> Void)? { get set }
    var eventDidOccur: ((TerminalEvent) -> Void)? { get set }
}

@MainActor
extension TerminalAdapter {
    func cancelPromptInput() {}

    // Default for non-Libghostty adapters (mocks, tests). The Libghostty adapter
    // overrides this to send a synthetic Return key event *outside* bracketed-paste
    // wrapping, which is required for zsh to fire `accept-line` on the pasted
    // command. See LibghosttyAdapter.submitCommand.
    func submitCommand(_ command: String) {
        sendText(command + "\r")
    }
}

@MainActor
protocol TerminalTextReading: AnyObject {
    func readText(includeScrollback: Bool, lineLimit: Int?) -> String?
    /// The live terminal grid dimensions (columns × rows), or `nil` when no live
    /// surface backs the pane yet.
    var gridSize: (cols: Int, rows: Int)? { get }
}

/// Fixed-grid control-lease takeover (companion §2.6). While leased, the pane's
/// surface is sized to a phone-measured `cols`×`rows` grid instead of its
/// laid-out AppKit frame, and desktop rendering is suspended. Adopted by the
/// libghostty adapter; other adapters (mocks) inherit the no-op default.
@MainActor
protocol TerminalControlLeasing: AnyObject {
    /// Fixes the surface grid to `cols`×`rows` (pixel size = grid × cell metrics),
    /// stops honoring the frame-derived viewport, and occludes the desktop
    /// surface. Returns `false` when there is no live surface to resize.
    @discardableResult
    func applyControlLease(cols: Int, rows: Int) -> Bool
    /// Restores the frame-derived viewport and re-enables desktop rendering.
    func releaseControlLease()
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
protocol TerminalSmoothScrollConfiguring: AnyObject {
    var smoothScrollingEnabled: Bool { get set }
}

@MainActor
protocol TerminalMouseInteractionSuppressionControlling: AnyObject {
    func setMouseInteractionSuppressionRects(_ rects: [CGRect])
}

@MainActor
protocol TerminalContextMenuConfiguring: AnyObject {
    var contextMenuBuilder: ((NSEvent, NSMenu?) -> NSMenu?)? { get set }
}

@MainActor
protocol TerminalRemoteImagePasteConfiguring: AnyObject {
    var remoteImagePasteHandler: ((NSPasteboard, RemoteImagePasteSource) -> Bool)? { get set }
}

@MainActor
protocol TerminalSessionInheritanceConfiguring: AnyObject {
    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    )
}
