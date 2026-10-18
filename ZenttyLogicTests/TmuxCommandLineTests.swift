import XCTest
@testable import Zentty

final class TmuxCommandLineTests: XCTestCase {
    // MARK: - aliases

    func test_aliases_map_to_canonical_commands() {
        let expectations = [
            "splitw": "split-window", "neww": "new-window", "send": "send-keys",
            "killp": "kill-pane", "displayp": "display-panes", "display": "display-message",
            "lsp": "list-panes", "selectp": "select-pane", "setw": "set-window-option",
            "show": "show-options", "has": "has-session", "if": "if-shell", "run": "run-shell",
            "ls": "list-sessions", "respawnp": "respawn-pane", "wait": "wait-for",
        ]
        for (alias, canonical) in expectations {
            XCTAssertEqual(TmuxCommandLine.canonicalName(alias), canonical, alias)
        }
        XCTAssertEqual(TmuxCommandLine.canonicalName("Split-Window"), "split-window")
        XCTAssertEqual(TmuxCommandLine.canonicalName("not-a-command"), "not-a-command")
    }

    // MARK: - sequences

    func test_split_sequence_on_lone_semicolon_and_trailing_semicolon() {
        XCTAssertEqual(
            TmuxCommandLine.splitSequence(["start-server", ";", "set-option", "-g", "exit-empty", "off"]),
            [["start-server"], ["set-option", "-g", "exit-empty", "off"]]
        )
        XCTAssertEqual(
            TmuxCommandLine.splitSequence(["select-pane", "-t", "%1;", "kill-pane"]),
            [["select-pane", "-t", "%1"], ["kill-pane"]]
        )
    }

    func test_escaped_semicolon_is_literal() {
        XCTAssertEqual(
            TmuxCommandLine.splitSequence(["send-keys", "echo a\\;", "Enter"]),
            [["send-keys", "echo a;", "Enter"]]
        )
    }

    func test_double_dash_survives_sequence_splitting() {
        XCTAssertEqual(
            TmuxCommandLine.splitSequence(["split-window", "-d", "--", "cat"]),
            [["split-window", "-d", "--", "cat"]]
        )
    }

    // MARK: - command strings

    func test_parse_command_string_honours_tmux_quoting() throws {
        XCTAssertEqual(
            try TmuxCommandLine.parseCommandString(
                "split-window -h -t %1 -d -P -F '#{pane_id}' -c '/tmp/a b' 'sh -c \"x\" # r1'; display-message -p 'OK_1'"
            ),
            [
                ["split-window", "-h", "-t", "%1", "-d", "-P", "-F", "#{pane_id}", "-c", "/tmp/a b", "sh -c \"x\" # r1"],
                ["display-message", "-p", "OK_1"],
            ]
        )
    }

    func test_parse_command_string_double_quotes_and_escapes() throws {
        XCTAssertEqual(
            try TmuxCommandLine.parseCommandString(#"run-shell "exit 1""#),
            [["run-shell", "exit 1"]]
        )
        XCTAssertEqual(
            try TmuxCommandLine.parseCommandString(#"send-keys "say \"hi\"" Enter \; kill-pane"#),
            [["send-keys", "say \"hi\"", "Enter", ";", "kill-pane"]]
        )
    }

    func test_parse_command_string_comments_but_not_formats() throws {
        XCTAssertEqual(
            try TmuxCommandLine.parseCommandString("display-message -p #{pane_id} # trailing comment"),
            [["display-message", "-p", "#{pane_id}"]]
        )
        XCTAssertEqual(try TmuxCommandLine.parseCommandString("display-message -p ''"), [["display-message", "-p", ""]])
    }

    func test_parse_command_string_rejects_unterminated_quote() {
        XCTAssertThrowsError(try TmuxCommandLine.parseCommandString("display-message 'oops"))
    }

    func test_version_line() {
        XCTAssertEqual(TmuxCommandLine.versionLine, "tmux 3.4\n")
        XCTAssertTrue(TmuxCommandLine.isVersionRequest(["-V"]))
        XCTAssertTrue(TmuxCommandLine.isVersionRequest(["-S", "/tmp/zentty-tmux/x", "-V"]), "after other globals")
        XCTAssertTrue(TmuxCommandLine.isVersionRequest(["-2", "-u", "-V"]))
        XCTAssertFalse(TmuxCommandLine.isVersionRequest(["list-panes"]))
        XCTAssertFalse(TmuxCommandLine.isVersionRequest(["display-message", "-V"]), "-V after the subcommand is its own")
    }

    // MARK: - runner

    func test_runner_concatenates_sequence_output() {
        let backend = FakeTmuxBackend()
        backend.responses["display-message"] = TmuxCommandOutcome(stdout: "%1\n")
        let outcome = TmuxCommandRunner(backend: backend).run(["select-pane", "-t", "%1", ";", "display-message", "-p", "#{pane_id}"])

        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(outcome.stdout, "%1\n")
        XCTAssertEqual(backend.sent.map(\.0), ["select-pane", "display-message"])
    }

    func test_runner_stops_at_first_failure() {
        let backend = FakeTmuxBackend()
        backend.responses["kill-pane"] = .failure("can't find pane: %9")
        let outcome = TmuxCommandRunner(backend: backend).run(["kill-pane", "-t", "%9", ";", "display-message", "-p", "x"])

        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(outcome.stderr, "can't find pane: %9\n")
        XCTAssertEqual(backend.sent.map(\.0), ["kill-pane"])
    }

    func test_if_shell_format_condition_runs_the_matching_branch() {
        let backend = FakeTmuxBackend()
        backend.formats["#{==:#{pane_pid},5150}"] = "1"
        let outcome = TmuxCommandRunner(backend: backend).run([
            "if-shell", "-F", "-t", "%4", "#{==:#{pane_pid},5150}",
            "kill-pane -t %4 ; display-message -p 'receipt_1'",
            "display-message -p ''",
        ])

        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(backend.formatTargets, ["%4"])
        XCTAssertEqual(backend.sent.map(\.0), ["kill-pane", "display-message"])
        XCTAssertEqual(backend.sent.last?.1, ["-p", "receipt_1"])
    }

    func test_if_shell_false_format_runs_else_branch() {
        let backend = FakeTmuxBackend()
        backend.formats["#{pane_dead}"] = "0"
        _ = TmuxCommandRunner(backend: backend).run(["if", "-F", "#{pane_dead}", "kill-pane", "display -p no"])

        XCTAssertEqual(backend.sent.map(\.0), ["display"])
        XCTAssertEqual(backend.sent.first?.1, ["-p", "no"])
    }

    func test_if_shell_shell_condition_expands_formats_then_runs_shell() {
        let backend = FakeTmuxBackend()
        backend.formats["guard --pid '#{pid}'"] = "guard --pid '4242'"
        backend.shellExitCodes["guard --pid '4242'"] = 0
        _ = TmuxCommandRunner(backend: backend).run(["if-shell", "guard --pid '#{pid}'", "split-window -d", "display -p FAIL"])

        XCTAssertEqual(backend.shellCommands, ["guard --pid '4242'"])
        XCTAssertEqual(backend.sent.map(\.0), ["split-window"])
    }

    func test_if_shell_failing_shell_without_else_succeeds_silently() {
        let backend = FakeTmuxBackend()
        backend.shellExitCodes["false"] = 1
        let outcome = TmuxCommandRunner(backend: backend).run(["if-shell", "false", "kill-pane"])

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(backend.sent.isEmpty)
    }

    func test_run_shell_prints_output_and_fails_on_nonzero_exit() {
        let backend = FakeTmuxBackend()
        backend.shellOutput["echo hi"] = "hi\n"
        XCTAssertEqual(TmuxCommandRunner(backend: backend).run(["run-shell", "echo hi"]).stdout, "hi\n")

        backend.shellExitCodes["exit 1"] = 1
        let failed = TmuxCommandRunner(backend: backend).run(["run", "exit 1"])
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertEqual(failed.stderr, "'exit 1' returned 1\n")
    }

    func test_run_shell_background_and_tmux_command_modes() {
        let backend = FakeTmuxBackend()
        XCTAssertEqual(TmuxCommandRunner(backend: backend).run(["run-shell", "-b", "sleep 5"]), .success)
        XCTAssertEqual(backend.backgroundCommands, ["sleep 5"])

        _ = TmuxCommandRunner(backend: backend).run(["run-shell", "-C", "select-pane -t %2"])
        XCTAssertEqual(backend.sent.map(\.0), ["select-pane"])
    }

    func test_run_shell_expands_escaped_formats_once() {
        let backend = FakeTmuxBackend()
        backend.formats["tmux list-panes -F '##{pane_id}'"] = "tmux list-panes -F '#{pane_id}'"
        _ = TmuxCommandRunner(backend: backend).run(["run-shell", "tmux list-panes -F '##{pane_id}'"])

        XCTAssertEqual(backend.shellCommands, ["tmux list-panes -F '#{pane_id}'"])
    }
}

private final class FakeTmuxBackend: TmuxCommandBackend {
    var responses: [String: TmuxCommandOutcome] = [:]
    var formats: [String: String] = [:]
    var shellExitCodes: [String: Int32] = [:]
    var shellOutput: [String: String] = [:]
    private(set) var sent: [(String, [String])] = []
    private(set) var formatTargets: [String?] = []
    private(set) var shellCommands: [String] = []
    private(set) var backgroundCommands: [String] = []

    func send(subcommand: String, arguments: [String]) -> TmuxCommandOutcome {
        sent.append((subcommand, arguments))
        return responses[subcommand] ?? .success
    }

    func expandFormat(_ format: String, target: String?) -> String? {
        formatTargets.append(target)
        return formats[format] ?? format
    }

    func runShell(_ command: String) -> (stdout: String, exitCode: Int32) {
        shellCommands.append(command)
        return (shellOutput[command] ?? "", shellExitCodes[command] ?? 0)
    }

    func runShellInBackground(_ command: String) {
        backgroundCommands.append(command)
    }
}
