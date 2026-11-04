import XCTest
@testable import Zentty

/// A forked session's Claude config root travels as an `env` prefix on the typed fork command.
final class AgentForkClaudeConfigRootTests: XCTestCase {
    private let claudeID = "5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44"
    private let fakeHome = "/Users/test-fork-home"

    func test_alternate_root_prefixes_quoted_config_dir() {
        XCTAssertEqual(
            command(root: ClaudeConfigRoot(sourceRoot: "/Users/test/Claude Work/", homeDirectory: fakeHome)),
            "env CLAUDE_CONFIG_DIR='/Users/test/Claude Work' claude --resume \(claudeID) --fork-session"
        )
    }

    func test_default_root_unsets_config_dir() {
        let root = ClaudeConfigRoot(sourceRoot: "\(fakeHome)/.claude/", homeDirectory: fakeHome)
        XCTAssertEqual(root, .defaultRoot)
        XCTAssertEqual(command(root: root), "env -u CLAUDE_CONFIG_DIR claude --resume \(claudeID) --fork-session")
    }

    func test_unknown_root_keeps_the_bare_command() {
        XCTAssertNil(ClaudeConfigRoot(sourceRoot: nil, homeDirectory: fakeHome))
        XCTAssertNil(ClaudeConfigRoot(sourceRoot: "~/.claude-work", homeDirectory: fakeHome))
        XCTAssertNil(ClaudeConfigRoot(sourceRoot: "/", homeDirectory: fakeHome))
        XCTAssertEqual(command(root: nil), "claude --resume \(claudeID) --fork-session")
    }

    func test_forbidden_root_path_is_refused() {
        let override = AgentForkSessionOverride(
            tool: .claudeCode,
            sessionID: claudeID,
            claudeConfigRoot: .alternate("/Users/test/bypass-root")
        )
        XCTAssertEqual(
            availability(override)?.unavailableReason,
            AgentForkCommandBuilder.unsafeConfigRootReason
        )
    }

    func test_root_is_ignored_for_other_tools() {
        let override = AgentForkSessionOverride(
            tool: .codex,
            sessionID: "rollout_2026-10-18",
            claudeConfigRoot: .alternate("/Users/test/.claude-work")
        )
        XCTAssertEqual(availability(override)?.plan?.command, "codex fork rollout_2026-10-18")
    }

    /// The pane menu's fork (no override) never gets a root prefix.
    func test_pane_fork_without_override_is_unchanged() {
        let auxiliary = PaneAuxiliaryState(
            shellContext: PaneShellContext(scope: .local, path: "/tmp/agent", home: nil, user: nil, host: nil),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .running,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 1),
                trackedPID: 4242,
                workingDirectory: "/tmp/agent",
                sessionID: claudeID
            )
        )
        XCTAssertEqual(
            AgentForkCommandBuilder.availability(pane: pane, auxiliary: auxiliary, sessionOverride: nil)?.plan?.command,
            "claude --resume \(claudeID) --fork-session"
        )
    }

    // MARK: - Helpers

    private var pane: PaneState {
        PaneState(
            id: PaneID("pane"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/launch")
        )
    }

    private func availability(_ override: AgentForkSessionOverride) -> AgentForkAvailability? {
        AgentForkCommandBuilder.availability(pane: pane, auxiliary: PaneAuxiliaryState(), sessionOverride: override)
    }

    private func command(root: ClaudeConfigRoot?) -> String? {
        availability(AgentForkSessionOverride(tool: .claudeCode, sessionID: claudeID, claudeConfigRoot: root))?
            .plan?.command
    }
}
