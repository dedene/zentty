import XCTest
@testable import Zentty

final class MenuBarFleetStateTests: XCTestCase {
    func test_aggregate_waiting_beats_active_and_idle() {
        let aggregate = MenuBarFleetState.aggregate([.idle, .active, .waiting, .idle])
        XCTAssertEqual(aggregate, .waiting)
    }

    func test_aggregate_stopped_beats_active() {
        XCTAssertEqual(MenuBarFleetState.aggregate([.active, .stopped]), .stopped)
    }

    func test_aggregate_compacting_beats_active() {
        XCTAssertEqual(MenuBarFleetState.aggregate([.active, .compacting]), .compacting)
    }

    func test_aggregate_empty_returns_idle() {
        XCTAssertEqual(MenuBarFleetState.aggregate([]), .idle)
    }

    func test_resolve_needs_input_is_waiting() {
        let status = PaneAgentStatus(
            tool: .claudeCode,
            state: .needsInput,
            text: nil,
            artifactLink: nil,
            updatedAt: .distantPast
        )
        XCTAssertEqual(
            MenuBarFleetState.resolve(agentStatus: status, metadata: nil, paneTitle: nil),
            .waiting
        )
    }

    func test_resolve_starting_is_active() {
        let status = PaneAgentStatus(
            tool: .claudeCode,
            state: .starting,
            text: nil,
            artifactLink: nil,
            updatedAt: .distantPast
        )
        XCTAssertEqual(
            MenuBarFleetState.resolve(agentStatus: status, metadata: nil, paneTitle: nil),
            .active
        )
    }

    func test_menuStatusLabel_uses_interaction_kind_for_waiting() {
        XCTAssertEqual(
            MenuBarFleetState.waiting.menuStatusLabel(interactionKind: .approval),
            "Requires approval"
        )
    }

    func test_resolve_running_with_compact_text_is_compacting() {
        let status = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: "Compacting context",
            artifactLink: nil,
            updatedAt: .distantPast
        )
        XCTAssertEqual(
            MenuBarFleetState.resolve(agentStatus: status, metadata: nil, paneTitle: nil),
            .compacting
        )
    }

    func test_resolve_running_without_compact_hint_is_active() {
        let status = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: "Running tools",
            artifactLink: nil,
            updatedAt: .distantPast
        )
        XCTAssertEqual(
            MenuBarFleetState.resolve(agentStatus: status, metadata: nil, paneTitle: nil),
            .active
        )
    }

    func test_resolve_uses_sidebar_ready_state_over_running_presentation() {
        var presentation = PanePresentationState()
        presentation.runtimePhase = .running
        presentation.statusText = "Running"
        let paneRow = WorklaneSidebarPaneRow(
            paneID: PaneID("pn-ready"),
            primaryText: "Claude Code",
            trailingText: nil,
            detailText: nil,
            statusText: "Agent ready",
            attentionState: .ready,
            isFocused: true,
            isWorking: false
        )

        XCTAssertEqual(
            MenuBarFleetState.resolve(
                paneRow: paneRow,
                presentation: presentation,
                agentStatus: nil,
                metadata: nil,
                paneTitle: nil
            ),
            .idle
        )
    }

    func test_resolve_uses_sidebar_running_state() {
        var presentation = PanePresentationState()
        presentation.runtimePhase = .idle
        let paneRow = WorklaneSidebarPaneRow(
            paneID: PaneID("pn-running"),
            primaryText: "Claude Code",
            trailingText: nil,
            detailText: nil,
            statusText: "Running",
            attentionState: .running,
            isFocused: true,
            isWorking: true
        )

        XCTAssertEqual(
            MenuBarFleetState.resolve(
                paneRow: paneRow,
                presentation: presentation,
                agentStatus: nil,
                metadata: nil,
                paneTitle: nil
            ),
            .active
        )
    }
}
