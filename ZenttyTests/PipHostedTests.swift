import XCTest
@testable import Zentty

/// PiPs through the real window: the hover legend's buttons take real
/// clicks, a click restores at the last float frame, a focused float hands
/// focus away when it shrinks, and a PiP mounted from a pill is primed at
/// the unscaled float size before it is scaled.
@MainActor
final class PipHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-pip")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")

    private var controller: MainWindowController?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: - Legend

    func test_legend_restore_button_restores_the_float() throws {
        let controller = try makePipController()

        try click(try legendButton(.restore, in: controller), in: controller)
        waitForLayout("restored")

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode, .floating)
        XCTAssertNotNil(canvas(controller).floatLayerView.floatHostForTesting(floatID))
    }

    func test_legend_minimize_button_sends_the_pip_to_the_pill_bar() throws {
        let controller = try makePipController()

        try click(try legendButton(.minimize, in: controller), in: controller)
        waitForLayout("minimized")

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode.wireName, "minimized")
        XCTAssertNil(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        XCTAssertNotNil(canvas(controller).pillBarView.pillViewForTesting(floatID))
    }

    func test_legend_close_button_closes_only_the_pip() throws {
        let controller = try makePipController()

        try click(try legendButton(.close, in: controller), in: controller)
        waitForLayout("closed")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.allPanes.map(\.id), [tileID])
        XCTAssertEqual(adapters[floatID]?.closeCount, 1)
    }

    // MARK: - Click, focus

    func test_click_on_the_picture_restores_at_the_last_float_frame() throws {
        let controller = try makeFloatedController()
        let floatFrame = try XCTUnwrap(canvas(controller).floatLayerView.floatHostForTesting(floatID)?.paneFrame)
        store(controller).pipPane(floatID)
        waitForLayout("pip")
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        let point = pip.convert(CGPoint(x: pip.bounds.midX, y: pip.bounds.midY), to: nil)
        let contentView = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(contentView.hitTest(contentView.convert(point, from: nil)) === pip, "the PiP owns the click")
        var restoreMotions: [CGRect] = []
        canvas(controller).floatLayerView.onPipMotionForTesting = { _, frame in restoreMotions.append(frame) }

        try sendClick(at: point, in: controller)
        waitForLayout("restored")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(worklane.floatingPane(id: floatID)?.mode, .floating)
        XCTAssertEqual(worklane.focusedPaneID, floatID)
        XCTAssertEqual(canvas(controller).floatLayerView.floatHostForTesting(floatID)?.paneFrame, floatFrame)
        XCTAssertEqual(restoreMotions.count, 1, "springs out of the corner")
        XCTAssertEqual(adapters[floatID]?.spyView.mouseEventTypes, [], "the terminal never saw the click")
    }

    func test_focused_float_shrinking_to_pip_hands_focus_to_the_tile() throws {
        let controller = try makeFloatedController()
        let floatContainer = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: floatContainer) == true)

        store(controller).pipPane(floatID)
        waitForLayout("pip")

        XCTAssertEqual(store(controller).activeWorklane?.focusedPaneID, tileID)
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        let responder = controller.window.firstResponder as? NSView
        XCTAssertFalse(responder?.isDescendant(of: pip) == true, "a PiP never holds keyboard focus")
        let tile = try XCTUnwrap(canvas(controller).paneStripView.paneContainerViewForTesting(tileID))
        XCTAssertTrue(responder?.isDescendant(of: tile) == true, "the tile takes it back")
    }

    // MARK: - Unscaled prime (queued follow-up from Task 9)

    func test_pip_promoted_from_a_pill_is_primed_at_the_unscaled_float_size() throws {
        let controller = try makeFloatedController()
        let floatSize = try XCTUnwrap(canvas(controller).floatLayerView.floatHostForTesting(floatID)?.paneFrame.size)
        store(controller).minimizePane(floatID)
        waitForLayout("minimized")
        let spy = try XCTUnwrap(adapters[floatID]?.spyView)
        spy.suspensionLog.removeAll()
        spy.forcedSyncLog.removeAll()

        store(controller).pipPane(floatID)
        waitForLayout("pip")

        let primeIndex = try XCTUnwrap(
            spy.suspensionLog.firstIndex { !$0.suspended && !$0.wasInPip },
            "the fresh container syncs before it is scaled"
        )
        XCTAssertEqual(spy.suspensionLog[primeIndex].containerSize, floatSize)
        XCTAssertTrue(spy.forcedSyncLog.contains { !$0.wasInPip && $0.containerSize == floatSize })
        XCTAssertFalse(spy.suspensionLog.contains { !$0.suspended && $0.wasInPip }, "never resumed while scaled")
        XCTAssertFalse(spy.forcedSyncLog.contains { $0.wasInPip }, "never forced while scaled")
        XCTAssertEqual(spy.isViewportSyncSuspended, true)
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        XCTAssertEqual(pip.scaleViewForTesting.bounds.width, floatSize.width, accuracy: 0.001)
        XCTAssertEqual(pip.scaleViewForTesting.bounds.height, floatSize.height, accuracy: 0.001)
    }

    // MARK: - Fixtures

    private func legendButton(_ action: PaneBorderAction, in controller: MainWindowController) throws -> NSButton {
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        pip.setHovered(true)
        return try XCTUnwrap(pip.actionsViewForTesting.buttonForTesting(action))
    }

    private func click(_ button: NSButton, in controller: MainWindowController) throws {
        let windowPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let contentView = try XCTUnwrap(controller.window.contentView)
        let hit = contentView.hitTest(contentView.convert(windowPoint, from: nil))
        XCTAssertTrue(hit === button, "the legend button wins the window hit test, got \(String(describing: hit))")
        try sendClick(at: windowPoint, in: controller)
    }

    private func sendClick(at windowPoint: CGPoint, in controller: MainWindowController) throws {
        let mouseDown = try XCTUnwrap(mouseEvent(.leftMouseDown, at: windowPoint, in: controller))
        let mouseUp = try XCTUnwrap(mouseEvent(.leftMouseUp, at: windowPoint, in: controller))
        NSApp.postEvent(mouseUp, atStart: false)
        controller.window.sendEvent(mouseDown)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in controller: MainWindowController) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private func makePipController() throws -> MainWindowController {
        let controller = try makeFloatedController()
        store(controller).pipPane(floatID)
        waitForLayout("pip")
        XCTAssertNotNil(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        return controller
    }

    private func makeFloatedController() throws -> MainWindowController {
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
        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
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
