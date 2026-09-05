import Foundation
import XCTest
@testable import Zentty

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
        let directory = try makeTemporaryDirectory()
        let transcriptPath = directory.appendingPathComponent("agent-abc.jsonl").path
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()

        let started = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"abc","agent_type":"Explore","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertNil(started.first?.subagents?.entries.first?.model, "transcript does not exist yet at spawn")

        try #"{"type":"assistant","message":{"model":"claude-sonnet-5","role":"assistant"}}"#
            .write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        let toolUse = try claudePayloads(
            #"{"hook_event_name":"PreToolUse","session_id":"session-1","tool_name":"Read","agent_id":"abc","agent_type":"Explore","agent_transcript_path":"\#(transcriptPath)"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let payload = try XCTUnwrap(toolUse.first)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.subagents?.entries.first?.model, "claude-sonnet-5")
        XCTAssertEqual(payload.subagents?.entries.first?.modelLabel, "sonnet")
    }

    func test_claude_stop_clears_subagents_explicitly() throws {
        let sessionStore = try makeClaudeSessionStore()
        let subagentStore = try makeRegistryStore()
        _ = try claudePayloads(
            #"{"hook_event_name":"SubagentStart","session_id":"session-1","agent_id":"abc","agent_type":"Explore"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let stopped = try claudePayloads(
            #"{"hook_event_name":"Stop","session_id":"session-1"}"#,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        let payload = try XCTUnwrap(stopped.first)
        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.subagents, .empty)
        XCTAssertEqual(try subagentStore.summary(key: paneKey), .empty)
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

    private func makeRegistryStore(now: @escaping () -> Date = Date.init) throws -> AgentSubagentRegistryStore {
        AgentSubagentRegistryStore(
            stateURL: try makeTemporaryDirectory().appendingPathComponent("agent-subagent-sessions.json"),
            now: now
        )
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
