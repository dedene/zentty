import XCTest
@testable import Zentty

final class AgentResumeCommandBuilderTests: XCTestCase {
    func test_builder_returns_claude_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-claude",
            kind: .agentResume,
            toolName: "Claude Code",
            sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c"
        )
    }

    func test_builder_returns_nil_for_claude_non_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-claude",
            kind: .agentResume,
            toolName: "Claude Code",
            sessionID: "cli-pane-management",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_codex_resume_command_for_safe_thread_name() {
        let draft = PaneRestoreDraft(
            paneID: "pane-codex",
            kind: .agentResume,
            toolName: "Codex",
            sessionID: "add-faq-section-landing",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "codex resume add-faq-section-landing"
        )
    }

    func test_builder_returns_codex_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-codex",
            kind: .agentResume,
            toolName: "Codex",
            sessionID: "e248c933-5c37-486d-99c7-23d387961edb",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "codex resume e248c933-5c37-486d-99c7-23d387961edb"
        )
    }

    func test_builder_returns_nil_for_codex_unsafe_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-codex",
            kind: .agentResume,
            toolName: "Codex",
            sessionID: "session; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(
            AgentResumeCommandBuilder.command(for: draft)
        )
    }

    func test_builder_returns_opencode_resume_command_for_valid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-opencode",
            kind: .agentResume,
            toolName: "OpenCode",
            sessionID: "ses_28352bf9bffep9wfuql3YqyHlr",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "opencode --session ses_28352bf9bffep9wfuql3YqyHlr"
        )
    }

    func test_builder_returns_nil_for_opencode_invalid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-opencode",
            kind: .agentResume,
            toolName: "OpenCode",
            sessionID: "ses_bad; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_copilot_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-copilot",
            kind: .agentResume,
            toolName: "Copilot",
            sessionID: "0cb916db-26aa-40f2-86b5-1ba81b225fd2",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "copilot --resume=0cb916db-26aa-40f2-86b5-1ba81b225fd2"
        )
    }

    func test_builder_returns_nil_for_copilot_non_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-copilot",
            kind: .agentResume,
            toolName: "Copilot",
            sessionID: "resume-this-session",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }
}
