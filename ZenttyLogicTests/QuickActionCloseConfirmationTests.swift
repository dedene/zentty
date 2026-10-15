import XCTest

@testable import Zentty

/// Quick-action overlays die with the pane or worklane under them, so their
/// live processes must reach the close prompts even though they are not panes.
@MainActor
final class QuickActionCloseConfirmationTests: XCTestCase {
    private let worklaneID = WorklaneID("wl")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")
    private let gitDiff = RunningQuickAction(command: "git diff")
    private let shell = RunningQuickAction(command: nil)

    func test_idle_pane_with_a_live_quick_action_still_asks_before_closing() throws {
        let worklane = makeWorklane(title: "zentty", panes: [paneA])
        XCTAssertNil(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let context = try XCTUnwrap(
            PaneCloseConfirmationContext.make(paneID: paneA, in: worklane, runningQuickActions: [gitDiff])
        )
        XCTAssertNil(context.reason, "the pane itself has nothing to lose")
        XCTAssertEqual(context.runningQuickActions, [gitDiff])

        let copy = CloseConfirmationCopy.pane(context)
        XCTAssertEqual(
            copy.informativeText,
            "Quick action “git diff” is still running and will be terminated.\n\nWorklane: zentty"
        )
    }

    func test_pane_prompt_names_its_own_process_and_its_quick_action() throws {
        let worklane = makeWorklane(title: nil, panes: [paneA], running: [paneA: "pnpm dev"])
        let context = try XCTUnwrap(
            PaneCloseConfirmationContext.make(paneID: paneA, in: worklane, runningQuickActions: [shell])
        )

        XCTAssertEqual(context.reason, .runningProcess)
        XCTAssertEqual(
            CloseConfirmationCopy.pane(context).informativeText,
            "“pnpm dev” is still running and will be terminated. "
                + "A quick action is still running and will be terminated."
        )
    }

    func test_store_threads_quick_actions_into_pane_and_worklane_contexts() throws {
        let store = WorklaneStore(
            worklanes: [makeWorklane(title: nil, panes: [paneA, paneB])],
            activeWorklaneID: worklaneID
        )
        XCTAssertNil(store.paneCloseConfirmationContext(paneA))
        XCTAssertNil(store.worklaneCloseConfirmationContext(worklaneID))

        XCTAssertEqual(
            store.paneCloseConfirmationContext(paneA, runningQuickActions: [gitDiff])?.runningQuickActions,
            [gitDiff]
        )
        let worklaneContext = try XCTUnwrap(
            store.worklaneCloseConfirmationContext(worklaneID, runningQuickActions: [gitDiff])
        )
        XCTAssertEqual(worklaneContext.reason, .runningProcess)
        XCTAssertEqual(worklaneContext.runningPaneCount, 0)
    }

    func test_worklane_prompt_with_only_quick_actions_does_not_blame_a_pane() throws {
        let worklane = makeWorklane(title: "docs", panes: [paneA])
        let context = try XCTUnwrap(
            WorklaneCloseConfirmationContext.make(worklane: worklane, runningQuickActions: [gitDiff])
        )

        XCTAssertEqual(
            CloseConfirmationCopy.worklane(context).informativeText,
            "Quick action “git diff” is still running and will be terminated."
        )
    }

    func test_worklane_prompt_lists_running_panes_then_quick_actions() throws {
        let worklane = makeWorklane(title: nil, panes: [paneA, paneB], running: [paneA: "pnpm dev"])
        let context = try XCTUnwrap(
            WorklaneCloseConfirmationContext.make(
                worklane: worklane,
                runningQuickActions: [gitDiff, shell, RunningQuickAction(command: "git diff")]
            )
        )

        XCTAssertEqual(
            CloseConfirmationCopy.worklane(context).informativeText,
            "1 of 2 panes has a running process that will be terminated: pnpm dev. "
                + "3 quick actions are still running and will be terminated: git diff (2)."
        )
    }

    func test_worklane_history_prompt_switches_to_running_when_a_quick_action_is_live() throws {
        let worklane = makeWorklane(title: nil, panes: [paneA, paneB], history: [paneA])
        XCTAssertEqual(WorklaneCloseConfirmationContext.make(worklane: worklane)?.reason, .sessionHistory)

        let context = try XCTUnwrap(
            WorklaneCloseConfirmationContext.make(worklane: worklane, runningQuickActions: [shell])
        )
        XCTAssertEqual(context.reason, .runningProcess)
        XCTAssertEqual(
            CloseConfirmationCopy.worklane(context).informativeText,
            "A quick action is still running and will be terminated."
        )
    }

    // MARK: - Helpers

    private func makeWorklane(
        title: String?,
        panes: [PaneID],
        running: [PaneID: String] = [:],
        history: [PaneID] = []
    ) -> WorklaneState {
        var worklane = WorklaneState(
            id: worklaneID,
            title: title,
            paneStripState: PaneStripState(
                panes: panes.map { PaneState(id: $0, title: "shell") },
                focusedPaneID: panes.first
            )
        )
        for (paneID, command) in running {
            var aux = worklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
            aux.shellActivityState = .commandRunning
            aux.raw.lastRunCommand = command
            worklane.auxiliaryStateByPaneID[paneID] = aux
        }
        for paneID in history {
            var aux = worklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
            aux.hasCommandHistory = true
            worklane.auxiliaryStateByPaneID[paneID] = aux
        }
        return worklane
    }
}
