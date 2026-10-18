import XCTest
@testable import Zentty

/// Pure helpers behind the tmux commands the shim gained for tmux-based
/// orchestrators: `-e`, getopt clusters, argv commands, `send-keys --`,
/// general `respawn-pane`, stored options, `-P` defaults and which panes a
/// tool may close.
final class TmuxCompatHandlerHelpersTests: XCTestCase {
    private func parseCreate(_ arguments: [String]) -> TmuxCompatArguments {
        TmuxCompatArguments.parse(
            arguments,
            valueFlags: TmuxCompatIPCHandler.createPaneValueFlags,
            boolFlags: TmuxCompatIPCHandler.createPaneBoolFlags
        )
    }

    // MARK: - argument parsing

    func test_repeated_dash_e_values_are_all_kept() {
        let parsed = parseCreate(["-e", "A=1", "-t", "%1", "-e", "B=2", "-h", "-d", "cmd"])

        XCTAssertEqual(parsed.values("-e"), ["A=1", "B=2"])
        XCTAssertEqual(parsed.value("-e"), "B=2")
        XCTAssertEqual(parsed.positionals, ["cmd"])
    }

    func test_cluster_ending_in_a_value_flag_takes_the_next_argument() {
        // `set-option -at session terminal-features ',*:clipboard'`
        let parsed = TmuxCompatArguments.parse(
            ["-at", "=zentty:", "terminal-features", ",*:clipboard"],
            valueFlags: ["-t"],
            boolFlags: ["-a", "-g", "-p", "-q", "-s", "-u", "-w"]
        )

        XCTAssertTrue(parsed.hasFlag("-a"))
        XCTAssertEqual(parsed.value("-t"), "=zentty:")
        XCTAssertEqual(parsed.positionals, ["terminal-features", ",*:clipboard"])
    }

    func test_cluster_with_inline_value_after_boolean_flags() {
        let parsed = TmuxCompatArguments.parse(["-dl70%"], valueFlags: ["-l"], boolFlags: ["-d"])

        XCTAssertTrue(parsed.hasFlag("-d"))
        XCTAssertEqual(parsed.value("-l"), "70%")
    }

    func test_new_window_flags_parse_name_and_command() {
        let parsed = parseCreate(["-t", "=zentty", "-n", "teammate-alpha", "-P", "-F", "#{pane_id}", "--", "claude", "--agent-id", "a"])

        XCTAssertEqual(parsed.value("-n"), "teammate-alpha")
        XCTAssertEqual(parsed.value("-t"), "=zentty")
        XCTAssertEqual(parsed.positionals, ["claude", "--agent-id", "a"])
    }

    func test_options_end_at_the_first_command_word() {
        // tmux stops at the first non-option word: the command keeps its own
        // flags (`sh -c`, `bash -lc`) instead of losing them to split-window.
        let shell = parseCreate(["-d", "-P", "-F", "#{pane_id}", "-t", "%1", "sh", "-c", "exec worker"])
        XCTAssertNil(shell.value("-c"))
        XCTAssertEqual(shell.value("-t"), "%1")
        XCTAssertEqual(shell.positionals, ["sh", "-c", "exec worker"])

        let login = parseCreate(["-t", "%1", "bash", "-lc", "run x"])
        XCTAssertNil(login.value("-l"))
        XCTAssertEqual(login.positionals, ["bash", "-lc", "run x"])
        XCTAssertEqual(TmuxCompatIPCHandler.commandText(from: login.positionals), "bash -lc 'run x'")
    }

    // MARK: - commands

    func test_command_text_quotes_argv_form_only_when_needed() {
        XCTAssertEqual(TmuxCompatIPCHandler.commandText(from: ["cat", "README.md"]), "cat README.md")
        XCTAssertEqual(
            TmuxCompatIPCHandler.commandText(from: ["opencode", "attach", "http://x:1", "--dir", "/tmp/a b"]),
            "opencode attach http://x:1 --dir '/tmp/a b'"
        )
        XCTAssertEqual(TmuxCompatIPCHandler.commandText(from: ["sh -c 'x; y'"]), "sh -c 'x; y'")
        XCTAssertNil(TmuxCompatIPCHandler.commandText(from: []))
        XCTAssertNil(TmuxCompatIPCHandler.commandText(from: ["  "]))
    }

    func test_split_window_runs_argv_command_through_the_login_shell() {
        let arguments = ["-d", "-P", "-F", "#{pane_id}", "-e", "TOKEN=1", "opencode", "attach", "http://x:1"]
        let request = TmuxCompatIPCHandler.splitWindowStartupRequest(
            arguments: arguments,
            parsed: parseCreate(arguments),
            loginShellPath: "/bin/zsh"
        )

        XCTAssertEqual(request.nativeCommand, "'/bin/zsh' -lic 'opencode attach http://x:1'")
        XCTAssertTrue(request.waitAfterNativeCommand)
    }

    func test_send_keys_treats_everything_after_double_dash_as_keys() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-t", "%1", "-l", "--", "-v please", "Enter"], standardInput: nil),
            "-v please Enter"
        )
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-t", "%1", "--", "-x", "Enter"], standardInput: nil),
            "-x\r"
        )
    }

    func test_send_keys_flags_end_at_the_first_key() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-t", "%2", "claude", "--model", "opus", "Enter"], standardInput: nil),
            "claude --model opus\r"
        )
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-t", "%2", "ls", "-la", "Enter"], standardInput: nil),
            "ls -la\r"
        )
    }

    func test_send_keys_cluster_ending_in_target() {
        let parsed = TmuxCompatIPCHandler.parseSendKeys(["-lt", "%3", "hello"])

        XCTAssertEqual(parsed.value("-t"), "%3")
        XCTAssertEqual(TmuxCompatIPCHandler.sendKeysText(parsed: parsed, standardInput: nil), "hello")
    }

    func test_send_keys_cursor_and_control_keys() {
        XCTAssertEqual(TmuxCompatIPCHandler.sendKeysText(arguments: ["Up", "C-u"], standardInput: nil), "\u{1b}[A\u{15}")
    }

    func test_respawn_pane_request_parses_live_placeholder_respawn() {
        // oh-my-openagent: `respawn-pane -k -e K=V -t %4 'sh -c "opencode attach …"'`
        let request = TmuxCompatIPCHandler.respawnPaneRequest(
            arguments: ["-k", "-e", "PASSWORD=x", "-t", "%4", "sh -c \"opencode attach\""]
        )

        XCTAssertEqual(request.target, "%4")
        XCTAssertTrue(request.kill)
        XCTAssertEqual(request.environment, ["PASSWORD=x"])
        XCTAssertEqual(request.command, "sh -c \"opencode attach\"")
    }

    func test_respawn_pane_request_without_command_or_kill() {
        let request = TmuxCompatIPCHandler.respawnPaneRequest(arguments: ["-t", "%4"])

        XCTAssertFalse(request.kill)
        XCTAssertNil(request.command)
    }

    // MARK: - options and output

    func test_show_options_prefers_stored_values() {
        let stored = ["@omx_owner": "team-1", "mouse": "on"]
        XCTAssertEqual(
            TmuxCompatIPCHandler.showOptionsStdout(arguments: ["-qv", "-p", "-t", "%4", "@omx_owner"], lookup: { stored[$0] }),
            "team-1\n"
        )
        XCTAssertEqual(TmuxCompatIPCHandler.showOptionsStdout(arguments: ["-Av", "mouse"], lookup: { stored[$0] }), "on\n")
    }

    func test_show_options_unset_user_option_prints_nothing() {
        XCTAssertEqual(TmuxCompatIPCHandler.showOptionsStdout(arguments: ["-qv", "@missing"]), "")
        XCTAssertEqual(TmuxCompatIPCHandler.showOptionsStdout(arguments: ["@missing"]), "")
    }

    func test_show_options_without_name_lists_options() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.showOptionsStdout(arguments: ["-g"], all: ["b": "2", "a": "1"]),
            "a 1\nb 2\n"
        )
    }

    func test_default_print_targets_resolve_back_to_the_created_pane() throws {
        // A teammate pane made by `new-window` sits in its own pane-group
        // window (@20) inside the lead's worklane; the lead stays active.
        let topology = TmuxTopologyFixture.makeWithPaneGroup()
        let created = try XCTUnwrap(topology.location(ofPane: "pn_worker"))
        let resolver = TmuxTargetResolver(topology: topology, callerPaneID: "pn_lead")

        for kind in [TmuxCompatIPCHandler.PaneCreationKind.split, .window, .session] {
            let printed = TmuxFormatRenderer.render(
                kind.defaultPrintFormat,
                context: TmuxFormatContext.pane(created.pane, window: created.window, in: topology)
            )
            XCTAssertEqual(resolver.pane(printed)?.pane.id, "pn_worker", "\(kind): \(printed)")
        }
        let windowID = TmuxFormatRenderer.render(
            "#{window_id}",
            context: TmuxFormatContext.pane(created.pane, window: created.window, in: topology)
        )
        XCTAssertEqual(windowID, "@20")
        XCTAssertEqual(resolver.pane(windowID)?.pane.id, "pn_worker")
    }

    // MARK: - which panes a tool may close

    func test_tools_may_close_their_own_and_shim_created_panes_only() {
        let anchor = WorklaneAnchor(leaderPaneID: "pn_lead", columnPaneIDs: ["pn_mate"])
        let shimCreated: Set<String> = ["pn_worker"]
        func may(_ paneID: String, caller: String = "pn_lead") -> Bool {
            TmuxCompatIPCHandler.mayClosePane(
                paneID,
                callerPaneID: caller,
                anchor: anchor,
                isShimCreated: shimCreated.contains
            )
        }

        XCTAssertTrue(may("pn_mate"), "team column pane")
        XCTAssertTrue(may("pn_worker"), "shim-created pane")
        XCTAssertTrue(may("pn_lead"), "the caller's own pane")
        XCTAssertFalse(may("pn_lead", caller: "pn_mate"), "a teammate cannot close the lead")
        XCTAssertFalse(may("pn_editor"), "the user's own pane")
    }

    func test_kill_window_closes_only_that_windows_teammates() {
        let topology = TmuxTopologyFixture.makeWithPaneGroup()
        let anchor = WorklaneAnchor(leaderPaneID: "pn_lead", columnPaneIDs: ["pn_mate", "pn_worker"])
        let shimCreated: Set<String> = ["pn_mate", "pn_worker", "pn_lead"]
        let windows = topology.session.windows
        func doomed(_ number: Int) -> [String] {
            let window = windows.first(where: { $0.number == number })!
            return TmuxCompatIPCHandler.panesToCloseForKillWindow(
                window,
                anchor: anchor,
                isShimCreated: shimCreated.contains
            )
        }

        XCTAssertEqual(doomed(5), ["pn_mate"], "the worklane's window keeps its lead and the pane-group window's pane")
        XCTAssertEqual(doomed(20), ["pn_worker"], "a pane-group window closes only its own panes")
        XCTAssertEqual(doomed(8), [], "a window without shim panes closes nothing")
    }

    func test_respawn_replacement_takes_over_anchor_and_active_pane() {
        var store = TmuxCompatStore(
            anchors: [
                "wl_lead": WorklaneAnchor(leaderPaneID: "pn_lead", columnPaneIDs: ["pn_mate", "pn_other"]),
            ],
            activePaneIDs: ["wl_lead": "pn_lead"]
        )

        store.replacePane("pn_lead", with: "pn_new", inWorklane: "wl_lead")
        XCTAssertEqual(store.anchors["wl_lead"]?.leaderPaneID, "pn_new")
        XCTAssertEqual(store.activePaneIDs["wl_lead"], "pn_new")

        store.replacePane("pn_mate", with: "pn_mate2", inWorklane: "wl_lead")
        XCTAssertEqual(store.anchors["wl_lead"]?.columnPaneIDs, ["pn_mate2", "pn_other"])
        XCTAssertEqual(store.activePaneIDs["wl_lead"], "pn_new")
    }

    func test_errors_use_tmux_wording() {
        XCTAssertEqual(TmuxCompatIPCError.paneNotFound("%9").localizedDescription, "can't find pane: %9")
        XCTAssertEqual(TmuxCompatIPCError.sessionNotFound("swarm").localizedDescription, "can't find session: swarm")
        XCTAssertEqual(
            TmuxCompatIPCError.paneStillActive("%4").localizedDescription,
            "respawn pane failed: pane %4 still active"
        )
    }
}
