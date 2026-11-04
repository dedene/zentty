import XCTest
@testable import Zentty

/// Two-finger swipe on a PiP: follow with a rubber band, flick one corner past
/// 70pt, bounce at a wall, spring back below the threshold, ignore the
/// momentum tail, follow the fingers whatever the scroll direction setting.
final class PipSwipeResolverTests: XCTestCase {
    private var resolver = PipSwipeResolver()
    private var clock: TimeInterval = 100

    override func setUp() {
        super.setUp()
        resolver = PipSwipeResolver()
        clock = 100
    }

    // MARK: - Direction

    func test_natural_scrolling_follows_the_fingers() {
        // Natural scrolling: fingers right → deltaX > 0; fingers up → deltaY < 0.
        XCTAssertEqual(
            PipSwipeResolver.fingerTravel(delta: CGVector(dx: 10, dy: -4), isDirectionInvertedFromDevice: true),
            CGVector(dx: 10, dy: 4)
        )
    }

    func test_classic_scrolling_still_follows_the_fingers() {
        // Classic scrolling reports the opposite deltas for the same finger move.
        XCTAssertEqual(
            PipSwipeResolver.fingerTravel(delta: CGVector(dx: -10, dy: 4), isDirectionInvertedFromDevice: false),
            CGVector(dx: 10, dy: 4)
        )
    }

    func test_classic_scrolling_flicks_the_same_way_as_natural() {
        _ = send(.began, dx: 0, inverted: false)
        let action = send(.changed, dx: -80, inverted: false, corner: .bottomLeft)

        XCTAssertEqual(action, .flick(to: .bottomRight), "fingers moved right")
    }

    // MARK: - Follow and rubber band

    func test_follows_with_a_rubber_band() {
        _ = send(.began, dx: 10)
        let action = send(.changed, dx: 10, dy: -20)

        // Finger travel (20 right, 20 down) → 0.35× = 7.
        XCTAssertEqual(action, .follow(offset: CGVector(dx: 7, dy: -7)))
    }

    func test_rubber_band_caps_at_28_points() {
        XCTAssertEqual(
            PipSwipeResolver.rubberBand(CGVector(dx: 200, dy: -60)),
            CGVector(dx: 28, dy: -21)
        )
    }

    // MARK: - Flick

    func test_flick_past_70_points_moves_to_the_next_corner() {
        _ = send(.began, dx: -30)
        XCTAssertEqual(send(.changed, dx: -30), .follow(offset: CGVector(dx: -21, dy: 0)))

        let action = send(.changed, dx: -15)

        XCTAssertEqual(action, .flick(to: .bottomLeft))
        XCTAssertTrue(resolver.isLocked)
    }

    func test_vertical_flick_goes_up_from_a_bottom_corner() {
        _ = send(.began, dy: 40)
        let action = send(.changed, dy: 40, corner: .bottomLeft)

        XCTAssertEqual(action, .flick(to: .topLeft))
    }

    func test_dominant_axis_decides_the_direction() {
        _ = send(.began, dx: 50, dy: 60, corner: .bottomLeft)
        let action = send(.changed, dx: 0, dy: 20, corner: .bottomLeft)

        XCTAssertEqual(action, .flick(to: .topLeft), "vertical travel (80) beats horizontal (50)")
    }

    func test_one_swipe_moves_one_corner() {
        _ = send(.began, corner: .bottomLeft)
        XCTAssertEqual(send(.changed, dx: 80, corner: .bottomLeft), .flick(to: .bottomRight))

        XCTAssertEqual(send(.changed, dx: 200, corner: .bottomRight), PipSwipeResolver.Action.none)
        XCTAssertEqual(send(.changed, dy: -200, corner: .bottomRight), PipSwipeResolver.Action.none)
    }

    // MARK: - Wall

    func test_swipe_toward_a_wall_bounces_14_points() {
        _ = send(.began, dx: 40)
        let action = send(.changed, dx: 40, corner: .bottomRight)

        XCTAssertEqual(action, .bounce(toward: CGVector(dx: 14, dy: 0)))
        XCTAssertTrue(resolver.isLocked, "a bounce also ends the swipe")
    }

    func test_swipe_down_from_a_bottom_corner_bounces_down() {
        _ = send(.began, dy: -40)
        let action = send(.changed, dy: -40, corner: .bottomLeft)

        XCTAssertEqual(action, .bounce(toward: CGVector(dx: 0, dy: -14)))
    }

    // MARK: - Lift below the threshold

    func test_lifting_below_the_threshold_springs_back() {
        _ = send(.began, dx: 20)
        _ = send(.changed, dx: 20)

        XCTAssertEqual(send(.ended), .settle)
        XCTAssertEqual(resolver.accumulated, .zero)
    }

    func test_cancelled_springs_back_too() {
        _ = send(.began, dx: 20)

        XCTAssertEqual(send(.cancelled), .settle)
    }

    func test_ended_without_travel_does_nothing() {
        _ = send(.began)

        XCTAssertEqual(send(.ended), PipSwipeResolver.Action.none)
    }

    // MARK: - Momentum and resets

    func test_momentum_never_moves_the_pip() {
        _ = send(.began, dx: 20)
        XCTAssertEqual(send(.ended), .settle)

        XCTAssertEqual(send(.none, momentum: .began, dx: 200), PipSwipeResolver.Action.none)
        XCTAssertEqual(send(.none, momentum: .changed, dx: 200), PipSwipeResolver.Action.none)
        XCTAssertEqual(resolver.accumulated, .zero)
    }

    func test_momentum_tail_after_a_flick_is_owned_until_it_ends() {
        _ = send(.began, corner: .bottomLeft)
        XCTAssertEqual(send(.changed, dx: 80, corner: .bottomLeft), .flick(to: .bottomRight))
        XCTAssertEqual(send(.ended), PipSwipeResolver.Action.none, "a flick needs no spring back")

        XCTAssertTrue(route(.none, momentum: .began, dx: 30))
        XCTAssertTrue(route(.none, momentum: .changed, dx: 10))
        XCTAssertTrue(route(.none, momentum: .ended), "the last momentum event is still the tail")
        XCTAssertFalse(resolver.isLocked)
        XCTAssertFalse(resolver.isOwning)
        XCTAssertFalse(route(.none, momentum: .changed, dx: 10))
    }

    /// The rubber band moves the PiP off a pointer near its edge long before
    /// 70pt: the swipe must stay the PiP's from its first touch.
    func test_a_swipe_is_owned_from_its_first_touch_not_from_the_flick() {
        XCTAssertFalse(resolver.isOwning)
        XCTAssertEqual(send(.began, dx: -20), .follow(offset: CGVector(dx: -7, dy: 0)))

        XCTAssertTrue(resolver.isOwning)
        XCTAssertFalse(resolver.isLocked)
        XCTAssertTrue(owns(.changed, dx: -30))
        XCTAssertEqual(send(.changed, dx: -60), .flick(to: .bottomLeft))
    }

    func test_momentum_after_a_spring_back_stays_owned() {
        _ = send(.began, dx: -20)
        XCTAssertEqual(send(.ended), .settle)

        XCTAssertTrue(owns(.none, momentum: .began, dx: -30), "not handed to the view underneath")
        XCTAssertEqual(send(.none, momentum: .ended), PipSwipeResolver.Action.none)
        XCTAssertFalse(resolver.isOwning)
    }

    func test_a_mouse_wheel_event_ends_ownership() {
        _ = send(.began, dx: -20)

        XCTAssertFalse(owns(.none, dy: 10))
        XCTAssertFalse(resolver.isOwning)
    }

    func test_a_pause_of_220ms_releases_the_lock() {
        _ = send(.began, corner: .bottomLeft)
        XCTAssertEqual(send(.changed, dx: 80, corner: .bottomLeft), .flick(to: .bottomRight))

        clock += 0.23
        XCTAssertFalse(owns(.changed, dx: 5))
        XCTAssertFalse(resolver.isLocked)
        XCTAssertFalse(resolver.isOwning)
    }

    func test_events_within_220ms_keep_the_lock() {
        _ = send(.began, corner: .bottomLeft)
        XCTAssertEqual(send(.changed, dx: 80, corner: .bottomLeft), .flick(to: .bottomRight))

        clock += 0.2
        XCTAssertTrue(owns(.changed, dx: 5))
    }

    func test_a_new_touch_starts_a_new_swipe() {
        _ = send(.began, corner: .bottomLeft)
        XCTAssertEqual(send(.changed, dx: 80, corner: .bottomLeft), .flick(to: .bottomRight))
        XCTAssertFalse(owns(.began), "a fresh touch is not the tail")
        XCTAssertFalse(owns(.mayBegin))

        _ = send(.began, dx: -50)
        XCTAssertEqual(send(.changed, dx: -30, corner: .bottomRight), .flick(to: .bottomLeft))
    }

    func test_stale_travel_resets_after_a_gap() {
        _ = send(.began, dx: 60)
        clock += 0.5

        XCTAssertEqual(send(.changed, dx: 20), .follow(offset: CGVector(dx: 7, dy: 0)), "starts over")
    }

    func test_plain_mouse_wheel_is_ignored() {
        XCTAssertEqual(send(.none, dx: 0, dy: 500), PipSwipeResolver.Action.none)
        XCTAssertEqual(resolver.accumulated, .zero)
    }

    // MARK: - Corners

    func test_next_corner_in_each_direction() {
        XCTAssertEqual(PipSwipeResolver.corner(from: .bottomLeft, horizontal: true, positive: true), .bottomRight)
        XCTAssertEqual(PipSwipeResolver.corner(from: .topRight, horizontal: true, positive: false), .topLeft)
        XCTAssertEqual(PipSwipeResolver.corner(from: .bottomRight, horizontal: false, positive: true), .topRight)
        XCTAssertEqual(PipSwipeResolver.corner(from: .topLeft, horizontal: false, positive: false), .bottomLeft)
        XCTAssertEqual(PipSwipeResolver.corner(from: .topLeft, horizontal: false, positive: true), .topLeft)
    }

    // MARK: - Helpers

    /// Natural-scrolling deltas from finger travel (dx right, dy up).
    private func event(
        _ phase: PipSwipeResolver.Phase,
        momentum: PipSwipeResolver.Phase = .none,
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        inverted: Bool = true
    ) -> PipSwipeResolver.Event {
        PipSwipeResolver.Event(
            phase: phase,
            momentumPhase: momentum,
            delta: CGVector(dx: dx, dy: -dy),
            isDirectionInvertedFromDevice: inverted,
            timestamp: clock
        )
    }

    /// The capture monitor's question for an event that may not be over the
    /// PiP any more.
    private func owns(
        _ phase: PipSwipeResolver.Phase,
        momentum: PipSwipeResolver.Phase = .none,
        dx: CGFloat = 0,
        dy: CGFloat = 0
    ) -> Bool {
        resolver.owns(event(phase, momentum: momentum, dx: dx, dy: dy))
    }

    /// What the capture monitor does: an owned event goes to `handle`.
    private func route(
        _ phase: PipSwipeResolver.Phase,
        momentum: PipSwipeResolver.Phase = .none,
        dx: CGFloat = 0
    ) -> Bool {
        guard owns(phase, momentum: momentum, dx: dx) else { return false }
        _ = send(phase, momentum: momentum, dx: dx)
        return true
    }

    private func send(
        _ phase: PipSwipeResolver.Phase,
        momentum: PipSwipeResolver.Phase = .none,
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        inverted: Bool = true,
        corner: FloatCorner = .bottomRight
    ) -> PipSwipeResolver.Action {
        clock += 0.016
        // Classic-scrolling fixtures pass raw deltas: undo the helper's flip.
        let raw = inverted
            ? event(phase, momentum: momentum, dx: dx, dy: dy, inverted: true)
            : PipSwipeResolver.Event(
                phase: phase,
                momentumPhase: momentum,
                delta: CGVector(dx: dx, dy: dy),
                isDirectionInvertedFromDevice: false,
                timestamp: clock
            )
        return resolver.handle(raw, corner: corner)
    }
}
