import AppKit

/// The gesture the custom window chrome should perform for a mouse-down.
///
/// The main window draws its own chrome over the native titlebar
/// (`.fullSizeContentView` + `titlebarAppearsTransparent`), so AppKit's built-in
/// titlebar double-click handling never runs there. Resolving the gesture here
/// reproduces native behavior, honoring the "Double-click a window's title bar to"
/// system setting. `AppleActionOnDoubleClick` (NSGlobalDomain) holds one of
/// `Maximize`, `Minimize`, `Fill`, `None`, or is absent (treated as Maximize).
///
/// "None" and fullscreen deliberately resolve to `.windowDrag`: a native titlebar
/// still lets the second click of a double-click start a drag, it just skips the action.
enum WindowChromeTitlebarGesture: Equatable {
    case windowDrag
    case zoom
    case fill
    case miniaturize

    static func resolve(
        clickCount: Int,
        isFullscreen: Bool,
        doubleClickActionPreference: String?
    ) -> WindowChromeTitlebarGesture {
        guard clickCount == 2, !isFullscreen else { return .windowDrag }
        switch doubleClickActionPreference {
        case "Minimize": return .miniaturize
        case "Fill": return .fill
        case "None": return .windowDrag
        default: return .zoom
        }
    }
}

/// Mouse-down handling shared by the chrome's drag surfaces: clicks and drags keep
/// moving the window; double-clicks perform the system titlebar action instead.
///
/// Window-drag suppression in this app is expressed as `isMovable == false`
/// (proxy-icon hover halo, `ProxyAwareWindow`). `performDrag(with:)` already
/// honors it; zoom / fill / miniaturize do not, so it is checked here for every gesture.
@MainActor
func performWindowChromeMouseDown(_ event: NSEvent, window: NSWindow?) {
    guard let window, window.isMovable else { return }
    let gesture = WindowChromeTitlebarGesture.resolve(
        clickCount: event.clickCount,
        isFullscreen: window.styleMask.contains(.fullScreen),
        doubleClickActionPreference: window.windowChromeDoubleClickActionPreference
    )
    switch gesture {
    case .windowDrag:
        window.performDrag(with: event)
    case .zoom:
        window.performZoom(event)
    case .fill:
        window.performWindowChromeFill(event)
    case .miniaturize:
        window.performMiniaturize(event)
    }
}

extension NSWindow {
    /// The system "Double-click a window's title bar to" setting. `@objc` so tests can
    /// override it on an `NSWindow` subclass instead of writing to the global domain.
    @objc var windowChromeDoubleClickActionPreference: String? {
        UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    }

    /// Sequoia's "Fill" titlebar action. AppKit exposes no public API for it; Chromium and
    /// iTerm2 both call the private `_zoomFill:` selector behind `responds(to:)`, falling
    /// back to a regular zoom, which lands on the same screen frame minus tiling margins.
    @objc func performWindowChromeFill(_ sender: Any?) {
        let zoomFill = NSSelectorFromString("_zoomFill:")
        if responds(to: zoomFill) {
            perform(zoomFill, with: sender)
        } else {
            performZoom(sender)
        }
    }
}
