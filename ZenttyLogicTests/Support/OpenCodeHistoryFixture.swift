import Foundation
import XCTest
@testable import Zentty

/// A temp `opencode.db` with the v1 (`session`/`message`/`part`) and optionally v2
/// (`session_v2`/`session_message`) tables, written through `AgentHistoryDatabase(.readWrite)`.
/// Column sets follow opencode's schema (only what the adapter reads, plus a few neighbours).
/// Never touches the real `~/.local/share/opencode`.
final class OpenCodeHistoryFixture: @unchecked Sendable {
    let rootURL: URL
    let databaseURL: URL
    private(set) var database: AgentHistoryDatabase?

    init(testCase: XCTestCase, v2: Bool = true, includeParts: Bool = true) throws {
        rootURL = try AgentHistoryFixtures.makeTemporaryDirectory(testCase).appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        databaseURL = rootURL.appendingPathComponent("opencode.db")
        let database = try AgentHistoryDatabase(url: databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        self.database = database
        testCase.addTeardownBlock { [weak self] in self?.close() }

        try database.execute("""
            CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL);
            CREATE TABLE session (
              id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL,
              directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER,
              agent TEXT, model TEXT);
            CREATE TABLE message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE INDEX message_session_time_created_id_idx ON message (session_id, time_created, id);
            """)
        if includeParts {
            try database.execute("""
                CREATE TABLE part (
                  id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
                  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
                CREATE INDEX part_session_idx ON part (session_id);
                """)
        }
        if v2 {
            try database.execute("""
                CREATE TABLE session_v2 (
                  id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL,
                  directory TEXT NOT NULL, title TEXT, version TEXT NOT NULL,
                  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER,
                  agent TEXT, model TEXT);
                CREATE TABLE session_message (
                  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
                  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
                CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
                """)
        }
    }

    var root: AgentHistorySourceRoot {
        AgentHistorySourceRoot(agent: .opencode, path: rootURL.path, isDefault: false)
    }

    private var db: AgentHistoryDatabase {
        get throws {
            guard let database else { throw AgentHistoryDatabaseError.closed() }
            return database
        }
    }

    // MARK: - Rows

    enum Generation { case v1, v2 }

    func addSession(
        _ id: String,
        in generation: Generation = .v1,
        directory: String = "/work/project",
        title: String = "A session",
        version: String = "1.14.0",
        parentID: String? = nil,
        createdMs: Int64,
        updatedMs: Int64,
        archivedMs: Int64? = nil,
        model: [String: Any]? = nil
    ) throws {
        let table = generation == .v1 ? "session" : "session_v2"
        try db.run(
            """
            INSERT INTO \(table) (id, project_id, parent_id, slug, directory, title, version,
                                  time_created, time_updated, time_archived, model)
            VALUES (?, 'prj', ?, 'slug', ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(id), .of(parentID), .text(directory), .text(title), .text(version),
             .integer(createdMs), .integer(updatedMs), .of(archivedMs), .of(try model.map(Self.json))]
        )
    }

    func touchSession(_ id: String, in generation: Generation = .v1, updatedMs: Int64, title: String? = nil) throws {
        let table = generation == .v1 ? "session" : "session_v2"
        try db.run("UPDATE \(table) SET time_updated = ?, title = COALESCE(?, title) WHERE id = ?",
                   [.integer(updatedMs), .of(title), .text(id)])
    }

    /// A v1 message row; `role` goes into `data` with `extra`.
    func addMessage(
        _ id: String, session: String, role: String, createdMs: Int64, updatedMs: Int64? = nil,
        extra: [String: Any] = [:]
    ) throws {
        var data = extra
        data["role"] = role
        data["time"] = ["created": createdMs]
        try db.run(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(session), .integer(createdMs), .integer(updatedMs ?? createdMs), .text(try Self.json(data))]
        )
    }

    func addPart(
        _ id: String, message: String, session: String, data: [String: Any], createdMs: Int64, updatedMs: Int64? = nil
    ) throws {
        try db.run(
            "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id), .text(message), .text(session), .integer(createdMs), .integer(updatedMs ?? createdMs),
             .text(try Self.json(data))]
        )
    }

    func addTextPart(
        _ id: String, message: String, session: String, text: String, synthetic: Bool = false, createdMs: Int64
    ) throws {
        var data: [String: Any] = ["type": "text", "text": text]
        if synthetic { data["synthetic"] = true }
        try addPart(id, message: message, session: session, data: data, createdMs: createdMs)
    }

    func addToolPart(
        _ id: String, message: String, session: String, tool: String, input: [String: Any], output: String? = nil,
        createdMs: Int64
    ) throws {
        var state: [String: Any] = ["status": "completed", "input": input]
        if let output { state["output"] = output }
        try addPart(id, message: message, session: session,
                    data: ["type": "tool", "tool": tool, "callID": "call_\(id)", "state": state], createdMs: createdMs)
    }

    func updatePart(_ id: String, text: String, updatedMs: Int64) throws {
        try db.run("UPDATE part SET data = json_set(data, '$.text', ?), time_updated = ? WHERE id = ?",
                   [.text(text), .integer(updatedMs), .text(id)])
    }

    func deletePart(_ id: String) throws {
        try db.run("DELETE FROM part WHERE id = ?", [.text(id)])
    }

    func deleteSession(_ id: String) throws {
        try db.run("DELETE FROM session WHERE id = ?", [.text(id)])
        try? db.run("DELETE FROM session_v2 WHERE id = ?", [.text(id)])
    }

    func addSessionMessage(
        _ id: String, session: String, type: String, seq: Int, data: [String: Any], createdMs: Int64,
        updatedMs: Int64? = nil
    ) throws {
        var data = data
        data["time"] = ["created": createdMs]
        try db.run(
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(id), .text(session), .text(type), .integer(Int64(seq)), .integer(createdMs),
             .integer(updatedMs ?? createdMs), .text(try Self.json(data))]
        )
    }

    /// Runs arbitrary writes on the fixture connection.
    func write(_ body: (AgentHistoryDatabase) throws -> Void) throws {
        try body(try db)
    }

    /// Rewrites a `session_message` row in place (same rowid), the way opencode v2 streams an
    /// assistant reply.
    func updateSessionMessage(_ id: String, data: [String: Any], updatedMs: Int64) throws {
        try db.run("UPDATE session_message SET data = ?, time_updated = ? WHERE id = ?",
                   [.text(try Self.json(data)), .integer(updatedMs), .text(id)])
    }

    func deleteSessionMessage(_ id: String) throws {
        try db.run("DELETE FROM session_message WHERE id = ?", [.text(id)])
    }

    /// A `session_message` row whose `data` is written verbatim (malformed or odd JSON).
    func addRawSessionMessage(
        _ id: String, session: String, type: String, seq: Int, rawData: String, createdMs: Int64
    ) throws {
        try db.run(
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(id), .text(session), .text(type), .integer(Int64(seq)), .integer(createdMs),
             .integer(createdMs), .text(rawData)]
        )
    }

    /// A `part` row whose `data` is written verbatim.
    func addRawPart(_ id: String, message: String, session: String, rawData: String, createdMs: Int64) throws {
        try db.run(
            "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id), .text(message), .text(session), .integer(createdMs), .integer(createdMs), .text(rawData)]
        )
    }

    /// Checkpoints everything into the main file, closes the writer and removes `-wal`/`-shm`
    /// if this SQLite build kept them: the database looks like opencode after a clean quit.
    func close() {
        guard let database else { return }
        try? database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        database.close()
        self.database = nil
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
