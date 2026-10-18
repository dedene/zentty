import XCTest
@testable import Zentty

final class PaneEventSnapshotTests: XCTestCase {
    private typealias Pane = PaneEventSnapshot.Pane
    private typealias Worklane = PaneEventSnapshot.Worklane

    // MARK: - Envelope

    func test_envelope_carries_version_type_timestamp_and_snake_case_fields() throws {
        let event = PaneEvent(
            type: .agentPhase,
            window: "wd_1",
            worklane: "wl_1",
            pane: "pn_1",
            agent: "Claude Code",
            phase: "needs-input",
            previousPhase: "running",
            interaction: "approval"
        ).stamped(Date(timeIntervalSince1970: 0))

        let line = try event.encodedLine()
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "agent.phase")
        XCTAssertEqual(object["ts"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(object["previous_phase"] as? String, "running")
        XCTAssertEqual(object["interaction"] as? String, "approval")
        XCTAssertEqual(object["pane"] as? String, "pn_1")
    }

    func test_envelope_omits_absent_fields() throws {
        let line = try PaneEvent(type: .worklaneClosed, worklane: "wl_1").stamped(Date()).encodedLine()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "type", "ts", "worklane"])
    }

    func test_envelope_decodes_back() throws {
        let event = PaneEvent(type: .streamDropped, count: 3).stamped(Date(timeIntervalSince1970: 5))
        let decoded = try JSONDecoder().decode(PaneEvent.self, from: try event.encodedLine().dropLast())
        XCTAssertEqual(decoded, event)
    }

    // MARK: - Diff

    func test_new_worklane_and_pane_emit_creation_then_focus() {
        let new = snapshot(
            worklanes: [("wl_1", Worklane(windowID: "wd", focusedPaneID: "pn_1"))],
            panes: [("pn_1", Pane(windowID: "wd", worklaneID: "wl_1"))]
        )
        XCTAssertEqual(
            types(PaneEventSnapshot.diff(from: .empty, to: new)),
            ["worklane.created", "pane.created", "pane.focused"]
        )
    }

    func test_closing_panes_and_worklanes_emits_closures_last() {
        let old = snapshot(
            worklanes: [("wl_1", Worklane(windowID: "wd", focusedPaneID: "pn_1"))],
            panes: [
                ("pn_1", Pane(windowID: "wd", worklaneID: "wl_1")),
                ("pn_2", Pane(windowID: "wd", worklaneID: "wl_1")),
            ]
        )
        XCTAssertEqual(
            types(PaneEventSnapshot.diff(from: old, to: .empty)),
            ["pane.closed", "pane.closed", "worklane.closed"]
        )
    }

    func test_focus_change_within_worklane() {
        let panes: [(String, Pane)] = [
            ("pn_1", Pane(windowID: "wd", worklaneID: "wl_1")),
            ("pn_2", Pane(windowID: "wd", worklaneID: "wl_1")),
        ]
        let old = snapshot(worklanes: [("wl_1", Worklane(windowID: "wd", focusedPaneID: "pn_1"))], panes: panes)
        let new = snapshot(worklanes: [("wl_1", Worklane(windowID: "wd", focusedPaneID: "pn_2"))], panes: panes)
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["pane.focused"])
        XCTAssertEqual(events.first?.pane, "pn_2")
    }

    func test_switching_worklanes_reports_activation_with_its_focused_pane() {
        let panes: [(String, Pane)] = [
            ("pn_a", Pane(windowID: "wd", worklaneID: "wl_a")),
            ("pn_b", Pane(windowID: "wd", worklaneID: "wl_b")),
        ]
        let old = snapshot(
            worklanes: [
                ("wl_a", Worklane(windowID: "wd", focusedPaneID: "pn_a", isActive: true)),
                ("wl_b", Worklane(windowID: "wd", focusedPaneID: "pn_b")),
            ],
            panes: panes
        )
        let new = snapshot(
            worklanes: [
                ("wl_a", Worklane(windowID: "wd", focusedPaneID: "pn_a")),
                ("wl_b", Worklane(windowID: "wd", focusedPaneID: "pn_b", isActive: true)),
            ],
            panes: panes
        )
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["worklane.activated"])
        XCTAssertEqual(events.first?.worklane, "wl_b")
        XCTAssertEqual(events.first?.pane, "pn_b")
    }

    func test_focus_moving_in_a_background_worklane_does_not_activate_it() {
        let panes: [(String, Pane)] = [
            ("pn_1", Pane(windowID: "wd", worklaneID: "wl_bg")),
            ("pn_2", Pane(windowID: "wd", worklaneID: "wl_bg")),
        ]
        let old = snapshot(worklanes: [("wl_bg", Worklane(windowID: "wd", focusedPaneID: "pn_1"))], panes: panes)
        let new = snapshot(worklanes: [("wl_bg", Worklane(windowID: "wd", focusedPaneID: "pn_2"))], panes: panes)
        XCTAssertEqual(types(PaneEventSnapshot.diff(from: old, to: new)), ["pane.focused"])
    }

    func test_agent_phase_change_carries_previous_phase_and_interaction() {
        let old = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Codex", phase: "running"))
        let new = single(Pane(
            windowID: "wd",
            worklaneID: "wl",
            agent: "Codex",
            phase: "needs-input",
            interaction: "approval",
            attention: "needs-input"
        ))
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["agent.phase", "attention.raised"])
        XCTAssertEqual(events[0].phase, "needs-input")
        XCTAssertEqual(events[0].previousPhase, "running")
        XCTAssertEqual(events[0].interaction, "approval")
        XCTAssertEqual(events[1].attention, "needs-input")
        XCTAssertEqual(events[1].agent, "Codex")
    }

    func test_attention_clears_when_agent_resumes() {
        let old = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Codex", phase: "idle", attention: "ready"))
        let new = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Codex", phase: "running"))
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["agent.phase", "attention.cleared"])
        XCTAssertEqual(events[1].previousAttention, "ready")
    }

    func test_agent_exit_reports_exited_with_last_agent() {
        let old = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Amp", phase: "idle"))
        let new = single(Pane(windowID: "wd", worklaneID: "wl"))
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["agent.phase"])
        XCTAssertEqual(events[0].agent, "Amp")
        XCTAssertEqual(events[0].phase, "exited")
        XCTAssertEqual(events[0].previousPhase, "idle")
    }

    func test_agent_start_reports_no_previous_phase() {
        let old = single(Pane(windowID: "wd", worklaneID: "wl"))
        let new = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Amp", phase: "starting"))
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["agent.phase"])
        XCTAssertNil(events[0].previousPhase)
    }

    func test_closing_pane_that_needed_attention_clears_it_first() {
        let old = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Codex", phase: "needs-input", attention: "needs-input"))
        var new = old
        new.panes = [:]
        new.paneOrder = []
        XCTAssertEqual(types(PaneEventSnapshot.diff(from: old, to: new)), ["attention.cleared", "pane.closed"])
    }

    func test_pane_moving_between_worklanes_is_a_move_not_close_and_create() {
        let old = snapshot(
            worklanes: [("wl_a", Worklane(windowID: "wd")), ("wl_b", Worklane(windowID: "wd"))],
            panes: [("pn_1", Pane(windowID: "wd", worklaneID: "wl_a"))]
        )
        let new = snapshot(
            worklanes: [("wl_a", Worklane(windowID: "wd")), ("wl_b", Worklane(windowID: "wd"))],
            panes: [("pn_1", Pane(windowID: "wd", worklaneID: "wl_b"))]
        )
        let events = PaneEventSnapshot.diff(from: old, to: new)
        XCTAssertEqual(types(events), ["pane.moved"])
        XCTAssertEqual(events[0].fromWorklane, "wl_a")
        XCTAssertEqual(events[0].worklane, "wl_b")
    }

    func test_identical_snapshots_produce_no_events() {
        let state = single(Pane(windowID: "wd", worklaneID: "wl", agent: "Codex", phase: "running"))
        XCTAssertTrue(PaneEventSnapshot.diff(from: state, to: state).isEmpty)
    }

    // MARK: - Capture from worklane state

    func test_make_reads_agent_phase_interaction_and_attention_from_presentation() {
        let shellID = PaneID("pn_shell")
        let agentID = PaneID("pn_agent")
        var presentation = PanePresentationState()
        presentation.recognizedTool = .claudeCode
        presentation.runtimePhase = .needsInput
        presentation.interactionKind = .approval
        let worklane = WorklaneState(
            id: WorklaneID("wl_main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: shellID, title: "shell"), PaneState(id: agentID, title: "claude")],
                focusedPaneID: agentID
            ),
            auxiliaryStateByPaneID: [agentID: PaneAuxiliaryState(presentation: presentation)]
        )

        let snapshot = PaneEventSnapshot.make(windows: [
            (windowID: WindowID("wd_1"), activeWorklaneID: WorklaneID("wl_main"), worklanes: [worklane]),
        ])

        XCTAssertEqual(snapshot.paneOrder, ["pn_shell", "pn_agent"])
        XCTAssertEqual(snapshot.worklanes["wl_main"]?.focusedPaneID, "pn_agent")
        XCTAssertEqual(snapshot.worklanes["wl_main"]?.isActive, true)
        XCTAssertNil(snapshot.panes["pn_shell"]?.agent)
        let agent = snapshot.panes["pn_agent"]
        XCTAssertEqual(agent?.agent, "Claude Code")
        XCTAssertEqual(agent?.phase, "needs-input")
        XCTAssertEqual(agent?.interaction, "approval")
        XCTAssertEqual(agent?.attention, "needs-input")
        XCTAssertEqual(agent?.windowID, "wd_1")
    }

    func test_ready_and_check_back_take_precedence_for_attention() {
        var presentation = PanePresentationState()
        presentation.recognizedTool = .codex
        presentation.runtimePhase = .idle
        presentation.isReady = true
        XCTAssertEqual(PaneEventSnapshot.attentionName(for: presentation), "ready")
        presentation.isReady = false
        presentation.isCheckBack = true
        XCTAssertEqual(PaneEventSnapshot.attentionName(for: presentation), "check-back")
        presentation.isCheckBack = false
        presentation.runtimePhase = .running
        XCTAssertNil(PaneEventSnapshot.attentionName(for: presentation))
    }

    // MARK: - Helpers

    private func snapshot(worklanes: [(String, Worklane)], panes: [(String, Pane)]) -> PaneEventSnapshot {
        var snapshot = PaneEventSnapshot()
        for (id, worklane) in worklanes {
            snapshot.insert(worklaneID: id, worklane)
        }
        for (id, pane) in panes {
            snapshot.insert(paneID: id, pane)
        }
        return snapshot
    }

    private func single(_ pane: Pane) -> PaneEventSnapshot {
        snapshot(worklanes: [(pane.worklaneID, Worklane(windowID: pane.windowID))], panes: [("pn_1", pane)])
    }

    private func types(_ events: [PaneEvent]) -> [String] {
        events.map(\.type)
    }
}
