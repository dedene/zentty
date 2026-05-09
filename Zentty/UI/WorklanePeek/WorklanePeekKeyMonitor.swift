import AppKit

/// Listens for the key events that drive the Worklane Peek while
/// it's armed or open: subsequent Tab/Shift-Tab presses, Escape, and the
/// moment Ctrl is released. Owned by the controller and installed only while
/// the gesture is active so it doesn't intercept Tab outside peek.
///
/// Lifecycle contract: callers MUST balance every `install()` with an
/// `uninstall()` once the gesture ends. While installed, the monitor swallows
/// Tab and Escape app-wide.
@MainActor
final class WorklanePeekKeyMonitor {
    enum Event: Equatable {
        case tab(forward: Bool)   // forward = Tab without Shift
        case escape
        case ctrlReleased
    }

    /// Pure-function input for `processFlagsChanged`, decoupled from `NSEvent`
    /// so the dispatch logic can be unit-tested.
    struct ModifierSnapshot: Equatable {
        let containsControl: Bool
    }

    /// Tab key code (US layout); stable across modern macOS releases.
    private static let tabKeyCode: UInt16 = 48
    /// Escape key code.
    private static let escapeKeyCode: UInt16 = 53

    private var monitor: Any?

    /// Tracks whether Ctrl was held during the previous flagsChanged event so
    /// `.ctrlReleased` only fires on the held → not-held transition. Without
    /// this, any modifier change that doesn't include Ctrl (e.g., Caps Lock
    /// toggle, Fn press, Shift release) would synthesize a stray release.
    private var wasCtrlDown = false

    /// Set before calling `install()`. Each handler call corresponds to one
    /// matched key event; the monitor swallows Tab/Escape so they don't reach
    /// the regular responder chain.
    var handler: ((Event) -> Void)?

    func install() {
        guard monitor == nil else { return }
        // The gesture begins with Ctrl held (the user just hit Ctrl+Tab), so
        // seed the edge tracker as down.
        wasCtrlDown = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.process(event)
        }
    }

    func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        wasCtrlDown = false
    }

    /// Pure dispatch for flagsChanged events. Returns the event to emit, if
    /// any, given the previous Ctrl state. Mutates `wasCtrlDown` to track the
    /// edge.
    func processFlagsChanged(_ snapshot: ModifierSnapshot) -> Event? {
        defer { wasCtrlDown = snapshot.containsControl }
        guard wasCtrlDown, !snapshot.containsControl else { return nil }
        return .ctrlReleased
    }

    private func process(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            switch event.keyCode {
            case Self.tabKeyCode:
                // Defense-in-depth: only swallow Tab / Shift+Tab when Ctrl
                // is actually held. The lifecycle keeps the monitor
                // installed only during the gesture, but a stray Tab
                // arriving between Ctrl-release and uninstall must NOT be
                // consumed.
                guard event.modifierFlags.contains(.control) else { return event }
                let shifted = event.modifierFlags.contains(.shift)
                handler?(.tab(forward: !shifted))
                return nil
            case Self.escapeKeyCode:
                handler?(.escape)
                return nil
            default:
                return event
            }
        case .flagsChanged:
            let snapshot = ModifierSnapshot(
                containsControl: event.modifierFlags.contains(.control)
            )
            if let emitted = processFlagsChanged(snapshot) {
                handler?(emitted)
            }
            return event
        default:
            return event
        }
    }
}
