import Foundation
import XCTest
@testable import Zentty

final class OpenCodeHistorySourceTests: OpenCodeHistorySourceTestCase {
    // MARK: - Content

    func test_v1_text_parts_skip_synthetic_reasoning() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0
        try fixture.addSession("ses_a", title: "Fix the login bug", createdMs: t, updatedMs: t + 5_000)
        try fixture.addMessage("msg_1", session: "ses_a", role: "user", createdMs: t + 1_000)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_a", text: "hello world", createdMs: t + 1_000)
        try fixture.addTextPart("prt_2", message: "msg_1", session: "ses_a", text: "Called the Read tool",
                                synthetic: true, createdMs: t + 1_001)
        try fixture.addMessage("msg_2", session: "ses_a", role: "assistant", createdMs: t + 2_000)
        try fixture.addPart("prt_3", message: "msg_2", session: "ses_a",
                            data: ["type": "reasoning", "text": "thinking hard"], createdMs: t + 2_000)
        try fixture.addPart("prt_4", message: "msg_2", session: "ses_a", data: ["type": "step-start"], createdMs: t + 2_001)
        try fixture.addTextPart("prt_5", message: "msg_2", session: "ses_a", text: "answer text", createdMs: t + 2_002)

        let (batches, _) = try drain(makeSource(fixture))
        let messages = batches.flatMap(\.messages)
        XCTAssertEqual(messages.map(\.text), ["hello world", "answer text"])
        XCTAssertEqual(messages.map(\.role), [.user, .agent])
        XCTAssertEqual(messages.map(\.seq), [0, 1])
        XCTAssertEqual(messages.map(\.atMs), [t + 1_000, t + 2_000])
        let draft = try XCTUnwrap(session(batches, "ses_a"))
        XCTAssertEqual(draft.title, "Fix the login bug")
        XCTAssertEqual(draft.titleKind, .generated)
        XCTAssertEqual(draft.generation, "v1")
        XCTAssertEqual(draft.cwd, "/work/project")
        XCTAssertEqual(draft.createdAtMs, t)
        XCTAssertEqual(draft.updatedAtMs, t + 5_000)
        XCTAssertEqual(draft.lastUserAtMs, t + 1_000)
        XCTAssertEqual(draft.archived, false)
        XCTAssertTrue(batches.flatMap(\.replaceContentOf).contains("ses_a"))
    }

    func test_v2_native_session() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_v2only", in: .v2, title: "Native v2", version: "2.0.3", createdMs: t, updatedMs: t + 9_000)
        try fixture.addSessionMessage("msg_u", session: "ses_v2only", type: "user", seq: 1,
                                      data: ["text": "list the files"], createdMs: t + 1_000)
        try fixture.addSessionMessage("msg_s", session: "ses_v2only", type: "synthetic", seq: 2,
                                      data: ["text": "synthetic reminder"], createdMs: t + 1_100)
        try fixture.addSessionMessage("msg_y", session: "ses_v2only", type: "system", seq: 3,
                                      data: ["text": "system prompt"], createdMs: t + 1_200)
        try fixture.addSessionMessage("msg_a", session: "ses_v2only", type: "assistant", seq: 4, data: [
            "model": ["providerID": "openai", "id": "gpt-5", "variant": "high"],
            "content": [
                ["type": "reasoning", "text": "let me think"],
                ["type": "text", "text": "here they are"],
                ["type": "tool", "id": "call_1", "name": "bash", "state": ["status": "completed", "input": ["command": "ls -la"]]],
            ],
        ], createdMs: t + 2_000)
        try fixture.addSessionMessage("msg_c", session: "ses_v2only", type: "compaction", seq: 5,
                                      data: ["summary": "compacted"], createdMs: t + 3_000)
        try fixture.addSessionMessage("msg_i", session: "ses_v2only", type: "idle", seq: 6,
                                      data: ["outcome": "done"], createdMs: t + 3_100)
        try fixture.addSessionMessage("msg_sh", session: "ses_v2only", type: "shell", seq: 7,
                                      data: ["command": "git status", "shellID": "sh_1"], createdMs: t + 4_000)

        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertEqual(texts(batches, "ses_v2only"), ["list the files", "here they are"])
        let draft = try XCTUnwrap(session(batches, "ses_v2only"))
        XCTAssertEqual(draft.generation, "v2")
        XCTAssertEqual(draft.title, "Native v2")
        XCTAssertEqual(draft.model, "openai/gpt-5")
        XCTAssertEqual(draft.effort, "high")
        XCTAssertEqual(batches.flatMap(\.artifacts).filter { $0.kind == .command }.map(\.value), ["ls -la", "git status"])
    }

    func test_both_generations_merge_by_id_newer_tail() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_both", title: "Merged", version: "1.14.0", createdMs: t, updatedMs: t + 1_000)
        try fixture.addSession("ses_both", in: .v2, title: "Merged", version: "1.14.0", createdMs: t, updatedMs: t + 1_000)
        // msg_1 in both: the v2 copy is newer and wins.
        try fixture.addMessage("msg_1", session: "ses_both", role: "user", createdMs: t + 100, updatedMs: t + 100)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_both", text: "old v1 prompt", createdMs: t + 100)
        try fixture.addSessionMessage("msg_1", session: "ses_both", type: "user", seq: 1,
                                      data: ["text": "edited v2 prompt"], createdMs: t + 100, updatedMs: t + 5_000)
        // msg_2 only in v1, msg_3 only in v2.
        try fixture.addMessage("msg_2", session: "ses_both", role: "assistant", createdMs: t + 200)
        try fixture.addTextPart("prt_2", message: "msg_2", session: "ses_both", text: "v1 only reply", createdMs: t + 200)
        try fixture.addSessionMessage("msg_3", session: "ses_both", type: "user", seq: 3,
                                      data: ["text": "v2 only follow-up"], createdMs: t + 300)
        // msg_4 in both, v1 newer this time.
        try fixture.addMessage("msg_4", session: "ses_both", role: "assistant", createdMs: t + 400, updatedMs: t + 4_000)
        try fixture.addTextPart("prt_4", message: "msg_4", session: "ses_both", text: "v1 newer reply", createdMs: t + 400)
        try fixture.addSessionMessage("msg_4", session: "ses_both", type: "assistant", seq: 4, data: [
            "content": [["type": "text", "text": "v2 stale reply"]],
        ], createdMs: t + 400, updatedMs: t + 400)

        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertEqual(texts(batches, "ses_both"),
                       ["edited v2 prompt", "v1 only reply", "v2 only follow-up", "v1 newer reply"])
        XCTAssertEqual(batches.flatMap(\.messages).map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(session(batches, "ses_both")?.generation, "v2", "the v2 tail (5,000) is newer than v1 (4,000)")
    }

    func test_migrated_duplicate_v1_part_update_beats_stale_v2_copy() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_part", title: "Part edit", version: "1.14.0", createdMs: t, updatedMs: t + 1_000)
        try fixture.addSession("ses_part", in: .v2, title: "Part edit", version: "1.14.0", createdMs: t, updatedMs: t + 1_000)
        // msg_1: v2 copied it at 500; v1 then rewrote only its text part at 2,000 (message row untouched).
        try fixture.addMessage("msg_1", session: "ses_part", role: "assistant", createdMs: t + 100, updatedMs: t + 100)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_part", text: "streaming", createdMs: t + 100)
        try fixture.updatePart("prt_1", text: "final v1 reply", updatedMs: t + 2_000)
        try fixture.addSessionMessage("msg_1", session: "ses_part", type: "assistant", seq: 1, data: [
            "content": [["type": "text", "text": "streaming"]],
        ], createdMs: t + 100, updatedMs: t + 500)
        // msg_2: v1 finished only a tool part after the copy; the v2 copy lacks the tool.
        try fixture.addMessage("msg_2", session: "ses_part", role: "assistant", createdMs: t + 200, updatedMs: t + 200)
        try fixture.addTextPart("prt_2", message: "msg_2", session: "ses_part", text: "running it", createdMs: t + 200)
        try fixture.addPart("prt_3", message: "msg_2", session: "ses_part", data: [
            "type": "tool", "tool": "bash", "callID": "call_3",
            "state": ["status": "completed", "input": ["command": "swift build"]],
        ], createdMs: t + 200, updatedMs: t + 3_000)
        try fixture.addSessionMessage("msg_2", session: "ses_part", type: "assistant", seq: 2, data: [
            "content": [["type": "text", "text": "running it"]],
        ], createdMs: t + 200, updatedMs: t + 600)
        // msg_3: every v1 part edit predates the v2 copy, so v2 still wins.
        try fixture.addMessage("msg_3", session: "ses_part", role: "user", createdMs: t + 300, updatedMs: t + 300)
        try fixture.addTextPart("prt_4", message: "msg_3", session: "ses_part", text: "old v1 prompt", createdMs: t + 300)
        try fixture.updatePart("prt_4", text: "still old v1 prompt", updatedMs: t + 400)
        try fixture.addSessionMessage("msg_3", session: "ses_part", type: "user", seq: 3,
                                      data: ["text": "edited v2 prompt"], createdMs: t + 300, updatedMs: t + 700)

        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertEqual(texts(batches, "ses_part"), ["final v1 reply", "running it", "edited v2 prompt"])
        XCTAssertEqual(batches.flatMap(\.artifacts).filter { $0.kind == .command }.map(\.value), ["swift build"])
    }

    func test_generation_v2_by_version() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        for (id, version) in [("ses_new", "2.1.0"), ("ses_old", "1.4.0")] {
            try fixture.addSession(id, version: version, createdMs: t, updatedMs: t)
            try fixture.addSession(id, in: .v2, version: version, createdMs: t, updatedMs: t)
            try fixture.addMessage("msg_\(id)_1", session: id, role: "user", createdMs: t + 10, updatedMs: t + 9_000)
            try fixture.addTextPart("prt_\(id)_1", message: "msg_\(id)_1", session: id, text: "prompt", createdMs: t + 10)
            try fixture.addSessionMessage("msg_\(id)_1", session: id, type: "user", seq: 1, data: ["text": "prompt"],
                                          createdMs: t + 10, updatedMs: t + 10)
        }
        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertEqual(session(batches, "ses_new")?.generation, "v2")
        XCTAssertEqual(session(batches, "ses_old")?.generation, "v1", "1.x version and an older v2 tail")
    }

    func test_children_skipped_archived_flag() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_parent", createdMs: t, updatedMs: t)
        try fixture.addSession("ses_child", title: "Child session - explore", parentID: "ses_parent", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_c", session: "ses_child", role: "user", createdMs: t + 10)
        try fixture.addTextPart("prt_c", message: "msg_c", session: "ses_child", text: "subagent prompt", createdMs: t + 10)
        try fixture.addSession("ses_archived", createdMs: t, updatedMs: t, archivedMs: t + 50)

        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertNil(session(batches, "ses_child"))
        XCTAssertTrue(texts(batches, "ses_child").isEmpty)
        XCTAssertEqual(batches.last?.diagnostics.skippedSessions["ses_child"], .child)
        XCTAssertTrue(batches.flatMap(\.removedNativeIDs).contains("ses_child"))
        XCTAssertEqual(session(batches, "ses_archived")?.archived, true)
        XCTAssertEqual(session(batches, "ses_parent")?.archived, false)
    }

    func test_excluded_and_tombstoned_sessions_store_nothing() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0
        try fixture.addSession("ses_secret", directory: "/work/secret/app", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_s", session: "ses_secret", role: "user", createdMs: t + 1)
        try fixture.addTextPart("prt_s", message: "msg_s", session: "ses_secret", text: "private", createdMs: t + 1)
        try fixture.addSession("ses_gone", createdMs: t, updatedMs: t)
        try fixture.addSession("ses_kept", createdMs: t, updatedMs: t)
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/work/secret"]),
            tombstones: [AgentHistorySessionKey(agent: .opencode, nativeID: "ses_gone")]
        )

        let (batches, _) = try drain(makeSource(fixture), context: AgentHistoryFixtures.context(admission: admission))
        XCTAssertEqual(batches.flatMap(\.sessions).map(\.nativeID), ["ses_kept"])
        XCTAssertTrue(batches.flatMap(\.messages).isEmpty)
        XCTAssertEqual(batches.last?.rejected, ["ses_secret": .excludedFolder, "ses_gone": .tombstoned])
        XCTAssertEqual(batches.last?.diagnostics.skippedSessions["ses_secret"], .excluded)
    }

    func test_placeholder_title_falls_back() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0
        try fixture.addSession("ses_p", title: "New session - 2026-10-31T10:00:00.000Z", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_1", session: "ses_p", role: "user", createdMs: t + 1)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_p", text: "Rename the build target", createdMs: t + 1)

        let (batches, _) = try drain(makeSource(fixture))
        let draft = try XCTUnwrap(session(batches, "ses_p"))
        XCTAssertEqual(draft.title, "Rename the build target")
        XCTAssertEqual(draft.titleKind, .firstPrompt)
    }

    func test_session_title_redacted() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let token = AgentHistoryFixtures.fakeGitHubToken()
        try fixture.addSession("ses_t", title: "Rotate \(token) now", createdMs: Self.t0, updatedMs: Self.t0)

        let (batches, _) = try drain(makeSource(fixture))
        let title = try XCTUnwrap(session(batches, "ses_t")?.title)
        XCTAssertFalse(title.contains(token))
        XCTAssertTrue(title.hasPrefix("Rotate"))
    }

    func test_model_effort_variant() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_v1", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_1", session: "ses_v1", role: "user", createdMs: t + 1,
                               extra: ["model": ["providerID": "google", "modelID": "gemini-pro"], "variant": "high"])
        try fixture.addMessage("msg_2", session: "ses_v1", role: "assistant", createdMs: t + 2,
                               extra: ["providerID": "anthropic", "modelID": "claude-sonnet", "variant": "xhigh"])
        try fixture.addSession("ses_v2", in: .v2, version: "2.0.0", createdMs: t, updatedMs: t)
        try fixture.addSessionMessage("msg_3", session: "ses_v2", type: "assistant", seq: 1, data: [
            "model": ["providerID": "dgx", "id": "local-ai", "variant": "default"], "content": [],
        ], createdMs: t + 3)
        try fixture.addSession("ses_row", createdMs: t, updatedMs: t,
                               model: ["providerID": "kimi", "id": "k2", "variant": "low"])

        let (batches, _) = try drain(makeSource(fixture))
        XCTAssertEqual(session(batches, "ses_v1")?.model, "anthropic/claude-sonnet")
        XCTAssertEqual(session(batches, "ses_v1")?.effort, "xhigh")
        XCTAssertEqual(session(batches, "ses_v2")?.model, "dgx/local-ai")
        XCTAssertNil(session(batches, "ses_v2")?.effort, "`default` is not an effort")
        XCTAssertEqual(session(batches, "ses_row")?.model, "kimi/k2", "falls back to the session row")
        XCTAssertEqual(session(batches, "ses_row")?.effort, "low")
    }

    // MARK: - Change detection

    func test_incremental_rowid_and_hot_update() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let clock = Clock(Self.t0)
        let hot = Self.t0 - 2 * Self.minute
        let cold = Self.t0 - Self.day
        try fixture.addSession("ses_hot", createdMs: hot, updatedMs: hot)
        try fixture.addMessage("msg_h", session: "ses_hot", role: "user", createdMs: hot)
        try fixture.addTextPart("prt_h", message: "msg_h", session: "ses_hot", text: "first draft", createdMs: hot)
        try fixture.addSession("ses_cold", createdMs: cold, updatedMs: cold)
        try fixture.addMessage("msg_c", session: "ses_cold", role: "user", createdMs: cold)
        try fixture.addTextPart("prt_c", message: "msg_c", session: "ses_cold", text: "old prompt", createdMs: cold)
        let source = makeSource(fixture, clock: clock)

        let (_, afterPass) = try drain(source)
        let idle = try drain(source, cursor: afterPass)
        XCTAssertTrue(idle.batches.flatMap(\.sessions).isEmpty, "nothing changed")

        // A new part on the cold session: found by rowid.
        try fixture.addMessage("msg_c2", session: "ses_cold", role: "assistant", createdMs: cold + 1)
        try fixture.addTextPart("prt_c2", message: "msg_c2", session: "ses_cold", text: "late reply", createdMs: cold + 1)
        let inserted = try drain(source, cursor: idle.cursor)
        XCTAssertEqual(inserted.batches.flatMap(\.sessions).map(\.nativeID), ["ses_cold"])
        XCTAssertEqual(texts(inserted.batches, "ses_cold"), ["old prompt", "late reply"])
        XCTAssertEqual(inserted.batches.flatMap(\.replaceContentOf), ["ses_cold"])

        // An in-place update keeps the rowid: only the hot set notices it.
        try fixture.updatePart("prt_h", text: "final draft", updatedMs: Self.t0)
        let updated = try drain(source, cursor: inserted.cursor)
        XCTAssertEqual(updated.batches.flatMap(\.sessions).map(\.nativeID), ["ses_hot"])
        XCTAssertEqual(texts(updated.batches, "ses_hot"), ["final draft"])

        // Out of the hot window (and before the reconcile is due) an in-place edit waits.
        clock.nowMs = Self.t0 + 11 * Self.minute
        try fixture.updatePart("prt_c", text: "edited cold prompt", updatedMs: Self.t0 + 11 * Self.minute)
        let quiet = try drain(source, cursor: updated.cursor)
        XCTAssertTrue(quiet.batches.flatMap(\.sessions).isEmpty)

        // The 15-minute reconcile scan picks it up.
        clock.nowMs = Self.t0 + 16 * Self.minute
        let reconciled = try drain(source, cursor: quiet.cursor)
        XCTAssertEqual(reconciled.batches.flatMap(\.sessions).map(\.nativeID), ["ses_cold"])
        XCTAssertEqual(texts(reconciled.batches, "ses_cold"), ["edited cold prompt", "late reply"])
    }

    func test_backfill_keyset_newest_first() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0 - Self.day
        for index in 0..<45 {
            // Two sessions share each change time so the id tie-break is exercised.
            try fixture.addSession(String(format: "ses_%02d", index), createdMs: t, updatedMs: t + Int64(index / 2))
        }
        let source = makeSource(fixture, sessionsPerBatch: 20)

        var batches: [AgentHistoryIngestBatch] = []
        var cursor: AgentHistoryCursor?
        for _ in 0..<2 {
            let batch = try ingest(source, cursor: cursor)
            batches.append(batch)
            cursor = batch.cursor
        }
        // A session touched mid-pass is past the target: the pass skips it.
        try fixture.touchSession("ses_00", updatedMs: Self.t0)
        let last = try ingest(source, cursor: cursor)
        batches.append(last)

        XCTAssertEqual(batches.map(\.hasMore), [true, true, false])
        XCTAssertEqual(batches.map(\.sessions.count), [20, 20, 4])
        let expected = (1..<45).sorted { lhs, rhs in
            lhs / 2 == rhs / 2 ? lhs > rhs : lhs / 2 > rhs / 2
        }.map { String(format: "ses_%02d", $0) }
        XCTAssertEqual(batches.flatMap(\.sessions).map(\.nativeID), expected)

        let next = try drain(source, cursor: last.cursor)
        XCTAssertEqual(next.batches.flatMap(\.sessions).map(\.nativeID), ["ses_00"], "the next poll catches it")
    }

    // MARK: - Schema and upstream state

    func test_missing_v2_tables() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        try fixture.addSession("ses_v1", createdMs: Self.t0, updatedMs: Self.t0)
        try fixture.addMessage("msg_1", session: "ses_v1", role: "user", createdMs: Self.t0)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_v1", text: "only v1", createdMs: Self.t0)

        let source = makeSource(fixture)
        let (batches, _) = try drain(source)
        XCTAssertNil(batches.last?.problem)
        XCTAssertEqual(texts(batches, "ses_v1"), ["only v1"])
        XCTAssertEqual(session(batches, "ses_v1")?.generation, "v1")
        XCTAssertEqual(try source.existingNativeIDs(), ["ses_v1"])
    }

    func test_unsupported_schema() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, includeParts: false)
        try fixture.addSession("ses_x", createdMs: Self.t0, updatedMs: Self.t0)
        let source = makeSource(fixture)

        let batch = try ingest(source, cursor: nil)
        guard case .unsupportedSchema? = batch.problem else {
            return XCTFail("expected unsupportedSchema, got \(String(describing: batch.problem))")
        }
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertFalse(batch.hasMore)
        XCTAssertNil(try source.existingNativeIDs())
    }

    func test_existing_native_ids_after_delete() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        try fixture.addSession("ses_a", createdMs: Self.t0, updatedMs: Self.t0)
        try fixture.addSession("ses_b", createdMs: Self.t0, updatedMs: Self.t0)
        try fixture.addSession("ses_b", in: .v2, createdMs: Self.t0, updatedMs: Self.t0)
        try fixture.addSession("ses_v2", in: .v2, createdMs: Self.t0, updatedMs: Self.t0)
        try fixture.addSession("ses_kid", parentID: "ses_a", createdMs: Self.t0, updatedMs: Self.t0)
        try fixture.addSession("bad id", createdMs: Self.t0, updatedMs: Self.t0)
        let source = makeSource(fixture)

        XCTAssertEqual(try source.existingNativeIDs(), ["ses_a", "ses_b", "ses_v2"])
        try fixture.deleteSession("ses_b")
        XCTAssertEqual(try source.existingNativeIDs(), ["ses_a", "ses_v2"])
    }

    func test_deleted_session_removed_on_reconcile() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let clock = Clock(Self.t0)
        try fixture.addSession("ses_a", createdMs: Self.t0 - Self.day, updatedMs: Self.t0 - Self.day)
        try fixture.addSession("ses_b", createdMs: Self.t0 - Self.day, updatedMs: Self.t0 - Self.day)
        let source = makeSource(fixture, clock: clock)
        let (_, afterPass) = try drain(source)

        try fixture.deleteSession("ses_b")
        clock.nowMs = Self.t0 + 16 * Self.minute
        let (batches, _) = try drain(source, cursor: afterPass)
        XCTAssertEqual(batches.flatMap(\.removedNativeIDs), ["ses_b"])
    }

    func test_discovery_event_target_and_classify() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let source = makeSource(fixture)
        let unit = try unit(source)
        XCTAssertEqual(unit.key, "db")
        XCTAssertEqual(unit.kind, .database)
        XCTAssertNil(unit.nativeSessionID)
        XCTAssertEqual(source.watchPaths, [fixture.rootURL.path])
        XCTAssertNil(source.estimatedSessionCount())

        XCTAssertEqual(source.eventTarget(forCanonicalPath: source.databasePath), .database("db"))
        XCTAssertEqual(source.eventTarget(forCanonicalPath: source.databasePath + "-wal"), .database("db"))
        XCTAssertNil(source.eventTarget(forCanonicalPath: fixture.rootURL.path + "/log/2026.log"))
        XCTAssertNil(source.eventTarget(forCanonicalPath: fixture.rootURL.path + "/snapshot/abc"))

        let cursor = AgentHistoryCursor(sourceID: 7, unitKey: "db")
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: nil), .new)
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: cursor), .append(fromOffset: 0, nextSeq: 0))
        let gone = AgentHistoryUnit(key: "db", path: unit.path, kind: .database, identity: nil, nativeSessionID: nil)
        XCTAssertEqual(source.classifyChange(unit: gone, cursor: cursor), .missing)
    }

    func test_never_writes_db() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_a", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_1", session: "ses_a", role: "user", createdMs: t)
        try fixture.addTextPart("prt_1", message: "msg_1", session: "ses_a", text: "hello", createdMs: t)
        try fixture.addSession("ses_b", in: .v2, version: "2.0.0", createdMs: t, updatedMs: t)
        try fixture.addSessionMessage("msg_2", session: "ses_b", type: "user", seq: 1, data: ["text": "hi"], createdMs: t)
        fixture.close()

        let listing = try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path).sorted()
        let bytes = try Data(contentsOf: fixture.databaseURL)
        let clock = Clock(t)
        let source = makeSource(fixture, clock: clock)

        let (batches, cursor) = try drain(source)
        XCTAssertEqual(Set(batches.flatMap(\.sessions).map(\.nativeID)), ["ses_a", "ses_b"])
        clock.nowMs = t + 16 * Self.minute
        _ = try drain(source, cursor: cursor)
        XCTAssertEqual(try source.existingNativeIDs(), ["ses_a", "ses_b"])

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path).sorted(), listing)
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), bytes)
    }
}
