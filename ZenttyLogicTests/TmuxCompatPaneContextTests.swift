import XCTest
@testable import Zentty

/// Format variables the tmux shim reports for a pane, window and session.
final class TmuxCompatPaneContextTests: XCTestCase {
    private let topology = TmuxTopologyFixture.make()

    private var lead: (window: TmuxTopology.Window, pane: TmuxTopology.Pane) {
        (topology.session.windows[0], topology.session.windows[0].panes[0])
    }

    func test_window_id_and_index_use_the_worklane_identity() {
        // `list-windows` reports each worklane at its enumeration index, so
        // `display-message` / `list-panes` must report the same identity for
        // the worklane the pane belongs to, not the pane's column.
        let second = topology.session.windows[1]
        let context = TmuxFormatContext.pane(second.panes[0], window: second, in: topology)

        XCTAssertEqual(context["window_id"], "@8")
        XCTAssertEqual(context["window_index"], "1")
        XCTAssertEqual(context["window_uuid"], "wl_second")
    }

    func test_pane_ids_are_numeric_like_tmux() {
        let context = TmuxFormatContext.pane(lead.pane, window: lead.window, in: topology)

        XCTAssertEqual(context["pane_id"], "%3")
        XCTAssertEqual(context["pane_uuid"], "pn_lead")
        XCTAssertEqual(context["pane_index"], "0")
        XCTAssertEqual(context["pane_title"], "lead")
        XCTAssertEqual(context["pane_current_path"], "/tmp/project")
        XCTAssertEqual(context["session_name"], "zentty")
    }

    func test_session_and_server_identity_variables() {
        let context = TmuxFormatContext.pane(lead.pane, window: lead.window, in: topology)

        XCTAssertEqual(context["session_id"], "$1")
        XCTAssertEqual(context["session_created"], "1700000000")
        XCTAssertEqual(context["session_windows"], "2")
        XCTAssertEqual(context["socket_path"], "/tmp/zentty-tmux/test")
        XCTAssertEqual(context["pid"], "4242")
        XCTAssertEqual(context["version"], "3.4")
    }

    func test_pane_active_and_pane_dead_are_zero_or_one() {
        let window = lead.window
        let activeContext = TmuxFormatContext.pane(window.panes[0], window: window, in: topology)
        let inactiveContext = TmuxFormatContext.pane(window.panes[1], window: window, in: topology)

        XCTAssertEqual(activeContext["pane_active"], "1")
        XCTAssertEqual(inactiveContext["pane_active"], "0")
        XCTAssertEqual(activeContext["pane_dead"], "0")
        XCTAssertEqual(activeContext["pane_in_mode"], "0")
        XCTAssertEqual(activeContext["window_active"], "1")
    }

    func test_pane_pid_size_and_start_command() {
        let window = lead.window
        let teammate = TmuxFormatContext.pane(window.panes[1], window: window, in: topology)

        XCTAssertEqual(teammate["pane_pid"], "5150")
        XCTAssertEqual(teammate["pane_width"], "60")
        XCTAssertEqual(teammate["pane_height"], "20")
        XCTAssertEqual(teammate["pane_left"], "101")
        XCTAssertEqual(teammate["pane_top"], "0")
        XCTAssertEqual(teammate["pane_start_command"], "claude --agent-id a")
        XCTAssertEqual(teammate["window_width"], "161")
        XCTAssertEqual(teammate["window_height"], "40")
        XCTAssertEqual(TmuxFormatContext.pane(window.panes[0], window: window, in: topology)["pane_pid"], "")
    }

    func test_user_options_and_tmux_defaults_are_format_variables() {
        let context = TmuxFormatContext.pane(
            lead.pane,
            window: lead.window,
            in: topology,
            options: ["@team_owner": "omx-1"]
        )

        XCTAssertEqual(context["@team_owner"], "omx-1")
        XCTAssertEqual(context["mouse"], "off")
        XCTAssertEqual(
            TmuxFormatRenderer.render("#{extended-keys-format}\t#{mouse}", context: context),
            "\toff"
        )
    }

    func test_pane_group_is_a_window_of_its_own() throws {
        let grouped = TmuxTopologyFixture.makeWithPaneGroup()
        let worklane = grouped.session.windows[0]
        let group = try XCTUnwrap(grouped.session.windows.first(where: { $0.groupKey != nil }))

        XCTAssertEqual(worklane.panes.map(\.id), ["pn_lead", "pn_mate"])
        XCTAssertEqual(group.panes.map(\.id), ["pn_worker"])
        XCTAssertEqual(group.panes.map(\.index), [0], "pane indexes count within each window")
        XCTAssertEqual(group.id, "wl_lead", "a pane group lives in its worklane")
        XCTAssertEqual(group.index, 2, "after every worklane")
        XCTAssertEqual(group.name, "worker-1")
        XCTAssertEqual(group.activePane?.id, "pn_worker")
        XCTAssertEqual(worklane.activePane?.id, "pn_lead")

        let context = TmuxFormatContext.pane(group.panes[0], window: group, in: grouped)
        XCTAssertEqual(context["window_id"], "@20")
        XCTAssertEqual(context["window_panes"], "1")
        XCTAssertEqual(context["session_windows"], "3")
    }

    func test_window_without_active_pane_falls_back_to_the_focused_pane() {
        var worklane = topology.session.windows[0]
        for index in worklane.panes.indices {
            worklane.panes[index].isActive = false
        }
        var nextGroupIndex = 2
        let split = TmuxTopology.splittingPaneGroups(
            worklane,
            focusedPaneID: "pn_mate",
            groupOf: { _ in nil },
            groupNumber: { _ in 0 },
            nextGroupIndex: &nextGroupIndex
        )

        XCTAssertEqual(split.worklane.activePane?.id, "pn_mate")
        XCTAssertTrue(split.groups.isEmpty)
        XCTAssertEqual(nextGroupIndex, 2)
    }

    func test_claude_identity_probe_matches_its_validation_pattern() {
        // Claude Code validates `#{session_name}:#{window_id}.#{pane_id}` with
        // /^[A-Za-z0-9_.-]{1,64}:@?\d{1,6}\.%?\d{1,6}$/.
        let rendered = TmuxFormatRenderer.render(
            "#{session_name}:#{window_id}.#{pane_id}",
            context: TmuxFormatContext.pane(lead.pane, window: lead.window, in: topology)
        )
        XCTAssertNotNil(rendered.range(of: #"^[A-Za-z0-9_.-]{1,64}:@?\d{1,6}\.%?\d{1,6}$"#, options: .regularExpression))
    }
}

enum TmuxTopologyFixture {
    /// Two worklanes: `wl_lead` (lead + one teammate, lead active) and
    /// `wl_second` (one pane).
    static func make() -> TmuxTopology {
        let lead = TmuxTopology.Pane(
            id: "pn_lead", number: 3, index: 0, title: "lead", workingDirectory: "/tmp/project",
            isActive: true, pid: nil, columns: 100, rows: 40, left: 0, top: 0,
            startCommand: "", isLaunchDeferred: false
        )
        let teammate = TmuxTopology.Pane(
            id: "pn_mate", number: 4, index: 1, title: "mate", workingDirectory: nil,
            isActive: false, pid: 5150, columns: 60, rows: 20, left: 101, top: 0,
            startCommand: "claude --agent-id a", isLaunchDeferred: false
        )
        let other = TmuxTopology.Pane(
            id: "pn_other", number: 9, index: 0, title: "other", workingDirectory: nil,
            isActive: true, pid: 77, columns: 80, rows: 24, left: 0, top: 0,
            startCommand: "", isLaunchDeferred: false
        )
        return TmuxTopology(
            session: TmuxTopology.Session(
                id: "wd_main",
                number: 1,
                name: "zentty",
                created: 1_700_000_000,
                windows: [
                    TmuxTopology.Window(
                        id: "wl_lead", number: 5, index: 0, name: "project", isActive: true,
                        panes: [lead, teammate], columns: 161, rows: 40
                    ),
                    TmuxTopology.Window(
                        id: "wl_second", number: 8, index: 1, name: "notes", isActive: false,
                        panes: [other], columns: 80, rows: 24
                    ),
                ]
            ),
            socketPath: "/tmp/zentty-tmux/test",
            serverPID: 4242
        )
    }

    /// `make()` plus `pn_worker`, a pane a `new-window` call made in the
    /// lead's worklane: its pane-group window is `@20`, index 2.
    static func makeWithPaneGroup() -> TmuxTopology {
        var topology = make()
        var worklane = topology.session.windows[0]
        worklane.panes.append(TmuxTopology.Pane(
            id: "pn_worker", number: 11, index: 2, title: "worker-1", workingDirectory: nil,
            isActive: false, pid: nil, columns: 60, rows: 20, left: 101, top: 21,
            startCommand: "codex", isLaunchDeferred: false
        ))
        var nextGroupIndex = topology.session.windows.count
        let split = TmuxTopology.splittingPaneGroups(
            worklane,
            focusedPaneID: "pn_lead",
            groupOf: { $0 == "pn_worker" ? "tmux-window:pn_worker" : nil },
            groupNumber: { _ in 20 },
            nextGroupIndex: &nextGroupIndex
        )
        topology.session.windows[0] = split.worklane
        topology.session.windows.append(contentsOf: split.groups)
        return topology
    }
}
