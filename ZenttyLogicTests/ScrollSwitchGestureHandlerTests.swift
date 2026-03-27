import XCTest
@testable import Zentty

@MainActor
final class ScrollSwitchGestureHandlerTests: XCTestCase {
    private var handler: ScrollSwitchGestureHandler!

    override func setUp() {
        super.setUp()
        handler = ScrollSwitchGestureHandler()
    }

    // MARK: - Basic threshold tests

    func test_small_horizontal_scroll_returns_none() {
        // With precise scrolling, threshold is 40. A delta of 5 should not trigger.
        let event = MockScrollEvent(
            scrollingDeltaX: 5,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .none)
    }

    func test_large_horizontal_scroll_right_returns_switchRight() {
        // Positive horizontal scroll should reveal the pane on the right.
        let event = MockScrollEvent(
            scrollingDeltaX: 50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchRight)
    }

    func test_large_horizontal_scroll_left_returns_switchLeft() {
        let event = MockScrollEvent(
            scrollingDeltaX: -50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchLeft)
    }

    func test_wheel_threshold_is_lower() {
        // Non-precise (wheel) threshold is 1
        let event = MockScrollEvent(
            scrollingDeltaX: 2,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: false,
            phase: [],
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchRight)
    }

    func test_reset_clears_accumulated_state() {
        // Accumulate some delta but not enough to trigger
        let partial = MockScrollEvent(
            scrollingDeltaX: 20,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )
        _ = handler.handle(scrollEvent: partial.asNSEvent)

        handler.reset()

        // Another partial should not reach threshold since state was reset
        let result = handler.handle(scrollEvent: partial.asNSEvent)
        XCTAssertEqual(result, .none)
    }

    func test_vertical_scroll_without_shift_returns_none() {
        let event = MockScrollEvent(
            scrollingDeltaX: 0,
            scrollingDeltaY: 50,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .none)
    }

    func test_negative_delta_returns_switchLeft() {
        // Negative accumulated delta means reveal the pane on the left.
        let event = MockScrollEvent(
            scrollingDeltaX: -50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchLeft)
    }

    func test_began_phase_resets_gesture() {
        // Accumulate partial delta
        let partial = MockScrollEvent(
            scrollingDeltaX: 20,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )
        _ = handler.handle(scrollEvent: partial.asNSEvent)

        // A .began event resets the accumulation
        let began = MockScrollEvent(
            scrollingDeltaX: 15,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .began,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )
        let result = handler.handle(scrollEvent: began.asNSEvent)

        // 15 alone is below 40 threshold
        XCTAssertEqual(result, .none)
    }
}

// MARK: - Mock scroll event

/// Minimal mock that creates an NSEvent with controlled scroll properties.
/// Uses CGEvent to avoid private API.
private struct MockScrollEvent {
    let scrollingDeltaX: CGFloat
    let scrollingDeltaY: CGFloat
    let hasPreciseScrollingDeltas: Bool
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase
    let isDirectionInvertedFromDevice: Bool
    let modifierFlags: NSEvent.ModifierFlags

    var asNSEvent: NSEvent {
        // Create via CGEvent for scroll wheel
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: hasPreciseScrollingDeltas ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(scrollingDeltaY),
            wheel2: Int32(scrollingDeltaX),
            wheel3: 0
        )!

        // Set precise deltas via CGEvent fields
        if hasPreciseScrollingDeltas {
            cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(scrollingDeltaX))
            cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(scrollingDeltaY))
        }

        // Set phase
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))

        // Set direction inversion
        cgEvent.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: hasPreciseScrollingDeltas ? 1 : 0
        )
        cgEvent.setIntegerValueField(
            .scrollWheelEventScrollCount,
            value: isDirectionInvertedFromDevice ? 1 : 0
        )

        if !modifierFlags.isEmpty {
            cgEvent.flags = CGEventFlags(rawValue: UInt64(modifierFlags.rawValue))
        }

        return NSEvent(cgEvent: cgEvent)!
    }
}
