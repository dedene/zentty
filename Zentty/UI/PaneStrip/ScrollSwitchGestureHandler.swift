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
        static let postSwitchCooldown: TimeInterval = 0.15
    }

    // MARK: - Private state

    private var activeScrollSwitchAxis: ScrollSwitchAxis?
    private var accumulatedScrollSwitchDelta: CGFloat = 0
    private var hasTriggeredScrollSwitchInGesture = false
    private var requiresFreshPreciseGestureStart = false
    private var postSwitchCooldownDeadline: TimeInterval = 0

    // MARK: - Public API

    /// Processes a scroll event and returns whether a pane switch should occur.
    /// Returns `.none` if the event is not a horizontal pane-switch gesture.
    /// When `.none` is returned, the caller should forward the event to `super`.
    func handle(scrollEvent event: NSEvent) -> SwitchResult {
        if event.hasPreciseScrollingDeltas {
            return handlePreciseScroll(event)
        } else {
            return handleWheelScroll(event)
        }
    }

    func reset() {
        let shouldRequireFreshStart =
            activeScrollSwitchAxis != nil
            || accumulatedScrollSwitchDelta != 0
            || hasTriggeredScrollSwitchInGesture
            || requiresFreshPreciseGestureStart
            || isWithinPostSwitchCooldown

        resetState(
            requiresFreshPreciseGestureStart: shouldRequireFreshStart,
            preserveCooldown: isWithinPostSwitchCooldown
        )
    }

    // MARK: - Private helpers

    private func handlePreciseScroll(_ event: NSEvent) -> SwitchResult {
        let shouldEndGesture = shouldEndGesture(for: event)

        if shouldResetGesture(for: event) {
            resetState()
        } else if activeScrollSwitchAxis == nil, isWithinPostSwitchCooldown, !shouldEndGesture {
            return .consumed
        }

        guard let axis = resolvedAxis(for: event) else {
            if shouldEndGesture {
                let hadActiveGesture =
                    activeScrollSwitchAxis != nil
                    || accumulatedScrollSwitchDelta != 0
                    || hasTriggeredScrollSwitchInGesture
                    || requiresFreshPreciseGestureStart
                resetState(requiresFreshPreciseGestureStart: hadActiveGesture)
            }
            return activeScrollSwitchAxis == nil ? .none : .consumed
        }

        if activeScrollSwitchAxis == nil {
            guard !requiresFreshPreciseGestureStart else {
                if shouldEndGesture {
                    resetState(requiresFreshPreciseGestureStart: true)
                }
                return .none
            }

            activeScrollSwitchAxis = axis
            accumulatedScrollSwitchDelta = 0
            hasTriggeredScrollSwitchInGesture = false
        }

        guard activeScrollSwitchAxis == axis else {
            return .consumed
        }

        if hasTriggeredScrollSwitchInGesture {
            if shouldEndGesture {
                resetState(
                    requiresFreshPreciseGestureStart: true,
                    preserveCooldown: isWithinPostSwitchCooldown
                )
            }
            return .consumed
        }

        accumulatedScrollSwitchDelta += scrollDelta(for: event, axis: axis)
        let result: SwitchResult
        if abs(accumulatedScrollSwitchDelta) >= ScrollSwitchThreshold.precise {
            hasTriggeredScrollSwitchInGesture = true
            postSwitchCooldownDeadline = monotonicNow + ScrollSwitchThreshold.postSwitchCooldown
            result = accumulatedScrollSwitchDelta > 0 ? .switchRight : .switchLeft
        } else {
            result = .none
        }

        if shouldEndGesture {
            let preserveCooldown = result != .none && isWithinPostSwitchCooldown
            let hadActiveGesture =
                activeScrollSwitchAxis != nil
                || accumulatedScrollSwitchDelta != 0
                || hasTriggeredScrollSwitchInGesture
            resetState(
                requiresFreshPreciseGestureStart: hadActiveGesture,
                preserveCooldown: preserveCooldown
            )
        }

        return result
    }

    private func handleWheelScroll(_ event: NSEvent) -> SwitchResult {
        guard event.momentumPhase == [] else {
            return .none
        }

        guard let axis = resolvedAxis(for: event) else {
            return .none
        }

        let delta = scrollDelta(for: event, axis: axis)
        guard abs(delta) >= ScrollSwitchThreshold.wheel else {
            return .none
        }

        return delta > 0 ? .switchRight : .switchLeft
    }

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

    private var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private var isWithinPostSwitchCooldown: Bool {
        postSwitchCooldownDeadline > monotonicNow
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

    private func resetState(
        requiresFreshPreciseGestureStart: Bool = false,
        preserveCooldown: Bool = false
    ) {
        activeScrollSwitchAxis = nil
        accumulatedScrollSwitchDelta = 0
        hasTriggeredScrollSwitchInGesture = false
        self.requiresFreshPreciseGestureStart = requiresFreshPreciseGestureStart
        if !preserveCooldown {
            postSwitchCooldownDeadline = 0
        }
    }
}
