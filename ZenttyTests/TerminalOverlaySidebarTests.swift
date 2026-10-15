import AppKit
import XCTest
@testable import Zentty

/// The overlay's shell reports `cd` and commands under the overlay's own ID;
/// those signals must reach the overlay, not the worklane store.
@MainActor
final class TerminalOverlaySidebarTests: XCTestCase {
    func test_overlay_shell_signals_reach_the_overlay_and_pane_signals_still_reach_the_store() throws {
        let adapter = OverlayTestAdapter()
        let controller = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            overlayAdapterFactory: { _ in adapter }
        ).prepareForHostedTesting()
        addTeardownBlock { controller.closeWindowBypassingConfirmation() }
        controller.showWindow(nil)
        let root = controller.rootViewControllerForTesting
        let lane = controller.worklaneStore.activeWorklaneID
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        let overlayID = try controller.openOverlay(on: pane, options: PaneOverlayIPCOptions(
            command: "", workingDirectory: "/tmp", wait: false,
            follow: false, notify: false, sizePercent: 100, placement: .pane
        ))
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))

        let environment = try XCTUnwrap(adapter.request?.environmentVariables)
        XCTAssertEqual(environment["ZENTTY_PANE_ID"], overlayID, "the shell must report as the overlay")

        let overlayPayload = paneContext(lane: lane, pane: PaneID(overlayID), path: "/private/var")
        XCTAssertEqual(root.onOverlayAgentStatusPayload?(overlayPayload), true)
        XCTAssertEqual(session.sidebarOverlay.workingDirectory, "/private/var")

        let panePayload = paneContext(lane: lane, pane: pane, path: "/private/var")
        XCTAssertEqual(root.onOverlayAgentStatusPayload?(panePayload), false)
    }

    private func paneContext(lane: WorklaneID, pane: PaneID, path: String) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: lane, paneID: pane, signalKind: .paneContext, state: nil,
            paneContext: PaneShellContext(scope: .local, path: path, home: NSHomeDirectory(), user: nil, host: nil),
            origin: .shell, toolName: nil, text: nil, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        )
    }
}
