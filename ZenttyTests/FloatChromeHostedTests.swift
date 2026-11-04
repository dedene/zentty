import XCTest
@testable import Zentty

/// Hosted slice for the pane chrome: real window clicks on the right-legend
/// buttons of tiles and floats, and the float container's wiring.
@MainActor
final class FloatChromeHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-chrome")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")

    private var controller: MainWindowController?

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        super.tearDown()
    }

    // MARK: - Tile

    func test_tile_float_button_click_floats_pane() throws {
        let controller = try makeSeededController()
        let tileView = try XCTUnwrap(canvas(controller).paneStripView.paneContainerViewForTesting(floatID))
        tileView.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            tileView.borderActionsViewForTesting.buttonForTesting(.float),
            "the focused tile shows its float button"
        )
        XCTAssertNotNil(tileView.borderActionsFrameForTesting)

        try click(button, in: controller)
        waitForLayout("floated")

        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
        XCTAssertNotNil(canvas(controller).floatLayerView.containerForTesting(floatID))
    }

    // MARK: - Float

    func test_float_mounts_inside_float_container_view() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let container = try XCTUnwrap(layer.containerForTesting(floatID))
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))

        XCTAssertTrue(container.superview === host)
        XCTAssertTrue(host.superview === layer)
        XCTAssertEqual(container.chromeKind, .float)
        XCTAssertEqual(host.paneFrame, host.convert(container.frame, to: layer))
        XCTAssertEqual(host.shadowLayersForTesting.count, 2)
        XCTAssertEqual(container.layer?.shadowOpacity, 0)
    }

    func test_float_pip_button_pips() throws {
        let controller = try makeFloatedController()

        try click(try floatButton(.pip, in: controller), in: controller)
        waitForLayout("pip")

        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: floatID))
        XCTAssertEqual(float.mode.wireName, "pip")
        XCTAssertNotNil(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        XCTAssertNil(canvas(controller).floatLayerView.floatHostForTesting(floatID))
        XCTAssertEqual(canvas(controller).floatLayerView.containerForTesting(floatID)?.chromeKind, .pip)
    }

    func test_float_minimize_button_minimizes() throws {
        let controller = try makeFloatedController()

        try click(try floatButton(.minimize, in: controller), in: controller)
        waitForLayout("minimized")

        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: floatID))
        XCTAssertEqual(float.mode.wireName, "minimized")
        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(floatID))
    }

    func test_float_dock_button_docks_to_origin() throws {
        let controller = try makeFloatedController()

        try click(try floatButton(.dock, in: controller), in: controller)
        waitForLayout("docked")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [tileID, floatID])
        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(floatID))
    }

    func test_float_close_button_closes_only_float() throws {
        let controller = try makeFloatedController()

        try click(try floatButton(.close, in: controller), in: controller)
        waitForLayout("closed")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.allPanes.map(\.id), [tileID])
        XCTAssertTrue(controller.window.isVisible)
    }

    func test_float_container_gets_strip_providers_and_context_menu() throws {
        let controller = try makeFloatedController()
        let root = controller.rootViewControllerForTesting
        var copied: [String] = []
        root.pasteboardStringWriterForTesting = { copied.append($0) }
        let container = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))

        XCTAssertNotNil(container.rightPaneCommandPresentationProvider)
        XCTAssertNotNil(container.moveToWorklaneCatalogProvider)
        XCTAssertNotNil(container.restoredRerunnableCommandProvider)
        XCTAssertNotNil(container.agentForkAvailabilityProvider)
        XCTAssertNotNil(container.contextMenuForTesting())
        let onBorderContextClicked = try XCTUnwrap(container.onBorderContextClicked)

        onBorderContextClicked(floatID)

        XCTAssertEqual(copied, ["/tmp/float-cwd"])
    }

    // MARK: - Fixtures

    private func floatButton(_ action: PaneBorderAction, in controller: MainWindowController) throws -> NSButton {
        let container = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))
        container.layoutSubtreeIfNeeded()
        return try XCTUnwrap(container.borderActionsViewForTesting.buttonForTesting(action))
    }

    private func click(_ button: NSButton, in controller: MainWindowController) throws {
        let windowPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = controller.window.contentView?.hitTest(
            controller.window.contentView!.convert(windowPoint, from: nil)
        )
        XCTAssertTrue(hit === button, "the button wins the window hit test, got \(String(describing: hit))")
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        NSApp.postEvent(mouseUp, atStart: false)
        controller.window.sendEvent(mouseDown)
    }

    private func makeFloatedController() throws -> MainWindowController {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated")
        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
        return controller
    }

    private func makeSeededController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
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
                auxiliaryStateByPaneID: [
                    floatID: PaneAuxiliaryState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/float-cwd",
                            home: nil,
                            user: nil,
                            host: nil
                        )
                    ),
                ]
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
        wait(for: [settled], timeout: 2.0)
    }
}
