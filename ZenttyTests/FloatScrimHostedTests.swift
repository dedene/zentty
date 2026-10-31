import XCTest
@testable import Zentty

/// The strip scrim in a real window: it dims while a float has focus, a
/// click on a dimmed tile reaches the tile and lifts the dim, and peek hides
/// it together with the float layer.
@MainActor
final class FloatScrimHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-scrim")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")
    private let seededFloatFrame = NormalizedRect(x: 0.4, y: 0.25, width: 0.4, height: 0.4)

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 2_000

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = false
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        registry = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    func test_click_tile_through_scrim_focuses_tile_and_lifts_dim() throws {
        let controller = try makeFloatedController()
        let scrim = canvas(controller).floatLayerView.scrimViewForTesting
        XCTAssertTrue(scrim.isScrimVisible, "a focused float dims the strip")

        try click(at: try tilePointOutsideFloat(in: controller), in: controller)
        waitForLayout("tile focused", delay: FloatScrimView.fadeDuration + 0.2)

        XCTAssertEqual(adapters[tileID]?.spyView.mouseEventTypes.first, .leftMouseDown, "the click reached the tile")
        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertFalse(worklane.floatOwnsFocus)
        XCTAssertEqual(worklane.focusedPaneID, tileID)
        XCTAssertFalse(scrim.isScrimVisible)
        XCTAssertTrue(scrim.isHidden)
    }

    func test_focusing_float_dims_again() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let scrim = layer.scrimViewForTesting
        try click(at: try tilePointOutsideFloat(in: controller), in: controller)
        waitForLayout("tile focused", delay: FloatScrimView.fadeDuration + 0.2)
        XCTAssertFalse(scrim.isScrimVisible)

        // The spy terminal forwards its mouse-down up the responder chain
        // (the real terminal consumes it and takes first responder), so
        // focus the float the way that click ends: through the store.
        store(controller).focusPane(id: floatID)
        waitForLayout("float focused", delay: FloatScrimView.fadeDuration + 0.2)

        XCTAssertTrue(store(controller).activeWorklane?.floatOwnsFocus == true)
        XCTAssertTrue(scrim.isScrimVisible)
        XCTAssertFalse(scrim.isHidden)
        XCTAssertEqual(scrim.alphaValue, 1, accuracy: 0.001)
    }

    func test_scrim_hidden_during_peek() throws {
        let controller = try makeFloatedController()
        let root = controller.rootViewControllerForTesting
        let scrim = canvas(controller).floatLayerView.scrimViewForTesting
        XCTAssertFalse(scrim.isHiddenOrHasHiddenAncestor)

        root.peekControllerForTesting.handleTab(forward: true)
        waitForLayout("peek opened", delay: 0.5)
        XCTAssertTrue(scrim.isHiddenOrHasHiddenAncestor, "peek hides the float layer and its scrim")

        root.peekControllerForTesting.handleEscape()
        waitForLayout("peek closed", delay: 0.6)
        XCTAssertTrue(store(controller).activeWorklane?.floatOwnsFocus == true)
        XCTAssertTrue(scrim.isScrimVisible)
        XCTAssertFalse(scrim.isHiddenOrHasHiddenAncestor, "the dim returns with the float layer")
    }

    // MARK: - Events

    private func click(at windowPoint: CGPoint, in controller: MainWindowController) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            clock += 0.05
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
            NSApp.postEvent(event, atStart: true)
            let dequeued = try XCTUnwrap(NSApp.nextEvent(
                matching: [.leftMouseDown, .leftMouseUp],
                until: Date(),
                inMode: .default,
                dequeue: true
            ))
            controller.window.sendEvent(dequeued)
        }
    }

    /// A point on the tile left of the float, in window coordinates.
    private func tilePointOutsideFloat(in controller: MainWindowController) throws -> CGPoint {
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let point = CGPoint(x: host.paneFrame.minX / 2, y: host.paneFrame.midY)
        XCTAssertFalse(host.frame.contains(point))
        return layer.convert(point, to: nil)
    }

    // MARK: - Fixtures

    private func makeFloatedController() throws -> MainWindowController {
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
                        PaneState(id: tileID, title: "a"),
                        PaneState(id: floatID, title: "b"),
                    ],
                    focusedPaneID: floatID
                )
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")

        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.6)
        store(controller).moveFloat(floatID, frame: seededFloatFrame)
        waitForLayout("placed", delay: FloatScrimView.fadeDuration + 0.2)
        XCTAssertTrue(store(controller).activeWorklane?.floatOwnsFocus == true)
        adapters.values.forEach { $0.spyView.resetMouseEventsForTesting() }
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
