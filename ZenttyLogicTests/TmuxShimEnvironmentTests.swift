import XCTest
@testable import Zentty

final class TmuxShimEnvironmentTests: XCTestCase {
    func test_socket_path_is_short_absolute_and_sanitized() {
        XCTAssertEqual(
            TmuxShimEnvironment.socketPath(instanceID: "1b2c3d4e-aaaa-bbbb-cccc"),
            "/tmp/zentty-tmux/1b2c3d4e-aaa"
        )
        XCTAssertEqual(TmuxShimEnvironment.socketPath(instanceID: nil), "/tmp/zentty-tmux/default")
        XCTAssertEqual(TmuxShimEnvironment.socketPath(instanceID: "../../x"), "/tmp/zentty-tmux/x")
    }

    func test_tmux_value_has_socket_numeric_pid_and_session() {
        let value = TmuxShimEnvironment.tmuxValue(socketPath: "/tmp/zentty-tmux/a", serverPID: 4242, sessionNumber: 1)
        let parts = value.split(separator: ",")
        XCTAssertEqual(parts, ["/tmp/zentty-tmux/a", "4242", "1"])
    }

    func test_apply_sets_shim_variables_and_prepends_shim_once() {
        var environment = ["PATH": "/usr/bin:/opt/shim:/bin"]
        TmuxShimEnvironment.apply(
            to: &environment,
            shimDirectory: "/opt/shim",
            tmux: "/tmp/zentty-tmux/a,1,0",
            tmuxPane: "%3",
            tracePath: "/tmp/trace.jsonl"
        )

        XCTAssertEqual(environment["PATH"], "/opt/shim:/usr/bin:/bin")
        XCTAssertEqual(environment["TMUX"], "/tmp/zentty-tmux/a,1,0")
        XCTAssertEqual(environment["TMUX_PANE"], "%3")
        XCTAssertEqual(environment["ZENTTY_TMUX_SHIM"], "1")
        XCTAssertEqual(environment["ZENTTY_TMUX_SHIM_DIR"], "/opt/shim")
        XCTAssertEqual(environment["ZENTTY_TMUX_COMPAT_TRACE_PATH"], "/tmp/trace.jsonl")
    }

    func test_parse_identity_accepts_only_tmux_shaped_output() {
        XCTAssertEqual(
            TmuxShimEnvironment.parseIdentity("/tmp/zentty-tmux/a\t4242\t$1\t%3\n"),
            TmuxShimEnvironment.Identity(socketPath: "/tmp/zentty-tmux/a", serverPID: 4242, sessionNumber: 1, paneID: "%3")
        )
        XCTAssertNil(TmuxShimEnvironment.parseIdentity("/tmp/a\t0\t$1\t%3"))
        XCTAssertNil(TmuxShimEnvironment.parseIdentity("/tmp/a\t42\t1\t%3"))
        XCTAssertNil(TmuxShimEnvironment.parseIdentity("/tmp/a\t42\t$1\t%pn_x"))
        XCTAssertNil(TmuxShimEnvironment.parseIdentity(""))
    }

    func test_launch_environment_enables_claude_teams_only_when_asked() {
        let identity = TmuxShimEnvironment.Identity(socketPath: "/tmp/zentty-tmux/a", serverPID: 9, sessionNumber: 2, paneID: "%5")
        let teams = TmuxShimEnvironment.launchEnvironment(
            base: ["PATH": "/usr/bin"],
            shimDirectory: "/opt/shim",
            identity: identity,
            enableClaudeAgentTeams: true
        )
        XCTAssertEqual(teams["TMUX"], "/tmp/zentty-tmux/a,9,2")
        XCTAssertEqual(teams["TMUX_PANE"], "%5")
        XCTAssertEqual(teams["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"], "1")
        XCTAssertEqual(teams["PATH"], "/opt/shim:/usr/bin")

        let plain = TmuxShimEnvironment.launchEnvironment(
            base: ["PATH": "/usr/bin"],
            shimDirectory: "/opt/shim",
            identity: identity,
            enableClaudeAgentTeams: false
        )
        XCTAssertNil(plain["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"])
    }

    func test_launch_plan_reads_teams_before_or_right_after_the_tool() {
        XCTAssertEqual(
            TmuxShimEnvironment.launchPlan(command: ["claude", "--resume"], teams: true, tmuxShim: false),
            .init(mode: .agent(tool: "claude", arguments: ["--resume"]), enablesClaudeAgentTeams: true)
        )
        XCTAssertEqual(
            TmuxShimEnvironment.launchPlan(command: ["claude", "--teams", "--resume"], teams: false, tmuxShim: false),
            .init(mode: .agent(tool: "claude", arguments: ["--resume"]), enablesClaudeAgentTeams: true)
        )
        XCTAssertEqual(
            TmuxShimEnvironment.launchPlan(command: ["opencode", "--teams"], teams: false, tmuxShim: false),
            .init(mode: .agent(tool: "opencode", arguments: []), enablesClaudeAgentTeams: false)
        )
    }

    func test_launch_plan_leaves_later_teams_flags_to_the_tool() {
        XCTAssertNil(TmuxShimEnvironment.launchPlan(command: ["claude", "-p", "--teams"], teams: false, tmuxShim: false))
        XCTAssertNil(TmuxShimEnvironment.launchPlan(command: ["claude"], teams: false, tmuxShim: false))
    }

    func test_launch_plan_for_tmux_shim_runs_any_command_or_the_shell() {
        XCTAssertEqual(
            TmuxShimEnvironment.launchPlan(command: ["--", "omx", "team", "3:executor"], teams: false, tmuxShim: true),
            .init(mode: .command(["omx", "team", "3:executor"]), enablesClaudeAgentTeams: false)
        )
        XCTAssertEqual(
            TmuxShimEnvironment.launchPlan(command: [], teams: false, tmuxShim: true),
            .init(mode: .command([]), enablesClaudeAgentTeams: false)
        )
        XCTAssertEqual(
            TmuxShimEnvironment.launchPlan(command: ["omc", "team"], teams: true, tmuxShim: true),
            .init(mode: .command(["omc", "team"]), enablesClaudeAgentTeams: true)
        )
    }

    func test_environment_assignments_from_dash_e() {
        XCTAssertEqual(
            TmuxShimEnvironment.environmentAssignments(["A=1", "B=x=y", "=bad", "noequals", "C="]),
            ["A": "1", "B": "x=y", "C": ""]
        )
    }

    func test_tmux_pane_identity_is_added_to_shim_created_panes() {
        var environment = [
            "ZENTTY_TMUX_SHIM": "1",
            "ZENTTY_TMUX_SHIM_DIR": "/opt/shim",
            "PATH": "/usr/bin:/bin",
        ]
        let paneID = PaneID("pn_shim_env_test")
        WorklaneSessionEnvironment.applyTmuxPaneIdentity(to: &environment, paneID: paneID)

        XCTAssertEqual(environment["TMUX_PANE"], "%\(TmuxCompatSessionState.shared.paneNumber(for: paneID.rawValue))")
        XCTAssertEqual(environment["PATH"], "/opt/shim:/usr/bin:/bin")

        // A respawn-pane replacement arrives with the replaced pane's id.
        var respawned = ["ZENTTY_TMUX_SHIM": "1", "TMUX_PANE": "%2"]
        WorklaneSessionEnvironment.applyTmuxPaneIdentity(to: &respawned, paneID: PaneID("pn_replacement_test"))
        XCTAssertEqual(respawned["TMUX_PANE"], "%2")

        var plain = ["PATH": "/usr/bin"]
        WorklaneSessionEnvironment.applyTmuxPaneIdentity(to: &plain, paneID: paneID)
        XCTAssertNil(plain["TMUX_PANE"])
        XCTAssertEqual(plain["PATH"], "/usr/bin")
    }
}
