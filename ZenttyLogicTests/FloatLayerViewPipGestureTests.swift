import AppKit
import XCTest
@testable import Zentty

/// PiP drag (lift, follow, momentum release into a corner), two-finger swipe
/// (rubber band, flick, bounce, spring back, captured tail) and Reduce Motion,
/// on a float layer in an offscreen window.
@MainActor
final class FloatLayerViewPipGestureTests: AppKitTestCase {
    private let pipID = PaneID("pip")
    private let neighbourID = PaneID("neighbour")
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)
    private let floatFrame = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
    private var window: NSWindow?
    private var clock: TimeInterval = 1000
    private var moveRequests: [(PaneID, FloatCorner)] = []
    private var clicks: [PaneID] = []

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = false
        moveRequests = []
        clicks = []
        clock = 1000
    }

    override func tearDown() {
        FloatMotion.reduceMotionOverride = nil
        window?.close()
        window = nil
        super.tearDown()
    }

    // MARK: - Click vs drag

    func test_click_without_moving_restores_on_mouse_up() throws {
        let (layer, pip) = try makePip()
        let center = CGPoint(x: pip.frame.midX, y: pip.frame.midY)

        pip.mouseDown(with: mouse(.leftMouseDown, at: center))
        XCTAssertEqual(clicks, [], "a press alone is not a click yet")
        pip.mouseUp(with: mouse(.leftMouseUp, at: center.offsetBy(dx: 1, dy: 1)))

        XCTAssertEqual(clicks, [pipID])
        XCTAssertTrue(moveRequests.isEmpty)
        XCTAssertFalse(layer.isGestureActive)
    }

    func test_drag_lifts_and_follows_the_pointer() throws {
        let (layer, pip) = try makePip()
        let resting = pip.frame
        let start = CGPoint(x: resting.midX, y: resting.midY)

        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        XCTAssertTrue(layer.isGestureActive, "a press blocks float commands")
        pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: -100, dy: 60)))

        XCTAssertTrue(pip.isLifted)
        assertFrame(pip.modelFrame, resting.offsetBy(dx: -100, dy: 60))
        XCTAssertEqual(pip.frame.width, resting.width * PipChrome.liftScale, accuracy: 0.001)
        XCTAssertEqual(pip.frame.midX, resting.midX - 100, accuracy: 0.001, "lifted about its centre")
        XCTAssertEqual(pip.bounds.width, resting.width, accuracy: 0.001, "bounds trick: nothing inside is laid out anew")
        XCTAssertEqual(pip.bounds.height, resting.height, accuracy: 0.001)
        XCTAssertEqual(pip.scaleViewForTesting.bounds.size, CGSize(width: 600, height: 350), "terminal keeps the float size")
        XCTAssertEqual(pip.shadowLayerForTesting.shadowRadius, PipChrome.liftedShadow.radius)
        XCTAssertTrue(clicks.isEmpty)
    }

    func test_rerender_mid_drag_keeps_the_pip_under_the_pointer() throws {
        let (layer, pip) = try makePip()
        let start = CGPoint(x: pip.frame.midX, y: pip.frame.midY)
        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: -200, dy: 0)))
        let dragged = pip.modelFrame

        layer.render(content(pipCorner: .bottomRight))

        XCTAssertEqual(pip.modelFrame, dragged)
        XCTAssertTrue(pip.isLifted)
    }

    func test_restore_mid_drag_lands_at_the_float_frame_not_the_drag_frame() throws {
        let (layer, pip) = try makePip()
        let start = CGPoint(x: pip.frame.midX, y: pip.frame.midY)
        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: -300, dy: 100)))

        // An IPC restore while the pointer is still down.
        layer.render(FloatLayerContent(
            floats: [FloatingPaneState(
                pane: PaneState(id: pipID, title: "pip"),
                mode: .floating,
                floatFrame: floatFrame,
                stackOrder: 0,
                origin: nil
            )],
            floatsHidden: false,
            focusedFloatID: nil
        ))

        let host = try XCTUnwrap(layer.floatHostForTesting(pipID))
        XCTAssertEqual(host.paneFrame, CGRect(x: 100, y: 140, width: 600, height: 350))
        XCTAssertNil(layer.interactiveFrameForTesting(pipID))
        XCTAssertFalse(layer.isGestureActive)
        pip.mouseUp(with: mouse(.leftMouseUp, at: start.offsetBy(dx: -300, dy: 100)))
        XCTAssertTrue(moveRequests.isEmpty, "a release after the PiP left asks nothing")
    }

    func test_reduce_motion_drag_does_not_lift() throws {
        FloatMotion.reduceMotionOverride = true
        let (_, pip) = try makePip()
        let resting = pip.frame
        let start = CGPoint(x: resting.midX, y: resting.midY)

        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: -50, dy: 0)))

        XCTAssertFalse(pip.isLifted)
        XCTAssertEqual(pip.frame.size, resting.size)
    }

    // MARK: - Release

    func test_fast_release_projects_into_the_far_corner_with_a_spring() throws {
        let (layer, pip) = try makePip()
        let start = CGPoint(x: pip.frame.midX, y: pip.frame.midY)
        var motions: [CGRect] = []
        layer.onPipMotionForTesting = { motions.append($1) }

        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        for step in 1...4 {
            pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: CGFloat(step) * -30, dy: 0), after: 0.01))
        }
        let releaseFrame = pip.frame
        pip.mouseUp(with: mouse(.leftMouseUp, at: start.offsetBy(dx: -150, dy: 0), after: 0.01))

        // ≈3000 pt/s left coasts ≈1500pt: far past the middle.
        XCTAssertEqual(moveRequests.map(\.1), [.bottomLeft])
        XCTAssertFalse(pip.isLifted)
        let corner = try XCTUnwrap(layer.pipHostForTesting(pipID)?.frame)
        XCTAssertEqual(corner.minX, FloatLayout.pipMargin, "settled in the new corner")
        let spring = try XCTUnwrap(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) as? CASpringAnimation)
        XCTAssertNotEqual(spring.initialVelocity, 0, "seeded with the release velocity")
        XCTAssertEqual(spring.damping, FloatSnapSpring.parameters(from: .zero, to: .zero, gestureVelocity: .zero).damping)
        XCTAssertEqual(motions.last?.width ?? 0, releaseFrame.width, accuracy: 0.5, "springs from where it was let go")
        XCTAssertEqual(motions.last?.midX ?? 0, releaseFrame.midX, accuracy: 0.5)
    }

    func test_slow_release_in_its_own_quadrant_springs_home_without_a_store_change() throws {
        let (layer, pip) = try makePip()
        let resting = pip.frame
        let start = CGPoint(x: resting.midX, y: resting.midY)
        var settled: [FloatCorner] = []
        layer.onPipSettledForTesting = { settled.append($1) }

        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: -40, dy: 30), after: 0.2))
        pip.mouseUp(with: mouse(.leftMouseUp, at: start.offsetBy(dx: -40, dy: 30), after: 0.3))

        XCTAssertTrue(moveRequests.isEmpty, "same corner: nothing to ask the store")
        XCTAssertEqual(settled, [.bottomRight])
        assertFrame(pip.frame, resting)
        XCTAssertFalse(pip.isLifted)
        XCTAssertTrue(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) is CASpringAnimation)
        XCTAssertNil(layer.interactiveFrameForTesting(pipID))
        XCTAssertFalse(layer.isGestureActive)
    }

    func test_reduce_motion_release_eases_without_overshoot() throws {
        FloatMotion.reduceMotionOverride = true
        let (_, pip) = try makePip()
        let start = CGPoint(x: pip.frame.midX, y: pip.frame.midY)

        pip.mouseDown(with: mouse(.leftMouseDown, at: start))
        pip.mouseDragged(with: mouse(.leftMouseDragged, at: start.offsetBy(dx: -40, dy: 0), after: 0.2))
        pip.mouseUp(with: mouse(.leftMouseUp, at: start.offsetBy(dx: -40, dy: 0), after: 0.3))

        let animation = try XCTUnwrap(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey))
        XCTAssertFalse(animation is CASpringAnimation)
        XCTAssertEqual(animation.duration, FloatMotion.reducedDuration, accuracy: 0.0001)
    }

    func test_pip_that_leaves_a_corner_lets_its_neighbour_spring_down() throws {
        let layer = makeLayer()
        layer.render(content(pipCorner: .bottomRight, neighbour: true))
        let neighbour = try XCTUnwrap(layer.pipHostForTesting(neighbourID))
        let outer = neighbour.frame
        var motions: [PaneID] = []
        layer.onPipMotionForTesting = { id, _ in motions.append(id) }

        layer.render(content(pipCorner: .topLeft, neighbour: true, neighbourOrder: 0))

        XCTAssertLessThan(neighbour.frame.minY, outer.minY, "drops into the corner slot")
        XCTAssertTrue(motions.contains(neighbourID), "springs, does not jump")
    }

    // MARK: - Swipe

    func test_swipe_follows_the_fingers_with_a_rubber_band() throws {
        let (_, pip) = try makePip()
        let resting = pip.frame

        pip.handleSwipe(swipe(.began, fingerDX: -20))

        XCTAssertEqual(pip.swipeOffset, CGVector(dx: -7, dy: 0))
        assertFrame(pip.frame, resting.offsetBy(dx: -7, dy: 0))
        assertFrame(pip.modelFrame, resting)
    }

    func test_swipe_past_the_threshold_flicks_one_corner_and_captures_the_tail() throws {
        let (layer, pip) = try makePip()
        var motions: [CGRect] = []
        layer.onPipMotionForTesting = { motions.append($1) }

        pip.handleSwipe(swipe(.began, fingerDX: -40))
        let rubberBanded = pip.frame
        pip.handleSwipe(swipe(.changed, fingerDX: -40))

        XCTAssertEqual(moveRequests.map(\.1), [.bottomLeft])
        XCTAssertEqual(pip.swipeOffset, .zero)
        XCTAssertEqual(motions.last, rubberBanded, "springs from the rubber band into the new corner")
        XCTAssertTrue(pip.isSwipeCaptureActiveForTesting, "the rest of the gesture can't scroll what's under the pointer")

        pip.handleSwipe(swipe(.changed, fingerDX: -200))
        XCTAssertEqual(moveRequests.count, 1, "one swipe, one corner")
    }

    func test_swipe_toward_a_wall_bounces() throws {
        let (_, pip) = try makePip()

        pip.handleSwipe(swipe(.began, fingerDX: 40))
        pip.handleSwipe(swipe(.changed, fingerDX: 40))

        XCTAssertTrue(moveRequests.isEmpty)
        XCTAssertEqual(pip.swipeOffset, .zero)
        let bounce = try XCTUnwrap(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) as? CAKeyframeAnimation)
        let peak = try XCTUnwrap((bounce.values?[1] as? NSValue)?.caTransform3DValue)
        XCTAssertEqual(peak.m41, PipSwipeResolver.bounceDistance)
    }

    func test_lifting_below_the_threshold_springs_back() throws {
        let (_, pip) = try makePip()
        let resting = pip.frame

        pip.handleSwipe(swipe(.began, fingerDX: -30))
        pip.handleSwipe(swipe(.ended))

        assertFrame(pip.frame, resting)
        XCTAssertTrue(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) is CASpringAnimation)
        XCTAssertTrue(moveRequests.isEmpty)
    }

    func test_reduce_motion_swipe_has_no_rubber_band_or_bounce_but_still_flicks() throws {
        FloatMotion.reduceMotionOverride = true
        let (_, pip) = try makePip()

        pip.handleSwipe(swipe(.began, fingerDX: 40))
        XCTAssertEqual(pip.swipeOffset, .zero)
        pip.handleSwipe(swipe(.changed, fingerDX: 40))
        XCTAssertFalse(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) is CAKeyframeAnimation)

        pip.handleSwipe(swipe(.began, fingerDX: -80))
        XCTAssertEqual(moveRequests.map(\.1), [.bottomLeft])
    }

    // MARK: - Scroll events

    func test_scroll_on_a_pip_never_reaches_the_views_behind_it() throws {
        let spy = ScrollSpyView(frame: canvas)
        let layer = makeLayer(root: spy)
        layer.render(content(pipCorner: .bottomRight))
        let pip = try XCTUnwrap(layer.pipHostForTesting(pipID))
        let event = try XCTUnwrap(scrollEvent(phase: .began, dx: 30, dy: 0))

        pip.scrollWheel(with: event)
        pip.scrollWheel(with: try XCTUnwrap(scrollEvent(phase: nil, dx: 0, dy: 40)))

        XCTAssertEqual(spy.scrollCount, 0)
    }

    func test_scroll_event_maps_phases_and_deltas() throws {
        let began = PipSwipeResolver.Event(try XCTUnwrap(scrollEvent(phase: .began, dx: 12, dy: -5)))
        XCTAssertEqual(began.phase, .began)
        XCTAssertEqual(began.momentumPhase, PipSwipeResolver.Phase.none)
        XCTAssertEqual(began.delta.dx, 12, accuracy: 0.5)
        XCTAssertEqual(began.delta.dy, -5, accuracy: 0.5)

        let momentum = PipSwipeResolver.Event(try XCTUnwrap(scrollEvent(phase: nil, momentum: .continuous, dx: 3, dy: 0)))
        XCTAssertEqual(momentum.phase, PipSwipeResolver.Phase.none)
        XCTAssertEqual(momentum.momentumPhase, .changed)
    }

    func test_captured_tail_is_dropped_until_the_momentum_ends() throws {
        let (_, pip) = try makePip()
        let tail = try XCTUnwrap(scrollEvent(phase: .changed, dx: -10, dy: 0))
        // Real events carry uptime timestamps: flick just before the tail.
        clock = tail.timestamp - 0.05
        pip.handleSwipe(swipe(.began, fingerDX: -80))
        XCTAssertTrue(pip.isSwipeCaptureActiveForTesting)

        XCTAssertTrue(pip.captureSwipeTail(tail))
        XCTAssertTrue(pip.captureSwipeTail(try XCTUnwrap(scrollEvent(phase: nil, momentum: .end, dx: 0, dy: 0))))

        XCTAssertFalse(pip.isSwipeCaptureActiveForTesting)
        XCTAssertFalse(pip.captureSwipeTail(try XCTUnwrap(scrollEvent(phase: .changed, dx: -10, dy: 0))))
    }

    // MARK: - Fixtures

    private func assertFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func makePip() throws -> (FloatLayerView, PipContainerView) {
        let layer = makeLayer()
        layer.render(content(pipCorner: .bottomRight))
        return (layer, try XCTUnwrap(layer.pipHostForTesting(pipID)))
    }

    private func makeLayer(root: NSView? = nil) -> FloatLayerView {
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in GestureSpyAdapter() })
        let layer = FloatLayerView(runtimeRegistry: registry)
        layer.frame = canvas
        let window = NSWindow(contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = root ?? NSView(frame: canvas)
        window.contentView = root
        root.addSubview(layer)
        self.window = window
        layer.onPipClicked = { [unowned self] in self.clicks.append($0) }
        // Like the store: a different corner re-renders right away.
        layer.onPipMoveRequested = { [unowned self, unowned layer] paneID, corner in
            self.moveRequests.append((paneID, corner))
            layer.render(self.content(pipCorner: corner))
        }
        return layer
    }

    private func content(
        pipCorner: FloatCorner,
        neighbour: Bool = false,
        neighbourOrder: Int = 1
    ) -> FloatLayerContent {
        var floats = [
            FloatingPaneState(
                pane: PaneState(id: pipID, title: "pip"),
                mode: .pip(corner: pipCorner, order: 0),
                floatFrame: floatFrame,
                stackOrder: 0,
                origin: nil
            ),
        ]
        if neighbour {
            floats.append(FloatingPaneState(
                pane: PaneState(id: neighbourID, title: "neighbour"),
                mode: .pip(corner: .bottomRight, order: neighbourOrder),
                floatFrame: floatFrame,
                stackOrder: 1,
                origin: nil
            ))
        }
        return FloatLayerContent(floats: floats, floatsHidden: false, focusedFloatID: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, after interval: TimeInterval = 0.05) -> NSEvent {
        clock += interval
        return NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: clock,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    /// A natural-scrolling swipe event for finger travel `fingerDX` (right +).
    private func swipe(_ phase: PipSwipeResolver.Phase, fingerDX: CGFloat = 0) -> PipSwipeResolver.Event {
        clock += 0.016
        return PipSwipeResolver.Event(
            phase: phase,
            momentumPhase: .none,
            delta: CGVector(dx: fingerDX, dy: 0),
            isDirectionInvertedFromDevice: true,
            timestamp: clock
        )
    }

    private func scrollEvent(
        phase: CGScrollPhase?,
        momentum: CGMomentumScrollPhase = .none,
        dx: Int32,
        dy: Int32
    ) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            return nil
        }
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return NSEvent(cgEvent: cgEvent)
    }
}

private extension FloatLayerView {
    func render(_ content: FloatLayerContent) {
        render(content, theme: ZenttyTheme.fallback(for: nil), showPaneBorders: true, smoothScrollingEnabled: false)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

private final class ScrollSpyView: NSView {
    private(set) var scrollCount = 0

    override func scrollWheel(with event: NSEvent) {
        scrollCount += 1
    }
}

@MainActor
private final class GestureSpyAdapter: TerminalAdapter {
    let view = NSView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    func makeTerminalView() -> NSView { view }
    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}
