import XCTest
@testable import Zentty

final class AgentResumeCommandBuilderTests: XCTestCase {
    func test_builder_returns_amp_thread_continue_command_for_valid_thread_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-amp",
            kind: .agentResume,
            toolName: "Amp",
            sessionID: "T-ZenttyBenchRestore",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "amp threads continue T-ZenttyBenchRestore"
        )
    }

    func test_builder_preserves_sanitized_amp_resume_arguments() {
        let draft = PaneRestoreDraft(
            paneID: "pane-amp",
            kind: .agentResume,
            toolName: "Amp",
            sessionID: "T-ZenttyBenchRestore",
            workingDirectory: "/tmp/project",
            trackedPID: 4242,
            agentLaunchSnapshot: AgentLaunchSnapshot(
                arguments: ["--mode", "smart", "--effort", "high", "--settings-file", "/tmp/amp settings.json"]
            )
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            #"amp threads continue --mode smart --effort high --settings-file '/tmp/amp settings.json' T-ZenttyBenchRestore"#
        )
    }

    func test_builder_returns_nil_for_unsafe_amp_thread_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-amp",
            kind: .agentResume,
            toolName: "Amp",
            sessionID: "T-safe; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_nil_for_amp_execute_resume_argument_with_value() {
        let draft = PaneRestoreDraft(
            paneID: "pane-amp",
            kind: .agentResume,
            toolName: "Amp",
            sessionID: "T-ZenttyBenchRestore",
            workingDirectory: "/tmp/project",
            trackedPID: 4242,
            agentLaunchSnapshot: AgentLaunchSnapshot(arguments: ["--execute=echo hi"])
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

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

    func test_builder_returns_cursor_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-cursor",
            kind: .agentResume,
            toolName: "Cursor",
            sessionID: "0CB916DB-26AA-40F2-86B5-1BA81B225FD2",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "cursor-agent --resume=0cb916db-26aa-40f2-86b5-1ba81b225fd2"
        )
    }

    func test_builder_returns_nil_for_cursor_non_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-cursor",
            kind: .agentResume,
            toolName: "Cursor",
            sessionID: "resume-this-session",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_kimi_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-kimi",
            kind: .agentResume,
            toolName: "Kimi",
            sessionID: "0cb916db-26aa-40f2-86b5-1ba81b225fd2",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "kimi -r 0cb916db-26aa-40f2-86b5-1ba81b225fd2"
        )
    }

    func test_builder_returns_nil_for_kimi_non_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-kimi",
            kind: .agentResume,
            toolName: "Kimi",
            sessionID: "resume-this-session",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_grok_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-grok",
            kind: .agentResume,
            toolName: "Grok",
            sessionID: "0CB916DB-26AA-40F2-86B5-1BA81B225FD2",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "grok --resume 0cb916db-26aa-40f2-86b5-1ba81b225fd2"
        )
    }

    func test_builder_returns_grok_resume_command_for_short_alphanumeric_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-grok",
            kind: .agentResume,
            toolName: "Grok",
            sessionID: "sess_abc12",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "grok --resume sess_abc12"
        )
    }

    func test_builder_returns_grok_directory_resume_when_session_id_has_shell_metacharacters() {
        // Hostile session IDs containing shell metacharacters (`;`, spaces, slashes, etc.)
        // must NEVER be interpolated into the resume command. The validator rejects them
        // and the builder falls back to the directory-based resume.
        let draft = PaneRestoreDraft(
            paneID: "pane-grok",
            kind: .agentResume,
            toolName: "Grok",
            sessionID: "abc;rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "grok --resume"
        )
    }

    func test_builder_returns_grok_directory_resume_when_session_id_blank_and_cwd_present() {
        let draft = PaneRestoreDraft(
            paneID: "pane-grok",
            kind: .agentResume,
            toolName: "Grok",
            sessionID: "",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "grok --resume"
        )
    }

    func test_builder_returns_nil_for_grok_when_session_id_blank_and_working_directory_missing() {
        let draft = PaneRestoreDraft(
            paneID: "pane-grok",
            kind: .agentResume,
            toolName: "Grok",
            sessionID: "",
            workingDirectory: nil,
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_gemini_resume_command_when_working_directory_exists_without_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-gemini",
            kind: .agentResume,
            toolName: "Gemini",
            sessionID: "",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "gemini --resume"
        )
    }

    func test_builder_returns_nil_for_gemini_when_working_directory_is_missing() {
        let draft = PaneRestoreDraft(
            paneID: "pane-gemini",
            kind: .agentResume,
            toolName: "Gemini",
            sessionID: "",
            workingDirectory: nil,
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_pi_resume_command_when_working_directory_exists_without_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-pi",
            kind: .agentResume,
            toolName: "Pi",
            sessionID: "",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "pi -c"
        )
    }

    func test_builder_returns_nil_for_pi_when_working_directory_is_missing() {
        let draft = PaneRestoreDraft(
            paneID: "pane-pi",
            kind: .agentResume,
            toolName: "Pi",
            sessionID: "",
            workingDirectory: nil,
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_agy_resume_command_for_alphanumeric_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-agy",
            kind: .agentResume,
            toolName: "agy",
            sessionID: "conversation-123",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "agy --conversation conversation-123"
        )
    }

    func test_builder_returns_agy_continue_command_when_session_id_is_empty() {
        let draft = PaneRestoreDraft(
            paneID: "pane-agy",
            kind: .agentResume,
            toolName: "agy",
            sessionID: "",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "agy --continue"
        )
    }

    func test_builder_returns_nil_for_agy_unsafe_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-agy",
            kind: .agentResume,
            toolName: "agy",
            sessionID: "sess; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_falls_back_to_continue_when_agy_session_id_is_a_zentty_placeholder() {
        // The launch bootstrap injects `zentty-placeholder-<uuid>` until the
        // first real conversation_id arrives from a hook. If the user
        // restores before that supersession ever happens we must not pass
        // the placeholder to `--conversation` — agy would reject it.
        let draft = PaneRestoreDraft(
            paneID: "pane-agy",
            kind: .agentResume,
            toolName: "agy",
            sessionID: "zentty-placeholder-cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "agy --continue"
        )
    }

    func test_builder_returns_hermes_resume_command_for_safe_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-hermes",
            kind: .agentResume,
            toolName: "Hermes Agent",
            sessionID: "hermes-session-123",
            workingDirectory: "/tmp/project",
            trackedPID: 4242,
            agentLaunchSnapshot: AgentLaunchSnapshot(arguments: ["--tui", "--model", "anthropic/claude-sonnet-4.6"])
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "hermes --tui --model anthropic/claude-sonnet-4.6 --resume hermes-session-123"
        )
    }

    func test_builder_prefixes_hermes_home_when_launch_snapshot_captured_it() {
        let draft = PaneRestoreDraft(
            paneID: "pane-hermes",
            kind: .agentResume,
            toolName: "Hermes Agent",
            sessionID: "hermes-session-123",
            workingDirectory: "/tmp/project",
            trackedPID: 4242,
            agentLaunchSnapshot: AgentLaunchSnapshot(
                arguments: ["chat", "--tui", "--resume", "old-session", "--model", "anthropic/claude-sonnet-4.6"],
                environment: ["HERMES_HOME": "/tmp/hermes profile"]
            )
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            #"env HERMES_HOME='/tmp/hermes profile' hermes --tui --model anthropic/claude-sonnet-4.6 --resume hermes-session-123"#
        )
    }

    func test_builder_returns_nil_for_hermes_one_shot_launch_arguments() {
        let draft = PaneRestoreDraft(
            paneID: "pane-hermes",
            kind: .agentResume,
            toolName: "Hermes Agent",
            sessionID: "hermes-session-123",
            workingDirectory: "/tmp/project",
            trackedPID: 4242,
            agentLaunchSnapshot: AgentLaunchSnapshot(arguments: ["--oneshot", "fix this"])
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_nil_for_hermes_unsafe_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-hermes",
            kind: .agentResume,
            toolName: "Hermes Agent",
            sessionID: "session; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }

    func test_builder_returns_vibe_resume_command_for_uuid_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-vibe",
            kind: .agentResume,
            toolName: "Mistral Vibe",
            sessionID: "0CB916DB-26AA-40F2-86B5-1BA81B225FD2",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "vibe --resume 0cb916db-26aa-40f2-86b5-1ba81b225fd2"
        )
    }

    func test_builder_returns_vibe_resume_command_for_safe_alphanumeric_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-vibe",
            kind: .agentResume,
            toolName: "Mistral Vibe",
            sessionID: "vibe_session_01",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertEqual(
            AgentResumeCommandBuilder.command(for: draft),
            "vibe --resume vibe_session_01"
        )
    }

    func test_builder_returns_nil_for_vibe_unsafe_session_id() {
        let draft = PaneRestoreDraft(
            paneID: "pane-vibe",
            kind: .agentResume,
            toolName: "Mistral Vibe",
            sessionID: "sess; rm -rf /",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )

        XCTAssertNil(AgentResumeCommandBuilder.command(for: draft))
    }
}
