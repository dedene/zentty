import XCTest

@testable import Zentty

@MainActor
final class CloseConfirmationContextTests: XCTestCase {
    private let worklaneID = WorklaneID("wl")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")
    private let paneC = PaneID("pane-c")

    private var repoPath: String {
        NSHomeDirectory() + "/Development/Personal/zentty"
    }

    // MARK: - Pane context

    func test_pane_context_uses_custom_title_and_last_command() throws {
        let worklane = makeWorklane(
            title: "zentty",
            panes: [PaneState(id: paneA, title: "shell", customTitle: "api")],
            metadata: [paneA: TerminalMetadata(currentWorkingDirectory: repoPath, processName: "node", gitBranch: "main")],
            running: [paneA: "pnpm dev"]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.reason, .runningProcess)
        XCTAssertEqual(context.paneName, "api")
        XCTAssertEqual(context.worklaneName, "zentty")
        XCTAssertEqual(context.runningActivity, "pnpm dev")
        XCTAssertEqual(context.locationLine, "main · ~/Development/Personal/zentty")
    }

    func test_pane_context_names_recognized_agent_as_activity() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(currentWorkingDirectory: repoPath, processName: "claude", gitBranch: "main")],
            running: [paneA: "claude"]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.reason, .runningProcess)
        XCTAssertEqual(context.runningActivity, "Claude Code")
        XCTAssertNil(context.worklaneName)
        XCTAssertFalse(context.paneName.isEmpty)
    }

    func test_pane_context_resolves_agent_from_running_command_with_flags_and_env() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "node")],
            running: [paneA: "FOO=1 /opt/homebrew/bin/claude --resume abc123"]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.activity, .tool("Claude Code"))
    }

    func test_pane_context_prefers_running_command_over_stale_recognized_tool() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "claude")],
            running: [paneA: "pnpm dev"]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.activity, .command("pnpm dev"))
        XCTAssertNotEqual(context.paneName, "Claude Code")
    }

    func test_pane_context_keeps_recognized_tool_name_when_idle() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "claude")],
            history: [paneA]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.paneName, "Claude Code")
    }

    func test_pane_context_uses_remote_location_for_remote_shells() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(currentWorkingDirectory: repoPath, gitBranch: "main")],
            shellContext: [
                paneA: PaneShellContext(
                    scope: .remote, path: "/srv/app", home: "/home/deploy", user: "deploy", host: "web-1")
            ],
            running: [paneA: "tail -f log"]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let location = try XCTUnwrap(context.locationLine)
        XCTAssertTrue(location.hasPrefix("web-1"), location)
        XCTAssertFalse(location.contains("Development"), location)
    }

    func test_pane_context_ignores_plain_shell_process_as_activity() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "zsh")],
            running: [paneA: nil]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.reason, .runningProcess)
        XCTAssertNil(context.runningActivity)
        XCTAssertNil(context.locationLine)
    }

    func test_pane_context_truncates_long_commands() throws {
        let longCommand = "pnpm exec vitest run --coverage --reporter=verbose --watch=false src/components"
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "node")],
            running: [paneA: longCommand]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let activity = try XCTUnwrap(context.runningActivity)
        XCTAssertLessThanOrEqual(activity.count, PaneCloseConfirmationContext.maximumActivityLength)
        XCTAssertTrue(activity.hasSuffix("…"), activity)
        XCTAssertTrue(activity.hasPrefix("pnpm exec vitest"), activity)
    }

    func test_pane_context_reports_session_history_when_idle() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [:],
            history: [paneA]
        )

        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        XCTAssertEqual(context.reason, .sessionHistory)
        XCTAssertNil(context.runningActivity)
    }

    func test_pane_context_is_nil_when_nothing_to_confirm() {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [:]
        )

        XCTAssertNil(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))
    }

    // MARK: - Pane copy

    func test_pane_copy_for_running_command() throws {
        let worklane = makeWorklane(
            title: "zentty",
            panes: [PaneState(id: paneA, title: "shell", customTitle: "api")],
            metadata: [paneA: TerminalMetadata(currentWorkingDirectory: repoPath, processName: "node", gitBranch: "main")],
            running: [paneA: "pnpm dev"]
        )
        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let copy = CloseConfirmationCopy.pane(context)

        XCTAssertEqual(copy.messageText, "Close pane “api”?")
        XCTAssertEqual(copy.confirmButtonTitle, "Close Pane")
        XCTAssertTrue(
            copy.informativeText.hasPrefix("“pnpm dev” is still running and will be terminated."),
            copy.informativeText
        )
        XCTAssertTrue(copy.informativeText.contains("zentty"), copy.informativeText)
        XCTAssertTrue(copy.informativeText.contains("main"), copy.informativeText)
    }

    func test_pane_copy_for_agent_does_not_quote_tool_name() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(currentWorkingDirectory: repoPath, processName: "claude", gitBranch: "main")],
            running: [paneA: "claude"]
        )
        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let copy = CloseConfirmationCopy.pane(context)

        XCTAssertTrue(
            copy.informativeText.hasPrefix("Claude Code is still running and will be terminated."),
            copy.informativeText
        )
    }

    func test_pane_copy_falls_back_to_generic_running_text() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "zsh")],
            running: [paneA: nil]
        )
        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let copy = CloseConfirmationCopy.pane(context)

        XCTAssertEqual(copy.informativeText, "The running process in this pane will be terminated.")
    }

    func test_pane_copy_for_session_history() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [paneA: TerminalMetadata(currentWorkingDirectory: repoPath, gitBranch: "main")],
            history: [paneA]
        )
        let context = try XCTUnwrap(PaneCloseConfirmationContext.make(paneID: paneA, in: worklane))

        let copy = CloseConfirmationCopy.pane(context)

        XCTAssertTrue(
            copy.informativeText.hasPrefix("This pane's session history will be lost."),
            copy.informativeText
        )
        XCTAssertTrue(copy.informativeText.contains("main"), copy.informativeText)
    }

    // MARK: - Worklane context and copy

    func test_worklane_context_aggregates_running_activities() throws {
        let worklane = makeWorklane(
            title: "zentty",
            panes: [
                PaneState(id: paneA, title: "shell"),
                PaneState(id: paneB, title: "shell", customTitle: "api"),
                PaneState(id: paneC, title: "shell"),
            ],
            metadata: [
                paneA: TerminalMetadata(processName: "claude"),
                paneB: TerminalMetadata(processName: "node"),
            ],
            running: [paneA: "claude", paneB: "pnpm dev"],
            history: [paneC]
        )

        let context = try XCTUnwrap(WorklaneCloseConfirmationContext.make(worklane: worklane))
        let copy = CloseConfirmationCopy.worklane(context)

        XCTAssertEqual(context.reason, .runningProcess)
        XCTAssertEqual(context.worklaneName, "zentty")
        XCTAssertEqual(context.paneCount, 3)
        XCTAssertEqual(context.runningActivities, ["Claude Code", "pnpm dev"])
        XCTAssertEqual(copy.messageText, "Close worklane “zentty”?")
        XCTAssertEqual(copy.confirmButtonTitle, "Close Worklane")
        XCTAssertEqual(
            copy.informativeText,
            "2 of 3 panes have running processes that will be terminated: Claude Code, pnpm dev."
        )
    }

    func test_worklane_copy_singular_running_pane_without_activity_name() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell"), PaneState(id: paneB, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "zsh")],
            running: [paneA: nil]
        )

        let context = try XCTUnwrap(WorklaneCloseConfirmationContext.make(worklane: worklane))
        let copy = CloseConfirmationCopy.worklane(context)

        XCTAssertEqual(copy.messageText, "Close this worklane?")
        XCTAssertEqual(copy.informativeText, "1 of 2 panes has a running process that will be terminated.")
    }

    func test_worklane_copy_for_session_history_only() throws {
        let worklane = makeWorklane(
            title: "docs",
            panes: [PaneState(id: paneA, title: "shell"), PaneState(id: paneB, title: "shell")],
            metadata: [:],
            history: [paneA, paneB]
        )

        let context = try XCTUnwrap(WorklaneCloseConfirmationContext.make(worklane: worklane))
        let copy = CloseConfirmationCopy.worklane(context)

        XCTAssertEqual(context.reason, .sessionHistory)
        XCTAssertEqual(copy.informativeText, "Session history in 2 panes will be lost.")
    }

    func test_worklane_copy_for_single_pane_session_history() throws {
        let worklane = makeWorklane(
            title: nil,
            panes: [PaneState(id: paneA, title: "shell")],
            metadata: [:],
            history: [paneA]
        )

        let context = try XCTUnwrap(WorklaneCloseConfirmationContext.make(worklane: worklane))
        let copy = CloseConfirmationCopy.worklane(context)

        XCTAssertEqual(copy.informativeText, "Session history in this pane will be lost.")
    }

    // MARK: - Store integration

    func test_store_resolves_pane_and_worklane_contexts() throws {
        let worklane = makeWorklane(
            title: "zentty",
            panes: [PaneState(id: paneA, title: "shell"), PaneState(id: paneB, title: "shell")],
            metadata: [paneA: TerminalMetadata(processName: "claude")],
            running: [paneA: "claude"]
        )
        let store = WorklaneStore(worklanes: [worklane], activeWorklaneID: worklaneID)

        let paneContext = try XCTUnwrap(store.paneCloseConfirmationContext(paneA))
        XCTAssertEqual(paneContext.worklaneName, "zentty")
        XCTAssertEqual(paneContext.runningActivity, "Claude Code")
        XCTAssertNil(store.paneCloseConfirmationContext(paneB))

        let worklaneContext = try XCTUnwrap(store.worklaneCloseConfirmationContext(worklaneID))
        XCTAssertEqual(worklaneContext.runningActivities, ["Claude Code"])
        XCTAssertNil(store.worklaneCloseConfirmationContext(WorklaneID("missing")))
    }

    // MARK: - Helpers

    /// `running` maps a pane to its last run command (nil = running with no
    /// known command); `history` lists idle panes with session history.
    private func makeWorklane(
        title: String?,
        panes: [PaneState],
        metadata: [PaneID: TerminalMetadata],
        shellContext: [PaneID: PaneShellContext] = [:],
        running: [PaneID: String?] = [:],
        history: [PaneID] = []
    ) -> WorklaneState {
        var worklane = WorklaneState(
            id: worklaneID,
            title: title,
            paneStripState: PaneStripState(panes: panes, focusedPaneID: panes.first?.id),
            metadataByPaneID: metadata,
            paneContextByPaneID: shellContext
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
