import AppKit

/// Listens for the local input events that drive the Worklane Peek while
/// it's armed or open: subsequent Tab/Shift-Tab presses, Escape, Ctrl release,
/// pointer capture, and trackpad scroll gestures.
///
/// Lifecycle contract: callers MUST balance every `install()` with an
/// `uninstall()` once the gesture ends. While installed, the monitor swallows
/// Tab and Escape in `targetWindow`. Modifier changes stay app-wide, so a Ctrl
/// release seen in another window of the app still ends the gesture.
@MainActor
final class WorklanePeekKeyMonitor {
    enum Event: Equatable {
        case tab(forward: Bool)   // forward = Tab without Shift
        case escape
        case ctrlReleased
        case mouseDown(locationInWindow: CGPoint)
        case mouseDragged
        case mouseUp
        case spatialSwipe(WorklanePeekSpatialDirection)
    }

    /// Pure-function input for `processFlagsChanged`, decoupled from `NSEvent`
    /// so the dispatch logic can be unit-tested.
    struct ModifierSnapshot: Equatable {
        let containsControl: Bool
    }

    struct KeySnapshot: Equatable {
        let keyCode: UInt16
        let containsControl: Bool
        let containsShift: Bool
        let isPeeking: Bool
    }

    enum MouseKind: Equatable {
        case down
        case dragged
        case up
    }

    /// Pure-function input for pointer events. The AppKit monitor consumes
    /// every matching mouse event while peek is armed/open; only mouseDown
    /// carries a point because it can preview-select a pane.
    struct MouseSnapshot: Equatable {
        let kind: MouseKind
        let locationInWindow: CGPoint
    }

    /// Tab key code (US layout); stable across modern macOS releases.
    private static let tabKeyCode: UInt16 = 48
    /// Escape key code.
    private static let escapeKeyCode: UInt16 = 53
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126

    private var monitor: Any?
    private let scrollGestureHandler = WorklanePeekScrollGestureHandler()

    /// Tracks whether Ctrl was held during the previous flagsChanged event so
    /// `.ctrlReleased` only fires on the held → not-held transition. Without
    /// this, any modifier change that doesn't include Ctrl (e.g., Caps Lock
    /// toggle, Fn press, Shift release) would synthesize a stray release.
    private var wasCtrlDown = false

    weak var targetWindow: NSWindow?
    var isPeeking = false

    /// Set before calling `install()`. Each handler call corresponds to one
    /// matched key event; the monitor swallows Tab/Escape so they don't reach
    /// the regular responder chain.
    var handler: ((Event) -> Void)?

    func install() {
        guard monitor == nil else { return }
        // The gesture begins with Ctrl held (the user just hit Ctrl+Tab), so
        // seed the edge tracker as down.
        wasCtrlDown = true
        scrollGestureHandler.reset()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .keyDown,
                .flagsChanged,
                .leftMouseDown,
                .leftMouseDragged,
                .leftMouseUp,
                .rightMouseDown,
                .rightMouseDragged,
                .rightMouseUp,
                .otherMouseDown,
                .otherMouseDragged,
                .otherMouseUp,
                .scrollWheel,
            ]
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
        targetWindow = nil
        isPeeking = false
        scrollGestureHandler.reset()
    }

    /// Pure dispatch for flagsChanged events. Returns the event to emit, if
    /// any, given the previous Ctrl state. Mutates `wasCtrlDown` to track the
    /// edge.
    func processFlagsChanged(_ snapshot: ModifierSnapshot) -> Event? {
        defer { wasCtrlDown = snapshot.containsControl }
        guard wasCtrlDown, !snapshot.containsControl else { return nil }
        return .ctrlReleased
    }

    func processKeyDown(_ snapshot: KeySnapshot) -> Event? {
        switch snapshot.keyCode {
        case Self.tabKeyCode:
            guard snapshot.containsControl else { return nil }
            return .tab(forward: !snapshot.containsShift)
        case Self.escapeKeyCode:
            return .escape
        case Self.leftArrowKeyCode:
            guard snapshot.containsControl, snapshot.isPeeking else { return nil }
            return .spatialSwipe(.left)
        case Self.rightArrowKeyCode:
            guard snapshot.containsControl, snapshot.isPeeking else { return nil }
            return .spatialSwipe(.right)
        case Self.upArrowKeyCode:
            guard snapshot.containsControl, snapshot.isPeeking else { return nil }
            return .spatialSwipe(.up)
        case Self.downArrowKeyCode:
            guard snapshot.containsControl, snapshot.isPeeking else { return nil }
            return .spatialSwipe(.down)
        default:
            return nil
        }
    }

    func processMouseEvent(_ snapshot: MouseSnapshot) -> Event {
        switch snapshot.kind {
        case .down:
            return .mouseDown(locationInWindow: snapshot.locationInWindow)
        case .dragged:
            return .mouseDragged
        case .up:
            return .mouseUp
        }
    }

    func processScrollEvent(_ event: NSEvent) -> Event? {
        guard let direction = scrollGestureHandler.handle(scrollEvent: event) else {
            return nil
        }
        return .spatialSwipe(direction)
    }

    func process(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            guard shouldProcessWindowScopedEvent(event) else { return event }
            let emitted = processKeyDown(.init(
                keyCode: event.keyCode,
                containsControl: event.modifierFlags.contains(.control),
                containsShift: event.modifierFlags.contains(.shift),
                isPeeking: isPeeking
            ))
            if let emitted {
                handler?(emitted)
                return nil
            }
            return event
        case .flagsChanged:
            let snapshot = ModifierSnapshot(
                containsControl: event.modifierFlags.contains(.control)
            )
            if let emitted = processFlagsChanged(snapshot) {
                handler?(emitted)
            }
            return event
        case .leftMouseDown:
            guard shouldProcessWindowScopedEvent(event) else { return event }
            handler?(processMouseEvent(.init(kind: .down, locationInWindow: event.locationInWindow)))
            return nil
        case .rightMouseDown, .otherMouseDown:
            guard shouldProcessWindowScopedEvent(event) else { return event }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard shouldProcessWindowScopedEvent(event) else { return event }
            handler?(processMouseEvent(.init(kind: .dragged, locationInWindow: event.locationInWindow)))
            return nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard shouldProcessWindowScopedEvent(event) else { return event }
            handler?(processMouseEvent(.init(kind: .up, locationInWindow: event.locationInWindow)))
            return nil
        case .scrollWheel:
            guard shouldProcessWindowScopedEvent(event) else { return event }
            if let emitted = processScrollEvent(event) {
                handler?(emitted)
            }
            return nil
        default:
            return event
        }
    }

    private func shouldProcessWindowScopedEvent(_ event: NSEvent) -> Bool {
        Self.isWindowScoped(eventWindow: event.window, keyWindow: NSApp.keyWindow, targetWindow: targetWindow)
    }

    /// Whether an event belongs to the peek's window. An event with no window
    /// counts as the key window's.
    static func isWindowScoped(eventWindow: NSWindow?, keyWindow: NSWindow?, targetWindow: NSWindow?) -> Bool {
        guard let targetWindow else { return true }
        return eventWindow === targetWindow || eventWindow == nil && keyWindow === targetWindow
    }
}

@MainActor
private final class WorklanePeekScrollGestureHandler {
    private enum Axis {
        case horizontal
        case vertical
    }

    private enum Threshold {
        static let precise: CGFloat = 40
        static let wheel: CGFloat = 1
    }

    private var activeAxis: Axis?
    private var accumulatedDelta: CGFloat = 0
    private var hasTriggeredInGesture = false
    private var requiresFreshPreciseGestureStart = false

    func handle(scrollEvent event: NSEvent) -> WorklanePeekSpatialDirection? {
        guard event.momentumPhase == [] else {
            return nil
        }

        if shouldResetGesture(for: event) {
            reset()
        }

        guard let axis = resolvedAxis(for: event) else {
            if shouldEndGesture(for: event) {
                reset(requiresFreshPreciseGestureStart: activeAxis != nil || accumulatedDelta != 0 || hasTriggeredInGesture)
            }
            return nil
        }

        if activeAxis == nil {
            guard !requiresFreshPreciseGestureStart || shouldResetGesture(for: event) else {
                return nil
            }
            activeAxis = axis
            accumulatedDelta = 0
            hasTriggeredInGesture = false
        }

        guard activeAxis == axis else {
            return nil
        }

        if event.hasPreciseScrollingDeltas {
            let direction = handlePreciseScroll(event, axis: axis)
            if shouldEndGesture(for: event) {
                reset(requiresFreshPreciseGestureStart: true)
            }
            return direction
        } else {
            return handleWheelScroll(event, axis: axis)
        }
    }

    func reset() {
        reset(requiresFreshPreciseGestureStart: false)
    }

    private func reset(requiresFreshPreciseGestureStart: Bool) {
        activeAxis = nil
        accumulatedDelta = 0
        hasTriggeredInGesture = false
        self.requiresFreshPreciseGestureStart = requiresFreshPreciseGestureStart
    }

    private func handlePreciseScroll(_ event: NSEvent, axis: Axis) -> WorklanePeekSpatialDirection? {
        guard !hasTriggeredInGesture else { return nil }

        accumulatedDelta += scrollDelta(for: event, axis: axis)
        guard abs(accumulatedDelta) >= Threshold.precise else {
            return nil
        }

        hasTriggeredInGesture = true
        return direction(for: accumulatedDelta, axis: axis)
    }

    private func handleWheelScroll(_ event: NSEvent, axis: Axis) -> WorklanePeekSpatialDirection? {
        let delta = scrollDelta(for: event, axis: axis)
        guard abs(delta) >= Threshold.wheel else { return nil }
        return direction(for: delta, axis: axis)
    }

    private func resolvedAxis(for event: NSEvent) -> Axis? {
        let horizontalDelta = abs(event.scrollingDeltaX)
        let verticalDelta = abs(event.scrollingDeltaY)

        if horizontalDelta > verticalDelta, horizontalDelta > 0 {
            return .horizontal
        }
        if verticalDelta > 0, verticalDelta >= horizontalDelta {
            return .vertical
        }
        return nil
    }

    private func scrollDelta(for event: NSEvent, axis: Axis) -> CGFloat {
        let inversionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        switch axis {
        case .horizontal:
            return event.scrollingDeltaX * inversionMultiplier
        case .vertical:
            return event.scrollingDeltaY * inversionMultiplier
        }
    }

    private func direction(for delta: CGFloat, axis: Axis) -> WorklanePeekSpatialDirection {
        switch axis {
        case .horizontal:
            return delta > 0 ? .right : .left
        case .vertical:
            return delta > 0 ? .down : .up
        }
    }

    private func shouldResetGesture(for event: NSEvent) -> Bool {
        event.phase.contains(.began) || event.phase.contains(.mayBegin)
    }

    private func shouldEndGesture(for event: NSEvent) -> Bool {
        event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
    }
}
