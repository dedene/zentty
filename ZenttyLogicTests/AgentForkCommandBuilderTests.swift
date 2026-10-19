import XCTest
@testable import Zentty

final class AgentForkCommandBuilderTests: XCTestCase {
    private let claudeID = "5B1F9E52-5C1D-4E8A-9D53-7F3E0B1C2A44"

    override func setUp() {
        super.setUp()
        AgentManifestRegistry.provider = { AgentManifestRegistry(manifests: []) }
        addTeardownBlock {
            AgentManifestRegistry.provider = { .shared }
        }
    }

    // MARK: - Command table

    func test_claude_fork_resumes_with_fork_session_and_lowercases_uuid() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .claudeCode, sessionID: claudeID),
            "claude --resume 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44 --fork-session"
        )
    }

    func test_codex_fork_uses_fork_subcommand() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .codex, sessionID: claudeID),
            "codex fork 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44"
        )
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .codex, sessionID: "rollout_2026-10-18"),
            "codex fork rollout_2026-10-18"
        )
    }

    func test_opencode_fork_continues_session_with_fork_flag() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .openCode, sessionID: "ses_abc123"),
            "opencode --session ses_abc123 --fork"
        )
    }

    func test_droid_fork_uses_fork_flag() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .droid, sessionID: "a1b2-c3d4"),
            "droid --fork a1b2-c3d4"
        )
    }

    func test_grok_fork_resumes_with_fork_session() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .grok, sessionID: claudeID),
            "grok --resume 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44 --fork-session"
        )
    }

    func test_pi_fork_requires_full_uuid() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .pi, sessionID: claudeID),
            "pi --fork 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44"
        )
        XCTAssertNil(AgentForkCommandBuilder.command(for: .pi, sessionID: "pane-pi"))
    }

    func test_session_id_is_trimmed_before_validation() {
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .openCode, sessionID: "  ses_abc123\n"),
            "opencode --session ses_abc123 --fork"
        )
    }

    func test_shell_unsafe_session_ids_are_rejected() {
        XCTAssertNil(AgentForkCommandBuilder.command(for: .claudeCode, sessionID: "not-a-uuid"))
        XCTAssertNil(AgentForkCommandBuilder.command(for: .codex, sessionID: "abc; rm -rf ~"))
        XCTAssertNil(AgentForkCommandBuilder.command(for: .openCode, sessionID: "ses_abc $(id)"))
        XCTAssertNil(AgentForkCommandBuilder.command(for: .droid, sessionID: "id'quote"))
        XCTAssertNil(AgentForkCommandBuilder.command(for: .grok, sessionID: "a b c d"))
    }

    func test_agents_without_a_fork_command_are_not_forkable() {
        let tools: [AgentTool] = [
            .amp, .copilot, .cursor, .gemini, .kimi, .agy, .hermes,
            .vibe, .devin, .muse, .omp, .smallHarness, .zentty,
        ]
        for tool in tools {
            XCTAssertFalse(AgentForkCommandBuilder.supportsFork(tool), "\(tool.displayName)")
            XCTAssertNil(AgentForkCommandBuilder.command(for: tool, sessionID: claudeID), "\(tool.displayName)")
        }
    }

    // MARK: - Manifest agents

    func test_manifest_fork_template_substitutes_validated_session_id() {
        installManifest(fork: AgentManifest.Resume(
            command: "kilo --session {sessionId} --fork",
            sessionIdPattern: "^ses_[A-Za-z0-9]+$"
        ))

        XCTAssertTrue(AgentForkCommandBuilder.supportsFork(.custom("Kilo Code")))
        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .custom("Kilo Code"), sessionID: "ses_abc"),
            "kilo --session ses_abc --fork"
        )
        XCTAssertNil(AgentForkCommandBuilder.command(for: .custom("Kilo Code"), sessionID: "abc"))
    }

    func test_manifest_fork_quotes_ids_when_pattern_is_permissive() {
        installManifest(fork: AgentManifest.Resume(command: "kilo --session {sessionId} --fork"))

        XCTAssertEqual(
            AgentForkCommandBuilder.command(for: .custom("Kilo Code"), sessionID: "it's mine"),
            "kilo --session 'it'\\''s mine' --fork"
        )
    }

    func test_manifest_fork_substitutes_quoted_working_directory() {
        installManifest(fork: AgentManifest.Resume(command: "kilo --dir {workingDirectory} --fork {sessionId}"))

        XCTAssertEqual(
            AgentForkCommandBuilder.command(
                for: .custom("Kilo Code"),
                sessionID: "ses_abc",
                workingDirectory: "/tmp/my project"
            ),
            "kilo --dir '/tmp/my project' --fork ses_abc"
        )
    }

    func test_manifest_without_session_template_or_fork_block_is_not_forkable() {
        installManifest(fork: AgentManifest.Resume(command: "kilo --continue --fork"))
        XCTAssertFalse(AgentForkCommandBuilder.supportsFork(.custom("Kilo Code")))

        installManifest(fork: nil)
        XCTAssertFalse(AgentForkCommandBuilder.supportsFork(.custom("Kilo Code")))
    }

    func test_bundled_kilo_manifest_declares_fork() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources/agents/kilo.json")
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(contentsOf: url))

        XCTAssertEqual(manifest.fork?.command, "kilo --session {sessionId} --fork")
        XCTAssertEqual(manifest.fork?.sessionIdPattern, manifest.resume?.sessionIdPattern)
    }

    // MARK: - Availability

    func test_availability_returns_plan_for_forkable_agent() {
        let availability = AgentForkCommandBuilder.availability(for: AgentForkSource(
            tool: .claudeCode,
            sessionID: claudeID,
            workingDirectory: "/tmp/project"
        ))

        XCTAssertEqual(availability, .available(AgentForkPlan(
            tool: .claudeCode,
            command: "claude --resume 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44 --fork-session",
            workingDirectory: "/tmp/project"
        )))
        XCTAssertTrue(availability.isAvailable)
        XCTAssertNil(availability.unavailableReason)
    }

    func test_availability_reason_for_agent_without_fork_command() {
        let availability = AgentForkCommandBuilder.availability(for: AgentForkSource(
            tool: .copilot,
            sessionID: claudeID,
            workingDirectory: "/tmp/project"
        ))

        XCTAssertEqual(availability.unavailableReason, "Copilot can't fork a conversation.")
    }

    func test_availability_reason_when_session_id_is_unknown() {
        for sessionID in [nil, "", "  "] as [String?] {
            let availability = AgentForkCommandBuilder.availability(for: AgentForkSource(
                tool: .claudeCode,
                sessionID: sessionID,
                workingDirectory: "/tmp/project"
            ))
            XCTAssertEqual(availability.unavailableReason, "Claude Code hasn't reported a session ID yet.")
        }
    }

    func test_availability_reason_when_working_directory_is_unknown() {
        let availability = AgentForkCommandBuilder.availability(for: AgentForkSource(
            tool: .codex,
            sessionID: claudeID,
            workingDirectory: nil
        ))

        XCTAssertEqual(availability.unavailableReason, "The agent's working directory is unknown.")
    }

    func test_placeholder_session_id_counts_as_unreported() {
        installManifest(fork: AgentManifest.Resume(command: "kilo --session {sessionId} --fork"))
        let tools: [AgentTool] = [.claudeCode, .codex, .openCode, .droid, .grok, .pi, .custom("Kilo Code")]
        for tool in tools {
            let availability = AgentForkCommandBuilder.availability(for: AgentForkSource(
                tool: tool,
                sessionID: "pane-\(tool.displayName.lowercased())",
                workingDirectory: "/tmp/project"
            ))
            XCTAssertEqual(
                availability.unavailableReason,
                "\(tool.displayName) hasn't reported a session ID yet.",
                "\(tool.displayName)"
            )
        }
    }

    func test_availability_reason_when_session_id_is_invalid() {
        let availability = AgentForkCommandBuilder.availability(for: AgentForkSource(
            tool: .claudeCode,
            sessionID: "not-a-uuid",
            workingDirectory: "/tmp/project"
        ))

        XCTAssertEqual(availability.unavailableReason, "Claude Code reported a session ID that can't be forked.")
    }

    func test_pane_availability_is_nil_without_agent() {
        let pane = PaneState(id: PaneID("pane"), title: "shell")

        XCTAssertNil(AgentForkCommandBuilder.availability(pane: pane, auxiliary: nil))
        XCTAssertNil(AgentForkCommandBuilder.availability(pane: pane, auxiliary: PaneAuxiliaryState()))
    }

    func test_pane_availability_rejects_remote_panes() {
        let pane = PaneState(id: PaneID("pane"), title: "shell")
        let auxiliary = PaneAuxiliaryState(
            shellContext: PaneShellContext(scope: .remote, path: "/srv/app", home: nil, user: "deploy", host: "box"),
            agentStatus: agentStatus(tool: .claudeCode, sessionID: claudeID, workingDirectory: "/srv/app")
        )

        XCTAssertEqual(
            AgentForkCommandBuilder.availability(pane: pane, auxiliary: auxiliary)?.unavailableReason,
            AgentForkCommandBuilder.remotePaneReason
        )
    }

    func test_pane_availability_prefers_agent_working_directory_over_shell_path() {
        let pane = PaneState(
            id: PaneID("pane"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/launch")
        )
        let auxiliary = PaneAuxiliaryState(
            shellContext: PaneShellContext(scope: .local, path: "/tmp/shell", home: nil, user: nil, host: nil),
            agentStatus: agentStatus(tool: .codex, sessionID: claudeID, workingDirectory: "/tmp/agent")
        )

        XCTAssertEqual(
            AgentForkCommandBuilder.availability(pane: pane, auxiliary: auxiliary)?.plan?.workingDirectory,
            "/tmp/agent"
        )
    }

    func test_pane_availability_falls_back_to_launch_directory() {
        let pane = PaneState(
            id: PaneID("pane"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/launch")
        )
        let auxiliary = PaneAuxiliaryState(
            agentStatus: agentStatus(tool: .codex, sessionID: claudeID, workingDirectory: nil)
        )

        XCTAssertEqual(
            AgentForkCommandBuilder.availability(pane: pane, auxiliary: auxiliary)?.plan?.workingDirectory,
            "/tmp/launch"
        )
    }

    // MARK: - Title

    func test_forked_pane_title_carries_custom_title_once() {
        XCTAssertEqual(AgentForkCommandBuilder.forkedPaneTitle(sourceCustomTitle: "API work"), "API work (fork)")
        XCTAssertEqual(AgentForkCommandBuilder.forkedPaneTitle(sourceCustomTitle: "API work (fork)"), "API work (fork)")
        XCTAssertNil(AgentForkCommandBuilder.forkedPaneTitle(sourceCustomTitle: nil))
        XCTAssertNil(AgentForkCommandBuilder.forkedPaneTitle(sourceCustomTitle: "  "))
    }

    // MARK: - Helpers

    private func installManifest(fork: AgentManifest.Resume?) {
        let manifest = AgentManifest(
            schemaVersion: 1,
            id: "kilo",
            displayName: "Kilo Code",
            binaries: ["kilo"],
            family: .canonical,
            resume: AgentManifest.Resume(command: "kilo --session {sessionId}"),
            fork: fork
        )
        let registry = AgentManifestRegistry(manifests: [manifest])
        AgentManifestRegistry.provider = { registry }
    }

    private func agentStatus(tool: AgentTool, sessionID: String?, workingDirectory: String?) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: tool,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
    }
}
