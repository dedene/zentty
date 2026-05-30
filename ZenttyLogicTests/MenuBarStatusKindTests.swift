import XCTest
@testable import Zentty

final class MenuBarStatusKindTests: XCTestCase {
    // MARK: resolve(fleetState:attentionState:)

    /// Every attentionState value, including nil, that resolve must handle.
    private let allAttentionStates: [WorklaneAttentionState?] = [
        nil, .needsInput, .unresolvedStop, .ready, .running,
    ]

    func test_resolve_active_is_running_for_all_attention_states() {
        for attention in allAttentionStates {
            XCTAssertEqual(
                MenuBarStatusKind.resolve(fleetState: .active, attentionState: attention),
                .running,
                "active should resolve to .running for attentionState \(String(describing: attention))"
            )
        }
    }

    func test_resolve_compacting_is_compacting_for_all_attention_states() {
        for attention in allAttentionStates {
            XCTAssertEqual(
                MenuBarStatusKind.resolve(fleetState: .compacting, attentionState: attention),
                .compacting,
                "compacting should resolve to .compacting for attentionState \(String(describing: attention))"
            )
        }
    }

    func test_resolve_waiting_is_needsInput_for_all_attention_states() {
        for attention in allAttentionStates {
            XCTAssertEqual(
                MenuBarStatusKind.resolve(fleetState: .waiting, attentionState: attention),
                .needsInput,
                "waiting should resolve to .needsInput for attentionState \(String(describing: attention))"
            )
        }
    }

    func test_resolve_stopped_is_stoppedEarly_for_all_attention_states() {
        for attention in allAttentionStates {
            XCTAssertEqual(
                MenuBarStatusKind.resolve(fleetState: .stopped, attentionState: attention),
                .stoppedEarly,
                "stopped should resolve to .stoppedEarly for attentionState \(String(describing: attention))"
            )
        }
    }

    func test_resolve_idle_with_ready_is_ready() {
        XCTAssertEqual(
            MenuBarStatusKind.resolve(fleetState: .idle, attentionState: .ready),
            .ready
        )
    }

    func test_resolve_idle_with_nil_is_idle() {
        XCTAssertEqual(
            MenuBarStatusKind.resolve(fleetState: .idle, attentionState: nil),
            .idle
        )
    }

    func test_resolve_idle_with_needsInput_is_idle() {
        // fleetState is authoritative: attentionState only promotes idle -> ready.
        XCTAssertEqual(
            MenuBarStatusKind.resolve(fleetState: .idle, attentionState: .needsInput),
            .idle
        )
    }

    func test_resolve_idle_with_unresolvedStop_is_idle() {
        XCTAssertEqual(
            MenuBarStatusKind.resolve(fleetState: .idle, attentionState: .unresolvedStop),
            .idle
        )
    }

    func test_resolve_idle_with_running_is_idle() {
        XCTAssertEqual(
            MenuBarStatusKind.resolve(fleetState: .idle, attentionState: .running),
            .idle
        )
    }

    /// Exhaustive 5 fleet states x 5 attentionState values = 25 assertions in one sweep,
    /// guarding the full contract against any regression.
    func test_resolve_full_matrix_is_exhaustive() {
        for fleetState in MenuBarFleetState.allCases {
            for attention in allAttentionStates {
                let expected: MenuBarStatusKind
                switch fleetState {
                case .active:
                    expected = .running
                case .compacting:
                    expected = .compacting
                case .waiting:
                    expected = .needsInput
                case .stopped:
                    expected = .stoppedEarly
                case .idle:
                    expected = attention == .ready ? .ready : .idle
                }

                XCTAssertEqual(
                    MenuBarStatusKind.resolve(fleetState: fleetState, attentionState: attention),
                    expected,
                    "fleetState \(fleetState) + attentionState \(String(describing: attention))"
                )
            }
        }
    }

    // MARK: init(snapshot:)

    func test_init_snapshot_forwards_idle_with_ready_to_ready() {
        let snapshot = makeSnapshot(fleetState: .idle, attentionState: .ready)
        XCTAssertEqual(MenuBarStatusKind(snapshot: snapshot), .ready)
    }

    func test_init_snapshot_forwards_idle_with_nil_to_idle() {
        let snapshot = makeSnapshot(fleetState: .idle, attentionState: nil)
        XCTAssertEqual(MenuBarStatusKind(snapshot: snapshot), .idle)
    }

    func test_init_snapshot_forwards_idle_with_needsInput_to_idle() {
        let snapshot = makeSnapshot(fleetState: .idle, attentionState: .needsInput)
        XCTAssertEqual(MenuBarStatusKind(snapshot: snapshot), .idle)
    }

    func test_init_snapshot_forwards_active_to_running() {
        // Proves init reads fleetState (not just attentionState): active wins over a
        // .ready attentionState that would otherwise promote idle.
        let snapshot = makeSnapshot(fleetState: .active, attentionState: .ready)
        XCTAssertEqual(MenuBarStatusKind(snapshot: snapshot), .running)
    }

    // MARK: Helpers

    private func makeSnapshot(
        fleetState: MenuBarFleetState,
        attentionState: WorklaneAttentionState?
    ) -> MenuBarPaneSnapshot {
        MenuBarPaneSnapshot(
            windowID: WindowID("win-test"),
            windowTitle: "Window 1",
            worklaneID: WorklaneID("wl-test"),
            paneID: PaneID("pn-test"),
            agentTool: .claudeCode,
            primaryText: "Claude Code",
            contextText: "zentty · main",
            statusLabel: "Status",
            attentionState: attentionState,
            fleetState: fleetState,
            updatedAt: Date(timeIntervalSince1970: 0),
            taskProgress: nil,
            sortPriority: 0
        )
    }
}
