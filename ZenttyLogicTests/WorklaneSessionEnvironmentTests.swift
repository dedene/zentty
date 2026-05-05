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

        XCTAssertEqual(env["TMUX"], "/tmp/zentty-claude-teams/wl_env_test,0,pn_env_test")
        XCTAssertEqual(env["TMUX_PANE"], "%pn_env_test")
        XCTAssertEqual(env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"], "1")

        let shimDirectory = try XCTUnwrap(AgentStatusHelper.tmuxShimDirectoryPath())
        XCTAssertEqual(env["ZENTTY_TMUX_SHIM_DIR"], shimDirectory)
        XCTAssertTrue(
            env["ZENTTY_TMUX_COMPAT_TRACE_PATH"]?.hasSuffix(".config/zentty/tmux-compat-trace.jsonl") == true
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
}
