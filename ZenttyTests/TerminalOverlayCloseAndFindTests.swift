import AppKit
import XCTest
@testable import Zentty

/// Close prompts and pane search with quick-action overlays: overlays die with
/// the pane or worklane under them, and search must not act on a covered pane.
@MainActor
final class TerminalOverlayCloseAndFindTests: XCTestCase {
    private func mockController(adapter: OverlayTestAdapter = OverlayTestAdapter()) -> MainWindowController {
        let controller = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            overlayAdapterFactory: { _ in adapter }
        ).prepareForHostedTesting()
        addTeardownBlock {
            if let sheet = controller.window.attachedSheet { controller.window.endSheet(sheet) }
            controller.closeWindowBypassingConfirmation()
        }
        controller.showWindow(nil)
        return controller
    }

    private func options(placement: PaneOverlayIPCOptions.Placement) -> PaneOverlayIPCOptions {
        PaneOverlayIPCOptions(command: "test command", workingDirectory: "/tmp", wait: true,
                              follow: false, notify: false, sizePercent: 100, placement: placement)
    }

    /// Lets deferred focus retries in the pane strip run.
    private func settleFocus() {
        let settled = expectation(description: "focus settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    func test_closing_a_pane_asks_first_while_its_hidden_overlay_is_live() throws {
        let adapter = OverlayTestAdapter()
        adapter.needsConfirmQuit = true
        let controller = mockController(adapter: adapter)
        let lane = controller.worklaneStore.activeWorklaneID
        let paneB = try XCTUnwrap(controller.splitWithLayout(placement: .afterFocused, isHorizontal: true, layout: .equal))
        _ = try controller.openOverlay(on: paneB, options: options(placement: .pane))
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: paneB))
        session.hide()
        controller.focusPane(id: paneB, in: lane)
        settleFocus()

        controller.closeFocusedPane(nil)
        let sheet = try XCTUnwrap(controller.window.attachedSheet, "the overlay's process would die silently")
        XCTAssertNotNil(controller.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == paneB })
        controller.window.endSheet(sheet)
        settleFocus()

        adapter.needsConfirmQuit = false
        controller.focusPane(id: paneB, in: lane)
        controller.closeFocusedPane(nil)
        XCTAssertNil(controller.window.attachedSheet)
        XCTAssertNil(controller.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == paneB })
        XCTAssertEqual(adapter.closeCount, 1)
    }

    func test_close_prompts_see_the_overlays_that_close_with_a_pane_or_worklane() throws {
        let adapter = OverlayTestAdapter()
        let controller = mockController(adapter: adapter)
        let root = controller.rootViewControllerForTesting
        let lane = controller.worklaneStore.activeWorklaneID
        let paneA = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        let paneB = try XCTUnwrap(controller.splitWithLayout(placement: .afterFocused, isHorizontal: true, layout: .equal))
        _ = try controller.openOverlay(on: paneA, options: options(placement: .worklane))
        _ = try controller.openOverlay(on: paneB, options: options(placement: .pane))
        let running = RunningQuickAction(command: "test command")

        XCTAssertEqual(root.runningQuickActionsClosingWithWorklane?(lane), [], "idle overlays need no prompt")

        adapter.needsConfirmQuit = true
        XCTAssertEqual(root.runningQuickActionsClosingWithPane?(paneB), [running])
        XCTAssertEqual(root.runningQuickActionsClosingWithPane?(paneA), [], "the worklane overlay outlives paneA")
        XCTAssertEqual(root.runningQuickActionsClosingWithWorklane?(lane), [running, running])

        _ = controller.worklaneStore.closePane(id: paneB)
        XCTAssertEqual(
            root.runningQuickActionsClosingWithPane?(paneA), [running],
            "closing the last pane closes the worklane and its overlay"
        )
    }

    func test_pane_search_leaves_the_pane_under_a_focused_overlay_alone() throws {
        let controller = mockController()
        let root = controller.rootViewControllerForTesting
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options(placement: .pane))
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        XCTAssertTrue(session.holdsKeyboardFocus)

        XCTAssertFalse(root.isCommandAvailable(.find))
        controller.find(nil)
        XCTAssertNotEqual(root.focusedPaneSearchStateForTesting?.isHUDVisible, true)
        XCTAssertTrue(session.holdsKeyboardFocus)

        session.hide()
        settleFocus()
        XCTAssertTrue(root.isCommandAvailable(.find))
        controller.find(nil)
        XCTAssertEqual(root.focusedPaneSearchStateForTesting?.isHUDVisible, true)
    }
}
