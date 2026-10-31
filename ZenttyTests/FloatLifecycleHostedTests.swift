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
    private var adapters: [PaneID: SpyTerminalAdapter] = [:]

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

    // MARK: - Fixtures

    private func makeSeededController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = SpyTerminalAdapter()
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

/// Mock terminal that records what the registry does to it.
@MainActor
private final class SpyTerminalAdapter: TerminalAdapter {
    private let terminalView = SpyTerminalView()

    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var closeCount = 0
    private(set) var startCount = 0
    private(set) var lastActivity: TerminalSurfaceActivity?

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startCount += 1
    }

    func close() {
        closeCount += 1
    }

    func sendText(_ text: String) {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastActivity = activity
    }
}

private final class SpyTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }
}
