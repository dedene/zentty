import XCTest
@testable import Zentty

final class TmuxCompatArgumentsTests: XCTestCase {
    /// Stands in for the topology resolver: `%leader` and `%agent` exist.
    private func resolveKnownPane(_ selector: String) -> PaneID? {
        let id = selector.hasPrefix("%") ? String(selector.dropFirst()) : selector
        return ["leader", "agent"].contains(id) ? PaneID(id) : nil
    }

    func test_displayTemplateUsesPositionalFormatAfterPrintFlag() {
        let parsed = TmuxCompatArguments.parse(
            ["-t", "%pn_leader", "-p", "#{session_name}:#{window_index}"],
            valueFlags: ["-F", "-t"],
            boolFlags: ["-p"]
        )

        XCTAssertEqual(parsed.value("-t"), "%pn_leader")
        XCTAssertTrue(parsed.hasFlag("-p"))
        XCTAssertEqual(parsed.displayTemplate, "#{session_name}:#{window_index}")
    }

    func test_displayTemplateFallsBackToFormatFlagWhenNoPositionalText() {
        let parsed = TmuxCompatArguments.parse(
            ["-p", "-F", "#{pane_id}"],
            valueFlags: ["-F", "-t"],
            boolFlags: ["-p"]
        )

        XCTAssertEqual(parsed.displayTemplate, "#{pane_id}")
    }

    func test_formatTemplateReadsUppercaseFormatFlag() {
        let parsed = TmuxCompatArguments.parse(
            ["-t", "zentty:1", "-F", "#{pane_id}"],
            valueFlags: ["-F", "-t"],
            boolFlags: []
        )

        XCTAssertEqual(parsed.value("-t"), "zentty:1")
        XCTAssertEqual(parsed.formatTemplate, "#{pane_id}")
    }

    func test_parseSupportsClusteredBooleanFlags() {
        let parsed = TmuxCompatArguments.parse(
            ["-dPh", "-F", "#{pane_id}"],
            valueFlags: ["-F"],
            boolFlags: ["-d", "-P", "-h"]
        )

        XCTAssertTrue(parsed.hasFlag("-d"))
        XCTAssertTrue(parsed.hasFlag("-P"))
        XCTAssertTrue(parsed.hasFlag("-h"))
        XCTAssertEqual(parsed.value("-F"), "#{pane_id}")
    }

    func test_parseSupportsClusteredShowOptionFlags() {
        let parsed = TmuxCompatArguments.parse(
            ["-Av", "mouse"],
            valueFlags: ["-t"],
            boolFlags: ["-A", "-g", "-v", "-w"]
        )

        XCTAssertTrue(parsed.hasFlag("-A"))
        XCTAssertTrue(parsed.hasFlag("-v"))
        XCTAssertEqual(parsed.positionals, ["mouse"])
    }

    func test_parseSupportsClusteredValueFlag() {
        let parsed = TmuxCompatArguments.parse(
            ["-l70%", "-P"],
            valueFlags: ["-l"],
            boolFlags: ["-P"]
        )

        XCTAssertEqual(parsed.value("-l"), "70%")
        XCTAssertTrue(parsed.hasFlag("-P"))
    }

    func test_parseTreatsDoubleDashAsEndOfOptionsTerminator() {
        // A tmux `split-window … -- <command>` uses `--` to terminate options.
        // The terminator must be consumed so the command (e.g. the `cat`
        // keep-alive placeholder) survives intact instead of collapsing to the
        // crashing `-- cat` string that dies with `zsh: no such option: cat`.
        // Regression for dedene/zentty#58.
        let parsed = TmuxCompatArguments.parse(
            ["-d", "--", "cat"],
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )

        XCTAssertTrue(parsed.hasFlag("-d"))
        XCTAssertEqual(parsed.positionals, ["cat"])
    }

    func test_parseStopsOptionProcessingAfterDoubleDash() {
        // Everything after `--` is positional verbatim, even option-like tokens,
        // so a command carrying its own flags is not mis-parsed.
        let parsed = TmuxCompatArguments.parse(
            ["--", "-c", "value"],
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )

        XCTAssertNil(parsed.value("-c"))
        XCTAssertEqual(parsed.positionals, ["-c", "value"])
    }

    func test_splitWindowStartupRequestDefersExactClaudeBootstrap() {
        let arguments = [
            "-d", "-t", "%leader", "-h", "-l", "70%", "-P", "-F", "#{pane_id}", "--", "cat"
        ]
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )

        let request = TmuxCompatIPCHandler.splitWindowStartupRequest(
            arguments: arguments,
            parsed: parsed,
            loginShellPath: "/bin/zsh"
        )

        XCTAssertTrue(request.isLaunchDeferred)
        XCTAssertNil(request.command)
        XCTAssertNil(request.nativeCommand)
    }

    func test_splitWindowStartupRequestKeepsOrdinaryCatImmediate() {
        let arguments = ["--", "cat"]
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )

        let request = TmuxCompatIPCHandler.splitWindowStartupRequest(
            arguments: arguments,
            parsed: parsed,
            loginShellPath: "/bin/zsh"
        )

        XCTAssertFalse(request.isLaunchDeferred)
        XCTAssertEqual(request.nativeCommand, "'/bin/zsh' -lic 'cat'")
    }

    func test_splitWindowStartupRequestKeepsNonPlaceholderCommandImmediate() {
        let arguments = [
            "-d", "-t", "%leader", "-h", "-l", "70%", "-P", "-F", "#{pane_id}", "--", "cat", "README.md"
        ]
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )

        let request = TmuxCompatIPCHandler.splitWindowStartupRequest(
            arguments: arguments,
            parsed: parsed,
            loginShellPath: "/bin/zsh"
        )

        XCTAssertFalse(request.isLaunchDeferred)
        XCTAssertEqual(request.nativeCommand, "'/bin/zsh' -lic 'cat README.md'")
    }

    func test_respawnPaneLaunchRequestPreservesClaudeCompoundCommand() {
        let command = "cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate"

        let request = TmuxCompatIPCHandler.respawnPaneLaunchRequest(
            arguments: ["-k", "-t", "%agent", "--", command],
            resolvePane: resolveKnownPane,
            loginShellPath: "/bin/zsh"
        )

        XCTAssertEqual(request?.paneID, PaneID("agent"))
        XCTAssertEqual(
            request?.nativeCommand,
            "'/bin/zsh' -lic 'cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate'"
        )
    }

    func test_respawnPaneLaunchRequestRejectsUnsupportedOrUnsafeShapes() {
        let command = "cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate"
        let cases: [[String]] = [
            ["-t", "%agent", "--", command],
            ["-k", "--", command],
            ["-k", "-t", "%agent", command],
            ["-k", "-t", "%agent", "--"],
            ["-k", "-t", "%agent", "--", command, "extra"],
            ["-k", "-t", "%missing", "--", command],
            ["-k", "-k", "-t", "%agent", "--", command],
            ["-t", "%agent", "-k", "--", command],
            ["-k", "-t", "%leader", "-t", "%agent", "--", command],
            ["-k", "-t%agent", "--", command],
            ["-k", "-x", "-t", "%agent", "--", command],
        ]

        for arguments in cases {
            XCTAssertNil(
                TmuxCompatIPCHandler.respawnPaneLaunchRequest(
                    arguments: arguments,
                    resolvePane: resolveKnownPane,
                    loginShellPath: "/bin/zsh"
                ),
                "Expected nil for arguments: \(arguments)"
            )
        }
    }

    func test_unresolvedTargetResultRejectsTargetDependentLaunchCommands() {
        for subcommand in ["split-window", "splitw", "new-window", "neww", "respawn-pane", "respawnp"] {
            XCTAssertThrowsError(try TmuxCompatIPCHandler.unresolvedTargetResult(for: subcommand)) { error in
                guard let tmuxError = error as? TmuxCompatIPCError else {
                    return XCTFail("Expected TmuxCompatIPCError, got \(error)")
                }
                guard case .targetUnavailable = tmuxError else {
                    return XCTFail("Expected targetUnavailable, got \(tmuxError)")
                }
                XCTAssertEqual(
                    tmuxError.localizedDescription,
                    "Cannot route tmux command: the target Zentty worklane or pane is no longer available."
                )
            }
        }
    }

    func test_unresolvedTargetResultAcknowledgesSetOption() throws {
        let result = try TmuxCompatIPCHandler.unresolvedTargetResult(for: "set-option")

        XCTAssertNil(result.stdout)
    }

    func test_sendKeysTranslatesEnterToCarriageReturn() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-t", "%pane", "claude", "Enter"], standardInput: nil),
            "claude\r"
        )
    }

    func test_sendKeysLiteralModePreservesSpecialKeyNames() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.sendKeysText(arguments: ["-l", "-t", "%pane", "claude", "Enter"], standardInput: nil),
            "claude Enter"
        )
    }

    func test_launchCommandFromSendKeysTextStripsTrailingEnter() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.launchCommandFromSendKeysText(
                "cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate\r"
            ),
            "cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate"
        )
    }

    func test_launchCommandFromSendKeysTextRequiresOnlyTrailingEnter() {
        XCTAssertNil(TmuxCompatIPCHandler.launchCommandFromSendKeysText("echo hello"))
        XCTAssertNil(TmuxCompatIPCHandler.launchCommandFromSendKeysText("\r"))
        XCTAssertNil(TmuxCompatIPCHandler.launchCommandFromSendKeysText("echo hello\rmore"))
    }

    func test_shellWrappedGhosttyCommandRunsLaunchTextThroughShell() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.shellWrappedGhosttyCommand(
                "cd /tmp/a b && env NAME='x' claude",
                loginShellPath: "/bin/zsh"
            ),
            "'/bin/zsh' -lic 'cd /tmp/a b && env NAME='\"'\"'x'\"'\"' claude'"
        )
    }

    func test_showOptionsPrintsValueOnlyWhenValueFlagIsSet() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.showOptionsStdout(arguments: ["-gv", "focus-events"]),
            "off\n"
        )
    }

    func test_showOptionsPrintsNameAndValueByDefault() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.showOptionsStdout(arguments: ["mouse"]),
            "mouse off\n"
        )
    }

    func test_capturePaneOptionsParsesPrintTargetAndNegativeStartAsLineLimit() {
        let options = TmuxCompatIPCHandler.capturePaneOptions(
            arguments: ["-p", "-J", "-S", "-20", "-t", "%pane"]
        )

        XCTAssertEqual(options.target, "%pane")
        XCTAssertTrue(options.print)
        XCTAssertEqual(options.lineLimit, 20)
        XCTAssertTrue(options.includeScrollback)
    }

    func test_capturePaneOptionsDoesNotLimitPositiveStart() {
        let options = TmuxCompatIPCHandler.capturePaneOptions(arguments: ["-S", "0"])

        XCTAssertNil(options.lineLimit)
        XCTAssertTrue(options.includeScrollback)
    }

    func test_waitForActionParsesSignal() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.waitForAction(arguments: ["-S", "agent-ready"]),
            .signal("agent-ready")
        )
    }

    func test_waitForActionParsesDefaultWait() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.waitForAction(arguments: ["agent-ready"]),
            .wait(name: "agent-ready", timeout: 30)
        )
    }

    func test_tailTerminalLinesKeepsLastRequestedLines() {
        XCTAssertEqual(
            TmuxCompatIPCHandler.tailTerminalLines("one\ntwo\nthree\n", maxLines: 2),
            "two\nthree\n"
        )
    }
}
