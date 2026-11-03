import XCTest
@testable import Zentty

/// PiP drag and two-finger swipe through the real window and store: a
/// thrown PiP lands in the corner its momentum points at, a swipe flicks it
/// one corner, and neither the PiP's terminal nor the tile under the old
/// spot sees any of the mouse or scroll events.
@MainActor
final class PipGestureHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-pip-gesture")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")

    private var controller: MainWindowController?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 0

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
        clock = ProcessInfo.processInfo.systemUptime
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    func test_fast_drag_throws_the_pip_into_the_far_corner() throws {
        let controller = try makePipController()
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        let start = pip.convert(CGPoint(x: pip.bounds.midX, y: pip.bounds.midY), to: nil)
        adapters[floatID]?.spyView.resetMouseEventsForTesting()

        try sendMouse(.leftMouseDown, at: start, in: controller)
        for step in 1...4 {
            try sendMouse(.leftMouseDragged, at: start.offsetBy(dx: CGFloat(step) * -30, dy: CGFloat(step) * 15), after: 0.01, in: controller)
        }
        try sendMouse(.leftMouseUp, at: start.offsetBy(dx: -150, dy: 75), after: 0.01, in: controller)
        waitForLayout("thrown")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(worklane.floatingPane(id: floatID)?.mode, .pip(corner: .topLeft, order: 0))
        let landed = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        XCTAssertTrue(landed === pip, "the same PiP moves; nothing is re-mounted")
        XCTAssertEqual(landed.frame.minX, FloatLayout.pipMargin, accuracy: 0.5)
        XCTAssertFalse(canvas(controller).floatLayerView.isGestureActive)
        XCTAssertEqual(adapters[floatID]?.spyView.mouseEventTypes, [], "the PiP's terminal never saw the drag")
        XCTAssertEqual(adapters[floatID]?.spyView.isViewportSyncSuspended, true, "still frozen at the float grid")
    }

    func test_swipe_flicks_one_corner_and_the_tail_never_scrolls_the_tile() throws {
        let controller = try makePipController()
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        let point = pip.convert(CGPoint(x: pip.bounds.midX, y: pip.bounds.midY), to: nil)
        let contentView = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(contentView.hitTest(contentView.convert(point, from: nil)) === pip)

        // Fingers moving left.
        try sendScroll(phase: .began, dx: -30, at: point, in: controller)
        try sendScroll(phase: .changed, dx: -30, at: point, in: controller)
        try sendScroll(phase: .changed, dx: -30, at: point, in: controller)
        waitForLayout("flicked")

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode, .pip(corner: .bottomLeft, order: 0))
        let tileSpy = try XCTUnwrap(adapters[tileID]?.spyView)
        let underOldSpot = contentView.hitTest(contentView.convert(point, from: nil))
        XCTAssertFalse(underOldSpot is PipContainerView, "the PiP left the pointer")

        XCTAssertTrue(pip.isSwipeCaptureActiveForTesting)
        try sendScroll(phase: .changed, dx: -30, at: point, in: controller)
        try sendScroll(phase: .ended, dx: 0, at: point, in: controller)
        try sendScroll(phase: nil, momentum: .begin, dx: -20, at: point, in: controller)
        try sendScroll(phase: nil, momentum: .end, dx: 0, at: point, in: controller)

        XCTAssertEqual(tileSpy.scrollEventCount, 0, "the swipe's tail is swallowed")
        XCTAssertEqual(adapters[floatID]?.spyView.scrollEventCount, 0)
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode, .pip(corner: .bottomLeft, order: 0), "one swipe, one corner")
        XCTAssertFalse(pip.isSwipeCaptureActiveForTesting, "the capture ends with the momentum")

        // Control: a new gesture at the old spot does reach the tile.
        try sendScroll(phase: .began, dx: -5, at: point, in: controller)
        XCTAssertGreaterThan(tileSpy.scrollEventCount, 0, "without the capture the tail would have scrolled the tile")
    }

    /// Regression: a swipe starting near the PiP's edge slid it off the
    /// still pointer with the rubber band before the 70pt flick latched the
    /// capture, so the tile underneath got the rest of the gesture.
    func test_swipe_starting_near_the_edge_stays_on_the_pip_after_the_rubber_band_moves_it() throws {
        let controller = try makePipController()
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        // 3pt inside the trailing edge; fingers moving left pull the PiP away.
        let point = pip.convert(CGPoint(x: pip.bounds.maxX - 3, y: pip.bounds.midY), to: nil)
        let contentView = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(contentView.hitTest(contentView.convert(point, from: nil)) === pip)
        let tileSpy = try XCTUnwrap(adapters[tileID]?.spyView)
        FloatMotion.reduceMotionOverride = false

        try sendScroll(phase: .began, dx: -20, at: point, in: controller)
        XCTAssertFalse(contentView.hitTest(contentView.convert(point, from: nil)) is PipContainerView, "the rubber band slid it off the pointer")
        XCTAssertTrue(pip.isSwipeCaptureActiveForTesting, "owned from the first touch")
        try sendScroll(phase: .changed, dx: -30, at: point, in: controller)
        try sendScroll(phase: .changed, dx: -30, at: point, in: controller)
        waitForLayout("flicked")

        XCTAssertEqual(tileSpy.scrollEventCount, 0, "the tile never saw the swipe")
        XCTAssertEqual(adapters[floatID]?.spyView.scrollEventCount, 0)
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode, .pip(corner: .bottomLeft, order: 0))
        try sendScroll(phase: .ended, dx: 0, at: point, in: controller)
        XCTAssertEqual(tileSpy.scrollEventCount, 0)
    }

    // MARK: - Events

    private func sendMouse(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        after interval: TimeInterval = 0.1,
        in controller: MainWindowController
    ) throws {
        clock += interval
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: clock,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        if type == .leftMouseDown {
            // Posted and dequeued, so it is `NSApp.currentEvent` during the
            // hit test, like a real press.
            NSApp.postEvent(event, atStart: true)
            let dequeued = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(), inMode: .default, dequeue: true))
            controller.window.sendEvent(dequeued)
        } else {
            controller.window.sendEvent(event)
        }
    }

    /// A trackpad scroll at `windowPoint`. Synthesized scroll events carry
    /// no window, so `NSApp.sendEvent` can't route them: this runs the PiP's
    /// swipe-capture monitor step (what `NSApp` does before dispatch), then
    /// lets the window hit-test and deliver the event.
    private func sendScroll(
        phase: CGScrollPhase?,
        momentum: CGMomentumScrollPhase = .none,
        dx: Int32,
        at windowPoint: CGPoint,
        in controller: MainWindowController
    ) throws {
        // `dx` is finger travel in natural-scrolling terms; flip it when the
        // synthesized event reports classic scrolling.
        let probe = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
        let isNatural = NSEvent(cgEvent: probe)?.isDirectionInvertedFromDevice ?? true
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: isNatural ? dx : -dx,
            wheel3: 0
        ))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        // A window-less event's location is its window point here.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: windowPoint.x, y: primaryHeight - windowPoint.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertEqual(event.locationInWindow.x, windowPoint.x, accuracy: 0.5)
        XCTAssertEqual(event.locationInWindow.y, windowPoint.y, accuracy: 0.5)
        if let pip = canvas(controller).floatLayerView.pipHostForTesting(floatID),
           pip.isSwipeCaptureActiveForTesting, pip.routeCapturedSwipe(event) {
            return
        }
        controller.window.sendEvent(event)
    }

    // MARK: - Fixtures

    private func makePipController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = HostedSpyTerminalAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let controller = MainWindowController(runtimeRegistry: registry).prepareForHostedTesting()
        self.controller = controller
        controller.showWindow(nil)
        waitForLayout()

        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [
                        PaneState(id: tileID, title: "a"),
                        PaneState(id: floatID, title: "b"),
                    ],
                    focusedPaneID: floatID
                ),
                auxiliaryStateByPaneID: [:]
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.4)
        store(controller).pipPane(floatID, corner: .bottomRight)
        waitForLayout("pip")
        XCTAssertNotNil(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        return controller
    }

    private func store(_ controller: MainWindowController) -> WorklaneStore {
        controller.rootViewControllerForTesting.worklaneStore
    }

    private func canvas(_ controller: MainWindowController) -> AppCanvasView {
        controller.rootViewControllerForTesting.appCanvasViewForTesting
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.15) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}
