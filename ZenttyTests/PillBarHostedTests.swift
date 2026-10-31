import XCTest
@testable import Zentty

/// Pills through the real window: minimizing puts the float in the bar and
/// the strip gives up the bar's height; a click restores, a drag up promotes
/// to a PiP; a minimized surface stays occluded while its pill is peeked.
@MainActor
final class PillBarHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-pills")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 5_000

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        registry = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: - Tests

    func test_minimizing_shows_a_pill_and_the_strip_gives_up_the_bar_height() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)

        XCTAssertFalse(canvas.pillBarView.isHidden)
        XCTAssertNotNil(canvas.pillBarView.pillViewForTesting(floatID))
        XCTAssertEqual(canvas.paneStripView.frame.height, canvas.bounds.height - PillBarLayout.barHeight, accuracy: 0.5)
        XCTAssertEqual(canvas.paneStripView.frame.minY, PillBarLayout.barHeight, accuracy: 0.5)
        XCTAssertEqual(store(controller).paneViewportHeight, canvas.paneViewportHeight, accuracy: 0.5)
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
    }

    func test_clicking_a_pill_restores_and_focuses_the_float_and_the_strip_grows_back() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        let pill = try XCTUnwrap(canvas.pillBarView.pillViewForTesting(floatID))
        let point = canvas.pillBarView.convert(CGPoint(x: pill.frame.midX, y: pill.frame.midY), to: nil)

        try sendDown(at: point, in: controller)
        try send(.leftMouseUp, at: point, in: controller)
        waitForLayout("restored", delay: 0.3)

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(worklane.floatingPane(id: floatID)?.mode, .floating)
        XCTAssertEqual(worklane.focusedPaneID, floatID)
        XCTAssertNotNil(canvas.floatLayerView.floatHostForTesting(floatID))
        XCTAssertTrue(canvas.pillBarView.isHidden)
        XCTAssertEqual(canvas.paneStripView.frame.height, canvas.bounds.height, accuracy: 0.5)
        XCTAssertEqual(adapters[floatID]?.startCount, 1, "same runtime, never restarted")
    }

    func test_dragging_a_pill_up_makes_a_pip_in_the_nearest_corner() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        let bar = canvas.pillBarView
        let pill = try XCTUnwrap(bar.pillViewForTesting(floatID))
        let start = bar.convert(CGPoint(x: pill.frame.midX, y: pill.frame.midY), to: nil)
        let layer = canvas.floatLayerView
        let topLeft = layer.convert(CGPoint(x: layer.bounds.minX + 80, y: layer.bounds.maxY - 80), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y + 60), in: controller)
        try send(.leftMouseDragged, at: topLeft, in: controller)
        try send(.leftMouseUp, at: topLeft, in: controller)
        waitForLayout("promoted", delay: 0.3)

        XCTAssertEqual(
            store(controller).activeWorklane?.floatingPane(id: floatID)?.mode,
            .pip(corner: .topLeft, order: 0)
        )
        XCTAssertNotNil(layer.pipHostForTesting(floatID))
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
    }

    func test_a_peeked_pill_stays_occluded() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isVisible, false)
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isFocused, false)

        try XCTUnwrap(canvas.pillBarView.pillViewForTesting(floatID)).setHovered(true)
        XCTAssertTrue(canvas.pillPeekView.isPolling)
        waitForLayout("peek polled", delay: PillPeekView.pollInterval * 3)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        waitForLayout("window activation")

        XCTAssertGreaterThanOrEqual(canvas.pillPeekView.pollCount, 2)
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isVisible, false, "peeking never un-occludes")
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isFocused, false)
        XCTAssertEqual(adapters[floatID]?.lastActivity?.keepsRuntimeLive, true)
    }

    func test_an_overlay_opened_out_of_sight_is_reachable_from_its_worklanes_pill_bar() throws {
        let controller = try makeSeededController()
        controller.newWorklane(nil)
        waitForLayout("second worklane")
        let options = PaneOverlayIPCOptions(
            command: "/bin/sleep 30", workingDirectory: "/tmp", wait: true,
            follow: false, notify: false, sizePercent: 100, placement: .worklane
        )
        let overlayID = try controller.openOverlay(on: tileID, options: options).id
        waitForLayout("background overlay")
        XCTAssertTrue(canvas(controller).pillBarView.isHidden, "the other worklane has no pills")

        store(controller).selectWorklane(id: worklaneID)
        waitForLayout("back to the overlay's worklane", delay: 0.3)

        let bar = canvas(controller).pillBarView
        XCTAssertFalse(bar.isHidden)
        let pill = try XCTUnwrap(bar.pillViewForTesting(overlayID))
        let point = bar.convert(CGPoint(x: pill.frame.midX, y: pill.frame.midY), to: nil)
        try sendDown(at: point, in: controller)
        try send(.leftMouseUp, at: point, in: controller)
        waitForLayout("restored", delay: 0.3)

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: overlayID)?.mode, .floating)
        XCTAssertEqual(store(controller).activeWorklane?.focusedPaneID, overlayID)
    }

    // MARK: - Events

    private func makeEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        in controller: MainWindowController
    ) throws -> NSEvent {
        clock += 0.1
        return try XCTUnwrap(NSEvent.mouseEvent(
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
    }

    /// Posted and dequeued, so it is `NSApp.currentEvent` while AppKit
    /// hit-tests it, like a real press.
    private func sendDown(at windowPoint: CGPoint, in controller: MainWindowController) throws {
        NSApp.postEvent(try makeEvent(.leftMouseDown, at: windowPoint, in: controller), atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(
            matching: [.leftMouseDown],
            until: Date(),
            inMode: .default,
            dequeue: true
        ))
        controller.window.sendEvent(dequeued)
    }

    private func send(_ type: NSEvent.EventType, at windowPoint: CGPoint, in controller: MainWindowController) throws {
        controller.window.sendEvent(try makeEvent(type, at: windowPoint, in: controller))
    }

    // MARK: - Fixtures

    private func makeMinimizedController() throws -> MainWindowController {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.4)
        store(controller).minimizePane(floatID)
        waitForLayout("minimized", delay: 0.3)
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode, .minimized(order: 0))
        return controller
    }

    private func makeSeededController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = HostedSpyTerminalAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let controller = MainWindowController(runtimeRegistry: registry).prepareForHostedTesting()
        self.controller = controller
        self.registry = registry
        controller.showWindow(nil)
        waitForLayout()

        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [
                        PaneState(id: tileID, title: "a", sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp")),
                        PaneState(id: floatID, title: "b", sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp")),
                    ],
                    focusedPaneID: floatID
                )
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")
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
        wait(for: [settled], timeout: 3.0)
    }
}
