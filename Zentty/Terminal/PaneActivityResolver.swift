import Foundation

/// How a pane is presented on the canvas. Tiles live in the strip; the other
/// cases mirror `FloatingPaneMode` without its geometry.
enum PanePresentationMode: Equatable, Sendable {
    case tile
    case floating
    case pip
    case minimized

    init(_ floatMode: FloatingPaneMode) {
        switch floatMode {
        case .floating:
            self = .floating
        case .pip:
            self = .pip
        case .minimized:
            self = .minimized
        }
    }
}

struct PaneActivityInput: Equatable, Sendable {
    var mode: PanePresentationMode
    var floatsHidden: Bool
    var isActiveWorklane: Bool
    /// The worklane is rendered as a Worklane Peek preview.
    var isPeekVisible: Bool
    var windowIsVisible: Bool
    var windowIsKey: Bool
    /// The pane is its worklane's float-aware `focusedPaneID`.
    var isFocusedPane: Bool
    /// A Worklane Peek session is open in the window. The float layer is
    /// hidden while it is, so floats and PiPs are not drawn.
    var isPeekOpen: Bool = false
}

/// Decides Ghostty occlusion and focus for one pane. The registry recomputes
/// this for every live pane on each pass, so a one-off occlusion (e.g. on
/// minimize) would be overwritten; mode-driven rules live here instead.
///
/// - tile: visible when the window is visible and the worklane is active or
///   peek-visible; focused when also active, key and the focused pane.
/// - floating: visible only in the active worklane (peek previews render the
///   strip, not floats), only while floats are shown and never while a peek
///   is open (the float layer is hidden then); focused like a tile.
/// - pip: visible like a floating pane, never focused.
/// - minimized: never visible, never focused.
///
/// Every mode keeps its runtime live: putting a pane away never ends its process.
enum PaneActivityResolver {
    static func activity(for input: PaneActivityInput) -> TerminalSurfaceActivity {
        let isVisible: Bool
        let canTakeFocus: Bool
        switch input.mode {
        case .tile:
            isVisible = input.windowIsVisible && (input.isActiveWorklane || input.isPeekVisible)
            canTakeFocus = true
        case .floating:
            isVisible = Self.floatLayerIsDrawn(for: input)
            canTakeFocus = true
        case .pip:
            isVisible = Self.floatLayerIsDrawn(for: input)
            canTakeFocus = false
        case .minimized:
            isVisible = false
            canTakeFocus = false
        }

        let isFocused = canTakeFocus
            && isVisible
            && input.windowIsKey
            && input.isActiveWorklane
            && input.isFocusedPane
        return TerminalSurfaceActivity(
            keepsRuntimeLive: true,
            isVisible: isVisible,
            isFocused: isFocused
        )
    }

    private static func floatLayerIsDrawn(for input: PaneActivityInput) -> Bool {
        input.windowIsVisible && input.isActiveWorklane && !input.floatsHidden && !input.isPeekOpen
    }
}
