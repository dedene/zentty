import Foundation
import XCTest
@testable import Zentty

final class CodexHistorySourceTests: XCTestCase {
    private typealias C = CodexHistoryFixtures
    private typealias F = AgentHistoryFixtures

    private func key(_ id: String) -> String { "rollout:" + id }

    // MARK: - Discovery

    func test_discovers_plain_and_zst_by_thread_id_incl_archived() throws {
        let (root, source) = try C.makeRoot(self)
        let plain = C.newThreadID(), compressed = C.newThreadID(), archived = C.newThreadID(), both = C.newThreadID()
        try C.writeRollout(root: root, id: plain, lines: [C.sessionMeta(plain)])
        try C.writeRollout(root: root, id: compressed, lines: [C.sessionMeta(compressed)], compressed: true)
        try C.writeRollout(root: root, id: archived, lines: [C.sessionMeta(archived)], directory: "archived_sessions")
        try C.writeRollout(root: root, id: both, lines: [C.sessionMeta(both)])
        try C.writeRollout(root: root, id: both, lines: [C.sessionMeta(both)], compressed: true)
        try Data("noise".utf8).write(to: root.appendingPathComponent("sessions/2026/10/30/notes.txt"))
        try Data().write(to: root.appendingPathComponent("logs_2.sqlite"))

        let units = Dictionary(uniqueKeysWithValues: try source.discoverUnits().map { ($0.key, $0) })
        XCTAssertEqual(Set(units.keys), [key(plain), key(compressed), key(archived), key(both)])
        XCTAssertEqual(units[key(plain)]?.kind, .jsonl)
        XCTAssertEqual(units[key(compressed)]?.kind, .zstdJSONL)
        XCTAssertEqual(units[key(archived)]?.nativeSessionID, archived)
        XCTAssertEqual(units[key(both)]?.kind, .jsonl, "mid-compression the plain file wins")
        XCTAssertNotNil(units[key(plain)]?.identity)
        XCTAssertEqual(source.estimatedSessionCount(), 4)

        try C.writeCatalog(root: root, rows: [C.ThreadRow(id: plain)])
        let withState = try source.discoverUnits()
        let state = try XCTUnwrap(withState.first { $0.key == "state" })
        XCTAssertEqual(state.kind, .database)
        XCTAssertNil(state.nativeSessionID)
    }

    func test_invalid_thread_id_skipped() throws {
        let (root, source) = try C.makeRoot(self)
        let folder = root.appendingPathComponent("sessions/2026/10/30", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("rollout-2026-10-30T10-00-00-not-a-thread-id.jsonl"))
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("rollout-2026-10-30T10-00-00-zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz.jsonl"))
        XCTAssertEqual(try source.discoverUnits(), [])
        XCTAssertNil(CodexHistorySource.parseRolloutFileName("rollout-x.jsonl"))

        let unit = AgentHistoryUnit(key: "rollout:bad", path: folder.appendingPathComponent("rollout-2026-10-30T10-00-00-not-a-thread-id.jsonl").path,
                                    kind: .jsonl, identity: nil, nativeSessionID: "bad id!")
        let batch = try source.ingest(unit: unit, cursor: nil, mode: .fromStart, context: F.context())
        XCTAssertEqual(batch.diagnostics.skippedSessions, ["bad id!": .invalidSessionID])
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertFalse(batch.hasMore)
    }

    func test_event_targets_map_rollouts_and_catalog_and_ignore_noise() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let base = root.path
        XCTAssertEqual(source.eventTarget(forCanonicalPath: "\(base)/sessions/2026/10/30/\(C.rolloutName(id))"), .unit(key(id)))
        XCTAssertEqual(source.eventTarget(forCanonicalPath: "\(base)/archived_sessions/\(C.rolloutName(id, compressed: true))"), .unit(key(id)))
        XCTAssertEqual(source.eventTarget(forCanonicalPath: "\(base)/state_5.sqlite"), .database("state"))
        XCTAssertEqual(source.eventTarget(forCanonicalPath: "\(base)/state_5.sqlite-wal"), .database("state"))
        XCTAssertNil(source.eventTarget(forCanonicalPath: "\(base)/logs_2.sqlite-wal"))
        XCTAssertNil(source.eventTarget(forCanonicalPath: "\(base)/history.jsonl"))
        XCTAssertNil(source.eventTarget(forCanonicalPath: "\(base)/\(C.rolloutName(id))"), "rollouts only count under sessions/")
        XCTAssertNil(source.eventTarget(forCanonicalPath: "/elsewhere/sessions/\(C.rolloutName(id))"))
        XCTAssertEqual(source.watchPaths, [base])
    }

    // MARK: - Catalog metadata

    func test_catalog_title_name_model_effort_branch_archived() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id, cwd: "/work/from-meta", branch: "meta-branch"),
            C.turnContext(model: "gpt-meta", effort: "low", at: 1),
            C.user("Fix the parser", at: 2_000),
            C.assistant("Done.", at: 3_000),
        ], directory: "archived_sessions")
        var row = C.ThreadRow(id: id)
        row.cwd = "/work/proj"
        row.title = "Generated title"
        row.name = "My custom name"
        row.firstUserMessage = "Fix the parser"
        row.model = "gpt-6-astra"
        row.effort = "high"
        row.branch = "feature/x"
        row.archived = false
        row.createdAtMs = C.baseMs - 5_000
        row.updatedAtMs = C.baseMs + 9_000
        try C.writeCatalog(root: root, rows: [row])

        let batches = try C.ingestAll(source, unit: try C.unit(source, key: key(id)))
        let session = try XCTUnwrap(batches.last?.sessions.first)
        XCTAssertEqual(session.title, "My custom name")
        XCTAssertEqual(session.titleKind, .custom)
        XCTAssertEqual(session.cwd, "/work/proj", "catalog folder wins over session_meta")
        XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertEqual(session.effort, "high")
        XCTAssertEqual(session.branch, "feature/x")
        XCTAssertEqual(session.archived, true, "a rollout under archived_sessions is archived")
        XCTAssertEqual(session.createdAtMs, C.baseMs - 5_000)
        XCTAssertEqual(session.updatedAtMs, C.baseMs + 9_000)
        XCTAssertEqual(session.transcriptPath, try C.unit(source, key: key(id)).path)
        XCTAssertNil(session.parentNativeID)
        XCTAssertNil(batches.last?.problem)

        // Without name and title: the generated title, then the first prompt.
        row.name = nil
        try C.writeCatalog(root: root, rows: [row])
        XCTAssertEqual(try C.ingestAll(source, unit: try C.unit(source, key: key(id))).last?.sessions.first?.titleKind, .generated)
    }

    func test_model_and_effort_fall_back_to_latest_turn_context() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id, branch: "meta-branch"),
            C.turnContext(model: "gpt-old", effort: "low", at: 1),
            C.user("hello", at: 2),
            C.turnContext(model: "gpt-new", effort: "xhigh", at: 3),
            C.turnContext(model: "default", effort: nil, at: 4),
        ])
        try C.writeCatalog(root: root, rows: [C.ThreadRow(id: id)])
        let session = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(id))).last?.sessions.first)
        XCTAssertEqual(session.model, "gpt-new")
        XCTAssertEqual(session.effort, "xhigh")
        XCTAssertEqual(session.branch, "meta-branch")
        XCTAssertEqual(session.title, "hello")
        XCTAssertEqual(session.titleKind, .firstPrompt)
    }

    func test_catalog_titles_and_first_message_redacted() throws {
        let (root, source) = try C.makeRoot(self)
        let token = F.fakeGitHubToken()
        let id = C.newThreadID(), other = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [C.sessionMeta(id), C.user("use \(token)", at: 1)])
        try C.writeRollout(root: root, id: other, lines: [C.sessionMeta(other), C.user("plain ask", at: 1)])
        var named = C.ThreadRow(id: id)
        named.name = "deploy with \(token)"
        var titled = C.ThreadRow(id: other)
        titled.title = "title \(token)"
        titled.firstUserMessage = "first \(token)"
        try C.writeCatalog(root: root, rows: [named, titled])

        let first = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(id))).last)
        XCTAssertFalse(try XCTUnwrap(first.sessions.first?.title).contains(token))
        XCTAssertFalse(first.messages.contains { $0.text.contains(token) })
        let second = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(other))).last?.sessions.first)
        XCTAssertEqual(second.titleKind, .generated)
        XCTAssertFalse(try XCTUnwrap(second.title).contains(token))

        // The catalog unit redacts too.
        var batch = try source.ingest(unit: try C.unit(source, key: "state"), cursor: nil, mode: .fromStart, context: F.context())
        XCTAssertEqual(batch.sessions.count, 2)
        XCTAssertFalse(batch.sessions.contains { $0.title?.contains(token) == true })
        titled.title = ""
        try FileManager.default.removeItem(at: root.appendingPathComponent("state_5.sqlite"))
        try C.writeCatalog(root: root, rows: [titled])
        batch = try source.ingest(unit: try C.unit(source, key: "state"), cursor: nil, mode: .fromStart, context: F.context())
        let firstPrompt = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(firstPrompt.titleKind, .firstPrompt)
        XCTAssertFalse(try XCTUnwrap(firstPrompt.title).contains(token))
    }

    // MARK: - Children

    func test_children_not_discovered() throws {
        let (root, source) = try C.makeRoot(self)
        let parent = C.newThreadID()
        let bySource = C.newThreadID(), byThreadSource = C.newThreadID(), byGuardian = C.newThreadID()
        let byAttached = C.newThreadID(), bySpawnEdge = C.newThreadID()
        for id in [parent, bySource, byThreadSource, byGuardian, byAttached, bySpawnEdge] {
            try C.writeRollout(root: root, id: id, lines: [C.sessionMeta(id)])
        }
        var rows = [C.ThreadRow(id: parent)]
        var row = C.ThreadRow(id: bySource)
        row.source = #"{"subagent":{"other":"guardian"}}"#
        rows.append(row)
        row = C.ThreadRow(id: byThreadSource)
        row.threadSource = "subagent"
        rows.append(row)
        row = C.ThreadRow(id: byGuardian)
        row.threadSource = "guardian_review"
        rows.append(row)
        row = C.ThreadRow(id: byAttached)
        row.attachedParent = parent
        rows.append(row)
        rows.append(C.ThreadRow(id: bySpawnEdge))
        try C.writeCatalog(root: root, rows: rows, spawnEdges: [(parent, bySpawnEdge)])

        let keys = Set(try source.discoverUnits().map(\.key))
        XCTAssertEqual(keys, [key(parent), "state"])
        // A plain `exec` thread is not a child (headless sessions are indexed, D12).
        XCTAssertFalse(CodexThreadCatalog.isSubagentSource("exec"))
        XCTAssertTrue(CodexThreadCatalog.isSubagentSource(#"{"subagent":"review"}"#))
    }

    func test_children_from_session_meta_without_db() throws {
        let (root, source) = try C.makeRoot(self)
        let parent = C.newThreadID(), bySource = C.newThreadID(), byParent = C.newThreadID()
        try C.writeRollout(root: root, id: parent, lines: [C.sessionMeta(parent), C.user("top level", at: 1)])
        try C.writeRollout(root: root, id: bySource, lines: [
            C.sessionMeta(bySource, source: ["subagent": ["thread_spawn": ["parent_thread_id": parent]]]),
            C.user("child work", at: 1),
        ])
        try C.writeRollout(root: root, id: byParent, lines: [
            C.sessionMeta(byParent, parentThreadID: parent),
            C.user("forked child", at: 1),
        ])

        XCTAssertEqual(Set(try source.discoverUnits().map(\.key)), [key(parent), key(bySource), key(byParent)],
                       "without a catalog children are only known at ingest")
        for id in [bySource, byParent] {
            let batches = try C.ingestAll(source, unit: try C.unit(source, key: key(id)))
            let batch = try XCTUnwrap(batches.last)
            XCTAssertTrue(batch.sessions.isEmpty)
            XCTAssertTrue(batch.messages.isEmpty)
            XCTAssertEqual(batch.removedNativeIDs, [id])
            XCTAssertEqual(batch.diagnostics.skippedSessions[id], .child)
            XCTAssertFalse(batch.hasMore)
            XCTAssertEqual(batch.problem, .metadataFromTranscripts)
        }
        let top = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(parent))).last)
        XCTAssertEqual(top.messages.map(\.text), ["top level"])
    }

    func test_parent_session_meta_inside_a_rollout_is_not_authoritative() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID(), parent = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id, cwd: "/work/own"),
            C.sessionMeta(parent, cwd: "/work/parent", parentThreadID: C.newThreadID()),
            C.user("mine", at: 1),
        ])
        let batch = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(id))).last)
        XCTAssertEqual(batch.sessions.first?.cwd, "/work/own")
        XCTAssertEqual(batch.messages.map(\.text), ["mine"])
    }

    // MARK: - Messages and artifacts

    func test_message_filters() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id),
            C.message(role: "developer", parts: [("input_text", "You are Codex")], at: 1),
            C.message(role: "user", parts: [("input_text", "# AGENTS.md instructions for /work/proj\n\nbe nice"),
                                            ("input_text", "<environment_context>\n<cwd>/work</cwd>\n</environment_context>")], at: 2),
            C.user("inherited from the parent", inherited: true, at: 3),
            C.message(role: "user", parts: [("input_text", "<role>reviewer</role>"), ("input_text", "Real question?"),
                                            ("input_image", "ignored")], at: 4),
            C.message(role: "user", parts: [("input_text", "<user_action>clicked</user_action>")], at: 5),
            C.message(role: "user", parts: [("input_text", "<skill>\nname: x\n</skill>")], at: 5),
            C.message(role: "user", parts: [("input_text", "<image name=shot.png>")], at: 5),
            C.reasoning(at: 6),
            C.agentMessage("inter-agent note", at: 7),
            C.eventMessage("Real question?", at: 8),
            C.line("compacted", at: 9, payload: ["message": "summary"]),
            C.line("token_usage_record", at: 9, payload: ["usage": ["input_tokens": 1]]),
            C.line("world_state", at: 9, payload: ["full": true]),
            C.message(role: "assistant", parts: [("output_text", "Answer one."), ("output_text", "Answer two.")], at: 10),
            "{not json",
        ])
        let batch = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(id))).last)
        XCTAssertEqual(batch.messages.map(\.text), ["Real question?", "Answer one.\n\nAnswer two."])
        XCTAssertEqual(batch.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(batch.messages.map(\.seq), [0, 1])
        XCTAssertEqual(batch.messages.first?.atMs, C.baseMs + 4)
        XCTAssertEqual(batch.sessions.first?.title, "Real question?")
        XCTAssertEqual(batch.sessions.first?.lastUserAtMs, C.baseMs + 4)
        XCTAssertEqual(batch.diagnostics.malformedLines, 1)
        XCTAssertEqual(batch.cursor.nextSeq, 2)
        XCTAssertFalse(batch.hasMore)
    }

    func test_artifacts_exec_shell_patch_commit() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let patch = "*** Begin Patch\n*** Update File: /work/proj/Sources/App.swift\n@@\n-a\n+b\n*** Add File: docs/new.md\n+x\n*** End Patch"
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id, cwd: "/work/proj"),
            C.user("ship it", at: 1),
            C.functionCall("exec_command", arguments: ["cmd": "swift test --filter Parser", "workdir": "/work/proj"], callID: "c1", at: 2),
            C.functionCall("shell", arguments: ["command": ["bash", "-lc", "git status"]], callID: "c2", at: 3),
            C.customToolCall("apply_patch", input: patch, callID: "c3", at: 4),
            C.functionCall("exec_command", arguments: ["cmd": "git commit -m 'Fix parser'"], callID: "c4", at: 5),
            C.functionCallOutput("c1", output: "[main deadbee] not a commit call", at: 6),
            C.functionCallOutput("c4", output: "[main 1a2b3c4d] Fix parser\n 1 file changed", at: 7),
            C.functionCall("spawn_agent", arguments: ["message": "go"], callID: "c5", at: 8),
            C.assistant("Opened https://github.com/zenjoy/zentty/pull/42 for review.", at: 9),
        ])
        let batch = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: key(id))).last)
        let artifacts = batch.artifacts.map { "\($0.kind.rawValue):\($0.value)" }
        XCTAssertEqual(artifacts, [
            "command:swift test --filter Parser",
            "command:git status",
            "path:Sources/App.swift",
            "path:docs/new.md",
            "command:git commit -m 'Fix parser'",
            "commit:1a2b3c4d",
            "pr:https://github.com/zenjoy/zentty/pull/42",
        ])
        XCTAssertEqual(CodexRolloutState.decode(batch.cursor.adapterState)?.pendingCommitCallIDs, [])
    }

    func test_pending_commit_call_survives_batch_boundary() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id),
            C.user("one", at: 1),
            C.functionCall("exec_command", arguments: ["cmd": "git commit -am wip"], callID: "commit-1", at: 2),
            C.user("two", at: 3),
            C.functionCallOutput("commit-1", output: "[feature abcdef1] wip", at: 4),
            C.user("three", at: 5),
        ])
        let batches = try C.ingestAll(source, unit: try C.unit(source, key: key(id)), context: F.context(messageLimit: 1))
        XCTAssertGreaterThan(batches.count, 2)
        XCTAssertEqual(batches.flatMap(\.messages).map(\.text), ["one", "two", "three"])
        XCTAssertEqual(batches.flatMap(\.messages).map(\.seq), [0, 1, 2])
        XCTAssertTrue(batches.flatMap(\.artifacts).contains { $0.kind == .commit && $0.value == "abcdef1" })
        XCTAssertFalse(try XCTUnwrap(batches.last).hasMore)
    }

    func test_redacts_messages_and_commands() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let key = F.fakeOpenAIKey()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id),
            C.user("my key is \(key)", at: 1),
            C.functionCall("exec_command", arguments: ["cmd": "export OPENAI_API_KEY=\(key)"], callID: "c1", at: 2),
        ])
        let batch = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: self.key(id))).last)
        XCTAssertFalse(batch.messages.contains { $0.text.contains(key) || $0.searchText.contains(key.lowercased()) })
        XCTAssertFalse(batch.artifacts.contains { $0.value.contains(key) })
        XCTAssertFalse(batch.sessions.contains { $0.title?.contains(key) == true })
    }

    // MARK: - Admission

    func test_excluded_and_tombstoned_store_nothing_and_reject() throws {
        let (root, source) = try C.makeRoot(self)
        let excluded = C.newThreadID(), tombstoned = C.newThreadID()
        try C.writeRollout(root: root, id: excluded, lines: [C.sessionMeta(excluded, cwd: "/secret/repo"), C.user("hidden", at: 1)])
        try C.writeRollout(root: root, id: tombstoned, lines: [C.sessionMeta(tombstoned), C.user("removed", at: 1)])
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/secret"]),
            tombstones: [AgentHistorySessionKey(agent: .codex, nativeID: tombstoned)]
        )
        let context = F.context(admission: admission)

        let first = try source.ingest(unit: try C.unit(source, key: key(excluded)), cursor: nil, mode: .fromStart, context: context)
        XCTAssertEqual(first.rejected, [excluded: .excludedFolder])
        XCTAssertTrue(first.sessions.isEmpty && first.messages.isEmpty)
        XCTAssertEqual(first.diagnostics.skippedSessions[excluded], .excluded)

        let second = try source.ingest(unit: try C.unit(source, key: key(tombstoned)), cursor: nil, mode: .fromStart, context: context)
        XCTAssertEqual(second.rejected, [tombstoned: .tombstoned])
        XCTAssertTrue(second.sessions.isEmpty && second.messages.isEmpty)
        XCTAssertEqual(second.cursor.byteOffset, 0, "a tombstone rejects before reading")

        // With the folder known from the catalog, exclusion also rejects before reading.
        var row = C.ThreadRow(id: excluded)
        row.cwd = "/secret/repo"
        try C.writeCatalog(root: root, rows: [row])
        let third = try source.ingest(unit: try C.unit(source, key: key(excluded)), cursor: nil, mode: .fromStart, context: context)
        XCTAssertEqual(third.rejected, [excluded: .excludedFolder])
        XCTAssertEqual(third.cursor.byteOffset, 0)
    }

    // MARK: - Incremental plain rollouts

    func test_incremental_append_resumes_with_seq_and_fingerprint() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let url = try C.writeRollout(root: root, id: id, lines: [C.sessionMeta(id), C.user("first", at: 1)])
        var unit = try C.unit(source, key: key(id))
        let first = try XCTUnwrap(try C.ingestAll(source, unit: unit).last)
        XCTAssertEqual(first.cursor.byteOffset, unit.identity?.size)
        XCTAssertEqual(first.cursor.fingerprint, AgentHistoryFileFingerprint.compute(path: unit.path, endOffset: first.cursor.byteOffset))
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: first.cursor), .unchanged)

        try F.append(C.assistant("reply", at: 2) + "\n" + C.user("partial", at: 3), to: url)
        unit = try C.unit(source, key: key(id))
        let change = source.classifyChange(unit: unit, cursor: first.cursor)
        XCTAssertEqual(change, .append(fromOffset: first.cursor.byteOffset, nextSeq: 1))
        let second = try source.ingest(unit: unit, cursor: first.cursor, mode: .fromOffset(first.cursor.byteOffset, nextSeq: 1), context: F.context())
        XCTAssertEqual(second.messages.map(\.text), ["reply"], "the unterminated trailing line waits")
        XCTAssertEqual(second.messages.map(\.seq), [1])
        XCTAssertEqual(second.sessions.first?.cwd, "/work/proj", "the folder is carried in adapter state")
    }
}
