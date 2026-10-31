import Foundation
import XCTest
@testable import Zentty

/// The thread catalog (`state_5.sqlite`), its fallbacks, and the `state` unit.
final class CodexHistorySourceCatalogTests: XCTestCase {
    private typealias C = CodexHistoryFixtures
    private typealias F = AgentHistoryFixtures

    func test_fallback_missing_db_note() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [
            C.sessionMeta(id, cwd: "/work/meta", branch: "meta-branch"),
            C.turnContext(model: "gpt-meta", effort: "medium", at: 1),
            C.user("hello there", at: 2),
        ], directory: "archived_sessions")

        XCTAssertFalse(try source.discoverUnits().contains { $0.key == "state" })
        let batch = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: "rollout:" + id)).last)
        XCTAssertEqual(batch.problem, .metadataFromTranscripts)
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.cwd, "/work/meta")
        XCTAssertEqual(session.branch, "meta-branch")
        XCTAssertEqual(session.model, "gpt-meta")
        XCTAssertEqual(session.effort, "medium")
        XCTAssertEqual(session.archived, true)
        XCTAssertEqual(session.title, "hello there")
        XCTAssertEqual(session.createdAtMs, C.baseMs)
    }

    func test_fallback_missing_column() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        try C.writeRollout(root: root, id: id, lines: [C.sessionMeta(id, cwd: "/work/meta"), C.user("hi", at: 1)])
        let database = try AgentHistoryDatabase(url: root.appendingPathComponent("state_5.sqlite"), mode: .readWrite,
                                                busyTimeoutMilliseconds: 2_000)
        try database.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, cwd TEXT)")
        try database.run("INSERT INTO threads VALUES (?, 'Catalog title', '/work/catalog')", [.text(id)])
        database.close()

        XCTAssertEqual(source.catalog.lookup(), CodexThreadCatalogLookup(snapshot: nil, problem: .metadataFromTranscripts))
        let batch = try XCTUnwrap(try C.ingestAll(source, unit: try C.unit(source, key: "rollout:" + id)).last)
        XCTAssertEqual(batch.problem, .metadataFromTranscripts)
        XCTAssertEqual(batch.sessions.first?.cwd, "/work/meta")
        XCTAssertEqual(batch.sessions.first?.title, "hi")
    }

    func test_catalog_handles_old_schemas_without_ms_columns() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        let database = try AgentHistoryDatabase(url: root.appendingPathComponent("state_5.sqlite"), mode: .readWrite,
                                                busyTimeoutMilliseconds: 2_000)
        try database.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER)")
        try database.run("INSERT INTO threads VALUES (?, '/r.jsonl', '/work/x', 100, 200)", [.text(id.uppercased())])
        database.close()

        let row = try XCTUnwrap(source.catalog.lookup().snapshot?.rows[id], "ids are normalized")
        XCTAssertEqual(row.createdAtMs, 100_000)
        XCTAssertEqual(row.updatedAtMs, 200_000)
        XCTAssertNil(row.title)
        XCTAssertFalse(row.archived)
        XCTAssertFalse(row.isChild)
    }

    func test_catalog_cache_follows_database_identity() throws {
        let (root, source) = try C.makeRoot(self)
        let id = C.newThreadID()
        var row = C.ThreadRow(id: id)
        row.title = "Before"
        try C.writeCatalog(root: root, rows: [row])
        XCTAssertEqual(source.catalog.lookup().snapshot?.rows[id]?.title, "Before")
        row.title = "After"
        try C.writeCatalog(root: root, rows: [row])
        XCTAssertEqual(source.catalog.lookup().snapshot?.rows[id]?.title, "After")
    }

    // MARK: - state unit

    func test_state_unit_emits_renames_archives_since_watermark() throws {
        let (root, source) = try C.makeRoot(self)
        let a = C.newThreadID(), b = C.newThreadID(), child = C.newThreadID()
        var rowA = C.ThreadRow(id: a)
        rowA.title = "Alpha"
        rowA.updatedAtMs = C.baseMs + 1_000
        var rowB = C.ThreadRow(id: b)
        rowB.title = "Beta"
        rowB.updatedAtMs = C.baseMs + 2_000
        var rowChild = C.ThreadRow(id: child)
        rowChild.threadSource = "subagent"
        rowChild.updatedAtMs = C.baseMs + 3_000
        try C.writeCatalog(root: root, rows: [rowA, rowB, rowChild])

        let unit = try C.unit(source, key: "state")
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: nil), .new)
        let first = try source.ingest(unit: unit, cursor: nil, mode: .fromStart, context: F.context())
        XCTAssertTrue(first.updatesExistingSessionsOnly)
        XCTAssertEqual(first.sessions.map(\.nativeID), [a, b], "children never; oldest change first")
        XCTAssertEqual(first.cursor.watermark, C.baseMs + 2_000)
        XCTAssertFalse(first.hasMore)
        XCTAssertTrue(first.messages.isEmpty)

        XCTAssertEqual(source.classifyChange(unit: unit, cursor: first.cursor), .append(fromOffset: 0, nextSeq: 0))
        let idle = try source.ingest(unit: unit, cursor: first.cursor, mode: .fromOffset(0, nextSeq: 0), context: F.context())
        XCTAssertTrue(idle.sessions.isEmpty, "nothing changed since the watermark")

        rowA.name = "Renamed alpha"
        rowA.archived = true
        rowA.updatedAtMs = C.baseMs + 5_000
        try C.writeCatalog(root: root, rows: [rowA])
        let second = try source.ingest(unit: unit, cursor: first.cursor, mode: .fromOffset(0, nextSeq: 0), context: F.context())
        let renamed = try XCTUnwrap(second.sessions.first)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(renamed.title, "Renamed alpha")
        XCTAssertEqual(renamed.titleKind, .custom)
        XCTAssertEqual(renamed.archived, true)
        XCTAssertEqual(second.cursor.watermark, C.baseMs + 5_000)

        try FileManager.default.removeItem(at: root.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(source.classifyChange(unit: unit, cursor: second.cursor), .missing)
    }

    func test_state_unit_pages_with_keyset_on_equal_timestamps() throws {
        let (root, source) = try C.makeRoot(self)
        let ids = (0 ..< 5).map { _ in C.newThreadID() }.sorted()
        try C.writeCatalog(root: root, rows: ids.map { id in
            var row = C.ThreadRow(id: id)
            row.title = "t"
            row.updatedAtMs = C.baseMs
            return row
        })
        let unit = try C.unit(source, key: "state")
        let batches = try C.ingestAll(source, unit: unit, context: F.context(messageLimit: 2))
        XCTAssertEqual(batches.flatMap(\.sessions).map(\.nativeID), ids)
        XCTAssertEqual(batches.map(\.hasMore), [true, true, false])
    }

    func test_state_unit_skips_excluded_and_tombstoned() throws {
        let (root, source) = try C.makeRoot(self)
        let kept = C.newThreadID(), excluded = C.newThreadID(), tombstoned = C.newThreadID()
        var rowExcluded = C.ThreadRow(id: excluded)
        rowExcluded.cwd = "/secret/x"
        try C.writeCatalog(root: root, rows: [C.ThreadRow(id: kept), rowExcluded, C.ThreadRow(id: tombstoned)])
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/secret"]),
            tombstones: [AgentHistorySessionKey(agent: .codex, nativeID: tombstoned)]
        )
        let batch = try source.ingest(unit: try C.unit(source, key: "state"), cursor: nil, mode: .fromStart,
                                      context: F.context(admission: admission))
        XCTAssertEqual(batch.sessions.map(\.nativeID), [kept])
        XCTAssertEqual(batch.diagnostics.skippedSessions, [excluded: .excluded, tombstoned: .tombstoned])
    }
}
