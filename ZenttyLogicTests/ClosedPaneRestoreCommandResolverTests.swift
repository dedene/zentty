import XCTest
@testable import Zentty

final class ClosedPaneRestoreCommandResolverTests: XCTestCase {
    func test_resolves_claude_session_to_resume_command() {
        let entry = makeEntry(
            agent: ClosedPaneAgentSnapshot(
                tool: .claudeCode,
                toolDisplayName: "Claude Code",
                sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c",
                workingDirectory: "/tmp/project"
            ),
            nativeCommand: nil
        )

        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        guard case let .agentResume(command, tool, sessionID) = outcome else {
            XCTFail("Expected agentResume, got \(outcome)")
            return
        }
        XCTAssertEqual(command, "claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c")
        XCTAssertEqual(tool, .claudeCode)
        XCTAssertEqual(sessionID, "237d8c32-2a27-4850-8da8-3a110f13682c")
    }

    func test_replays_native_command_when_no_agent_snapshot() {
        let entry = makeEntry(agent: nil, nativeCommand: "vim README.md")

        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        XCTAssertEqual(outcome, .replayCommand("vim README.md"))
    }

    func test_replays_command_when_only_command_field_set() {
        let entry = makeEntry(agent: nil, nativeCommand: nil, command: "npm run dev")

        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        XCTAssertEqual(outcome, .replayCommand("npm run dev"))
    }

    func test_falls_back_to_plain_shell_when_no_agent_no_command() {
        let entry = makeEntry(agent: nil, nativeCommand: nil)

        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        XCTAssertEqual(outcome, .plainShell)
    }

    func test_falls_back_to_replay_when_session_id_invalid_for_resume() {
        let entry = makeEntry(
            agent: ClosedPaneAgentSnapshot(
                tool: .claudeCode,
                toolDisplayName: "Claude Code",
                sessionID: "not-a-uuid",
                workingDirectory: nil
            ),
            nativeCommand: "claude"
        )

        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        XCTAssertEqual(outcome, .replayCommand("claude"))
    }

    func test_uses_gemini_resume_command_even_without_session_id() {
        let entry = makeEntry(
            agent: ClosedPaneAgentSnapshot(
                tool: .gemini,
                toolDisplayName: "Gemini",
                sessionID: nil,
                workingDirectory: nil
            ),
            nativeCommand: nil
        )

        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        guard case let .agentResume(command, tool, _) = outcome else {
            XCTFail("Expected agentResume, got \(outcome)")
            return
        }
        XCTAssertEqual(command, "gemini --resume")
        XCTAssertEqual(tool, .gemini)
    }

    private func makeEntry(
        agent: ClosedPaneAgentSnapshot?,
        nativeCommand: String?,
        command: String? = nil
    ) -> ClosedPaneEntry {
        ClosedPaneEntry(
            closedAt: Date(),
            originalPaneID: PaneID("pn_test"),
            originalWorklaneID: WorklaneID("wl_test"),
            originalColumnID: PaneColumnID("col_test"),
            originalColumnIndex: 0,
            originalPaneIndex: 0,
            originalColumnWidth: 600,
            originalHeightInColumn: nil,
            title: "test",
            workingDirectory: "/tmp",
            originalNativeCommand: nativeCommand,
            originalCommand: command,
            agentSnapshot: agent,
            scrollbackText: nil
        )
    }
}
