import XCTest
@testable import Zentty

@MainActor
final class MenuBarPaneSnapshotBuilderTests: XCTestCase {
    private let windowID = WindowID("win-menu-bar")

    func test_snapshots_include_only_agent_panes_and_sort_by_urgency_then_recent() {
        let waitingPaneID = PaneID("pn-waiting")
        let runningPaneID = PaneID("pn-running")
        let idlePaneID = PaneID("pn-idle")
        let plainPaneID = PaneID("pn-plain")

        let worklane = WorklaneState(
            id: WorklaneID("wl-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: plainPaneID, title: "shell"),
                    PaneState(id: idlePaneID, title: "idle-agent"),
                    PaneState(id: runningPaneID, title: "running-agent"),
                    PaneState(id: waitingPaneID, title: "waiting-agent"),
                ],
                focusedPaneID: plainPaneID
            ),
            agentStatusByPaneID: [
                idlePaneID: agentStatus(state: .idle, updatedAt: Date(timeIntervalSince1970: 10)),
                runningPaneID: agentStatus(state: .running, updatedAt: Date(timeIntervalSince1970: 20)),
                waitingPaneID: agentStatus(state: .needsInput, updatedAt: Date(timeIntervalSince1970: 30)),
            ]
        )

        let store = WorklaneStore(windowID: windowID, worklanes: [worklane])
        let source = MenuBarWorklaneSource(
            windowID: windowID,
            windowTitle: "Zentty",
            worklaneStore: store
        )

        let snapshots = MenuBarPaneSnapshotBuilder.snapshots(from: [source])

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.map(\.paneID), [waitingPaneID, runningPaneID, idlePaneID])
        XCTAssertEqual(snapshots[0].fleetState, .waiting)
        XCTAssertEqual(snapshots[2].fleetState, .idle)
        XCTAssertEqual(snapshots[0].agentTool, .claudeCode)
        XCTAssertEqual(snapshots[0].updatedAt, Date(timeIntervalSince1970: 30))
        XCTAssertFalse(snapshots[0].primaryText.contains("Main ·"))
    }

    func test_snapshots_include_recognized_agent_without_explicit_status_as_idle() {
        let codexPaneID = PaneID("pn-codex")
        let shellPaneID = PaneID("pn-shell")
        let worklane = WorklaneState(
            id: WorklaneID("wl-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: shellPaneID, title: "shell"),
                    PaneState(id: codexPaneID, title: "Ready | menubar-agent-status-item"),
                ],
                focusedPaneID: codexPaneID
            ),
            auxiliaryStateByPaneID: [
                shellPaneID: PaneAuxiliaryState(metadata: TerminalMetadata(
                    title: "zsh",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feat/menubar-agent-status-item",
                    processName: "zsh",
                    gitBranch: "feat/menubar-agent-status-item"
                )),
                codexPaneID: PaneAuxiliaryState(metadata: TerminalMetadata(
                    title: "Ready | menubar-agent-status-item",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feat/menubar-agent-status-item",
                    processName: "codex",
                    gitBranch: "feat/menubar-agent-status-item"
                )),
            ]
        )
        let store = WorklaneStore(windowID: windowID, worklanes: [worklane])
        let source = MenuBarWorklaneSource(
            windowID: windowID,
            windowTitle: "Zentty",
            worklaneStore: store
        )

        let snapshots = MenuBarPaneSnapshotBuilder.snapshots(from: [source])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].paneID, codexPaneID)
        XCTAssertEqual(snapshots[0].agentTool, .codex)
        XCTAssertEqual(snapshots[0].fleetState, .idle)
        XCTAssertEqual(snapshots[0].primaryText, "Ready | menubar-agent-status-item")
        XCTAssertEqual(snapshots[0].contextText, "menubar-agent-status-item · feat/menubar-agent-status-item")
    }

    func test_snapshots_do_not_treat_title_derived_running_as_live_status() {
        let paneID = PaneID("pn-resumed-codex")
        let worklane = WorklaneState(
            id: WorklaneID("wl-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "Working | hermes-agent-integration")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(metadata: TerminalMetadata(
                    title: "Working | hermes-agent-integration",
                    currentWorkingDirectory: "/Users/peter/Development/Personal/worktrees/hermes",
                    processName: "codex",
                    gitBranch: "feature/hermes"
                ))
            ]
        )
        let store = WorklaneStore(windowID: windowID, worklanes: [worklane])
        let source = MenuBarWorklaneSource(
            windowID: windowID,
            windowTitle: "Zentty",
            worklaneStore: store
        )

        let snapshots = MenuBarPaneSnapshotBuilder.snapshots(from: [source])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].agentTool, .codex)
        XCTAssertEqual(snapshots[0].fleetState, .idle)
        XCTAssertEqual(snapshots[0].statusLabel, "Idle")
    }

    func test_snapshots_use_normalized_presentation_state_over_stale_running_status() {
        let paneID = PaneID("pn-claude-interrupted")
        let worklane = WorklaneState(
            id: WorklaneID("wl-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "Claude Code")],
                focusedPaneID: paneID
            ),
            metadataByPaneID: [
                paneID: TerminalMetadata(
                    title: "✳ Audit AWS S3 usage in cluster",
                    currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/k8s-zenjoy",
                    processName: "claude",
                    gitBranch: "main"
                )
            ],
            agentStatusByPaneID: [
                paneID: agentStatus(
                    state: .running,
                    updatedAt: Date(timeIntervalSince1970: 40)
                )
            ]
        )
        let store = WorklaneStore(windowID: windowID, worklanes: [worklane])
        let source = MenuBarWorklaneSource(
            windowID: windowID,
            windowTitle: "Zentty",
            worklaneStore: store
        )

        let snapshots = MenuBarPaneSnapshotBuilder.snapshots(from: [source])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].agentTool, .claudeCode)
        XCTAssertEqual(snapshots[0].fleetState, .idle)
        XCTAssertEqual(snapshots[0].statusLabel, "Idle")
    }

    func test_snapshots_fall_back_to_project_name_when_title_is_generic() {
        let paneID = PaneID("pn-agent")
        let worklane = WorklaneState(
            id: WorklaneID("wl-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    metadata: TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: "/Users/peter/Development/Personal/zentty/Sources",
                        processName: "claude",
                        gitBranch: "main"
                    ),
                    agentStatus: agentStatus(state: .idle)
                )
            ]
        )
        let store = WorklaneStore(windowID: windowID, worklanes: [worklane])
        let source = MenuBarWorklaneSource(
            windowID: windowID,
            windowTitle: "Zentty",
            worklaneStore: store
        )

        let snapshots = MenuBarPaneSnapshotBuilder.snapshots(from: [source])

        XCTAssertEqual(snapshots.first?.primaryText, "Sources")
        XCTAssertEqual(snapshots.first?.contextText, "Sources · main")
    }

    private func agentStatus(
        state: PaneAgentState,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: .claudeCode,
            state: state,
            text: nil,
            artifactLink: nil,
            updatedAt: updatedAt
        )
    }
}
