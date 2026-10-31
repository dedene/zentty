import XCTest
@testable import Zentty

final class AgentHistoryResumeCommandBuilderTests: XCTestCase {
    private let claudeID = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"
    private let fakeHome = "/Users/test-history-home"

    private func source(
        _ agent: AgentHistoryAgent,
        id: String? = nil,
        workingDirectory: String? = "/Users/test/src/app",
        model: String? = nil,
        effort: String? = nil,
        generation: String? = nil,
        sourceRoot: String? = nil
    ) -> AgentHistoryResumeSource {
        let defaultID: String
        switch agent {
        case .claude: defaultID = claudeID
        case .codex: defaultID = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
        case .grok: defaultID = "6f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f"
        case .opencode: defaultID = "ses_abc123XYZ"
        }
        return AgentHistoryResumeSource(
            sessionRowID: 1,
            agent: agent,
            nativeSessionID: id ?? defaultID,
            title: "Session",
            workingDirectory: workingDirectory,
            repoRoot: nil,
            mainRepoRoot: nil,
            branch: nil,
            model: model,
            effort: effort,
            generation: generation,
            sourceRoot: sourceRoot
        )
    }

    private func plan(_ source: AgentHistoryResumeSource, home: String? = nil) -> AgentHistoryResumePlan? {
        guard case .available(let plan) = AgentHistoryResumeCommandBuilder.availability(
            for: source,
            homeDirectory: home ?? fakeHome
        ) else {
            return nil
        }
        return plan
    }

    private func command(_ source: AgentHistoryResumeSource, home: String? = nil) -> String? {
        plan(source, home: home)?.command
    }

    private func makeTemporaryHome() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    // MARK: - Base commands

    func test_claude_base_command_without_metadata() {
        let plan = plan(source(.claude))
        XCTAssertEqual(plan?.command, "claude --resume \(claudeID)")
        XCTAssertEqual(plan?.agent, .claude)
        XCTAssertEqual(plan?.sessionID, claudeID)
        XCTAssertEqual(plan?.environment, [:])
        XCTAssertEqual(AgentHistoryResumeCommandBuilder.command(for: source(.claude)), "claude --resume \(claudeID)")
    }

    func test_claude_adds_model_and_effort() {
        XCTAssertEqual(
            command(source(.claude, model: "claude-opus-4-1", effort: "High")),
            "claude --resume \(claudeID) --model claude-opus-4-1 --effort high"
        )
    }

    func test_claude_model_with_context_suffix_is_quoted() {
        XCTAssertEqual(
            command(source(.claude, model: "claude-opus-4[1m]", effort: "max")),
            "claude --resume \(claudeID) --model 'claude-opus-4[1m]' --effort max"
        )
    }

    func test_codex_adds_model_and_reasoning_effort_config() {
        let id = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
        XCTAssertEqual(
            command(source(.codex, model: "gpt-5.1-codex", effort: "xhigh")),
            "codex resume \(id) -m gpt-5.1-codex -c model_reasoning_effort=xhigh"
        )
        XCTAssertEqual(
            command(source(.codex, model: nil, effort: "minimal")),
            "codex resume \(id) -c model_reasoning_effort=minimal"
        )
    }

    func test_grok_adds_model_and_reasoning_effort() {
        let id = "6f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f"
        XCTAssertEqual(
            command(source(.grok, model: "grok-4-fast", effort: "medium")),
            "grok --resume \(id) -m grok-4-fast --reasoning-effort medium"
        )
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedEffort("xhigh", for: .grok))
    }

    func test_grok_invalid_id_is_unavailable_not_bare_resume() {
        let availability = AgentHistoryResumeCommandBuilder.availability(
            for: source(.grok, id: "a/b"),
            homeDirectory: fakeHome
        )
        XCTAssertEqual(availability, .unavailable(reason: "This session's ID can't be resumed safely."))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.command(for: source(.grok, id: "")))
    }

    func test_opencode_v1_adds_provider_model() {
        XCTAssertEqual(
            command(source(.opencode, model: "anthropic/claude-sonnet-4-5", effort: "high", generation: "v1")),
            "opencode --session ses_abc123XYZ --model anthropic/claude-sonnet-4-5"
        )
    }

    func test_opencode_model_without_provider_is_dropped() {
        XCTAssertEqual(
            command(source(.opencode, model: "claude-sonnet-4-5", generation: "v1")),
            "opencode --session ses_abc123XYZ"
        )
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedModel("/claude", for: .opencode))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedModel("anthropic/", for: .opencode))
    }

    func test_opencode_v2_adds_no_flags() {
        XCTAssertEqual(
            command(source(.opencode, model: "anthropic/claude-sonnet-4-5", effort: "high", generation: "v2")),
            "opencode --session ses_abc123XYZ"
        )
        XCTAssertEqual(
            command(source(.opencode, model: "anthropic/claude-sonnet-4-5", generation: nil)),
            "opencode --session ses_abc123XYZ"
        )
    }

    // MARK: - Allowlists

    func test_unknown_effort_values_are_dropped() {
        XCTAssertEqual(command(source(.claude, effort: "ultra")), "claude --resume \(claudeID)")
        XCTAssertEqual(command(source(.claude, effort: "none")), "claude --resume \(claudeID)")
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedEffort("turbo", for: .codex))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedEffort("low", for: .opencode))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedEffort("high; rm -rf /", for: .claude))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.validatedEffort(nil, for: .claude))
        XCTAssertEqual(AgentHistoryResumeCommandBuilder.validatedEffort(" None ", for: .codex), "none")
        XCTAssertEqual(AgentHistoryResumeCommandBuilder.validatedEffort("XHIGH", for: .claude), "xhigh")
    }

    func test_hostile_model_values_are_dropped() {
        let hostile = [
            "", " ", "-p", "--model", "opus; rm -rf ~", "$(whoami)", "`id`", "opus\nclaude",
            "opus && echo", "o'pus", "opus pus", String(repeating: "a", count: 129), "bypassPermissions",
            "x/--sandbox", "ünicode",
        ]
        for agent in AgentHistoryAgent.allCases {
            for value in hostile {
                XCTAssertNil(
                    AgentHistoryResumeCommandBuilder.validatedModel(value, for: agent),
                    "\(agent) accepted \(value.debugDescription)"
                )
            }
        }
        XCTAssertEqual(command(source(.claude, model: "$(whoami)")), "claude --resume \(claudeID)")
        XCTAssertEqual(AgentHistoryResumeCommandBuilder.validatedModel(" sonnet ", for: .claude), "sonnet")
    }

    func test_no_permission_or_sandbox_tokens_for_any_agent_or_metadata() {
        let models: [String?] = [
            nil, "opus", "anthropic/claude", "bypassPermissions", "--dangerously-skip-permissions",
            "-a never", "--yolo", "x/--full-auto", "approval_policy=never", "sandbox_mode=danger-full-access",
            "CODEX_HOME", "GROK_HOME", "--settings", "--profile", "--config-dir", "-p",
        ]
        let efforts: [String?] = [nil, "high", "bypass", "--yolo", "-a", "never", "danger-full-access"]
        let generations: [String?] = [nil, "v1", "v2"]
        let roots: [String?] = [nil, "/Users/test/.claude-work"]

        for agent in AgentHistoryAgent.allCases {
            for model in models {
                for effort in efforts {
                    for generation in generations {
                        for root in roots {
                            let built = source(agent, model: model, effort: effort, generation: generation, sourceRoot: root)
                            guard let command = command(built) else { continue }
                            for token in command.split(separator: " ").map(String.init) {
                                XCTAssertFalse(
                                    AgentHistoryResumeCommandBuilder.isForbiddenArgument(token),
                                    "\(agent) produced forbidden \(token) in \(command)"
                                )
                            }
                            let lowered = " \(command.lowercased()) "
                            for forbidden in AgentHistoryResumeCommandBuilder.forbiddenFlagTokens {
                                if forbidden.hasSuffix(" ") {
                                    XCTAssertFalse(lowered.contains(" \(forbidden.lowercased())"), command)
                                } else {
                                    XCTAssertFalse(lowered.contains(forbidden.lowercased()), command)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func test_forbidden_token_table_is_fixed() {
        XCTAssertEqual(AgentHistoryResumeCommandBuilder.forbiddenFlagTokens, [
            "--dangerously", "--permission-mode", "--allow-dangerously", "bypass", "--yolo", "--full-auto",
            "--sandbox", "-a ", "--ask-for-approval", "approval_policy", "sandbox_mode", "--settings",
            "--config-dir", "-p ", "--profile", "CODEX_HOME", "GROK_HOME",
        ])
    }

    // MARK: - Alternate Claude root

    func test_alternate_claude_root_prefixes_env_config_dir() {
        XCTAssertEqual(
            command(source(.claude, model: "sonnet", sourceRoot: "/Users/test/.claude-work/")),
            "env CLAUDE_CONFIG_DIR=/Users/test/.claude-work claude --resume \(claudeID) --model sonnet"
        )
        XCTAssertEqual(
            command(source(.claude, sourceRoot: "/Users/test/Claude Work")),
            "env CLAUDE_CONFIG_DIR='/Users/test/Claude Work' claude --resume \(claudeID)"
        )
        XCTAssertNil(AgentHistoryResumeCommandBuilder.claudeConfigDirectoryOverride(
            sourceRoot: "relative/.claude", homeDirectory: fakeHome
        ))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.claudeConfigDirectoryOverride(
            sourceRoot: "~/.claude-work", homeDirectory: fakeHome
        ))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.claudeConfigDirectoryOverride(
            sourceRoot: "/Users/test/.claude\nwork", homeDirectory: fakeHome
        ))
        XCTAssertNil(AgentHistoryResumeCommandBuilder.claudeConfigDirectoryOverride(
            sourceRoot: "", homeDirectory: fakeHome
        ))
    }

    func test_default_claude_root_sets_no_config_dir() throws {
        XCTAssertEqual(
            command(source(.claude, sourceRoot: "\(fakeHome)/.claude")),
            "claude --resume \(claudeID)"
        )
        XCTAssertEqual(
            command(source(.claude, sourceRoot: "\(fakeHome)/.claude/")),
            "claude --resume \(claudeID)"
        )

        let home = try makeTemporaryHome()
        let defaultRoot = (home as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: defaultRoot, withIntermediateDirectories: true)
        let link = (home as NSString).appendingPathComponent("claude-link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: defaultRoot)

        XCTAssertNil(AgentHistoryResumeCommandBuilder.claudeConfigDirectoryOverride(sourceRoot: link, homeDirectory: home))
        XCTAssertEqual(command(source(.claude, sourceRoot: link), home: home), "claude --resume \(claudeID)")
    }

    func test_config_dir_never_set_for_non_claude_agents() {
        for agent in AgentHistoryAgent.allCases where agent != .claude {
            let command = command(source(agent, sourceRoot: "/Users/test/.alt-root"))
            XCTAssertNotNil(command)
            XCTAssertFalse(command?.contains("CLAUDE_CONFIG_DIR") ?? true, "\(agent)")
            XCTAssertFalse(command?.hasPrefix("env ") ?? true, "\(agent)")
        }
    }

    // MARK: - Availability and copy text

    func test_invalid_session_id_is_unavailable_with_reason() {
        let reason = "This session's ID can't be resumed safely."
        for agent in AgentHistoryAgent.allCases {
            XCTAssertEqual(
                AgentHistoryResumeCommandBuilder.availability(for: source(agent, id: "bad id; rm"), homeDirectory: fakeHome),
                .unavailable(reason: reason),
                "\(agent)"
            )
        }
        XCTAssertEqual(
            plan(source(.claude, id: claudeID.uppercased()))?.sessionID,
            claudeID,
            "ids are normalized before building the command"
        )
    }

    func test_copyText_prefixes_cd_with_quoted_directory() throws {
        let plan = try XCTUnwrap(plan(source(.claude)))
        XCTAssertEqual(
            plan.copyText(workingDirectory: "/Users/test/My Project"),
            "cd '/Users/test/My Project' && claude --resume \(claudeID)"
        )
        XCTAssertEqual(
            plan.copyText(workingDirectory: "/Users/test/src/app"),
            "cd /Users/test/src/app && claude --resume \(claudeID)"
        )
        XCTAssertEqual(plan.copyText(workingDirectory: nil), "claude --resume \(claudeID)")
        XCTAssertEqual(plan.copyText(workingDirectory: "  "), "claude --resume \(claudeID)")
    }
}
