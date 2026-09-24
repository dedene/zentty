import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentRootMetadataTests: XCTestCase {
    private let worklaneID = WorklaneID("metadata-worklane")
    private let paneID = PaneID("metadata-pane")

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func payload(state: PaneAgentState?, sessionID: String = "root", model: String? = nil, kind: AgentSignalKind = .lifecycle) -> AgentStatusPayload {
        var payload = AgentStatusPayload(
            worklaneID: worklaneID, paneID: paneID, signalKind: kind, state: state,
            origin: .explicitHook, toolName: AgentTool.claudeCode.displayName, text: nil,
            sessionID: sessionID, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        )
        payload.carriesRootMetadata = true
        payload.agentModel = model
        return payload
    }

    func test_current_model_uses_latest_root_response_or_turn_context() {
        let claude = """
        {"type":"assistant","message":{"model":"claude-opus-5"}}
        {"type":"assistant","message":{"model":"claude-sonnet-5"}}
        {"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5"}}
        {"type":"assistant","message":{"model":"<synthetic>"}}
        """
        XCTAssertEqual(AgentRootMetadataResolver.currentModel(tool: .claudeCode, transcriptText: claude), "claude-sonnet-5")
        let codex = """
        {"type":"turn_context","payload":{"model":"gpt-6-astra"}}
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"type":"turn_context","payload":
        """
        XCTAssertEqual(AgentRootMetadataResolver.currentModel(tool: .codex, transcriptText: codex), "gpt-5.6-sol")
    }

    func test_transcript_fallback_reads_bounded_tail_not_first_model() throws {
        let path = try temporaryDirectory().appendingPathComponent("session.jsonl")
        let text = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"old\"}}\n"
            + String(repeating: " ", count: Int(AgentRootMetadataResolver.maxTranscriptBytes) + 100)
            + "\n{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6-astra\"}}\n"
        try text.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentRootMetadataResolver.currentModel(tool: .codex, transcriptPath: path.path), "gpt-6-astra")
    }

    func test_metadata_transport_and_subagent_copy_preserve_facts_without_clear() throws {
        var value = payload(state: nil, model: "claude-sonnet-5", kind: .agentMetadata)
        value.agentMetadataPID = 4321
        value.isClaudeRemoteControlActive = false
        let restored = try AgentStatusPayload(userInfo: XCTUnwrap(value.notificationUserInfo))
        XCTAssertEqual(restored, value)
        XCTAssertEqual(value.with(subagents: .empty).agentModel, value.agentModel)
        XCTAssertEqual(value.with(subagents: .empty).isClaudeRemoteControlActive, false)
        XCTAssertFalse(value.clearsStatus)
    }

    func test_claude_session_start_and_model_switch_report_root_metadata() throws {
        let directory = try temporaryDirectory()
        let sessions = ClaudeHookSessionStore(stateURL: directory.appendingPathComponent("claude.json"))
        let subagents = AgentSubagentRegistryStore(stateURL: directory.appendingPathComponent("children.json"))
        let environment = ["ZENTTY_WORKLANE_ID": worklaneID.rawValue, "ZENTTY_PANE_ID": paneID.rawValue, "ZENTTY_CLAUDE_PID": "4321", "CLAUDE_CODE_BRIDGE_SESSION_ID": "test-bridge"]
        let start = try AgentEventBridge.claudeAdapter(
            data: Data(#"{"hook_event_name":"SessionStart","session_id":"root","model":"claude-opus-5","transcript_path":"/tmp/root.jsonl"}"#.utf8),
            environment: environment, sessionStore: sessions, subagentStore: subagents
        )
        XCTAssertEqual(start.first?.agentModel, "claude-opus-5")
        XCTAssertEqual(start.first?.isClaudeRemoteControlActive, true)
        XCTAssertEqual(start.first?.agentTranscriptPath, "/tmp/root.jsonl")
        let switched = try AgentEventBridge.claudeAdapter(
            data: Data(#"{"hook_event_name":"PostModelSwitch","session_id":"root","from_model":"claude-opus-5","to_model":"claude-sonnet-5"}"#.utf8),
            environment: environment, sessionStore: sessions, subagentStore: subagents
        )
        XCTAssertEqual(switched.first?.agentModel, "claude-sonnet-5")
        XCTAssertEqual(switched.first?.signalKind, .agentMetadata)
        XCTAssertEqual(switched.first?.clearsStatus, false)
        let child = try AgentEventBridge.claudeAdapter(
            data: Data(#"{"hook_event_name":"PostModelSwitch","session_id":"root","agent_id":"child","to_model":"claude-haiku-4-5"}"#.utf8),
            environment: environment, sessionStore: sessions, subagentStore: subagents
        )
        XCTAssertTrue(child.isEmpty)
    }

    func test_codex_model_is_attached_only_to_root_hooks() throws {
        let directory = try temporaryDirectory()
        let registry = AgentSubagentRegistryStore(stateURL: directory.appendingPathComponent("children.json"))
        let environment = ["ZENTTY_WORKLANE_ID": worklaneID.rawValue, "ZENTTY_PANE_ID": paneID.rawValue, "ZENTTY_CODEX_PID": "4321"]
        let start = try AgentEventBridge.codexAdapter(
            data: Data(#"{"hook_event_name":"SessionStart","session_id":"root","model":"gpt-6-astra"}"#.utf8),
            defaultEventName: nil, environment: environment, subagentStore: registry
        )
        XCTAssertEqual(start.last?.agentModel, "gpt-6-astra")
        let child = try AgentEventBridge.codexAdapter(
            data: Data(#"{"hook_event_name":"SubagentStart","session_id":"child","agent_id":"child","model":"gpt-5.6-sol"}"#.utf8),
            defaultEventName: nil, environment: environment, subagentStore: registry
        )
        XCTAssertEqual(child.first?.carriesRootMetadata, false)
        XCTAssertNil(child.first?.agentModel)
    }

    func test_model_switch_while_idle_preserves_status_and_reducer_clocks() {
        let store = WorklaneStore()
        store.replaceWorklanes([WorklaneState(id: worklaneID, title: nil, paneStripState: PaneStripState(panes: [PaneState(id: paneID, title: "shell")], focusedPaneID: paneID))])
        store.applyAgentStatusPayload(payload(state: .running, model: "claude-opus-5"))
        store.applyAgentStatusPayload(payload(state: .idle))
        let before = store.worklanes[0].auxiliaryStateByPaneID[paneID]!
        store.applyAgentStatusPayload(payload(state: nil, model: "claude-sonnet-5", kind: .agentMetadata))
        let after = store.worklanes[0].auxiliaryStateByPaneID[paneID]!
        XCTAssertEqual(after.agentStatus, before.agentStatus)
        XCTAssertEqual(after.agentReducerState, before.agentReducerState)
        XCTAssertEqual(after.presentation.agentModel, "claude-sonnet-5")
        XCTAssertEqual(after.presentation.runtimePhase, .idle)
    }

    func test_new_session_does_not_inherit_model_and_late_switch_cannot_revive_cleared_root() {
        var raw = PaneRawState()
        raw.observeAgentMetadata(payload(state: .starting, model: "claude-opus-5"))
        raw.observeAgentMetadata(payload(state: .running, sessionID: "child", model: "claude-haiku-4-5"))
        XCTAssertEqual(raw.agentMetadata?.model, "claude-opus-5")
        raw.observeAgentMetadata(payload(state: .starting, sessionID: "new-root"))
        XCTAssertNil(raw.agentMetadata?.model)
        raw.observeAgentMetadata(payload(state: nil, sessionID: "new-root"))
        raw.observeAgentMetadata(payload(state: nil, sessionID: "new-root", model: "claude-sonnet-5", kind: .agentMetadata))
        XCTAssertNil(raw.agentMetadata)
    }

    func test_explicit_unknown_model_clears_old_selection_and_resolves_only_new_response_while_idle() throws {
        let path = try temporaryDirectory().appendingPathComponent("root.jsonl")
        let oldResponse = #"{"type":"assistant","message":{"model":"claude-opus-5"}}"# + "\n"
        let newResponse = #"{"type":"assistant","message":{"model":"claude-sonnet-5"}}"# + "\n"
        for unknown in ["default", "auto", "inherit"] {
            try oldResponse.write(to: path, atomically: true, encoding: .utf8)
            let store = WorklaneStore()
            store.replaceWorklanes([WorklaneState(id: worklaneID, title: nil, paneStripState: PaneStripState(panes: [PaneState(id: paneID, title: "shell")], focusedPaneID: paneID))])
            var start = payload(state: .running, model: "claude-opus-5")
            start.agentTranscriptPath = path.path
            store.applyAgentStatusPayload(start)
            store.applyAgentStatusPayload(payload(state: .idle))
            let before = store.worklanes[0].auxiliaryStateByPaneID[paneID]!
            XCTAssertEqual(before.presentation.agentModel, "claude-opus-5", "omitted model preserves known selection")

            store.applyAgentStatusPayload(payload(state: nil, model: unknown, kind: .agentMetadata))
            store.clearStaleAgentSessions()
            let unknownState = store.worklanes[0].auxiliaryStateByPaneID[paneID]!
            XCTAssertNil(unknownState.presentation.agentModel, "\(unknown) must not reuse the prior transcript response")
            XCTAssertEqual(unknownState.raw.agentMetadata?.modelWasReportedByHook, false)
            XCTAssertEqual(unknownState.agentStatus, before.agentStatus)
            XCTAssertEqual(unknownState.agentReducerState, before.agentReducerState)

            try (oldResponse + newResponse).write(to: path, atomically: true, encoding: .utf8)
            store.clearStaleAgentSessions()
            let resolved = store.worklanes[0].auxiliaryStateByPaneID[paneID]!
            XCTAssertEqual(resolved.presentation.agentModel, "claude-sonnet-5")
            XCTAssertEqual(resolved.presentation.runtimePhase, .idle)
            XCTAssertEqual(resolved.agentStatus, before.agentStatus)
            XCTAssertEqual(resolved.agentReducerState, before.agentReducerState)
        }
    }

    func test_remote_control_refresh_requires_matching_live_record_and_detects_disconnect() throws {
        let home = try temporaryDirectory()
        let path = AgentRootMetadataResolver.claudeSessionPath(pid: 4321, homeDirectory: home.path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeRecord(_ text: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        var metadata = PaneAgentMetadata(tool: .claudeCode, sessionID: "root", pid: 4321)
        try writeRecord(#"{"pid":4321,"sessionId":"other","bridgeSessionId":"test"}"#)
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in true }, homeDirectory: home.path))
        XCTAssertFalse(metadata.isClaudeRemoteControlActive)
        try writeRecord(#"{"pid":4321,"sessionId":"root","bridgeSessionId":"test"}"#)
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in true }, homeDirectory: home.path))
        XCTAssertTrue(metadata.isClaudeRemoteControlActive)
        let cached = metadata
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in true }, homeDirectory: home.path))
        XCTAssertEqual(metadata, cached)
        try writeRecord(#"{"pid":4321,"sessionId":"root"}"#)
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in true }, homeDirectory: home.path))
        XCTAssertFalse(metadata.isClaudeRemoteControlActive)
        XCTAssertFalse(metadata.refresh(isProcessAlive: { _ in false }, homeDirectory: home.path))
        try writeRecord(String(repeating: "x", count: Int(AgentRootMetadataResolver.maxSessionBytes) + 1))
        XCTAssertFalse(AgentRootMetadataResolver.claudeRemoteControlActive(path: path, pid: 4321, sessionID: "root"))
    }

    func test_explicit_model_survives_older_transcript_and_compaction() throws {
        let path = try temporaryDirectory().appendingPathComponent("root.jsonl")
        try #"{"type":"assistant","message":{"model":"claude-opus-5"}}"#.write(to: path, atomically: true, encoding: .utf8)
        var raw = PaneRawState()
        var start = payload(state: .starting, model: "claude-sonnet-5")
        start.agentTranscriptPath = path.path
        raw.observeAgentMetadata(start)
        XCTAssertTrue(raw.agentMetadata!.refresh(isProcessAlive: { _ in true }))
        XCTAssertEqual(raw.agentMetadata?.model, "claude-sonnet-5")
        raw.observeAgentMetadata(payload(state: .starting))
        XCTAssertEqual(raw.agentMetadata?.model, "claude-sonnet-5")
    }

    func test_remote_shell_keeps_hook_metadata_without_probing_local_pid_or_files() {
        var metadata = PaneAgentMetadata(tool: .claudeCode, sessionID: "remote-root", pid: 4321, model: "claude-opus-5", isClaudeRemoteControlActive: true)
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in XCTFail("Remote PID must not be probed locally"); return false }, localRuntimeFilesAvailable: false))
        XCTAssertTrue(metadata.isClaudeRemoteControlActive)
        XCTAssertEqual(metadata.model, "claude-opus-5")
    }

    func test_codex_new_turn_updates_model_but_old_resume_history_cannot_override_selection() throws {
        let path = try temporaryDirectory().appendingPathComponent("root.jsonl")
        let oldTurn = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"# + "\n"
        try oldTurn.write(to: path, atomically: true, encoding: .utf8)
        var metadata = PaneAgentMetadata(tool: .codex, sessionID: "root", pid: nil, model: "gpt-6-astra", transcriptPath: path.path)
        metadata.modelWasReportedByHook = true
        metadata.transcriptModelOffset = UInt64(oldTurn.utf8.count)
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in true }))
        XCTAssertEqual(metadata.model, "gpt-6-astra")
        try (oldTurn + #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"# + "\n").write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(metadata.refresh(isProcessAlive: { _ in true }))
        XCTAssertEqual(metadata.model, "gpt-5.6-sol")
    }
}

final class PaneForegroundAgentProbeTests: XCTestCase {
    private func process(_ parent: Int32, _ group: Int32, _ foreground: Int32, _ name: String) -> PaneForegroundProcessInfo {
        PaneForegroundProcessInfo(parentPID: parent, processGroupID: group, foregroundProcessGroupID: foreground, terminalDevice: 1, name: name)
    }

    func test_node_wrapper_is_owned_but_nested_and_background_agents_are_not() throws {
        let processes: [Int32: PaneForegroundProcessInfo] = [
            10: process(1, 10, 20, "zsh"),
            20: process(10, 20, 20, "node"),
            21: process(20, 20, 20, "codex"),
            30: process(21, 20, 20, "claude"),
            31: process(21, 20, 20, "codex"),
            40: process(10, 40, 20, "claude"),
        ]
        var reads: [Int32: Int] = [:]
        let probe = PaneForegroundAgentProbe(treePIDs: { _ in Array(processes.keys) }, processInfo: { pid in
            reads[pid, default: 0] += 1
            return processes[pid]
        })
        let owner = try XCTUnwrap(probe.scan(rootPID: 10)?.agent)
        XCTAssertEqual(owner.tool, .codex)
        XCTAssertEqual(owner.pid, 21)
        XCTAssertEqual(owner.launchPIDs, [20, 21])
        XCTAssertTrue(owner.owns(tool: .codex, pid: 20))
        XCTAssertFalse(owner.owns(tool: .codex, pid: 31))
        _ = probe.scan(rootPID: 10)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 })
    }

    func test_claude_owns_its_nested_codex_helper() {
        let processes: [Int32: PaneForegroundProcessInfo] = [
            10: process(1, 10, 20, "zsh"),
            20: process(10, 20, 20, "claude"),
            21: process(20, 20, 20, "node"),
            22: process(21, 20, 20, "codex"),
        ]
        let probe = PaneForegroundAgentProbe(treePIDs: { _ in Array(processes.keys) }, processInfo: { processes[$0] })
        XCTAssertEqual(probe.scan(rootPID: 10)?.agent?.tool, .claudeCode)
        XCTAssertEqual(probe.scan(rootPID: 10)?.agent?.launchPIDs, [20])
    }

    func test_native_claude_versioned_executable_is_recognized_without_changing_process_name() {
        var native = process(10, 20, 20, "2.1.278")
        native.executablePath = "/Users/test/.local/share/claude/versions/2.1.278"
        XCTAssertEqual(native.recognizedAgentTool, .claudeCode)
        XCTAssertEqual(native.name, "2.1.278")
        for path in [
            "/Users/test/.local/share/other/versions/2.1.278",
            "/Users/test/projects/claude/versions/2.1.278",
            "/Users/test/.local/share/claude/versions/2.1.999",
            "/tmp/2.1.278",
        ] {
            native.executablePath = path
            XCTAssertNil(native.recognizedAgentTool, path)
        }
        native.executablePath = nil
        XCTAssertNil(native.recognizedAgentTool)
    }

    func test_versioned_native_claude_owns_its_nested_codex_helper() {
        var native = process(10, 20, 20, "2.1.278")
        native.executablePath = "/Users/test/.local/share/claude/versions/2.1.278"
        let processes: [Int32: PaneForegroundProcessInfo] = [
            10: process(1, 10, 20, "zsh"),
            20: native,
            21: process(20, 20, 20, "node"),
            22: process(21, 20, 20, "codex"),
        ]
        let probe = PaneForegroundAgentProbe(treePIDs: { _ in Array(processes.keys) }, processInfo: { processes[$0] })
        XCTAssertEqual(probe.scan(rootPID: 10)?.agent?.tool, .claudeCode)
        XCTAssertEqual(probe.scan(rootPID: 10)?.agent?.pid, 20)
        XCTAssertEqual(probe.scan(rootPID: 10)?.agent?.launchPIDs, [20])
    }

    func test_unreadable_versioned_executable_does_not_promote_nested_helper() {
        let processes: [Int32: PaneForegroundProcessInfo] = [
            10: process(1, 10, 20, "zsh"),
            20: process(10, 20, 20, "2.1.278"),
            21: process(20, 20, 20, "codex"),
        ]
        let probe = PaneForegroundAgentProbe(treePIDs: { _ in Array(processes.keys) }, processInfo: { processes[$0] })
        XCTAssertNil(probe.scan(rootPID: 10), "Without the versioned executable path, the parent may be Claude")
    }

    func test_shell_foreground_does_not_select_background_agent() throws {
        let processes: [Int32: PaneForegroundProcessInfo] = [
            10: process(1, 10, 10, "zsh"),
            20: process(10, 20, 10, "codex"),
        ]
        let probe = PaneForegroundAgentProbe(treePIDs: { _ in Array(processes.keys) }, processInfo: { processes[$0] })
        XCTAssertNil(try XCTUnwrap(probe.scan(rootPID: 10)).agent)
        XCTAssertNil(probe.scan(rootPID: 99), "Unreadable process state must remain unknown")
    }

    func test_unreadable_foreground_child_is_unknown_not_an_empty_job() {
        let root = process(1, 10, 20, "zsh")
        let probe = PaneForegroundAgentProbe(
            treePIDs: { _ in [10, 20] },
            processInfo: { $0 == 10 ? root : nil }
        )
        XCTAssertNil(probe.scan(rootPID: 10))
    }

    func test_missing_parent_cannot_promote_a_readable_helper_to_owner() {
        let processes: [Int32: PaneForegroundProcessInfo] = [
            10: process(1, 10, 20, "zsh"),
            30: process(20, 20, 20, "codex"),
        ]
        for listed: [Int32] in [[10, 20, 30], [10, 30]] {
            let probe = PaneForegroundAgentProbe(treePIDs: { _ in listed }, processInfo: { processes[$0] })
            XCTAssertNil(probe.scan(rootPID: 10), "the unreadable or missing parent may own this helper")
        }
    }
}

@MainActor
final class PaneAgentOwnershipTests: XCTestCase {
    private let worklaneID = WorklaneID("owner-worklane")
    private let paneID = PaneID("owner-pane")

    private func snapshot(_ tool: AgentTool, pid: Int32, launchPIDs: Set<Int32>? = nil) -> PaneForegroundAgentSnapshot {
        let launchPIDs = launchPIDs ?? [pid]
        return PaneForegroundAgentSnapshot(agent: PaneForegroundAgent(tool: tool, pid: pid, launchPIDs: launchPIDs), foregroundPIDs: launchPIDs)
    }

    private func makeStore(resolver: @escaping (Int32) -> PaneForegroundAgentSnapshot?) -> WorklaneStore {
        let store = WorklaneStore(foregroundAgentResolver: resolver)
        store.replaceWorklanes([WorklaneState(
            id: worklaneID, title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: paneID, title: "Project — Current task")], focusedPaneID: paneID),
            auxiliaryStateByPaneID: [paneID: PaneAuxiliaryState(paneRootPID: 10)]
        )])
        return store
    }

    private func payload(_ tool: AgentTool, session: String, pid: Int32, state: PaneAgentState, model: String? = nil, subagents: PaneAgentSubagentSummary? = nil) -> AgentStatusPayload {
        var payload = AgentStatusPayload(
            worklaneID: worklaneID, paneID: paneID, state: state, origin: .explicitHook,
            toolName: tool.displayName, text: nil, confidence: .explicit, sessionID: session,
            subagents: subagents, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        )
        payload.carriesRootMetadata = true
        payload.agentMetadataPID = pid
        payload.agentModel = model
        return payload
    }

    private func state(_ store: WorklaneStore) -> PaneAuxiliaryState {
        store.worklanes[0].auxiliaryStateByPaneID[paneID]!
    }

    private func sweep(_ store: WorklaneStore, snapshot: PaneForegroundAgentSnapshot?) {
        store.clearStaleAgentSessions(sweepContext: AgentSessionSweepContext(
            processAliveResolver: { _ in true }, workingDirectoryResolver: { _ in nil },
            foregroundAgentResolver: { _ in snapshot }
        ))
    }

    func test_exiting_and_launching_other_agent_replaces_status_model_and_subagents_in_both_directions() {
        for (oldTool, newTool) in [(AgentTool.claudeCode, AgentTool.codex), (.codex, .claudeCode)] {
            for oldState in [PaneAgentState.running, .needsInput, .idle, .unresolvedStop] {
                var foreground = snapshot(oldTool, pid: 20)
                let store = makeStore { _ in foreground }
                store.applyAgentStatusPayload(payload(oldTool, session: "old", pid: 20, state: .running, model: "old-model", subagents: .init(entries: [.init(id: "old-child")])))
                store.applyAgentStatusPayload(payload(oldTool, session: "old", pid: 20, state: oldState))
                store.updateMetadata(paneID: paneID, metadata: TerminalMetadata(title: oldTool.displayName))
                foreground = snapshot(newTool, pid: 30)

                store.applyAgentStatusPayload(payload(newTool, session: "new", pid: 30, state: .starting, model: "new-model"))

                XCTAssertEqual(state(store).presentation.recognizedTool, newTool, "\(oldTool) \(oldState)")
                XCTAssertEqual(state(store).agentStatus?.sessionID, "new")
                XCTAssertEqual(state(store).presentation.agentModel, "new-model")
                XCTAssertNil(state(store).presentation.subagents)
                XCTAssertFalse(state(store).raw.showsReadyStatus)
                XCTAssertEqual(Set(state(store).agentReducerState.sessionsByID.keys), ["new"])
                store.applyAgentStatusPayload(payload(newTool, session: "new", pid: 30, state: .running))
                store.applyAgentStatusPayload(payload(newTool, session: "new", pid: 30, state: .idle))
                XCTAssertEqual(state(store).agentStatus?.sessionID, "new", "Old unresolved stop must not return after completion")
            }
        }
    }

    func test_payload_burst_reuses_one_foreground_scan_but_a_tool_switch_still_lands() {
        // The clock never advances, so the TTL never expires. Any correctness here
        // comes from the forced re-scan, not from the cache quietly refreshing.
        let frozen = Date(timeIntervalSince1970: 1_000)
        var scans = 0
        var foreground = snapshot(.claudeCode, pid: 20)
        let store = WorklaneStore(
            currentDateProvider: { frozen },
            foregroundAgentResolver: { _ in scans += 1; return foreground }
        )
        store.replaceWorklanes([WorklaneState(
            id: worklaneID, title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: paneID, title: "Project — Current task")], focusedPaneID: paneID),
            auxiliaryStateByPaneID: [paneID: PaneAuxiliaryState(paneRootPID: 10)]
        )])

        for _ in 0 ..< 8 {
            store.applyAgentStatusPayload(payload(.claudeCode, session: "s", pid: 20, state: .running))
        }
        XCTAssertEqual(scans, 1, "a burst of accepted payloads must not rewalk the process tree")

        // Codex replaces Claude. The cached probe still says Claude owns the pane,
        // so without the forced re-scan this payload would be dropped silently.
        foreground = snapshot(.codex, pid: 30)
        store.applyAgentStatusPayload(payload(.codex, session: "next", pid: 30, state: .starting))

        XCTAssertEqual(scans, 2, "a rejected payload must trigger exactly one fresh scan")
        XCTAssertEqual(state(store).presentation.recognizedTool, .codex, "the new agent must not be discarded")
        XCTAssertEqual(state(store).agentStatus?.sessionID, "next")
    }

    func test_foreground_scan_repeats_once_the_cache_window_has_passed() {
        var now = Date(timeIntervalSince1970: 1_000)
        var scans = 0
        let foreground = snapshot(.claudeCode, pid: 20)
        let store = WorklaneStore(
            currentDateProvider: { now },
            foregroundAgentResolver: { _ in scans += 1; return foreground },
            foregroundAgentContextTTL: 1
        )
        store.replaceWorklanes([WorklaneState(
            id: worklaneID, title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: paneID, title: "Project — Current task")], focusedPaneID: paneID),
            auxiliaryStateByPaneID: [paneID: PaneAuxiliaryState(paneRootPID: 10)]
        )])

        store.applyAgentStatusPayload(payload(.claudeCode, session: "s", pid: 20, state: .running))
        XCTAssertEqual(scans, 1)

        now = now.addingTimeInterval(2)
        store.applyAgentStatusPayload(payload(.claudeCode, session: "s", pid: 20, state: .running))
        XCTAssertEqual(scans, 2, "the cache must expire so ownership cannot go stale indefinitely")
    }

    func test_unhooked_replacement_uses_foreground_agent_despite_stale_title() {
        for (oldTool, newTool) in [(AgentTool.claudeCode, AgentTool.codex), (.codex, .claudeCode)] {
            let old = snapshot(oldTool, pid: 20)
            let store = makeStore { _ in old }
            store.applyAgentStatusPayload(payload(oldTool, session: "old", pid: 20, state: .running, model: "old-model", subagents: .init(entries: [.init(id: "old-child")])))
            store.updateMetadata(paneID: paneID, metadata: TerminalMetadata(title: oldTool.displayName))

            sweep(store, snapshot: snapshot(newTool, pid: 30))

            XCTAssertEqual(state(store).presentation.recognizedTool, newTool)
            XCTAssertNil(state(store).agentStatus)
            XCTAssertNil(state(store).presentation.agentModel)
            XCTAssertNil(state(store).presentation.subagents)
            XCTAssertFalse(state(store).raw.showsReadyStatus)
        }
    }

    func test_node_wrapper_hooks_keep_model_across_sweeps_and_nested_helpers_cannot_replace_it() {
        let owner = snapshot(.codex, pid: 21, launchPIDs: [20, 21])
        let store = makeStore { _ in owner }
        store.applyAgentStatusPayload(payload(.codex, session: "root", pid: 20, state: .running, model: "gpt-root"))
        let before = state(store)
        sweep(store, snapshot: owner)
        XCTAssertEqual(state(store).raw.agentMetadata, before.raw.agentMetadata)
        for tool in [AgentTool.codex, .claudeCode] {
            store.applyAgentStatusPayload(payload(tool, session: "helper", pid: 30, state: .starting, model: "helper-model"))
            store.applyAgentStatusPayload(payload(tool, session: "helper", pid: 30, state: .running))
            XCTAssertEqual(state(store).agentStatus?.sessionID, "root")
            XCTAssertEqual(state(store).presentation.recognizedTool, .codex)
            XCTAssertEqual(state(store).presentation.agentModel, "gpt-root")
        }
    }

    func test_claude_pid_attach_replaces_codex_before_first_prompt() {
        var foreground = snapshot(.codex, pid: 20)
        let store = makeStore { _ in foreground }
        store.applyAgentStatusPayload(payload(.codex, session: "old", pid: 20, state: .needsInput, model: "old-model"))
        foreground = snapshot(.claudeCode, pid: 30)
        var start = AgentStatusPayload(
            worklaneID: worklaneID, paneID: paneID, signalKind: .pid, state: nil,
            pid: 30, pidEvent: .attach, origin: .explicitHook, toolName: "Claude Code", text: nil,
            sessionID: "new", artifactKind: nil, artifactLabel: nil, artifactURL: nil
        )
        start.carriesRootMetadata = true
        start.agentMetadataPID = 30
        start.agentModel = "new-model"
        store.applyAgentStatusPayload(start)
        XCTAssertEqual(state(store).presentation.recognizedTool, .claudeCode)
        XCTAssertEqual(state(store).agentStatus?.sessionID, "new")
        XCTAssertEqual(state(store).presentation.agentModel, "new-model")
    }

    func test_native_child_approval_still_surfaces_without_replacing_root_identity() {
        let owner = snapshot(.claudeCode, pid: 20)
        let store = makeStore { _ in owner }
        store.applyAgentStatusPayload(payload(.claudeCode, session: "root", pid: 20, state: .running, model: "root-model"))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID, paneID: paneID, state: .needsInput, origin: .explicitHook,
            toolName: "Claude Code", text: "Allow write?", interactionKind: .approval, confidence: .explicit,
            sessionID: "child", parentSessionID: "root", artifactKind: nil, artifactLabel: nil, artifactURL: nil
        ))
        XCTAssertEqual(state(store).agentStatus?.sessionID, "child")
        XCTAssertEqual(state(store).presentation.runtimePhase, .needsInput)
        XCTAssertEqual(state(store).presentation.agentModel, "root-model")
    }

    func test_return_to_shell_clears_old_identity_even_when_title_does_not_change() {
        let old = snapshot(.claudeCode, pid: 20)
        let store = makeStore { _ in old }
        store.applyAgentStatusPayload(payload(.claudeCode, session: "old", pid: 20, state: .running, model: "old-model"))
        store.updateMetadata(paneID: paneID, metadata: TerminalMetadata(title: "Claude Code"))
        sweep(store, snapshot: PaneForegroundAgentSnapshot(agent: nil, foregroundPIDs: [10]))
        XCTAssertNil(state(store).presentation.recognizedTool)
        XCTAssertNil(state(store).agentStatus)
        XCTAssertNil(state(store).presentation.agentModel)
    }

    func test_failed_foreground_inspection_preserves_current_owner_and_metadata() {
        let owner = snapshot(.claudeCode, pid: 20)
        let store = makeStore { _ in owner }
        store.applyAgentStatusPayload(payload(.claudeCode, session: "root", pid: 20, state: .running, model: "root-model"))
        let before = state(store)
        sweep(store, snapshot: nil)
        XCTAssertEqual(state(store).raw.foregroundAgentSnapshot, before.raw.foregroundAgentSnapshot)
        XCTAssertEqual(state(store).raw.agentMetadata, before.raw.agentMetadata)
        XCTAssertEqual(state(store).agentStatus, before.agentStatus)
    }

    func test_remote_shell_does_not_use_local_foreground_processes() {
        let store = makeStore { _ in XCTFail("Remote PID must not be inspected locally"); return nil }
        var worklane = store.worklanes[0]
        worklane.auxiliaryStateByPaneID[paneID]?.raw.shellContext = PaneShellContext(scope: .remote, path: "/project", home: nil, user: nil, host: "server")
        store.replaceWorklanes([worklane])
        store.applyAgentStatusPayload(payload(.codex, session: "remote", pid: 20, state: .running, model: "remote-model"))
        store.clearStaleAgentSessions()
        XCTAssertEqual(state(store).presentation.recognizedTool, .codex)
        XCTAssertEqual(state(store).presentation.agentModel, "remote-model")
    }

    func test_entering_remote_shell_releases_previous_local_owner_before_remote_hooks() {
        let local = snapshot(.claudeCode, pid: 20)
        var isRemote = false
        let store = makeStore { _ in
            XCTAssertFalse(isRemote, "The remote shell must not be inspected locally")
            return local
        }
        store.applyAgentStatusPayload(payload(.claudeCode, session: "local", pid: 20, state: .running, model: "local-model"))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID, paneID: paneID, signalKind: .paneContext, state: nil,
            paneContext: PaneShellContext(scope: .remote, path: "/project", home: nil, user: nil, host: "server"),
            toolName: nil, text: nil, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        ))
        isRemote = true
        store.applyAgentStatusPayload(payload(.codex, session: "remote", pid: 30, state: .starting, model: "remote-model"))
        XCTAssertNil(state(store).raw.foregroundAgentSnapshot)
        XCTAssertEqual(state(store).presentation.recognizedTool, .codex)
        XCTAssertEqual(state(store).presentation.agentModel, "remote-model")
        XCTAssertEqual(state(store).agentStatus?.sessionID, "remote")
    }

    func test_sweep_caches_foreground_lookup_for_each_root_including_failures() {
        var calls: [Int32: Int] = [:]
        let context = AgentSessionSweepContext(foregroundAgentResolver: { pid in
            calls[pid, default: 0] += 1
            return pid == 10 ? self.snapshot(.codex, pid: 20) : nil
        })
        for _ in 0..<2 {
            _ = context.foregroundAgent(rootPID: 10)
            _ = context.foregroundAgent(rootPID: 99)
        }
        XCTAssertEqual(calls, [10: 1, 99: 1])
    }
}

final class AgentSubagentTrackingTests: XCTestCase {
    private let environment: [String: String] = [
        "ZENTTY_WORKLANE_ID": "worklane-main",
        "ZENTTY_PANE_ID": "worklane-main-shell",
    ]

    private let paneKey = AgentSubagentRegistryStore.Key(
        tool: "claude",
        worklaneID: WorklaneID("worklane-main"),
        paneID: PaneID("worklane-main-shell")
    )

    // MARK: - Model labels

    func test_model_label_shortens_known_families() {
        XCTAssertEqual(AgentModelLabel.short(from: "claude-opus-5"), "opus")
        XCTAssertEqual(AgentModelLabel.short(from: "claude-sonnet-5"), "sonnet")
        XCTAssertEqual(AgentModelLabel.short(from: "claude-fable-5-1"), "fable")
        XCTAssertEqual(AgentModelLabel.short(from: "claude-haiku-4-5-20251001"), "haiku")
        XCTAssertEqual(AgentModelLabel.short(from: "opus"), "opus")
        XCTAssertEqual(AgentModelLabel.short(from: "sonnet[1m]"), "sonnet")
        XCTAssertEqual(AgentModelLabel.short(from: "us.anthropic.claude-opus-5-v1:0"), "opus")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-6-astra"), "astra")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.6-sol"), "sol")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.6-terra"), "terra")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.6-luna"), "luna")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.3-codex-spark"), "codex-spark")
        XCTAssertEqual(AgentModelLabel.short(from: "codex-auto-review"), "auto-review")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(AgentModelLabel.short(from: "gpt-5.4-mini"), "gpt-5.4-mini")
        XCTAssertNil(AgentModelLabel.short(from: "   "))
    }

    // MARK: - Summary

    func test_summary_groups_by_model_and_type_most_numerous_first() {
        let summary = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "a", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "b", agentType: "general-purpose", model: "claude-opus-5"),
            PaneAgentSubagentEntry(id: "c", agentType: "codex-review", model: "claude-sonnet-5"),
            PaneAgentSubagentEntry(id: "d", agentType: "worker", model: "gpt-6-astra", nickname: "Dirac"),
        ])

        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.badgeText, "4")
        XCTAssertEqual(summary.tooltipText, "4 subagents\nClick for details")
        let groups = summary.groups
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups[0].modelText, "opus")
        XCTAssertEqual(groups[0].trailingText, "general-purpose")
        XCTAssertEqual(groups[1].modelText, "astra")
        XCTAssertEqual(groups[1].trailingText, "worker · Dirac")
        XCTAssertEqual(groups[2].modelText, "sonnet")
        XCTAssertEqual(groups[2].leadingText, "1 ×")
    }

    func test_summary_without_model_shows_placeholder() {
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", agentType: "Explore")])
        XCTAssertEqual(summary.tooltipText, "1 subagent\nClick for details")
        XCTAssertEqual(summary.groups.first?.modelText, "model?")
    }

    func test_payload_user_info_round_trips_subagents_including_explicit_empty() throws {
        let summary = PaneAgentSubagentSummary(entries: [
            PaneAgentSubagentEntry(id: "agent-1", agentType: "Explore", model: "claude-sonnet-5", transcriptPath: "/tmp/agent-1.jsonl"),
        ])
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane"),
            state: .running,
            toolName: "Claude Code",
            text: nil,
            subagents: summary,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        let decoded = try AgentStatusPayload(userInfo: XCTUnwrap(payload.notificationUserInfo))
        XCTAssertEqual(decoded.subagents, summary)

        let cleared = payload.with(subagents: .empty)
        let decodedCleared = try AgentStatusPayload(userInfo: XCTUnwrap(cleared.notificationUserInfo))
        XCTAssertEqual(decodedCleared.subagents, .empty)

        let untouched = payload.with(subagents: nil)
        let decodedUntouched = try AgentStatusPayload(userInfo: XCTUnwrap(untouched.notificationUserInfo))
        XCTAssertNil(decodedUntouched.subagents)
    }

    // MARK: - Registry store

    func test_registry_tracks_start_stop_and_clear() throws {
        let store = try makeRegistryStore()

        let afterFirst = try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", agentType: "Explore"))
        XCTAssertEqual(afterFirst.count, 1)
        let afterSecond = try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", agentType: "Plan", model: "claude-opus-5"))
        XCTAssertEqual(afterSecond.count, 2)

        let afterStop = try store.stop(key: paneKey, subagentID: "a")
        XCTAssertEqual(afterStop.entries.map(\.id), ["b"])

        let afterUnknownStop = try store.stop(key: paneKey, subagentID: "zzz")
        XCTAssertEqual(afterUnknownStop.count, 1, "stopping an unknown id must not retire a live subagent")

        let afterAnonymousStop = try store.stop(key: paneKey, subagentID: nil)
        XCTAssertEqual(afterAnonymousStop.count, 0, "a stop without id retires the oldest subagent")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "c"))
        XCTAssertEqual(try store.clear(key: paneKey), .empty)
        XCTAssertEqual(try store.summary(key: paneKey), .empty)

        try store.remove(key: paneKey)
        XCTAssertNil(try store.summary(key: paneKey))
    }

    func test_registry_merges_repeated_start_and_refreshes_missing_models() throws {
        let store = try makeRegistryStore()
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", agentType: "Explore", transcriptPath: "/tmp/a.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", model: "claude-sonnet-5"))
        let merged = try XCTUnwrap(try store.summary(key: paneKey)?.entries.first)
        XCTAssertEqual(merged.agentType, "Explore")
        XCTAssertEqual(merged.model, "claude-sonnet-5")
        XCTAssertEqual(merged.transcriptPath, "/tmp/a.jsonl")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", agentType: "Plan"))
        var resolvedIDs: [String] = []
        let refreshed = try store.refreshMissingModels(key: paneKey) { entry in
            resolvedIDs.append(entry.id)
            return entry.with(model: "claude-opus-5")
        }
        XCTAssertEqual(resolvedIDs, ["b"], "only entries without a model are resolved")
        XCTAssertEqual(refreshed?.entries.first(where: { $0.id == "b" })?.model, "claude-opus-5")
    }

    func test_registry_prunes_stale_entries_and_remembers_root_session() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = try makeRegistryStore(now: { now })
        try store.recordRootSession(key: paneKey, sessionID: "root-1")
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "old"))
        now = now.addingTimeInterval(AgentSubagentRegistryStore.staleEntryWindow + 1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "fresh"))

        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["fresh"])
        XCTAssertEqual(try store.rootSessionID(key: paneKey), "root-1")
    }

    func test_registry_tracked_stop_ignores_unknown_and_consumes_pruned_worker_once() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let lastWrite = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in lastWrite })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "worker", transcriptPath: "/t/worker.jsonl"))
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "internal-recap"))
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["worker"])

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertEqual(try store.summary(key: paneKey), .empty)
        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: "worker"), .empty)
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "worker"))
    }

    func test_registry_tracked_stop_accepts_fresh_completed_transcript() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var lastWrite = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in lastWrite })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "worker", transcriptPath: "/t/worker.jsonl"))
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        lastWrite = now

        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: "worker"), .empty)
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "worker"))
    }

    func test_registry_anonymous_tracked_stop_requires_a_live_worker() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let store = try makeRegistryStore(now: { now })
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: nil))
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: "  \n"))

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "first"))
        now = now.addingTimeInterval(1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "second"))
        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: nil)?.entries.map(\.id), ["second"])
        XCTAssertEqual(try store.stopIfTracked(key: paneKey, subagentID: " "), .empty)
        XCTAssertNil(try store.stopIfTracked(key: paneKey, subagentID: nil), "a duplicate anonymous stop must not resume a completed parent")
    }

    func test_registry_retires_entries_whose_transcript_went_quiet() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var modifiedAt: [String: Date] = [:]
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "busy", transcriptPath: "/t/busy.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "quiet", transcriptPath: "/t/quiet.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "no-transcript"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "not-yet-written", transcriptPath: "/t/missing.jsonl"))
        modifiedAt["/t/busy.jsonl"] = now
        modifiedAt["/t/quiet.jsonl"] = now

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        modifiedAt["/t/busy.jsonl"] = now
        XCTAssertEqual(
            try store.summary(key: paneKey)?.entries.map(\.id),
            ["busy", "no-transcript", "not-yet-written"],
            "only an existing transcript that stopped being written retires its entry"
        )

        now = now.addingTimeInterval(AgentSubagentRegistryStore.staleEntryWindow)
        modifiedAt["/t/busy.jsonl"] = now
        XCTAssertEqual(
            try store.summary(key: paneKey)?.entries.map(\.id),
            ["busy"],
            "entries without a readable transcript still fall back to the stale window"
        )
    }

    func test_registry_quiet_transcript_retires_claude_but_not_codex() throws {
        // Codex's parent turn outlives its sub-threads and `clear` retires the
        // set; a sub-thread parked between turns keeps a quiet rollout file,
        // so only the stale window applies there.
        var now = Date(timeIntervalSince1970: 10_000)
        let quietSince = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in quietSince })
        let codexKey = AgentSubagentRegistryStore.Key(tool: "codex", worklaneID: paneKey.worklaneID, paneID: paneKey.paneID)
        XCTAssertTrue(paneKey.transcriptIsLivenessSignal)
        XCTAssertFalse(codexKey.transcriptIsLivenessSignal)

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "claude-child", transcriptPath: "/t/claude.jsonl"))
        try store.start(key: codexKey, entry: PaneAgentSubagentEntry(id: "codex-child", transcriptPath: "/t/rollout.jsonl"))

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertEqual(try store.summary(key: paneKey), .empty, "a quiet Claude transcript retires the entry")
        XCTAssertEqual(try store.summary(key: codexKey)?.entries.map(\.id), ["codex-child"], "a quiet Codex rollout is not a finish signal")

        now = now.addingTimeInterval(AgentSubagentRegistryStore.staleEntryWindow)
        XCTAssertEqual(try store.summary(key: codexKey), .empty, "Codex entries still age out on the stale window")
    }

    func test_registry_fresh_re_registration_survives_stale_transcript_until_quiet_window() throws {
        // A child re-registered by its own hook is alive even when its
        // transcript has not been touched for a while (a long tool call); the
        // quiet window restarts from the re-registration, not the file mtime.
        var now = Date(timeIntervalSince1970: 10_000)
        let modifiedAt = now.addingTimeInterval(-(AgentSubagentRegistryStore.transcriptQuietWindow + 100))
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in modifiedAt })

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "abc", transcriptPath: "/t/abc.jsonl"))
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["abc"], "startedAt is newer than the quiet cutoff")

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow - 1)
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["abc"])

        now = now.addingTimeInterval(2)
        let pruned = try XCTUnwrap(try store.prunedSummary(key: paneKey))
        XCTAssertEqual(pruned.summary, .empty, "once the registration itself is older than the window the quiet transcript wins")
        XCTAssertTrue(pruned.retired)
    }

    func test_registry_keeps_explicit_transcript_path_over_later_update() throws {
        let store = try makeRegistryStore()
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", transcriptPath: "/explicit/agent-a.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a", agentType: "Explore", transcriptPath: "/derived/subagents/agent-a.jsonl"))
        let merged = try XCTUnwrap(try store.summary(key: paneKey)?.entries.first)
        XCTAssertEqual(merged.transcriptPath, "/explicit/agent-a.jsonl", "the first recorded path wins over a later derived one")
        XCTAssertEqual(merged.agentType, "Explore", "other facts still merge in")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", transcriptPath: "/late/agent-b.jsonl"))
        XCTAssertEqual(
            try store.summary(key: paneKey)?.entries.first(where: { $0.id == "b" })?.transcriptPath,
            "/late/agent-b.jsonl",
            "a path arriving after a pathless start is still adopted"
        )
    }

    func test_registry_stop_with_guessed_id_falls_back_to_oldest() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = try makeRegistryStore(now: { now })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "first"))
        now = now.addingTimeInterval(1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "second"))

        let explicitMiss = try store.stop(key: paneKey, subagentID: "unknown")
        XCTAssertEqual(explicitMiss.count, 2, "an explicit id that misses is a no-op")

        let guessedMiss = try store.stop(key: paneKey, subagentID: "unknown", retireOldestWhenUnknown: true)
        XCTAssertEqual(guessedMiss.entries.map(\.id), ["second"], "a guessed id that misses retires the oldest")

        let guessedHit = try store.stop(key: paneKey, subagentID: "second", retireOldestWhenUnknown: true)
        XCTAssertEqual(guessedHit, .empty, "a guessed id that matches retires exactly that entry")
    }

    func test_registry_guessed_stop_for_pruned_id_does_not_retire_a_sibling() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var modifiedAt: [String: Date] = [:]
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "gone", transcriptPath: "/t/gone.jsonl"))
        modifiedAt["/t/gone.jsonl"] = now
        now = now.addingTimeInterval(1)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "busy", transcriptPath: "/t/busy.jsonl"))

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        modifiedAt["/t/busy.jsonl"] = now
        XCTAssertEqual(try store.summary(key: paneKey)?.entries.map(\.id), ["busy"], "quiet transcript retired `gone`")

        let lateStop = try store.stop(key: paneKey, subagentID: "gone", retireOldestWhenUnknown: true)
        XCTAssertEqual(lateStop.entries.map(\.id), ["busy"], "a late stop for a pruned child must not take a sibling")

        let unknownStop = try store.stop(key: paneKey, subagentID: "never-seen", retireOldestWhenUnknown: true)
        XCTAssertEqual(unknownStop, .empty, "an id that was never pruned still falls back to the oldest")

        // A pruned child re-registering forgets its tombstone.
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "gone", transcriptPath: "/t/gone.jsonl"))
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "other"))
        XCTAssertEqual(try store.stop(key: paneKey, subagentID: "gone", retireOldestWhenUnknown: true).entries.map(\.id), ["other"])
    }

    func test_registry_pruned_id_memory_is_bounded_and_cleared() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let quietSince = now
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in quietSince })
        let overflow = AgentSubagentRegistryStore.prunedIDMemory + 1
        for index in 0..<overflow {
            try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "old-\(index)", transcriptPath: "/t/\(index).jsonl"))
        }
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertEqual(try store.summary(key: paneKey), .empty)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "live"))

        // Exactly one of the pruned ids fell out of memory; the rest are tombstones.
        var retiredLive = 0
        for index in 0..<overflow {
            if try store.stop(key: paneKey, subagentID: "old-\(index)", retireOldestWhenUnknown: true).isEmpty {
                retiredLive += 1
                try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "live"))
            }
        }
        XCTAssertEqual(retiredLive, 1)

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "fresh", transcriptPath: "/t/fresh.jsonl"))
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        _ = try store.summary(key: paneKey)
        _ = try store.clear(key: paneKey)
        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "live"))
        XCTAssertEqual(try store.stop(key: paneKey, subagentID: "fresh", retireOldestWhenUnknown: true), .empty, "clear drops the tombstones too")
    }

    func test_attach_subagents_leaves_long_standing_empty_registry_untouched() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        var modifiedAt: [String: Date] = [:]
        let store = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })
        let target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) = (nil, paneKey.worklaneID, paneKey.paneID)
        let running = [AgentEventBridge.lifecyclePayload(target: target, toolName: "Claude Code", state: .running)]

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "a"))
        try store.stop(key: paneKey, subagentID: "a")
        let untouched = try AgentEventBridge.attachSubagents(to: running, key: paneKey, subagentStore: store) { _ in nil }
        XCTAssertNil(untouched.first?.subagents, "an empty set that is not news stays off the payload")

        try store.start(key: paneKey, entry: PaneAgentSubagentEntry(id: "b", transcriptPath: "/t/b.jsonl"))
        modifiedAt["/t/b.jsonl"] = now
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        let retired = try AgentEventBridge.attachSubagents(to: running, key: paneKey, subagentStore: store) { _ in nil }
        XCTAssertEqual(retired.first?.subagents, .empty, "a set that just emptied travels explicitly")

        let again = try AgentEventBridge.attachSubagents(to: running, key: paneKey, subagentStore: store) { _ in nil }
        XCTAssertNil(again.first?.subagents, "the next read is a long-standing empty again")
    }

    func test_default_store_resolves_away_from_application_support_under_xctest() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.standardizedFileURL.path
        let appSupport = try XCTUnwrap(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Zentty", isDirectory: true).standardizedFileURL.path

        let underTests = AgentSubagentRegistryStore(environment: ["XCTestConfigurationFilePath": "/x/config.xctestconfiguration"])
        XCTAssertTrue(underTests.stateURL.standardizedFileURL.path.hasPrefix(temporary), "\(underTests.stateURL.path)")
        XCTAssertTrue(underTests.stateURL.path.contains("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertTrue(fileManager.fileExists(atPath: underTests.stateURL.deletingLastPathComponent().path), "per-process directory is created")

        let inApp = AgentSubagentRegistryStore(environment: [:])
        XCTAssertEqual(inApp.stateURL.standardizedFileURL.path, appSupport + "/agent-subagent-sessions.json")

        let overridden = AgentSubagentRegistryStore(environment: [
            "XCTestConfigurationFilePath": "/x/config.xctestconfiguration",
            "ZENTTY_SUBAGENT_STATE_PATH": "/custom/registry.json",
        ])
        XCTAssertEqual(overridden.stateURL.path, "/custom/registry.json", "the explicit override still wins")

        // The real test process must be routed too, not just a stubbed one.
        XCTAssertTrue(AgentSubagentRegistryStore().stateURL.standardizedFileURL.path.hasPrefix(temporary))
    }

    // MARK: - Model resolver

    func test_claude_model_resolver_prefers_meta_sidecar_then_transcript() throws {
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        XCTAssertNil(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath))

        try """
        {"parentUuid":null,"isSidechain":true,"agentId":"abc","type":"user","message":{"role":"user","content":"hi"}}
        {"parentUuid":"x","isSidechain":true,"agentId":"abc","type":"assistant","message":{"model":"claude-opus-5","role":"assistant","content":[]}}
        """.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath), "claude-opus-5")

        try """
        {"agentType":"general-purpose","description":"x","toolUseId":"toolu_1","spawnDepth":1,"model":"sonnet"}
        """.write(toFile: AgentSubagentModelResolver.claudeMetaPath(agentTranscriptPath: transcriptPath), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath), "sonnet")

        // A fork inherits the parent's model; the sidecar says `inherit`, so
        // the transcript's real model wins.
        try """
        {"agentType":"fork","description":"x","toolUseId":"toolu_2","spawnDepth":2,"model":"inherit"}
        """.write(toFile: AgentSubagentModelResolver.claudeMetaPath(agentTranscriptPath: transcriptPath), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSubagentModelResolver.claudeModel(agentTranscriptPath: transcriptPath), "claude-opus-5")
    }

    func test_claude_agent_transcript_path_derives_from_session_transcript() {
        XCTAssertEqual(
            AgentSubagentModelResolver.claudeAgentTranscriptPath(
                sessionTranscriptPath: "/Users/x/.claude/projects/p/session-1.jsonl",
                agentID: "a034fe"
            ),
            "/Users/x/.claude/projects/p/session-1/subagents/agent-a034fe.jsonl"
        )
        XCTAssertNil(AgentSubagentModelResolver.claudeAgentTranscriptPath(sessionTranscriptPath: nil, agentID: "a"))
    }

    func test_codex_thread_info_reads_nickname_role_and_model_from_rollout_head() {
        let rollout = """
        {"timestamp":"t","type":"session_meta","payload":{"id":"01a07132","parent_thread_id":"01a07119","source":{"subagent":{"thread_spawn":{"parent_thread_id":"01a07119","depth":1,"agent_path":"/root/unread_ui","agent_nickname":"Dirac","agent_role":"worker"}}},"thread_source":"subagent"}}
        {"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[]}}
        {"timestamp":"t","type":"turn_context","payload":{"turn_id":"1","cwd":"/tmp","model":"gpt-6-astra","effort":"medium"}}
        """
        let info = AgentSubagentModelResolver.codexThreadInfo(rolloutText: rollout)
        XCTAssertEqual(info, .init(model: "gpt-6-astra", nickname: "Dirac", role: "worker"))

        let guardian = """
        {"timestamp":"t","type":"session_meta","payload":{"id":"x","parent_thread_id":"y","source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review"}}
        {"timestamp":"t","type":"turn_context","payload":{"model":"codex-auto-review"}}
        """
        XCTAssertEqual(AgentSubagentModelResolver.codexThreadInfo(rolloutText: guardian), .init(model: "codex-auto-review", nickname: nil, role: nil))
        XCTAssertNil(AgentSubagentModelResolver.codexThreadInfo(rolloutText: "not json"))
    }

    // MARK: - Claude adapter

    func test_claude_subagent_start_and_stop_update_payload_subagents() throws {
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        try #"{"agentType":"general-purpose","model":"opus"}"#
            .write(toFile: AgentSubagentModelResolver.claudeMetaPath(agentTranscriptPath: transcriptPath), atomically: true, encoding: .utf8)
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()

        let started = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"abc","agent_type":"general-purpose","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let startPayload = try XCTUnwrap(started.first)
        XCTAssertEqual(startPayload.state, .running)
        XCTAssertEqual(startPayload.sessionID, "session-1")
        XCTAssertEqual(startPayload.subagents?.count, 1)
        XCTAssertEqual(startPayload.subagents?.entries.first?.model, "opus")
        XCTAssertEqual(startPayload.subagents?.entries.first?.agentType, "general-purpose")

        let stopped = try claudePayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"abc","agent_type":"general-purpose"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stopPayload = try XCTUnwrap(stopped.first)
        XCTAssertEqual(stopPayload.state, .running, "parent keeps working after a subagent finishes")
        XCTAssertEqual(stopPayload.subagents, .empty)
    }

    func test_claude_hooks_inside_subagent_fill_in_model_from_transcript() throws {
        // Live Claude 2.1.261 payloads: SubagentStart carries the session
        // transcript_path and agent_id but no agent_transcript_path, so the
        // subagent transcript is derived as <session>/subagents/agent-<id>.jsonl.
        let directory = try makeTemporaryDirectory()
        let sessionTranscriptPath = directory.appendingPathComponent("session-1.jsonl").path
        let subagentsDirectory = directory.appendingPathComponent("session-1/subagents")
        try FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        let transcriptPath = subagentsDirectory.appendingPathComponent("agent-abc.jsonl").path
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()

        let started = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","transcript_path":"\#(sessionTranscriptPath)","agent_id":"abc","agent_type":"Explore"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(started.first?.subagents?.entries.first?.model, "transcript does not exist yet at spawn")
        XCTAssertEqual(started.first?.subagents?.entries.first?.transcriptPath, transcriptPath)

        try #"{"type":"assistant","message":{"model":"claude-sonnet-5","role":"assistant"}}"#
            .write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        let toolUse = try claudePayloads(
            #"{"hook_event_name":"PreToolUse","session_id":"session-1","tool_name":"Read","agent_id":"abc","agent_type":"Explore"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let payload = try XCTUnwrap(toolUse.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.subagents?.entries.first?.model, "claude-sonnet-5")
        XCTAssertEqual(payload.subagents?.entries.first?.modelLabel, "sonnet")
    }

    func test_claude_stop_keeps_async_subagents_alive() throws {
        // Claude Code launches Agent tool calls asynchronously: the parent ends
        // its turn (Stop) while the subagents keep running and re-wakes on a
        // task notification. Stop must therefore carry the live set, not blank it.
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        for id in ["a1", "a2", "a3"] {
            _ = try claudePayloads(
                #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"\#(id)","agent_type":"general-purpose"}"#,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }

        let stopped = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stopPayload = try XCTUnwrap(stopped.first)
        XCTAssertEqual(stopPayload.state, .idle)
        XCTAssertEqual(stopPayload.subagents?.count, 3, "parent going idle must not blank running subagents")

        let idlePrompt = try claudePayloads(
            #"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"session-1","message":"Claude is waiting for your input"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(idlePrompt.first?.subagents?.count, 3, "idle prompt must not blank running subagents")

        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"a2","agent_type":"general-purpose"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stoppedAgain = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stoppedAgain.first?.subagents?.entries.map(\.id), ["a1", "a3"])

        for id in ["a1", "a3"] {
            _ = try claudePayloads(
                #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"\#(id)"}"#,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }
        let finalStop = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(finalStop.first?.subagents, .empty, "explicit empty once every subagent stopped")
    }

    func test_claude_stop_without_recorded_subagents_leaves_payload_untouched() throws {
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        let stopped = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(stopped.first?.subagents)
    }

    func test_claude_nested_fork_tracks_distinct_ids() throws {
        // A subagent spawning its own forks fires SubagentStart/Stop with the
        // child's agent_id from inside the enclosing subagent.
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"outer","agent_type":"general-purpose"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let nestedStart = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"inner","agent_type":"fork"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(nestedStart.first?.subagents?.entries.map(\.id), ["inner", "outer"])

        let nestedStop = try claudePayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"session-1","agent_id":"inner","agent_type":"fork"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(nestedStop.first?.subagents?.entries.map(\.id), ["outer"])
    }

    func test_claude_hook_inside_subagent_re_registers_a_retired_child() throws {
        // Liveness pruning can retire a child that sat in a long tool call. Its
        // next hook (which carries agent_id) puts it back.
        let sessionStore = try makeClaudeSessionStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        try "{}".write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        var transcriptModifiedAt = now
        let subagentStore = try makeRegistryStore(
            now: { now },
            transcriptModificationDate: { _ in transcriptModifiedAt }
        )

        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"abc","agent_type":"Explore","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        let parentHook = try claudePayloads(
            #"{"hook_event_name":"PreToolUse","session_id":"session-1","tool_name":"Bash"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(parentHook.first?.subagents, .empty, "retirement must reach the reducer as an explicit empty set")
        XCTAssertEqual(try subagentStore.summary(key: paneKey), .empty, "quiet transcript retires the entry")

        transcriptModifiedAt = now
        let toolUse = try claudePayloads(
            #"{"hook_event_name":"PostToolUse","session_id":"session-1","tool_name":"Bash","agent_id":"abc","agent_type":"Explore","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(toolUse.first?.subagents?.entries.map(\.id), ["abc"])
        XCTAssertEqual(toolUse.first?.subagents?.entries.first?.agentType, "Explore")
    }

    func test_claude_unrelated_hook_leaves_subagents_untouched_when_none_recorded() throws {
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        let payloads = try claudePayloads(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(payloads.first?.subagents)
    }

    // MARK: - Codex adapter

    func test_codex_subagent_start_attributes_to_root_session_and_reads_rollout() throws {
        let directory = try makeTemporaryDirectory()
        let rolloutPath = directory.appendingPathComponent("rollout-2026-09-05T12-52-37-01a07132-eb9a-7222-ad53-819ccda4db3c.jsonl").path
        try """
        {"type":"session_meta","payload":{"id":"01a07132-eb9a-7222-ad53-819ccda4db3c","parent_thread_id":"root","source":{"subagent":{"thread_spawn":{"agent_nickname":"Noether","agent_role":"default"}}}}}
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        """.write(toFile: rolloutPath, atomically: true, encoding: .utf8)
        let subagentStore = try makeRegistryStore()

        _ = try codexPayloads(#"{"hook_event_name":"SessionStart","session_id":"root"}"#, subagentStore: subagentStore)
        // Codex sends the thread id on start but the rollout path only on stop;
        // both must resolve to the same registry entry.
        let started = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"child-thread","agent_id":"01a07132-eb9a-7222-ad53-819ccda4db3c","agent_type":"worker","model":"gpt-5.6-sol"}"#,
            subagentStore: subagentStore
        )
        let payload = try XCTUnwrap(started.first)
        XCTAssertEqual(payload.sessionID, "root")
        XCTAssertEqual(payload.state, .running)
        let entry = try XCTUnwrap(payload.subagents?.entries.first)
        XCTAssertEqual(entry.id, "01a07132-eb9a-7222-ad53-819ccda4db3c")
        XCTAssertEqual(entry.model, "gpt-5.6-sol", "payload model is used until the rollout exists")
        XCTAssertNil(entry.nickname)

        let toolHook = try codexPayloads(
            #"{"hook_event_name":"PostToolUse","session_id":"root","agent_id":"01a07132-eb9a-7222-ad53-819ccda4db3c"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(toolHook.first?.subagents?.entries.first?.model, "gpt-5.6-sol")

        let stoppedWithPath = try codexPayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"child-thread","agent_id":"01a07132-eb9a-7222-ad53-819ccda4db3c","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stoppedWithPath.first?.subagents, .empty)

        let restarted = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"child-thread","agent_type":"worker","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        let entryFromRollout = try XCTUnwrap(restarted.first?.subagents?.entries.first)
        XCTAssertEqual(entryFromRollout.id, "01a07132-eb9a-7222-ad53-819ccda4db3c")
        XCTAssertEqual(entryFromRollout.model, "gpt-5.6-sol")
        XCTAssertEqual(entryFromRollout.nickname, "Noether")
        XCTAssertEqual(entryFromRollout.agentType, "worker")

        let childStop = try codexPayloads(#"{"hook_event_name":"Stop","session_id":"child-thread"}"#, subagentStore: subagentStore)
        XCTAssertNil(childStop.first?.subagents, "a sub-thread Stop must not blank the parent's badge")

        let stopped = try codexPayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"child-thread","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.subagents, .empty)

        let rootStop = try codexPayloads(#"{"hook_event_name":"Stop","session_id":"root"}"#, subagentStore: subagentStore)
        XCTAssertEqual(rootStop.first?.subagents, .empty)
    }

    func test_codex_positional_subagent_events_map_like_named_hooks() throws {
        let subagentStore = try makeRegistryStore()
        let payloads = try AgentEventBridge.codexAdapter(
            data: Data(#"{"session_id":"root","agent_type":"worker"}"#.utf8),
            defaultEventName: "subagent-start",
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(payloads.first?.subagents?.count, 1)
    }

    func test_codex_tool_hook_resolves_model_once_rollout_exists() throws {
        let directory = try makeTemporaryDirectory()
        let rolloutPath = directory.appendingPathComponent("rollout-x.jsonl").path
        let subagentStore = try makeRegistryStore()
        _ = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"root","agent_transcript_path":"\#(rolloutPath)"}"#,
            subagentStore: subagentStore
        )
        try #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#.write(toFile: rolloutPath, atomically: true, encoding: .utf8)
        let payloads = try codexPayloads(#"{"hook_event_name":"PostToolUse","session_id":"root"}"#, subagentStore: subagentStore)
        XCTAssertEqual(payloads.first?.subagents?.entries.first?.modelLabel, "astra")
    }

    func test_codex_quiet_rollout_keeps_subagent_until_stop() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let quietSince = now
        let subagentStore = try makeRegistryStore(now: { now }, transcriptModificationDate: { _ in quietSince })
        _ = try codexPayloads(#"{"hook_event_name":"SessionStart","session_id":"root"}"#, subagentStore: subagentStore)
        _ = try codexPayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"child","agent_id":"thread-1","agent_transcript_path":"/t/rollout-thread-1.jsonl"}"#,
            subagentStore: subagentStore
        )

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        let toolHook = try codexPayloads(#"{"hook_event_name":"PostToolUse","session_id":"root"}"#, subagentStore: subagentStore)
        XCTAssertEqual(toolHook.first?.subagents?.entries.map(\.id), ["thread-1"], "a quiet rollout does not retire a Codex sub-thread")

        let stopped = try codexPayloads(
            #"{"hook_event_name":"SubagentStop","session_id":"child","agent_id":"thread-1"}"#,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.subagents, .empty)
    }

    // MARK: - Grok adapter

    func test_grok_subagent_hooks_track_count() throws {
        let subagentStore = try makeRegistryStore()
        let started = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"sub-1","agent_type":"explore"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(started.first?.state, .running)
        XCTAssertEqual(started.first?.subagents?.entries.first?.agentType, "explore")

        let stopped = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"sub-1"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.subagents, .empty)
    }

    func test_grok_stop_keeps_background_subagents_and_derives_child_transcript() throws {
        // spawn_subagent runs in the background by default: the parent's
        // `stop` fires while the child is still working.
        let subagentStore = try makeRegistryStore()
        let started = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-1","subagentType":"explore","transcriptPath":"/Users/me/.grok/sessions/cwd/parent/updates.jsonl"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(
            started.first?.subagents?.entries.first?.transcriptPath,
            "/Users/me/.grok/sessions/cwd/child-1/updates.jsonl"
        )

        let stopped = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"Stop","sessionId":"parent"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stopped.first?.state, .idle)
        XCTAssertEqual(stopped.first?.subagents?.entries.map(\.id), ["child-1"])

        _ = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"SubagentStop","sessionId":"child-1","subagentId":"child-1"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        let stoppedAgain = try AgentEventBridge.grokAdapter(
            data: Data(#"{"hook_event_name":"Stop","sessionId":"parent"}"#.utf8),
            environment: environment,
            subagentStore: subagentStore
        )
        XCTAssertEqual(stoppedAgain.first?.subagents, .empty)
        XCTAssertNil(AgentEventBridge.grokSubagentTranscriptPath(parentTranscriptPath: nil, subagentID: "x"))
        XCTAssertNil(AgentEventBridge.grokSubagentTranscriptPath(parentTranscriptPath: "/updates.jsonl", subagentID: "x"))
    }

    func test_grok_subagent_stop_by_session_id_falls_back_to_oldest_child() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let subagentStore = try makeRegistryStore(now: { now })
        func grok(_ json: String) throws -> [AgentStatusPayload] {
            try AgentEventBridge.grokAdapter(data: Data(json.utf8), environment: environment, subagentStore: subagentStore)
        }
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-1"}"#)
        now = now.addingTimeInterval(1)
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-2"}"#)

        // The stop hook runs in the child's context: its session id is the child.
        let byChildSession = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"child-2"}"#)
        XCTAssertEqual(byChildSession.first?.subagents?.entries.map(\.id), ["child-1"])

        now = now.addingTimeInterval(1)
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"child-3"}"#)

        // A session id that matches nothing was only a guess: retire the oldest.
        let byUnknownSession = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"parent"}"#)
        XCTAssertEqual(byUnknownSession.first?.subagents?.entries.map(\.id), ["child-3"])

        // An explicit subagent id that misses stays a no-op.
        let byUnknownExplicit = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"parent","subagentId":"never-started"}"#)
        XCTAssertEqual(byUnknownExplicit.first?.subagents?.entries.map(\.id), ["child-3"])
    }

    func test_grok_late_stop_from_pruned_child_leaves_siblings_alone() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var modifiedAt: [String: Date] = [:]
        let subagentStore = try makeRegistryStore(now: { now }, transcriptModificationDate: { modifiedAt[$0] })
        func grok(_ json: String) throws -> [AgentStatusPayload] {
            try AgentEventBridge.grokAdapter(data: Data(json.utf8), environment: environment, subagentStore: subagentStore)
        }
        let parentTranscript = "/Users/me/.grok/sessions/cwd/parent/updates.jsonl"
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"A","transcriptPath":"\#(parentTranscript)"}"#)
        modifiedAt["/Users/me/.grok/sessions/cwd/A/updates.jsonl"] = now
        now = now.addingTimeInterval(1)
        _ = try grok(#"{"hook_event_name":"SubagentStart","sessionId":"parent","subagentId":"B","transcriptPath":"\#(parentTranscript)"}"#)

        now = now.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        modifiedAt["/Users/me/.grok/sessions/cwd/B/updates.jsonl"] = now
        let pruned = try grok(#"{"hook_event_name":"Stop","sessionId":"parent"}"#)
        XCTAssertEqual(pruned.first?.subagents?.entries.map(\.id), ["B"], "A's quiet transcript retired it")

        // A's stop hook arrives late, carrying only its session id.
        let lateStop = try grok(#"{"hook_event_name":"SubagentStop","sessionId":"A"}"#)
        XCTAssertEqual(lateStop.first?.subagents?.entries.map(\.id), ["B"], "a late stop for a pruned child must not retire B")
        XCTAssertEqual(lateStop.first?.subagents?.count, 1)
    }

    func test_grok_hooks_installer_registers_subagent_events_without_matcher() {
        XCTAssertTrue(GrokHooksInstaller.defaultManagedEvents.contains("SubagentStart"))
        XCTAssertTrue(GrokHooksInstaller.defaultManagedEvents.contains("SubagentStop"))
    }

    // MARK: - Reducer

    func test_reducer_carries_subagents_until_explicitly_cleared() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])

        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        reducerState.apply(claudePayload(state: .running, subagents: nil), now: startedAt.addingTimeInterval(1))
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(1))?.subagents, summary)

        reducerState.apply(claudePayload(state: .idle, subagents: .empty), now: startedAt.addingTimeInterval(2))
        XCTAssertEqual(reducerState.reducedStatus(now: startedAt.addingTimeInterval(2))?.subagents, .empty)
    }

    func test_reducer_keeps_idle_session_visible_while_subagents_run() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])

        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: startedAt.addingTimeInterval(1))

        let afterIdleWindow = startedAt.addingTimeInterval(1 + PaneAgentReducerState.idleVisibilityWindow + 1)
        reducerState.sweep(now: afterIdleWindow, isProcessAlive: { _ in true })
        let status = reducerState.reducedStatus(now: afterIdleWindow)
        XCTAssertEqual(status?.state, .idle, "idle parent stays visible while background subagents run")
        XCTAssertEqual(status?.subagents, summary)

        reducerState.apply(claudePayload(state: .idle, subagents: .empty), now: afterIdleWindow)
        let afterSecondWindow = afterIdleWindow.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow + 1)
        reducerState.sweep(now: afterSecondWindow, isProcessAlive: { _ in true })
        XCTAssertNil(reducerState.reducedStatus(now: afterSecondWindow), "normal idle expiry resumes once the subagents retire")
    }

    func test_reducer_subagent_snapshot_expires_without_fresh_hooks() {
        // Registry pruning only runs when a hook arrives, not on a timer. If
        // none fire (the children died, the pane was left alone), the reducer's
        // snapshot must not pin the idle parent forever: it ages out on the
        // registry's own quiet window.
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])
        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        let idleAt = startedAt.addingTimeInterval(1)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: idleAt)

        let insideWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow - 1)
        reducerState.sweep(now: insideWindow, isProcessAlive: { _ in true })
        XCTAssertEqual(reducerState.reducedStatus(now: insideWindow)?.subagents, summary, "still live inside the quiet window")

        let pastWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        // Shell activity bumps `updatedAt` but is not a hook: it must not
        // re-arm the badge.
        reducerState.apply(shellPayload(.promptIdle), now: pastWindow)
        XCTAssertNil(reducerState.reducedStatus(now: pastWindow), "an unrefreshed snapshot no longer counts as live")
        reducerState.sweep(now: pastWindow, isProcessAlive: { _ in true })
        XCTAssertTrue(reducerState.sessionsByID.isEmpty, "sweep retires the idle parent once the snapshot expired")
    }

    func test_reducer_subagent_snapshot_clock_is_the_last_hook_not_the_last_signal() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])
        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        let idleAt = startedAt.addingTimeInterval(1)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: idleAt)

        // Shell signals keep arriving right up to the window's edge...
        let lastShell = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow - 1)
        reducerState.apply(shellPayload(.promptIdle), now: lastShell)
        XCTAssertEqual(reducerState.reducedStatus(now: lastShell)?.subagents, summary)

        // ...and still do not stretch the badge past it.
        let pastWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        XCTAssertNil(reducerState.reducedStatus(now: pastWindow), "only a payload carrying subagents refreshes the cap")

        // A hook carrying the set does.
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: pastWindow)
        XCTAssertEqual(reducerState.reducedStatus(now: pastWindow.addingTimeInterval(1))?.subagents, summary)
    }

    func test_reducer_subagent_snapshot_expires_with_tracked_pid_alive() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducerState = PaneAgentReducerState()
        let summary = PaneAgentSubagentSummary(entries: [PaneAgentSubagentEntry(id: "a", model: "claude-opus-5")])
        reducerState.apply(claudePayload(state: .running, subagents: summary), now: startedAt)
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-shell"),
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitAPI,
                toolName: "Claude Code",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(0.5)
        )
        let idleAt = startedAt.addingTimeInterval(1)
        reducerState.apply(claudePayload(state: .idle, subagents: summary), now: idleAt)

        let afterIdleWindow = idleAt.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow + 1)
        reducerState.sweep(now: afterIdleWindow, isProcessAlive: { _ in true })
        let visible = reducerState.reducedStatus(now: afterIdleWindow)
        XCTAssertEqual(visible?.state, .idle)
        XCTAssertEqual(visible?.trackedPID, 4242)
        XCTAssertEqual(visible?.subagents, summary)

        let pastWindow = idleAt.addingTimeInterval(AgentSubagentRegistryStore.transcriptQuietWindow + 1)
        reducerState.apply(shellPayload(.promptIdle), now: pastWindow)
        reducerState.sweep(now: pastWindow, isProcessAlive: { _ in true })
        XCTAssertNil(reducerState.reducedStatus(now: pastWindow), "the badge cannot keep an idle pane visible past the quiet window")
        XCTAssertEqual(reducerState.sessionsByID.count, 1, "the live process keeps the session itself around")
    }

    // MARK: - Helpers

    private func claudePayload(state: PaneAgentState, subagents: PaneAgentSubagentSummary?) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-shell"),
            state: state,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            confidence: .explicit,
            sessionID: "session-1",
            subagents: subagents,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func shellPayload(_ shellActivityState: PaneShellActivityState) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-shell"),
            signalKind: .shellState,
            state: nil,
            shellActivityState: shellActivityState,
            origin: .shell,
            toolName: "Claude Code",
            text: nil,
            sessionID: "session-1",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func claudePayloads(
        _ json: String,
        sessionStore: ClaudeHookSessionStore,
        subagentStore: AgentSubagentRegistryStore
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.claudeMakePayloads(
            from: AgentEventBridge.claudeParseInput(Data(json.utf8)),
            environment: environment,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
    }

    private func codexPayloads(_ json: String, subagentStore: AgentSubagentRegistryStore) throws -> [AgentStatusPayload] {
        try AgentEventBridge.codexAdapter(
            data: Data(json.utf8),
            defaultEventName: nil,
            environment: environment,
            subagentStore: subagentStore
        )
    }

    private func makeClaudeSessionStore() throws -> ClaudeHookSessionStore {
        let store = ClaudeHookSessionStore(stateURL: try makeTemporaryDirectory().appendingPathComponent("claude-hook-sessions.json"))
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )
        return store
    }

    private func makeRegistryStore(
        now: @escaping () -> Date = Date.init,
        transcriptModificationDate: ((String) -> Date?)? = nil
    ) throws -> AgentSubagentRegistryStore {
        let stateURL = try makeTemporaryDirectory().appendingPathComponent("agent-subagent-sessions.json")
        if let transcriptModificationDate {
            return AgentSubagentRegistryStore(stateURL: stateURL, now: now, transcriptModificationDate: transcriptModificationDate)
        }
        // Tests that do not care about liveness treat every transcript as alive.
        return AgentSubagentRegistryStore(stateURL: stateURL, now: now, transcriptModificationDate: { _ in nil })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-subagent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
