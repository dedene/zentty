import XCTest
@testable import Zentty

final class WorklaneSessionEnvironmentTests: XCTestCase {
    private let windowID = WindowID("wd_env_test")
    private let worklaneID = WorklaneID("wl_env_test")
    private let paneID = PaneID("pn_env_test")

    func test_make_omits_team_env_when_toggle_off() {
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            agentTeamsEnabled: false
        )

        XCTAssertNil(env["TMUX"])
        XCTAssertNil(env["TMUX_PANE"])
        XCTAssertNil(env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"])
    }

    func test_make_injects_team_env_when_toggle_on_and_no_existing_tmux() throws {
        try XCTSkipIf(
            AgentStatusHelper.tmuxShimDirectoryPath() == nil,
            "Bundled tmux-shim not available in this test environment"
        )

        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            agentTeamsEnabled: true
        )

        // tmux tools validate these with `/^%\d+$/` and split `$TMUX` into
        // socket, numeric server pid and session number.
        let state = TmuxCompatSessionState.shared
        let expectedTMUX = TmuxShimEnvironment.tmuxValue(
            socketPath: WorklaneSessionEnvironment.tmuxSocketPath,
            serverPID: ProcessInfo.processInfo.processIdentifier,
            sessionNumber: state.sessionNumber(for: windowID.rawValue)
        )
        XCTAssertEqual(env["TMUX"], expectedTMUX)
        XCTAssertEqual(env["TMUX_PANE"], "%\(state.paneNumber(for: paneID.rawValue))")
        XCTAssertNotNil(env["TMUX_PANE"]?.range(of: #"^%\d+$"#, options: .regularExpression))
        XCTAssertEqual(env["ZENTTY_TMUX_SHIM"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"], "1")

        let shimDirectory = try XCTUnwrap(AgentStatusHelper.tmuxShimDirectoryPath())
        XCTAssertEqual(env["ZENTTY_TMUX_SHIM_DIR"], shimDirectory)
        XCTAssertTrue(
            env["ZENTTY_TMUX_COMPAT_TRACE_PATH"]?.hasSuffix("Library/Application Support/Zentty/tmux-compat-trace.jsonl") == true
        )
        let pathEntries = try XCTUnwrap(env["PATH"]).split(separator: ":").map(String.init)
        XCTAssertEqual(pathEntries.first, shimDirectory)
    }

    func test_make_uses_explicit_tmux_trace_path_when_present() throws {
        try XCTSkipIf(
            AgentStatusHelper.tmuxShimDirectoryPath() == nil,
            "Bundled tmux-shim not available in this test environment"
        )

        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: [
                "PATH": "/usr/bin:/bin",
                "ZENTTY_TMUX_COMPAT_TRACE_PATH": "/tmp/custom-tmux-trace.jsonl",
            ],
            agentTeamsEnabled: true
        )

        XCTAssertEqual(env["ZENTTY_TMUX_COMPAT_TRACE_PATH"], "/tmp/custom-tmux-trace.jsonl")
    }

    func test_make_skips_injection_when_existing_tmux_set() {
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: [
                "PATH": "/usr/bin:/bin",
                "TMUX": "/private/tmp/tmux-501/default,1234,0",
            ],
            agentTeamsEnabled: true
        )

        XCTAssertNil(env["TMUX"], "Should not override existing TMUX")
        XCTAssertNil(env["TMUX_PANE"])
        XCTAssertNil(env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"])
    }

    func test_make_does_not_double_prepend_shim_directory() throws {
        try XCTSkipIf(
            AgentStatusHelper.tmuxShimDirectoryPath() == nil,
            "Bundled tmux-shim not available in this test environment"
        )

        let shimDirectory = try XCTUnwrap(AgentStatusHelper.tmuxShimDirectoryPath())
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: ["PATH": "\(shimDirectory):/usr/bin:/bin"],
            agentTeamsEnabled: true
        )

        let occurrences = try XCTUnwrap(env["PATH"])
            .split(separator: ":")
            .filter { $0 == Substring(shimDirectory) }
            .count
        XCTAssertEqual(occurrences, 1, "Shim directory should appear exactly once on PATH")
    }

    func test_make_injects_and_preserves_xdg_data_dirs_for_modern_shells() throws {
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: [
                "PATH": "/usr/bin:/bin",
                "XDG_DATA_DIRS": "/custom/xdg:/usr/local/share:/usr/share",
            ],
            agentTeamsEnabled: false
        )

        XCTAssertNotNil(env["ZENTTY_SHELL_INTEGRATION_DIR"])
        XCTAssertEqual(env["ZENTTY_SHELL_INTEGRATION"], "1")

        let shellIntegrationDirectory = try XCTUnwrap(env["ZENTTY_SHELL_INTEGRATION_DIR"])
        let entries = try XCTUnwrap(env["XDG_DATA_DIRS"]).split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, shellIntegrationDirectory)
        XCTAssertTrue(entries.contains("/custom/xdg"), "must preserve prior XDG entries")

        XCTAssertEqual(env["ZENTTY_SHELL_INTEGRATION_XDG_DIR"], shellIntegrationDirectory)
        XCTAssertEqual(env["ZENTTY_ORIGINAL_XDG_DATA_DIRS"], "/custom/xdg:/usr/local/share:/usr/share")
    }

    func test_make_advertises_truecolor_when_colorterm_is_not_present() {
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            agentTeamsEnabled: false
        )

        XCTAssertEqual(env["COLORTERM"], "truecolor")
    }

    func test_make_preserves_existing_colorterm() {
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: [
                "PATH": "/usr/bin:/bin",
                "COLORTERM": "24bit",
            ],
            agentTeamsEnabled: false
        )

        XCTAssertEqual(env["COLORTERM"], "24bit")
    }

    func test_make_routes_kiro_term_through_bundled_wrapper() throws {
        try XCTSkipIf(
            AgentStatusHelper.kiroTermWrapperPath() == nil,
            "Bundled zentty-kiro-term wrapper not available in this test environment"
        )

        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            agentTeamsEnabled: false
        )

        XCTAssertEqual(env["Q_TERM_PATH"], AgentStatusHelper.kiroTermWrapperPath())
        XCTAssertNil(env["ZENTTY_ORIGINAL_Q_TERM_PATH"])
    }

    func test_make_preserves_user_q_term_path_for_wrapper() throws {
        let kiroTermWrapper = try XCTUnwrap(
            AgentStatusHelper.kiroTermWrapperPath(),
            "Bundled zentty-kiro-term wrapper not available in this test environment"
        )

        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: [
                "PATH": "/usr/bin:/bin",
                "Q_TERM_PATH": "/opt/kiro/kiro-cli-term",
            ],
            agentTeamsEnabled: false
        )

        XCTAssertEqual(env["Q_TERM_PATH"], kiroTermWrapper)
        XCTAssertEqual(env["ZENTTY_ORIGINAL_Q_TERM_PATH"], "/opt/kiro/kiro-cli-term")
    }

    func test_template_safe_overrides_drop_q_term_path() {
        let safe = WorklaneSessionEnvironment.templateSafeOverrides(
            from: ["Q_TERM_PATH": "/x", "FOO": "bar"]
        )

        XCTAssertEqual(safe, ["FOO": "bar"])
    }

    func test_template_safe_overrides_drop_tmux_identity_and_tool_assignments() {
        let safe = WorklaneSessionEnvironment.templateSafeOverrides(from: [
            "TMUX": "/tmp/zentty-tmux/abc,42,0",
            "TMUX_PANE": "%1",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
            "ZENTTY_TMUX_SHIM": "1",
            "OPENCODE_SERVER_PASSWORD": "secret",
            TmuxShimEnvironment.toolAssignedKeysKey: "OPENCODE_SERVER_PASSWORD",
            "FOO": "bar",
        ])

        XCTAssertEqual(safe, ["FOO": "bar"])
    }

    func test_make_injects_xdg_even_when_no_prior_xdg_data_dirs() throws {
        let env = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            agentTeamsEnabled: false
        )

        let shellIntegrationDirectory = try XCTUnwrap(env["ZENTTY_SHELL_INTEGRATION_DIR"])
        let entries = try XCTUnwrap(env["XDG_DATA_DIRS"]).split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, shellIntegrationDirectory)
        XCTAssertEqual(env["ZENTTY_SHELL_INTEGRATION_XDG_DIR"], shellIntegrationDirectory)
    }
}
