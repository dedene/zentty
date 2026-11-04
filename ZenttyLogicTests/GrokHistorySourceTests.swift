import Foundation
import XCTest
@testable import Zentty

final class GrokHistorySourceTests: XCTestCase {
    private let sessionID = "01a07283-b64e-77b3-b235-8cc132de66ed"
    private let otherSessionID = "01a09b96-0000-7000-8000-000000000001"

    private var root: URL!
    private var cwd: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = try AgentHistoryFixtures.makeTemporaryDirectory(self)
        root = base.appendingPathComponent("grok-home", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        cwd = project.path
    }

    // MARK: - Helpers

    private func makeSource() -> GrokHistorySource {
        GrokHistorySource(root: AgentHistorySourceRoot(
            agent: .grok,
            path: AgentHistoryPath.canonical(root.path),
            isDefault: false
        ))
    }

    private func unit(_ source: GrokHistorySource, id: String? = nil) throws -> AgentHistoryUnit {
        let wanted = id ?? sessionID
        let units = try source.discoverUnits()
        return try XCTUnwrap(units.first { $0.nativeSessionID == wanted })
    }

    private func ingest(
        _ source: GrokHistorySource,
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor? = nil,
        context: AgentHistoryIngestContext = AgentHistoryFixtures.context()
    ) throws -> AgentHistoryIngestBatch {
        let mode: AgentHistoryIngestMode = cursor.map { .fromOffset($0.byteOffset, nextSeq: $0.nextSeq) } ?? .fromStart
        return try source.ingest(unit: unit, cursor: cursor, mode: mode, context: context)
    }

    private func ms(_ iso: String) -> Int64 {
        AgentHistoryTimestamp.milliseconds(iso8601: iso)!
    }

    private func chat(
        _ type: String,
        _ text: String? = nil,
        promptIndex: Int? = nil,
        synthetic: String? = nil,
        plain: Bool = false
    ) throws -> String {
        try AgentHistoryFixtures.grokChat(type, text: text, promptIndex: promptIndex, syntheticReason: synthetic, plain: plain)
    }

    // MARK: - Discovery

    func test_discovers_session_directories_and_maps_events() throws {
        let directory = try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd, chat: [try chat("user", "hi", promptIndex: 0)]
        )
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: otherSessionID, cwd: cwd, chat: [try chat("user", "yo", promptIndex: 0)]
        )
        // Not a valid session id; never discovered.
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent().appendingPathComponent("bad id!", isDirectory: true),
            withIntermediateDirectories: true
        )

        let source = makeSource()
        let units = try source.discoverUnits()
        XCTAssertEqual(Set(units.compactMap(\.nativeSessionID)), [sessionID, otherSessionID])
        let found = try unit(source)
        XCTAssertEqual(found.kind, .directory)
        let chatStat = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: directory.appendingPathComponent("chat_history.jsonl").path))
        let summaryStat = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: directory.appendingPathComponent("summary.json").path))
        XCTAssertEqual(found.identity?.ino, chatStat.ino)
        XCTAssertEqual(found.identity?.size, chatStat.size)
        XCTAssertEqual(found.identity?.mtimeNs, max(chatStat.mtimeNs, summaryStat.mtimeNs))
        XCTAssertEqual(source.estimatedSessionCount(), 2)

        let sessionDir = AgentHistoryPath.canonical(root.path) + "/" + found.key
        XCTAssertEqual(source.eventTarget(forCanonicalPath: sessionDir + "/chat_history.jsonl"), .unit(found.key))
        XCTAssertEqual(source.eventTarget(forCanonicalPath: sessionDir + "/summary.json"), .unit(found.key))
        XCTAssertNil(source.eventTarget(forCanonicalPath: sessionDir + "/chat_history.jsonl.lock"))
        XCTAssertNil(source.eventTarget(forCanonicalPath: AgentHistoryPath.canonical(root.path) + "/auth.json"))
        XCTAssertEqual(source.watchPaths, [AgentHistoryPath.canonical(root.path) + "/sessions"])
    }

    // MARK: - Records

    func test_user_parts_assistant_content() throws {
        let user = try AgentHistoryFixtures.grokChat("user", parts: [
            ["type": "text", "text": "Fix the build"],
            ["type": "image", "url": "data:image/png;base64,AAAA"],
            ["type": "text", "text": "please"],
        ], promptIndex: 0)
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            user,
            try chat("assistant", "Done, the build is green."),
        ])

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))

        XCTAssertEqual(batch.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(batch.messages.map(\.seq), [0, 1])
        XCTAssertEqual(batch.messages.map(\.text), ["Fix the build\nplease", "Done, the build is green."])
        XCTAssertFalse(batch.hasMore)
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.nativeID, sessionID)
        XCTAssertEqual(session.title, "Fix the build please")
        XCTAssertEqual(session.titleKind, .firstPrompt)
        XCTAssertEqual(session.cwd, AgentHistoryPath.canonical(cwd))
        XCTAssertNotNil(session.transcriptPath)
        XCTAssertEqual(batch.replaceContentOf, [sessionID])
        XCTAssertEqual(batch.cursor.nextSeq, 2)
    }

    func test_skips_synthetic_reasoning_tool_backend_system() throws {
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            try chat("system", "You are Grok."),
            try chat("user", "<user_info>\nOS Version: macos\n</user_info>", plain: true),
            try chat("user", "<system-reminder>todo list</system-reminder>", synthetic: "system_reminder"),
            try chat("user", "Real question", promptIndex: 0),
            try chat("reasoning", "thinking hard"),
            try chat("backend_tool_call", "weather"),
            try AgentHistoryFixtures.grokChat("tool_result", text: "file contents", toolCallID: "call-1"),
            try chat("user", "Task finished", promptIndex: 1, synthetic: "task_completed"),
            try chat("assistant", "Real answer"),
        ])

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))

        XCTAssertEqual(batch.messages.map(\.text), ["Real question", "Real answer"])
        XCTAssertEqual(batch.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(batch.diagnostics.malformedLines, 0)
    }

    func test_malformed_lines_counted() throws {
        let directory = try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            try chat("user", "one", promptIndex: 0),
        ])
        try AgentHistoryFixtures.append("{not json\n", to: directory.appendingPathComponent("chat_history.jsonl"))
        try AgentHistoryFixtures.append(try chat("assistant", "two") + "\n", to: directory.appendingPathComponent("chat_history.jsonl"))

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))
        XCTAssertEqual(batch.messages.map(\.text), ["one", "two"])
        XCTAssertEqual(batch.diagnostics.malformedLines, 1)
    }

    // MARK: - Session kinds and formats

    func test_subagent_kind_skipped() throws {
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            summary: AgentHistoryFixtures.grokSummary(id: sessionID, cwd: cwd, kind: "subagent"),
            chat: [try chat("user", "explore the repo", promptIndex: 0), try chat("assistant", "ok")]
        )

        let source = makeSource()
        let found = try unit(source)
        let batch = try ingest(source, unit: found)

        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertTrue(batch.messages.isEmpty)
        XCTAssertEqual(batch.diagnostics.skippedSessions[sessionID], .child)
        XCTAssertEqual(batch.removedNativeIDs, [sessionID])
        XCTAssertFalse(batch.hasMore)
        XCTAssertEqual(batch.cursor.byteOffset, found.identity?.size)
        XCTAssertEqual(source.classifyChange(unit: try unit(source), cursor: batch.cursor), .unchanged)
    }

    func test_headless_kind_indexed() throws {
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            summary: AgentHistoryFixtures.grokSummary(id: sessionID, cwd: cwd, kind: "headless"),
            // Headless `-p` prompts are stored without the `<user_query>` wrapper.
            chat: [try chat("user", "run headless", promptIndex: 0, plain: true), try chat("assistant", "ran")]
        )

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))
        XCTAssertEqual(batch.messages.map(\.text), ["run headless", "ran"])
        XCTAssertEqual(batch.sessions.count, 1)
    }

    func test_unknown_format_unsupported() throws {
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            summary: AgentHistoryFixtures.grokSummary(id: sessionID, cwd: cwd, formatVersion: 2),
            chat: [try chat("user", "hello", promptIndex: 0)]
        )

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))

        XCTAssertEqual(batch.problem, .unsupportedFormat("Grok format 2"))
        XCTAssertEqual(batch.diagnostics.skippedSessions[sessionID], .unsupportedFormat("Grok format 2"))
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertTrue(batch.messages.isEmpty)
        XCTAssertFalse(batch.hasMore)
    }

    func test_excluded_cwd_rejects_before_reading_messages() throws {
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            try chat("user", "secret project", promptIndex: 0),
        ])
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: [cwd]),
            tombstones: []
        )

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source), context: AgentHistoryFixtures.context(admission: admission))

        XCTAssertEqual(batch.rejected[sessionID], .excludedFolder)
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertTrue(batch.messages.isEmpty)

        let tombstoned = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: []),
            tombstones: [AgentHistorySessionKey(agent: .grok, nativeID: sessionID)]
        )
        let second = try ingest(source, unit: try unit(source), context: AgentHistoryFixtures.context(admission: tombstoned))
        XCTAssertEqual(second.rejected[sessionID], .tombstoned)
        XCTAssertTrue(second.messages.isEmpty)
    }

    func test_missing_summary_cwd_falls_back_to_project_folder_for_exclusions() throws {
        var summary = AgentHistoryFixtures.grokSummary(id: sessionID, cwd: cwd)
        summary["info"] = ["id": sessionID]
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, summary: summary, chat: [
            try chat("user", "secret project", promptIndex: 0),
        ])
        let source = makeSource()

        let admitted = try ingest(source, unit: try unit(source))
        XCTAssertEqual(admitted.sessions.first?.cwd, AgentHistoryPath.canonical(cwd))

        let excluded = AgentHistoryAdmission(exclusions: AgentHistoryExclusionMatcher(folders: [cwd]), tombstones: [])
        let batch = try ingest(source, unit: try unit(source), context: AgentHistoryFixtures.context(admission: excluded))
        XCTAssertEqual(batch.rejected[sessionID], .excludedFolder)
        XCTAssertTrue(batch.messages.isEmpty)
    }

    func test_unknown_cwd_is_held_back_while_any_folder_is_excluded() throws {
        var summary = AgentHistoryFixtures.grokSummary(id: sessionID, cwd: "relative-project")
        summary["info"] = ["id": sessionID, "cwd": "relative-project"]
        try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: "relative-project", summary: summary, chat: [
            try chat("user", "where am I", promptIndex: 0),
        ])
        let source = makeSource()

        let unrestricted = try ingest(source, unit: try unit(source))
        XCTAssertEqual(unrestricted.sessions.count, 1)
        XCTAssertNil(unrestricted.sessions.first?.cwd)

        let excluded = AgentHistoryAdmission(exclusions: AgentHistoryExclusionMatcher(folders: ["/elsewhere"]), tombstones: [])
        let batch = try ingest(source, unit: try unit(source), context: AgentHistoryFixtures.context(admission: excluded))
        XCTAssertEqual(batch.rejected[sessionID], .excludedFolder)
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertTrue(batch.messages.isEmpty)
    }

    // MARK: - Timestamps and metadata

    func test_turn_started_timestamps_and_interpolation() throws {
        let t0 = "2026-09-05T17:01:00.250Z"
        let t1 = "2026-09-05T17:05:30.500Z"
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            chat: [
                try chat("user", "first", promptIndex: 0),
                try chat("assistant", "a1"),
                try chat("assistant", "a2"),
                try chat("user", "second", promptIndex: 1),
                try chat("assistant", "b1"),
            ],
            events: [
                try AgentHistoryFixtures.grokEvent("loop_started", ts: "2026-09-05T17:01:00.200Z"),
                try AgentHistoryFixtures.grokEvent("turn_started", ts: t0, turnNumber: 0),
                try AgentHistoryFixtures.grokEvent("phase_changed", ts: "2026-09-05T17:01:01.000Z"),
                try AgentHistoryFixtures.grokEvent("turn_started", ts: t1, turnNumber: 1),
            ]
        )
        // Compacted history: the transcript starts at prompt 1, so it maps to turn 1, not turn 0.
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: otherSessionID, cwd: cwd,
            chat: [
                try chat("user", "summary of earlier turns", synthetic: "compaction_meta"),
                try chat("user", "after compaction", promptIndex: 1),
                try chat("assistant", "c1"),
            ],
            events: [
                try AgentHistoryFixtures.grokEvent("turn_started", ts: t0, turnNumber: 0),
                try AgentHistoryFixtures.grokEvent("turn_started", ts: t1, turnNumber: 1),
            ]
        )

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))
        XCTAssertEqual(batch.messages.map(\.atMs), [ms(t0), ms(t0) + 1, ms(t0) + 2, ms(t1), ms(t1) + 1])

        let compacted = try ingest(source, unit: try unit(source, id: otherSessionID))
        XCTAssertEqual(compacted.messages.map(\.atMs), [ms(t1), ms(t1) + 1])

        // No events.jsonl: times are interpolated between created_at and last_active_at.
        let thirdID = "01a09b96-0000-7000-8000-000000000002"
        try AgentHistoryFixtures.writeGrokSession(root: root, id: thirdID, cwd: cwd, chat: [
            try chat("user", "no events", promptIndex: 0),
            try chat("assistant", "reply one"),
            try chat("user", "again", promptIndex: 1),
            try chat("assistant", "reply two"),
        ])
        let interpolated = try ingest(source, unit: try unit(source, id: thirdID))
        let times = interpolated.messages.map(\.atMs)
        let created = ms("2026-09-05T17:00:00.000000Z")
        let lastActive = ms("2026-09-05T17:10:00.000000Z")
        XCTAssertEqual(times.count, 4)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.allSatisfy { $0 >= created && $0 <= lastActive + 4 }, "\(times)")
        XCTAssertGreaterThan(times[2], times[0])
    }

    func test_summary_metadata_microseconds() throws {
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            summary: AgentHistoryFixtures.grokSummary(
                id: sessionID, cwd: cwd, title: "Build plan review", model: "grok-4.6", effort: "medium",
                branch: "main",
                createdAt: "2026-09-05T17:00:29.675977Z", lastActiveAt: "2026-09-05T17:00:35.688329Z"
            ),
            chat: [try chat("user", "hello", promptIndex: 0), try chat("assistant", "hi")]
        )

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.createdAtMs, ms("2026-09-05T17:00:29.675Z"))
        XCTAssertEqual(session.updatedAtMs.map { $0 >= ms("2026-09-05T17:00:35.688Z") }, true)
        XCTAssertEqual(session.title, "Build plan review")
        XCTAssertEqual(session.titleKind, .generated)
        XCTAssertEqual(session.model, "grok-4.6")
        XCTAssertEqual(session.effort, "medium")
        XCTAssertEqual(session.branch, "main")
        XCTAssertEqual(session.cwd, AgentHistoryPath.canonical(cwd))
        XCTAssertNil(session.parentNativeID)

        // Placeholder models are dropped.
        let otherDir = try AgentHistoryFixtures.writeGrokSession(
            root: root, id: otherSessionID, cwd: cwd,
            summary: AgentHistoryFixtures.grokSummary(id: otherSessionID, cwd: cwd, model: "default"),
            chat: [try chat("user", "x", promptIndex: 0)]
        )
        XCTAssertNotNil(otherDir)
        let other = try ingest(source, unit: try unit(source, id: otherSessionID))
        XCTAssertNil(other.sessions.first?.model)
    }

    func test_generated_title_redacted() throws {
        let token = AgentHistoryFixtures.fakeGitHubToken()
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            summary: AgentHistoryFixtures.grokSummary(id: sessionID, cwd: cwd, title: "Rotate \(token) now"),
            chat: [try chat("user", "use \(token)", promptIndex: 0)]
        )

        let source = makeSource()
        let batch = try ingest(source, unit: try unit(source))
        let title = try XCTUnwrap(batch.sessions.first?.title)
        XCTAssertFalse(title.contains(token))
        XCTAssertTrue(title.contains(AgentHistoryRedactor.replacement))
        XCTAssertFalse(batch.messages.contains { $0.text.contains(token) })
    }

    // MARK: - Change detection

    func test_summary_only_change_classifies_append() throws {
        let directory = try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            chat: [try chat("user", "hello", promptIndex: 0), try chat("assistant", "hi")]
        )
        let summaryURL = directory.appendingPathComponent("summary.json")
        try AgentHistoryFixtures.setModificationDate(Date(timeIntervalSince1970: 1_800_000_000), of: summaryURL)
        try AgentHistoryFixtures.setModificationDate(
            Date(timeIntervalSince1970: 1_800_000_000),
            of: directory.appendingPathComponent("chat_history.jsonl")
        )

        let source = makeSource()
        let before = try unit(source)
        let first = try ingest(source, unit: before)
        XCTAssertEqual(source.classifyChange(unit: try unit(source), cursor: first.cursor), .unchanged)

        // Grok writes a generated title into summary.json only.
        let renamed = AgentHistoryFixtures.grokSummary(id: sessionID, cwd: cwd, title: "Greeting session")
        try JSONSerialization.data(withJSONObject: renamed).write(to: summaryURL)
        try AgentHistoryFixtures.setModificationDate(Date(timeIntervalSince1970: 1_800_000_100), of: summaryURL)

        let expected = AgentHistoryUnitChange.append(fromOffset: first.cursor.byteOffset, nextSeq: 2)
        XCTAssertEqual(source.classifyChange(unit: try unit(source), cursor: first.cursor), expected)
        // Even against the identity stat'ed before the change, the summary watermark decides.
        XCTAssertEqual(source.classifyChange(unit: before, cursor: first.cursor), expected)

        let refresh = try ingest(source, unit: try unit(source), cursor: first.cursor)
        XCTAssertTrue(refresh.messages.isEmpty)
        XCTAssertTrue(refresh.replaceContentOf.isEmpty)
        XCTAssertEqual(refresh.sessions.first?.title, "Greeting session")
        XCTAssertEqual(refresh.sessions.first?.titleKind, .generated)
        XCTAssertEqual(source.classifyChange(unit: try unit(source), cursor: refresh.cursor), .unchanged)
    }

    func test_tool_call_artifacts() throws {
        let directory = try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            try chat("user", "commit it", promptIndex: 0),
            try AgentHistoryFixtures.grokChat("assistant", text: "Opened https://github.com/acme/app/pull/42", toolCalls: [
                (id: "call-commit", name: "run_terminal_command", arguments: ["command": "git commit -m 'Fix build'", "description": "commit"]),
                (id: "call-other", name: "run_terminal_command", arguments: ["command": "git log -1"]),
                (id: "call-edit", name: "search_replace", arguments: ["file_path": cwd + "/Sources/App.swift", "old_string": "a", "new_string": "b"]),
                (id: "call-write", name: "write", arguments: ["file_path": "/opt/elsewhere/notes.txt", "content": "x"]),
                (id: "call-read", name: "read_file", arguments: ["target_file": cwd + "/README.md"]),
            ]),
            try AgentHistoryFixtures.grokChat("tool_result", text: "[main deadbee] unrelated", toolCallID: "call-other"),
        ])

        let source = makeSource()
        let first = try ingest(source, unit: try unit(source))
        let values = first.artifacts.map { "\($0.kind.rawValue):\($0.value)" }
        XCTAssertEqual(Set(values), [
            "command:git commit -m 'Fix build'",
            "command:git log -1",
            "path:Sources/App.swift",
            "path:/opt/elsewhere/notes.txt",
            "pr:https://github.com/acme/app/pull/42",
        ])

        // The commit's tool result arrives in a later append: the pending id survives the cursor.
        try AgentHistoryFixtures.append(
            try AgentHistoryFixtures.grokChat("tool_result", text: "[main abc1234] Fix build\n 1 file changed", toolCallID: "call-commit") + "\n",
            to: directory.appendingPathComponent("chat_history.jsonl")
        )
        let second = try ingest(source, unit: try unit(source), cursor: first.cursor)
        XCTAssertEqual(second.artifacts.map { "\($0.kind.rawValue):\($0.value)" }, ["commit:abc1234"])
    }

    func test_rewind_replaces() throws {
        let directory = try AgentHistoryFixtures.writeGrokSession(root: root, id: sessionID, cwd: cwd, chat: [
            try chat("user", "first prompt", promptIndex: 0),
            try chat("assistant", "first answer"),
            try chat("user", "second prompt that goes wrong", promptIndex: 1),
            try chat("assistant", "second answer"),
        ])
        let source = makeSource()
        let first = try ingest(source, unit: try unit(source))
        XCTAssertEqual(first.messages.count, 4)

        // Rewind to prompt 1: Grok rewrites the history without the later turn.
        try AgentHistoryFixtures.writeJSONL([
            try chat("user", "first prompt", promptIndex: 0),
            try chat("assistant", "first answer"),
            try chat("user", "retry", promptIndex: 1),
        ], to: directory.appendingPathComponent("chat_history.jsonl"))

        XCTAssertEqual(source.classifyChange(unit: try unit(source), cursor: first.cursor), .rewrite)
        let replaced = try source.ingest(unit: try unit(source), cursor: first.cursor, mode: .fromStart, context: AgentHistoryFixtures.context())
        XCTAssertEqual(replaced.replaceContentOf, [sessionID])
        XCTAssertEqual(replaced.messages.map(\.seq), [0, 1, 2])
        XCTAssertEqual(replaced.messages.map(\.text), ["first prompt", "first answer", "retry"])
        XCTAssertEqual(replaced.cursor.nextSeq, 3)
    }

    func test_batch_limit_has_more_resumable() throws {
        let t0 = "2026-09-05T17:01:00.000Z"
        try AgentHistoryFixtures.writeGrokSession(
            root: root, id: sessionID, cwd: cwd,
            chat: [
                try chat("user", "p0", promptIndex: 0),
                try chat("assistant", "a0"),
                try chat("assistant", "a0b"),
                try chat("user", "p1", promptIndex: 1),
                try chat("assistant", "a1"),
            ],
            events: [try AgentHistoryFixtures.grokEvent("turn_started", ts: t0, turnNumber: 0)]
        )

        let source = makeSource()
        let found = try unit(source)
        let context = AgentHistoryFixtures.context(messageLimit: 2)
        var batch = try source.ingest(unit: found, cursor: nil, mode: .fromStart, context: context)
        var messages = batch.messages
        var rounds = 1
        while batch.hasMore, rounds < 10 {
            let cursor = batch.cursor
            batch = try source.ingest(
                unit: found, cursor: cursor,
                mode: .fromOffset(cursor.byteOffset, nextSeq: cursor.nextSeq), context: context
            )
            XCTAssertTrue(batch.replaceContentOf.isEmpty)
            messages += batch.messages
            rounds += 1
        }

        XCTAssertEqual(rounds, 3)
        XCTAssertEqual(messages.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertEqual(messages.map(\.text), ["p0", "a0", "a0b", "p1", "a1"])
        // The turn's start time carries across batches through the cursor.
        XCTAssertEqual(Array(messages.map(\.atMs).prefix(3)), [ms(t0), ms(t0) + 1, ms(t0) + 2])
        XCTAssertEqual(source.classifyChange(unit: try unit(source), cursor: batch.cursor), .unchanged)
    }
}
