import XCTest
@testable import Zentty

/// Hosted slice for floating panes: a real window, the real render path and
/// the shared runtime registry. Floating, docking, minimizing and closing must
/// keep using the pane's one runtime and host view.
@MainActor
final class FloatLifecycleHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-float")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        registry = nil
        adapters = [:]
        super.tearDown()
    }

    // MARK: - Tests

    func test_floating_a_pane_reuses_the_same_host_view() throws {
        let controller = try makeSeededController()
        let runtimeBefore = try XCTUnwrap(registry?.runtime(for: floatID))
        let hostViewBefore = runtimeBefore.hostView
        XCTAssertTrue(hostViewBefore.isDescendant(of: canvas(controller).paneStripView))

        controller.toggleFloat(nil)
        waitForLayout("floated")

        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
        XCTAssertTrue(registry?.runtime(for: floatID) === runtimeBefore)
        XCTAssertTrue(runtimeBefore.hostView === hostViewBefore)
        let floatContainer = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertTrue(hostViewBefore.isDescendant(of: floatContainer))
        XCTAssertFalse(hostViewBefore.isDescendant(of: canvas(controller).paneStripView))
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
        XCTAssertEqual(adapters[floatID]?.startCount, 1)
    }

    func test_floated_pane_receives_isFocused() throws {
        let controller = try makeSeededController()

        controller.toggleFloat(nil)
        waitForLayout("floated")

        let floatContainer = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: floatContainer), "the float's terminal takes first responder")
        XCTAssertTrue(store(controller).activeWorklane?.floatOwnsFocus == true)

        // The hosted runner cannot make the window key (.prohibited policy),
        // so drive the activity pass with a key window over the real state.
        let worklanes = store(controller).worklanes
        registry?.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: worklaneID,
            windowIsVisible: true,
            windowIsKey: true,
            peekVisibleWorklaneIDs: []
        )
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isFocused, true)
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isVisible, true)
        XCTAssertEqual(adapters[tileID]?.lastActivity?.isFocused, false)
    }

    func test_minimized_float_is_occluded() throws {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated")
        let runtime = try XCTUnwrap(registry?.runtime(for: floatID))

        store(controller).minimizePane(floatID)
        waitForLayout("minimized")

        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertNil(runtime.hostView.window, "a minimized float is not mounted anywhere")
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isVisible, false)
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isFocused, false)
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
        XCTAssertTrue(registry?.runtime(for: floatID) === runtime)
        let tileHostView = try XCTUnwrap(registry?.runtime(for: tileID)?.hostView)
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: tileHostView), "keyboard focus returns to the strip")

        registry?.updateSurfaceActivities(
            worklanes: store(controller).worklanes,
            activeWorklaneID: worklaneID,
            windowIsVisible: true,
            windowIsKey: true,
            peekVisibleWorklaneIDs: []
        )
        XCTAssertEqual(adapters[floatID]?.lastActivity?.isVisible, false, "still occluded once the window is key")
    }

    func test_dock_back_reuses_host_view() throws {
        let controller = try makeSeededController()
        let runtime = try XCTUnwrap(registry?.runtime(for: floatID))
        let hostView = runtime.hostView
        controller.toggleFloat(nil)
        waitForLayout("floated")

        controller.toggleFloat(nil)
        waitForLayout("docked")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [tileID, floatID])
        XCTAssertTrue(registry?.runtime(for: floatID) === runtime)
        XCTAssertTrue(runtime.hostView === hostView)
        XCTAssertTrue(hostView.isDescendant(of: canvas(controller).paneStripView))
        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
        XCTAssertEqual(adapters[floatID]?.startCount, 1)
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: hostView), "the docked pane keeps keyboard focus")
    }

    func test_close_float_closes_only_it() throws {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated")

        controller.closePane(id: floatID)
        waitForLayout("closed")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.allPanes.map(\.id), [tileID])
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertEqual(adapters[floatID]?.closeCount, 1)
        XCTAssertEqual(adapters[tileID]?.closeCount, 0)
        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertNil(registry?.runtime(for: floatID))
    }

    // MARK: - PiP mount and viewport suspension

    func test_enter_pip_suspends_before_reparenting_into_scaled_host() throws {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        // Floating in place keeps the grid frozen until the lift lands.
        waitForLayout("floated", delay: 0.6)
        let spyView = try spyTerminalView(floatID)
        XCTAssertEqual(spyView.isViewportSyncSuspended, false, "a floating pane syncs its viewport")
        spyView.suspensionLog.removeAll()

        store(controller).pipPane(floatID)
        waitForLayout("pip")

        let layer = canvas(controller).floatLayerView
        let pipHost = try XCTUnwrap(layer.pipHostForTesting(floatID))
        let container = try XCTUnwrap(layer.containerForTesting(floatID))
        XCTAssertTrue(container.superview === pipHost.scaleViewForTesting, "the container moves under the PiP host")
        XCTAssertTrue(spyView.isDescendant(of: pipHost))
        let scaleView = pipHost.scaleViewForTesting
        XCTAssertNotEqual(scaleView.bounds.size, scaleView.frame.size, "the PiP draws the float scaled")
        XCTAssertEqual(spyView.isViewportSyncSuspended, true, "the grid stays frozen while scaled")
        let firstSuspend = try XCTUnwrap(spyView.suspensionLog.first)
        XCTAssertTrue(firstSuspend.suspended)
        XCTAssertFalse(firstSuspend.wasInPip, "suspend happens before the container is scaled")
        XCTAssertFalse(
            spyView.suspensionLog.contains { !$0.suspended && $0.wasInPip },
            "never unsuspended while scaled"
        )
    }

    func test_leave_pip_reparents_unscaled_then_unsuspends() throws {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated")
        store(controller).pipPane(floatID)
        waitForLayout("pip")
        let spyView = try spyTerminalView(floatID)
        spyView.suspensionLog.removeAll()

        store(controller).restoreFloat(floatID)
        waitForLayout("restored")

        let layer = canvas(controller).floatLayerView
        XCTAssertNil(layer.pipHostForTesting(floatID))
        let container = try XCTUnwrap(layer.containerForTesting(floatID))
        XCTAssertTrue(container.superview is FloatContainerView)
        XCTAssertTrue(container.superview?.superview === layer)
        XCTAssertEqual(spyView.isViewportSyncSuspended, false)
        let resume = try XCTUnwrap(spyView.suspensionLog.last { !$0.suspended })
        XCTAssertFalse(resume.wasInPip, "re-parented out of the PiP before resuming")
        XCTAssertEqual(resume.containerSize, container.frame.size, "resumes at the unscaled float size")
    }

    func test_pip_click_restores_float() throws {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated")
        store(controller).pipPane(floatID)
        waitForLayout("pip")
        let pipHost = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(floatID))
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: pipHost.convert(CGPoint(x: pipHost.bounds.midX, y: pipHost.bounds.midY), to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: controller.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }

        // A click fires on release (the press could still become a drag).
        pipHost.mouseDown(with: try event(.leftMouseDown))
        pipHost.mouseUp(with: try event(.leftMouseUp))
        waitForLayout("clicked")

        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: floatID))
        XCTAssertEqual(float.mode, .floating)
        XCTAssertNil(canvas(controller).floatLayerView.pipHostForTesting(floatID))
    }

    /// Regression: suspension lives on the shared surface. A float re-mounted
    /// after leaving the layer while suspended (PiP → minimize → restore) used
    /// to keep the PiP's frozen grid for its whole life.
    func test_float_remounted_from_suspended_surface_resumes_viewport_sync() throws {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated")
        store(controller).pipPane(floatID)
        waitForLayout("pip")
        let spyView = try spyTerminalView(floatID)
        XCTAssertEqual(spyView.isViewportSyncSuspended, true)

        store(controller).minimizePane(floatID)
        waitForLayout("minimized")
        XCTAssertEqual(spyView.isViewportSyncSuspended, true, "unmounted while suspended")

        store(controller).restoreFloat(floatID)
        waitForLayout("restored")

        let container = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertTrue(container.superview is FloatContainerView)
        XCTAssertTrue(container.superview?.superview === canvas(controller).floatLayerView)
        XCTAssertTrue(spyView.isDescendant(of: container))
        XCTAssertEqual(spyView.isViewportSyncSuspended, false, "a new floating container resumes sync")
    }

    // MARK: - Fixtures

    private func spyTerminalView(_ paneID: PaneID) throws -> HostedSpyTerminalView {
        try XCTUnwrap(adapters[paneID]?.spyView)
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
                        PaneState(id: tileID, title: "a"),
                        PaneState(id: floatID, title: "b"),
                    ],
                    focusedPaneID: floatID
                ),
                auxiliaryStateByPaneID: [:]
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")
        XCTAssertNotNil(registry.runtime(for: floatID))
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
