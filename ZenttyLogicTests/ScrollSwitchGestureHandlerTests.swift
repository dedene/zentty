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

    func test_inverted_horizontal_scroll_right_returns_switchLeft() {
        let event = MockScrollEvent(
            scrollingDeltaX: 50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: true,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchLeft)
    }

    func test_inverted_horizontal_scroll_left_returns_switchRight() {
        let event = MockScrollEvent(
            scrollingDeltaX: -50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: true,
            modifierFlags: []
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchRight)
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

    func test_shift_vertical_wheel_scroll_down_returns_switchLeft() {
        let event = MockScrollEvent(
            scrollingDeltaX: 0,
            scrollingDeltaY: -1,
            hasPreciseScrollingDeltas: false,
            phase: [],
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: [.shift]
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchLeft)
    }

    func test_shift_vertical_wheel_scroll_up_returns_switchRight() {
        let event = MockScrollEvent(
            scrollingDeltaX: 0,
            scrollingDeltaY: 1,
            hasPreciseScrollingDeltas: false,
            phase: [],
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: [.shift]
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchRight)
    }

    func test_inverted_shift_vertical_wheel_scroll_down_returns_switchRight() {
        let event = MockScrollEvent(
            scrollingDeltaX: 0,
            scrollingDeltaY: -1,
            hasPreciseScrollingDeltas: false,
            phase: [],
            momentumPhase: [],
            isDirectionInvertedFromDevice: true,
            modifierFlags: [.shift]
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchRight)
    }

    func test_inverted_shift_vertical_wheel_scroll_up_returns_switchLeft() {
        let event = MockScrollEvent(
            scrollingDeltaX: 0,
            scrollingDeltaY: 1,
            hasPreciseScrollingDeltas: false,
            phase: [],
            momentumPhase: [],
            isDirectionInvertedFromDevice: true,
            modifierFlags: [.shift]
        )

        let result = handler.handle(scrollEvent: event.asNSEvent)

        XCTAssertEqual(result, .switchLeft)
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
        let finishingChange = MockScrollEvent(
            scrollingDeltaX: 50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )
        XCTAssertEqual(handler.handle(scrollEvent: finishingChange.asNSEvent), .switchRight)

        let ended = MockScrollEvent(
            scrollingDeltaX: 0,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .ended,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )
        XCTAssertEqual(handler.handle(scrollEvent: ended.asNSEvent), .none)

        let changedWithoutBegan = MockScrollEvent(
            scrollingDeltaX: 50,
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            isDirectionInvertedFromDevice: false,
            modifierFlags: []
        )

        XCTAssertEqual(handler.handle(scrollEvent: changedWithoutBegan.asNSEvent), .none)
    }
}

// MARK: - Mock scroll event

/// Minimal mock event with controlled scroll properties.
private struct MockScrollEvent {
    let scrollingDeltaX: CGFloat
    let scrollingDeltaY: CGFloat
    let hasPreciseScrollingDeltas: Bool
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase
    let isDirectionInvertedFromDevice: Bool
    let modifierFlags: NSEvent.ModifierFlags

    var asNSEvent: NSEvent {
        MockNSEvent(
            scrollingDeltaX: scrollingDeltaX,
            scrollingDeltaY: scrollingDeltaY,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
            phase: phase,
            momentumPhase: momentumPhase,
            isDirectionInvertedFromDevice: isDirectionInvertedFromDevice,
            modifierFlags: modifierFlags
        )
    }
}

private final class MockNSEvent: NSEvent {
    private let mockedScrollingDeltaX: CGFloat
    private let mockedScrollingDeltaY: CGFloat
    private let mockedHasPreciseScrollingDeltas: Bool
    private let mockedPhase: NSEvent.Phase
    private let mockedMomentumPhase: NSEvent.Phase
    private let mockedIsDirectionInvertedFromDevice: Bool
    private let mockedModifierFlags: NSEvent.ModifierFlags

    init(
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        isDirectionInvertedFromDevice: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        self.mockedScrollingDeltaX = scrollingDeltaX
        self.mockedScrollingDeltaY = scrollingDeltaY
        self.mockedHasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.mockedPhase = phase
        self.mockedMomentumPhase = momentumPhase
        self.mockedIsDirectionInvertedFromDevice = isDirectionInvertedFromDevice
        self.mockedModifierFlags = modifierFlags
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { mockedScrollingDeltaX }
    override var scrollingDeltaY: CGFloat { mockedScrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { mockedHasPreciseScrollingDeltas }
    override var phase: NSEvent.Phase { mockedPhase }
    override var momentumPhase: NSEvent.Phase { mockedMomentumPhase }
    override var isDirectionInvertedFromDevice: Bool { mockedIsDirectionInvertedFromDevice }
    override var modifierFlags: NSEvent.ModifierFlags { mockedModifierFlags }
}
