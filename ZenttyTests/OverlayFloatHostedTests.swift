import XCTest
@testable import Zentty

/// `zentty overlay …` through the real window: the IPC handler opens a
/// temporary float that mounts in the float layer on the shared runtime
/// registry, and closing it (or its owner) closes that runtime.
@MainActor
final class OverlayFloatHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-overlay")
    private let tileID = PaneID("pane-a")
    private let otherTileID = PaneID("pane-b")

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

    func test_ipc_open_mounts_a_focused_temporary_float_running_the_command() throws {
        let controller = try makeSeededController()

        let stdout = try dispatch(.overlayOpen, arguments: [
            "--wait", "--placement", "pane", "--command-json", "[\"htop\"]",
        ])
        waitForLayout("overlay mounted")

        let id = PaneID(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(worklane.floatingPane(id: id)?.mode, .floating, "the id printed is the float's pane id")
        XCTAssertEqual(
            worklane.auxiliaryStateByPaneID[id]?.lifetime,
            .temporary(owner: tileID, placement: .pane, waitAfterCommand: true)
        )
        let container = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(id))
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: container), "the overlay float takes focus")
        XCTAssertEqual(worklane.paneStripState.focusedPaneID, tileID, "the strip focus stays on the owner")

        let request = try XCTUnwrap(adapters[id]?.lastRequest)
        XCTAssertTrue(request.nativeCommand?.contains("htop") == true)
        XCTAssertTrue(request.waitAfterNativeCommand)

        let canvasBounds = canvas(controller).floatLayerView.bounds
        let floatFrame = try XCTUnwrap(worklane.floatingPane(id: id)?.floatFrame.resolved(in: canvasBounds))
        let tileFrame = try XCTUnwrap(canvas(controller).tileFrameInFloatLayer(for: tileID))
        XCTAssertEqual(floatFrame.midX, tileFrame.midX, accuracy: 1, "a pane overlay opens over its owner")
        XCTAssertEqual(floatFrame.width, tileFrame.width - 32, accuracy: 1)
    }

    func test_ipc_close_closes_the_overlays_runtime() throws {
        let controller = try makeSeededController()
        let id = PaneID(try dispatch(.overlayOpen, arguments: ["--command-json", "[\"sleep\",\"30\"]"])
            .trimmingCharacters(in: .whitespacesAndNewlines))
        waitForLayout("overlay mounted")
        let list = try dispatch(.overlayList)
        XCTAssertTrue(list.contains(id.rawValue))
        XCTAssertTrue(list.contains("\"mode\" : \"floating\""))

        _ = try dispatch(.overlayClose)
        waitForLayout("overlay closed")

        XCTAssertFalse(store(controller).activeWorklane?.containsPane(id: id) == true)
        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(id))
        XCTAssertEqual(adapters[id]?.closeCount, 1)
        XCTAssertEqual(adapters[tileID]?.closeCount, 0)
    }

    func test_closing_the_owner_closes_its_pane_overlay_and_asks_first_while_it_runs() throws {
        let controller = try makeSeededController()
        let result = try controller.openOverlay(on: tileID, options: options(placement: .pane))
        waitForLayout("overlay mounted")
        adapters[result.id]?.needsConfirmQuit = true

        let running = controller.rootViewControllerForTesting.runningQuickActionsClosingWithPane?(tileID) ?? []
        XCTAssertEqual(running.count, 1, "the close prompt names the overlay that dies with the pane")
        XCTAssertTrue(running.first?.command?.contains("sleep") == true)
        XCTAssertTrue(controller.rootViewControllerForTesting.runningQuickActionsClosingWithPane?(otherTileID).isEmpty != false)

        store(controller).closePane(id: tileID)
        waitForLayout("owner closed")

        XCTAssertNil(store(controller).worklaneIndex(containingPane: result.id))
        XCTAssertEqual(adapters[result.id]?.closeCount, 1)
    }

    func test_following_a_notify_overlay_to_its_pane_reveals_and_focuses_it() throws {
        let controller = try makeSeededController()
        controller.newWorklane(nil)
        waitForLayout("second worklane")
        XCTAssertNotEqual(store(controller).activeWorklaneID, worklaneID)

        let notifyOptions = PaneOverlayIPCOptions(
            command: "/bin/sleep 30", workingDirectory: "/tmp", wait: true,
            follow: false, notify: true, sizePercent: 100, placement: .worklane
        )
        let id = try controller.openOverlay(on: tileID, options: notifyOptions).id
        waitForLayout("background overlay")
        XCTAssertNotEqual(store(controller).activeWorklaneID, worklaneID, "opening out of sight keeps the selection")

        controller.navigateToPane(worklaneID: worklaneID, paneID: tileID)
        waitForLayout("navigated")

        XCTAssertEqual(store(controller).activeWorklaneID, worklaneID)
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: id)?.mode, .floating)
        let container = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(id))
        let responder = try XCTUnwrap(controller.window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: container))
    }

    // MARK: - Helpers

    private func options(placement: OverlayPlacement) -> PaneOverlayIPCOptions {
        PaneOverlayIPCOptions(
            command: "/bin/sleep 30", workingDirectory: "/tmp", wait: true,
            follow: false, notify: false, sizePercent: 100, placement: placement
        )
    }

    private func dispatch(_ subcommand: PaneIPCSubcommand, arguments: [String] = []) throws -> String {
        let controller = try XCTUnwrap(controller)
        let request = AgentIPCRequest(
            kind: .pane, arguments: arguments, standardInput: nil,
            environment: [:], expectsResponse: true, subcommand: subcommand.rawValue
        )
        let target = AgentIPCTarget(windowID: controller.windowID, worklaneID: worklaneID, paneID: tileID)
        let result = try PaneIPCHandler.dispatch(
            subcommand: subcommand, request: request, target: target,
            windowController: controller, appDelegate: AppDelegate(shouldOpenMainWindow: false)
        )
        return result.stdout ?? ""
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
                        PaneState(id: otherTileID, title: "b", sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp")),
                    ],
                    focusedPaneID: tileID
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

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.15) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }
}
