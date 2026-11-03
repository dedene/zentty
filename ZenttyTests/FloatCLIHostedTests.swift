import XCTest
@testable import Zentty

/// `zentty pane float|dock|pip|minimize|restore` and `zentty float
/// new|list|hide|show` through the IPC handler and the real window: the
/// mode changes mount the same live pane in the float layer, the pill bar or
/// a PiP, and a worklane that is not on screen changes without a switch.
@MainActor
final class FloatCLIHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-cli")
    private let offscreenWorklaneID = WorklaneID("wl-cli-off")
    private let tileID = PaneID("pane-a")
    private let otherTileID = PaneID("pane-b")
    private let offscreenTileID = PaneID("pane-c")
    /// Keeps `offscreenTileID` from being its worklane's only tile (which
    /// the CLI refuses to float).
    private let offscreenSpareID = PaneID("pane-d")

    private var controller: MainWindowController?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var adapterCreations: [PaneID] = []

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        adapters = [:]
        adapterCreations = []
        super.tearDown()
    }

    // MARK: - Tests

    func test_mode_commands_move_the_same_live_pane_through_every_state() throws {
        let controller = try makeSeededController()
        let layer = canvas(controller).floatLayerView
        let adapter = try XCTUnwrap(adapters[otherTileID])

        // Test pane ids lack the `pn_` prefix, so address it by its
        // `pane list` index, which stays 2 in every mode.
        try dispatch(.paneFloat, arguments: ["--target", "2"])
        waitForLayout("floated")
        XCTAssertEqual(mode(controller, otherTileID), .floating)
        XCTAssertNotNil(layer.floatHostForTesting(otherTileID))

        try dispatch(.panePip, arguments: ["--target", "2", "--corner", "top-left"])
        waitForLayout("pip")
        XCTAssertEqual(mode(controller, otherTileID), .pip(corner: .topLeft, order: 0))
        let pip = try XCTUnwrap(layer.pipHostForTesting(otherTileID))
        XCTAssertLessThan(pip.frame.midX, layer.bounds.midX, "top-left corner")
        XCTAssertGreaterThan(pip.frame.midY, layer.bounds.midY)

        try dispatch(.paneMinimize, arguments: ["--target", "2"])
        waitForLayout("pill")
        XCTAssertNotNil(canvas(controller).pillBarView.pillViewForTesting(otherTileID))
        XCTAssertNil(layer.pipHostForTesting(otherTileID))

        try dispatch(.paneRestore, arguments: ["--target", "2"])
        waitForLayout("restored")
        let float = try XCTUnwrap(layer.floatHostForTesting(otherTileID))
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: float), "restore focuses the float")

        try dispatch(.paneDock, arguments: ["--target", "2"])
        waitForLayout("docked")
        XCTAssertNil(mode(controller, otherTileID))
        XCTAssertEqual(store(controller).activeWorklane?.paneStripState.panes.map(\.id), [tileID, otherTileID])

        XCTAssertTrue(adapters[otherTileID] === adapter, "the same runtime throughout")
        XCTAssertEqual(adapter.closeCount, 0)
        XCTAssertEqual(adapterCreations.filter { $0 == otherTileID }.count, 1)
    }

    func test_pip_takes_a_tile_straight_to_a_pip() throws {
        let controller = try makeSeededController()
        let layer = canvas(controller).floatLayerView
        let pipAdapter = try XCTUnwrap(adapters[otherTileID])

        try dispatch(.panePip, arguments: ["--target", "2"])
        waitForLayout("tile to pip")

        XCTAssertEqual(mode(controller, otherTileID), .pip(corner: .bottomRight, order: 0))
        XCTAssertNotNil(layer.pipHostForTesting(otherTileID))
        XCTAssertNil(layer.floatHostForTesting(otherTileID))
        XCTAssertTrue(adapters[otherTileID] === pipAdapter)
        XCTAssertEqual(pipAdapter.closeCount, 0, "the process lives on")
    }

    func test_minimize_takes_a_tile_straight_to_a_pill() throws {
        let controller = try makeSeededController()
        let pillAdapter = try XCTUnwrap(adapters[tileID])

        try dispatch(.paneMinimize, arguments: ["--target", "1"])
        waitForLayout("tile to pill")

        XCTAssertEqual(mode(controller, tileID), .minimized(order: 0))
        XCTAssertNotNil(canvas(controller).pillBarView.pillViewForTesting(tileID))
        XCTAssertEqual(store(controller).activeWorklane?.paneStripState.panes.map(\.id), [otherTileID])
        XCTAssertTrue(adapters[tileID] === pillAdapter)
        XCTAssertEqual(pillAdapter.closeCount, 0, "the process lives on")
    }

    func test_float_pip_and_minimize_refuse_the_last_tile() throws {
        let controller = try makeSeededController()
        try dispatch(.paneMinimize, arguments: ["--target", "1"])
        waitForLayout("first tile to pill")

        for subcommand in [PaneIPCSubcommand.paneFloat, .panePip, .paneMinimize] {
            XCTAssertThrowsError(try dispatch(subcommand, target: (worklaneID, otherTileID)), "\(subcommand)") { error in
                XCTAssertEqual(error as? FloatControlIPCError, .soleTile(otherTileID.rawValue))
            }
        }
        XCTAssertEqual(store(controller).activeWorklane?.paneStripState.panes.map(\.id), [otherTileID])
    }

    func test_restore_on_a_tile_fails_and_leaves_it() throws {
        let controller = try makeSeededController()

        XCTAssertThrowsError(try dispatch(.paneRestore, arguments: ["--target", "1"])) {
            XCTAssertEqual($0 as? FloatControlIPCError, .notFloating(tileID.rawValue))
        }
        XCTAssertThrowsError(try dispatch(.paneFloat, arguments: ["--target", "9"])) {
            guard case PaneRoutingError.paneNotFound = $0 else {
                return XCTFail("unexpected error \($0)")
            }
        }
        XCTAssertNil(mode(controller, tileID))
    }

    func test_commands_on_a_worklane_off_screen_do_not_switch_to_it() throws {
        let controller = try makeSeededController()

        try dispatch(.paneMinimize, target: (offscreenWorklaneID, offscreenTileID))
        waitForLayout("minimized off screen")

        XCTAssertEqual(store(controller).activeWorklaneID, worklaneID)
        let offscreen = try XCTUnwrap(store(controller).worklanes.first { $0.id == offscreenWorklaneID })
        XCTAssertEqual(offscreen.floatingPane(id: offscreenTileID)?.mode, .minimized(order: 0))
        XCTAssertNil(canvas(controller).pillBarView.pillViewForTesting(offscreenTileID), "pills are per worklane")
        XCTAssertEqual(adapters[offscreenTileID]?.closeCount ?? 0, 0)

        let list = try XCTUnwrap(
            dispatchResult(.floatList, target: (offscreenWorklaneID, offscreenTileID)).floatList
        )
        XCTAssertEqual(list.map(\.id), [offscreenTileID.rawValue])
        XCTAssertEqual(list.first?.mode, "minimized")
        XCTAssertEqual(list.first?.windowID, controller.windowID.rawValue)
    }

    func test_float_new_list_hide_and_show() throws {
        let controller = try makeSeededController()

        let id = PaneID(try dispatch(.floatNew, arguments: ["--command-json", "[\"echo\",\"hi\"]"])
            .trimmingCharacters(in: .whitespacesAndNewlines))
        waitForLayout("float opened")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(worklane.floatingPane(id: id)?.mode, .floating, "the id printed is the float's pane id")
        XCTAssertEqual(worklane.pane(id: id)?.sessionRequest.workingDirectory, "/tmp")
        XCTAssertTrue(adapters[id]?.lastRequest?.command?.contains("echo hi") == true)
        let host = try XCTUnwrap(canvas(controller).floatLayerView.floatHostForTesting(id))
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: host), "the new float takes focus")

        var list = try XCTUnwrap(dispatchResult(.floatList).floatList)
        XCTAssertEqual(list.map(\.id), [id.rawValue])
        XCTAssertEqual(list.first?.index, 3, "numbered after the two tiles")
        XCTAssertEqual(list.first?.isFocused, true)
        XCTAssertNotNil(list.first?.frame)

        try dispatch(.floatHide)
        waitForLayout("hidden")
        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, true)
        list = try XCTUnwrap(dispatchResult(.floatList).floatList)
        XCTAssertEqual(list.first?.isHidden, true)

        try dispatch(.floatShow)
        waitForLayout("shown")
        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, false)
        XCTAssertEqual(adapters[id]?.closeCount ?? 0, 0)
    }

    // MARK: - Helpers

    @discardableResult
    private func dispatch(
        _ subcommand: PaneIPCSubcommand,
        arguments: [String] = [],
        target: (WorklaneID, PaneID)? = nil
    ) throws -> String {
        try dispatchResult(subcommand, arguments: arguments, target: target).stdout ?? ""
    }

    private func dispatchResult(
        _ subcommand: PaneIPCSubcommand,
        arguments: [String] = [],
        target: (WorklaneID, PaneID)? = nil
    ) throws -> AgentIPCResponseResult {
        let controller = try XCTUnwrap(controller)
        let request = AgentIPCRequest(
            kind: .pane, arguments: arguments, standardInput: nil,
            environment: [:], expectsResponse: true, subcommand: subcommand.rawValue
        )
        let (worklane, pane) = target ?? (worklaneID, tileID)
        return try PaneIPCHandler.dispatch(
            subcommand: subcommand,
            request: request,
            target: AgentIPCTarget(windowID: controller.windowID, worklaneID: worklane, paneID: pane),
            windowController: controller,
            appDelegate: AppDelegate(shouldOpenMainWindow: false)
        )
    }

    private func makeSeededController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = HostedSpyTerminalAdapter()
            self.adapters[paneID] = adapter
            self.adapterCreations.append(paneID)
            return adapter
        })
        let controller = MainWindowController(runtimeRegistry: registry).prepareForHostedTesting()
        self.controller = controller
        controller.showWindow(nil)
        waitForLayout()

        func pane(_ id: PaneID) -> PaneState {
            PaneState(id: id, title: id.rawValue, sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp"))
        }
        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(panes: [pane(tileID), pane(otherTileID)], focusedPaneID: tileID),
                auxiliaryStateByPaneID: [:]
            ),
            WorklaneState(
                id: offscreenWorklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [pane(offscreenSpareID), pane(offscreenTileID)],
                    focusedPaneID: offscreenTileID
                ),
                auxiliaryStateByPaneID: [:]
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

    private func mode(_ controller: MainWindowController, _ id: PaneID) -> FloatingPaneMode? {
        store(controller).activeWorklane?.floatingPane(id: id)?.mode
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.15) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }
}
