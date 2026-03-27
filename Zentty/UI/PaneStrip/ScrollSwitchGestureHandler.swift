import AppKit

/// Interprets scroll-wheel / trackpad horizontal gestures as pane-switch commands.
///
/// `PaneStripView.scrollWheel` feeds events into `handle(scrollEvent:)` and acts
/// on the returned `SwitchResult`. All accumulated state is internal; the handler
/// does not know about pane identifiers or the strip layout.
@MainActor
final class ScrollSwitchGestureHandler {

    enum SwitchResult {
        case switchLeft
        case switchRight
        case consumed
        case none
    }

    // MARK: - Private types

    private enum ScrollSwitchAxis {
        case horizontal
        case shiftedVertical
    }

    private enum ScrollSwitchThreshold {
        static let precise: CGFloat = 40
        static let wheel: CGFloat = 1
    }

    // MARK: - Private state

    private var activeScrollSwitchAxis: ScrollSwitchAxis?
    private var accumulatedScrollSwitchDelta: CGFloat = 0
    private var hasTriggeredScrollSwitchInGesture = false

    // MARK: - Public API

    /// Processes a scroll event and returns whether a pane switch should occur.
    /// Returns `.none` if the event is not a horizontal pane-switch gesture.
    /// When `.none` is returned, the caller should forward the event to `super`.
    func handle(scrollEvent event: NSEvent) -> SwitchResult {
        if shouldResetGesture(for: event) {
            resetState()
        }

        guard let axis = resolvedAxis(for: event) else {
            if shouldResetGesture(for: event) {
                resetState()
            }
            return .none
        }

        if activeScrollSwitchAxis == nil || !eventHasGesturePhases(event) {
            activeScrollSwitchAxis = axis
            accumulatedScrollSwitchDelta = 0
            hasTriggeredScrollSwitchInGesture = false
        }

        guard activeScrollSwitchAxis == axis else {
            return .consumed
        }

        if hasTriggeredScrollSwitchInGesture {
            if shouldEndGesture(for: event) {
                resetState()
            }
            return .consumed
        }

        accumulatedScrollSwitchDelta += scrollDelta(for: event, axis: axis)
        let threshold = event.hasPreciseScrollingDeltas
            ? ScrollSwitchThreshold.precise
            : ScrollSwitchThreshold.wheel

        var result: SwitchResult = .none

        if abs(accumulatedScrollSwitchDelta) >= threshold {
            hasTriggeredScrollSwitchInGesture = true
            result = accumulatedScrollSwitchDelta > 0 ? .switchRight : .switchLeft
        }

        if shouldEndGesture(for: event) || !eventHasGesturePhases(event) {
            resetState()
        }

        return result
    }

    func reset() {
        resetState()
    }

    // MARK: - Private helpers

    private func resolvedAxis(for event: NSEvent) -> ScrollSwitchAxis? {
        let horizontalDelta = abs(event.scrollingDeltaX)
        let verticalDelta = abs(event.scrollingDeltaY)

        if horizontalDelta > verticalDelta, horizontalDelta > 0 {
            return .horizontal
        }

        let deviceIndependentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !event.hasPreciseScrollingDeltas,
           deviceIndependentFlags.contains(.shift),
           verticalDelta > 0,
           verticalDelta >= horizontalDelta {
            return .shiftedVertical
        }

        return nil
    }

    private func scrollDelta(for event: NSEvent, axis: ScrollSwitchAxis) -> CGFloat {
        let inversionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        switch axis {
        case .horizontal:
            return event.scrollingDeltaX * inversionMultiplier
        case .shiftedVertical:
            return event.scrollingDeltaY * inversionMultiplier
        }
    }

    private func eventHasGesturePhases(_ event: NSEvent) -> Bool {
        event.phase != [] || event.momentumPhase != []
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

    private func resetState() {
        activeScrollSwitchAxis = nil
        accumulatedScrollSwitchDelta = 0
        hasTriggeredScrollSwitchInGesture = false
    }
}
