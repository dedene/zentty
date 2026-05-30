import XCTest
@testable import Zentty

final class AgentIntegrationConsentTests: XCTestCase {

    // MARK: - Classification coverage

    func test_persistent_and_ephemeral_lists_cover_every_tool() {
        let grouped = Set(AgentIntegrationConsent.allTools)
        XCTAssertEqual(
            grouped,
            Set(AgentBootstrapTool.allCases),
            "allTools must cover every AgentBootstrapTool — add new agents to the persistent/ephemeral lists"
        )
        XCTAssertEqual(AgentIntegrationConsent.allTools.count, AgentBootstrapTool.allCases.count)
        XCTAssertTrue(
            Set(AgentIntegrationConsent.persistentTools)
                .isDisjoint(with: AgentIntegrationConsent.ephemeralTools),
            "a tool must not be in both groups"
        )
    }

    func test_every_persistent_tool_has_hook_handlers_and_ephemeral_has_none() {
        for tool in AgentIntegrationConsent.persistentTools {
            XCTAssertNotNil(
                AgentIntegrationHooks.handlers(for: tool),
                "\(tool) is persistent but has no install/uninstall handlers — add it to AgentIntegrationHooks.handlers, "
                    + "otherwise the grandfather migration and Settings toggle silently no-op on disk"
            )
        }
        for tool in AgentIntegrationConsent.ephemeralTools {
            XCTAssertNil(
                AgentIntegrationHooks.handlers(for: tool),
                "\(tool) is ephemeral and must not have install/uninstall handlers"
            )
        }
    }

    func test_integration_class_matches_group_membership() {
        for tool in AgentIntegrationConsent.persistentTools {
            XCTAssertEqual(tool.integrationClass, .persistent, "\(tool) should be persistent")
        }
        for tool in AgentIntegrationConsent.ephemeralTools {
            XCTAssertEqual(tool.integrationClass, .ephemeral, "\(tool) should be ephemeral")
        }
    }

    func test_default_states() {
        XCTAssertEqual(AgentBootstrapTool.grok.defaultIntegrationState, .ask)
        XCTAssertEqual(AgentBootstrapTool.agy.defaultIntegrationState, .ask)
        XCTAssertEqual(AgentBootstrapTool.amp.defaultIntegrationState, .ask)
        XCTAssertEqual(AgentBootstrapTool.claude.defaultIntegrationState, .on)
        XCTAssertEqual(AgentBootstrapTool.kimi.defaultIntegrationState, .on)
        XCTAssertEqual(AgentBootstrapTool.copilot.defaultIntegrationState, .on)
    }

    // MARK: - Effective state

    func test_effective_state_falls_back_to_class_default() {
        XCTAssertEqual(AgentIntegrationConsent.effectiveState(for: .grok, storedState: nil), .ask)
        XCTAssertEqual(AgentIntegrationConsent.effectiveState(for: .grok, storedState: .on), .on)
        XCTAssertEqual(AgentIntegrationConsent.effectiveState(for: .claude, storedState: nil), .on)
        XCTAssertEqual(AgentIntegrationConsent.effectiveState(for: .claude, storedState: .off), .off)
    }

    // MARK: - Gate matrix

    func test_gate_persistent_ask_interactive_needs_consent() {
        XCTAssertEqual(
            AgentIntegrationConsent.gate(for: .agy, storedState: nil, isRestore: false),
            .needsConsent
        )
    }

    func test_gate_persistent_ask_during_restore_is_suppressed() {
        XCTAssertEqual(
            AgentIntegrationConsent.gate(for: .agy, storedState: nil, isRestore: true),
            .suppressedByRestore
        )
    }

    func test_gate_on_proceeds_regardless_of_restore() {
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .agy, storedState: .on, isRestore: false), .proceed)
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .agy, storedState: .on, isRestore: true), .proceed)
    }

    func test_gate_off_is_off_regardless_of_restore() {
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .agy, storedState: .off, isRestore: false), .off)
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .grok, storedState: .off, isRestore: true), .off)
    }

    func test_gate_ephemeral_default_proceeds_never_needs_consent() {
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .claude, storedState: nil, isRestore: false), .proceed)
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .codex, storedState: nil, isRestore: true), .proceed)
    }

    func test_gate_ephemeral_off_is_off() {
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .claude, storedState: .off, isRestore: false), .off)
    }

    func test_gate_ephemeral_stray_ask_proceeds_defensively() {
        // An ephemeral tool persisted as `.ask` is a data anomaly; it must not
        // block on a consent panel that has nothing to install.
        XCTAssertEqual(AgentIntegrationConsent.gate(for: .claude, storedState: .ask, isRestore: false), .proceed)
    }

    // MARK: - Decision mapping

    func test_immediate_decision_mapping() {
        XCTAssertEqual(AgentIntegrationGate.proceed.immediateDecision, .proceed)
        XCTAssertEqual(AgentIntegrationGate.off.immediateDecision, .off)
        XCTAssertEqual(AgentIntegrationGate.suppressedByRestore.immediateDecision, .suppressedByRestore)
        XCTAssertNil(AgentIntegrationGate.needsConsent.immediateDecision)
    }

    func test_decision_for_consent_answer() {
        XCTAssertEqual(AgentIntegrationConsent.decision(forConsentAnswer: .on), .proceed)
        XCTAssertEqual(AgentIntegrationConsent.decision(forConsentAnswer: .off), .off)
        // `.ask` is not a valid panel answer; treat as off (no install).
        XCTAssertEqual(AgentIntegrationConsent.decision(forConsentAnswer: .ask), .off)
    }

    // MARK: - Display mapping

    func test_agent_tool_display_names() {
        XCTAssertEqual(AgentBootstrapTool.claude.integrationDisplayName, "Claude Code")
        XCTAssertEqual(AgentBootstrapTool.agy.integrationDisplayName, "Antigravity")
        XCTAssertEqual(AgentBootstrapTool.opencode.integrationDisplayName, "OpenCode")
    }

    // MARK: - integrationGate restore-pending consumption
    //
    // These assert the wiring introduced for the one-shot restore signal: the
    // gate reads the pane id from the request env and consumes it via the
    // injected closure. The gate's *output* (isRestore -> .suppressedByRestore)
    // is covered by the pure `gate(...)` matrix above; `integrationGate` itself
    // reads the real on-disk config via `loadAppConfig()`, so we assert only the
    // consume wiring here, which is config-independent.

    private func bootstrapRequest(tool: AgentBootstrapTool, paneID: String?) -> AgentIPCRequest {
        var environment: [String: String] = [:]
        if let paneID { environment["ZENTTY_PANE_ID"] = paneID }
        return AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: environment,
            expectsResponse: true,
            tool: tool
        )
    }

    func test_integration_gate_consumes_pane_id_from_env() {
        var consumed: [String] = []
        let request = bootstrapRequest(tool: .agy, paneID: "pane-1")
        _ = AgentLaunchBootstrap.integrationGate(for: request) { id in
            consumed.append(id)
            return true
        }
        XCTAssertEqual(consumed, ["pane-1"], "the gate must consume the pane id from the request env")
    }

    func test_integration_gate_without_pane_id_does_not_consume() {
        var consumed: [String] = []
        let request = bootstrapRequest(tool: .agy, paneID: nil)
        _ = AgentLaunchBootstrap.integrationGate(for: request) { id in
            consumed.append(id)
            return true
        }
        XCTAssertTrue(consumed.isEmpty, "no pane id in the env means nothing to consume")
    }

    func test_integration_gate_returns_nil_without_tool_and_does_not_consume() {
        var consumed: [String] = []
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: ["ZENTTY_PANE_ID": "pane-1"],
            expectsResponse: true,
            tool: nil
        )
        let gate = AgentLaunchBootstrap.integrationGate(for: request) { id in
            consumed.append(id)
            return true
        }
        XCTAssertNil(gate, "a request with no tool has no gate")
        XCTAssertTrue(consumed.isEmpty, "and must not consume a restore token")
    }

    // MARK: - AgentIPCServer restore-pending one-shot

    func test_server_restore_pending_is_one_shot() {
        let server = AgentIPCServer()
        XCTAssertFalse(server.consumeRestorePendingPane("p1"), "an unregistered pane is not restore-pending")
        server.registerRestorePendingPane("p1")
        XCTAssertTrue(server.consumeRestorePendingPane("p1"), "a registered pane is restore-pending once")
        XCTAssertFalse(server.consumeRestorePendingPane("p1"), "and only once — the next launch in that pane prompts")
    }

    func test_server_restore_pending_tracks_panes_independently() {
        let server = AgentIPCServer()
        server.registerRestorePendingPane("a")
        server.registerRestorePendingPane("b")
        XCTAssertTrue(server.consumeRestorePendingPane("a"))
        XCTAssertFalse(server.consumeRestorePendingPane("a"))
        XCTAssertTrue(server.consumeRestorePendingPane("b"), "consuming one pane must not affect another")
    }

    // MARK: - PaneRestorationBuilder registers (no leaky env var)

    func test_makePane_registers_restore_pending_and_omits_legacy_env_var() {
        var registered: [String] = []
        let inputs = PaneRestorationBuilder.PaneInputs(
            id: PaneID("pane-xyz"),
            titleSeed: "shell",
            lastActivityTitle: nil,
            requestedWorkingDirectory: nil,
            command: "grok",
            prefillText: nil,
            environmentOverrides: [:],
            surfaceContext: .window,
            columnWidth: 0.5,
            statusTextWhenWorkingDirectoryMissing: nil
        )

        let result = PaneRestorationBuilder.makePane(
            inputs,
            windowID: WindowID("w"),
            worklaneID: WorklaneID("wl"),
            processEnvironment: ["HOME": "/tmp"]
        ) { registered.append($0.rawValue) }

        XCTAssertEqual(registered, ["pane-xyz"], "a restore pane must be registered exactly once")
        XCTAssertNil(
            result.pane.sessionRequest.environmentVariables["ZENTTY_RESTORE_LAUNCH"],
            "the legacy persistent env var must no longer be set (it leaked into the pane's shell)"
        )
    }

    func test_makePane_doesNotRegister_forShellPaneWithoutCommand() {
        var registered: [String] = []
        _ = PaneRestorationBuilder.makePane(
            makeRestoreInputs(command: nil),
            windowID: WindowID("w"),
            worklaneID: WorklaneID("wl"),
            processEnvironment: ["HOME": "/tmp"]
        ) { registered.append($0.rawValue) }

        XCTAssertEqual(registered, [], "a restored shell pane must not pre-consume the consent token")
    }

    func test_makePane_doesNotRegister_forNonAgentCommand() {
        var registered: [String] = []
        _ = PaneRestorationBuilder.makePane(
            makeRestoreInputs(command: "vim notes.txt"),
            windowID: WindowID("w"),
            worklaneID: WorklaneID("wl"),
            processEnvironment: ["HOME": "/tmp"]
        ) { registered.append($0.rawValue) }

        XCTAssertEqual(registered, [], "a non-agent command must not register a restore token")
    }

    func test_makePane_registers_forAgentResumeCommand() {
        var registered: [String] = []
        _ = PaneRestorationBuilder.makePane(
            makeRestoreInputs(command: "claude --resume abc123"),
            windowID: WindowID("w"),
            worklaneID: WorklaneID("wl"),
            processEnvironment: ["HOME": "/tmp"]
        ) { registered.append($0.rawValue) }

        XCTAssertEqual(registered, ["pane-xyz"], "an agent resume command must register the restore token")
    }

    func test_makePane_registers_forEnvPrefixedHermesResumeCommand() {
        var registered: [String] = []
        _ = PaneRestorationBuilder.makePane(
            makeRestoreInputs(command: #"env HERMES_HOME='/tmp/hermes profile' hermes --resume hermes-session-123"#),
            windowID: WindowID("w"),
            worklaneID: WorklaneID("wl"),
            processEnvironment: ["HOME": "/tmp"]
        ) { registered.append($0.rawValue) }

        XCTAssertEqual(
            registered,
            ["pane-xyz"],
            "an env-prefixed Hermes restore command must register the restore token"
        )
    }

    private func makeRestoreInputs(command: String?) -> PaneRestorationBuilder.PaneInputs {
        PaneRestorationBuilder.PaneInputs(
            id: PaneID("pane-xyz"),
            titleSeed: "shell",
            lastActivityTitle: nil,
            requestedWorkingDirectory: nil,
            command: command,
            prefillText: nil,
            environmentOverrides: [:],
            surfaceContext: .window,
            columnWidth: 0.5,
            statusTextWhenWorkingDirectoryMissing: nil
        )
    }

    // MARK: - wrappedAgent(forCommand:)

    func test_wrappedAgent_matchesKnownBinaries_andRejectsOthers() {
        XCTAssertEqual(AgentBootstrapTool.wrappedAgent(forCommand: "grok"), .grok)
        XCTAssertEqual(AgentBootstrapTool.wrappedAgent(forCommand: "claude --resume abc"), .claude)
        XCTAssertEqual(AgentBootstrapTool.wrappedAgent(forCommand: "/usr/local/bin/agy"), .agy)
        XCTAssertEqual(
            AgentBootstrapTool.wrappedAgent(forCommand: "cursor-agent"), .cursor,
            "cursor's real binary is cursor-agent"
        )
        XCTAssertNil(AgentBootstrapTool.wrappedAgent(forCommand: "vim"))
        XCTAssertNil(AgentBootstrapTool.wrappedAgent(forCommand: ""))
    }

    func test_wrappedAgent_matchesEnvPrefixedHermesCommand() {
        XCTAssertEqual(
            AgentBootstrapTool.wrappedAgent(
                forCommand: #"env HERMES_HOME='/tmp/hermes profile' hermes --resume hermes-session-123"#
            ),
            .hermes
        )
        XCTAssertEqual(
            AgentBootstrapTool.wrappedAgent(
                forCommand: #"/usr/bin/env HERMES_HOME='/tmp/hermes profile' hermes --resume hermes-session-123"#
            ),
            .hermes
        )
        XCTAssertNil(
            AgentBootstrapTool.wrappedAgent(forCommand: "env FOO=bar vim notes.txt"),
            "env-prefixed non-agent commands must stay non-agents"
        )
    }
}
