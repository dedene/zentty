import Foundation

/// What `opencode.db` looks like on this Mac. opencode v1 keeps `session` → `message` → `part`;
/// v2 adds `session_v2` → `session_message` beside them and copies v1 rows over (same ids).
/// Optional columns read as NULL when an older schema lacks them.
struct OpenCodeHistorySchema: Equatable, Sendable {
    static let requiredSessionColumns: Set<String> = ["id", "parent_id", "directory", "title", "time_created", "time_updated"]
    static let requiredMessageColumns: Set<String> = ["id", "session_id", "time_created", "time_updated", "data"]
    static let requiredPartColumns: Set<String> = ["id", "message_id", "session_id", "time_updated", "data"]
    static let requiredSessionV2Columns: Set<String> = ["id", "parent_id", "directory", "time_created", "time_updated"]
    static let requiredSessionMessageColumns: Set<String> = ["id", "session_id", "type", "time_created", "time_updated", "data"]

    let sessionColumns: Set<String>
    /// `session_v2` and `session_message` both exist with the columns read here.
    let hasV2: Bool
    let sessionV2Columns: Set<String>

    enum ProbeResult: Equatable {
        case supported(OpenCodeHistorySchema)
        case unsupported(String)
    }

    static func probe(_ database: AgentHistoryDatabase) throws -> ProbeResult {
        let session = try database.columns(of: "session")
        let message = try database.columns(of: "message")
        let part = try database.columns(of: "part")
        for (name, columns, required) in [
            ("session", session, requiredSessionColumns),
            ("message", message, requiredMessageColumns),
            ("part", part, requiredPartColumns),
        ] where !required.isSubset(of: columns) {
            return .unsupported(columns.isEmpty ? "opencode database without a \(name) table"
                                                : "opencode \(name) table has an unknown layout")
        }
        let sessionV2 = try database.columns(of: "session_v2")
        let sessionMessage = try database.columns(of: "session_message")
        let hasV2 = requiredSessionV2Columns.isSubset(of: sessionV2)
            && requiredSessionMessageColumns.isSubset(of: sessionMessage)
        return .supported(OpenCodeHistorySchema(
            sessionColumns: session,
            hasV2: hasV2,
            sessionV2Columns: hasV2 ? sessionV2 : []
        ))
    }
}

/// High-water marks of one poll. Rowids catch inserts (`time_updated` on `session` misses
/// message activity); `sessionUpdatedMs` catches renames and archiving.
struct OpenCodeHistoryWatermarks: Codable, Equatable, Sendable {
    var partRowID: Int64 = 0
    var messageRowID: Int64 = 0
    var sessionMessageRowID: Int64 = 0
    var sessionUpdatedMs: Int64 = 0

    /// A stored rowid above the current maximum: rows were deleted or the file was vacuumed,
    /// so rowids are no longer a reliable "after" marker.
    func isAhead(of current: OpenCodeHistoryWatermarks) -> Bool {
        partRowID > current.partRowID
            || messageRowID > current.messageRowID
            || sessionMessageRowID > current.sessionMessageRowID
    }
}

/// One row of `session` or `session_v2`.
struct OpenCodeHistorySessionRow: Equatable, Sendable {
    let id: String
    let parentID: String?
    let directory: String?
    let title: String?
    let version: String?
    let createdMs: Int64?
    let updatedMs: Int64?
    let archivedMs: Int64?
    let modelProvider: String?
    let modelID: String?
    let modelVariant: String?
}

/// A tool call's indexable inputs. `output` is read only for `git commit` commands.
struct OpenCodeHistoryToolCall: Equatable, Sendable {
    let name: String
    let command: String?
    let filePath: String?
    let patchText: String?
    let output: String?
}

/// One message of either generation, already reduced to what gets indexed.
struct OpenCodeHistoryMessage: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case user, assistant, shell }

    let id: String
    let kind: Kind
    let createdMs: Int64
    let updatedMs: Int64
    var texts: [String] = []
    var tools: [OpenCodeHistoryToolCall] = []
    var modelProvider: String? = nil
    var modelID: String? = nil
    var variant: String? = nil
}

/// Everything stored about one session, read in one transaction.
struct OpenCodeHistorySessionContent: Equatable, Sendable {
    var v1: OpenCodeHistorySessionRow?
    var v2: OpenCodeHistorySessionRow?
    var v1Messages: [OpenCodeHistoryMessage] = []
    var v2Messages: [OpenCodeHistoryMessage] = []
    /// Newest `time_updated` over `message` and `part` (v1) and over `session_message` (v2).
    var v1TailMs: Int64?
    var v2TailMs: Int64?
    /// Newest `time_updated` over every row of the session, unfiltered: the hot-set and
    /// reconcile comparisons use exactly this value.
    var lastChangeMs: Int64
}

/// The SQL the opencode adapter runs. Every statement is a plain read; table names are literals
/// and values are bound. JSON goes through `json_extract`/`json_each` behind a `json_valid`
/// guard, so one malformed row is skipped instead of failing the whole read.
enum OpenCodeHistoryQueries {
    static let gitCommitOutputPattern = "%git%commit%"

    // MARK: - Watermarks and change detection

    static func watermarks(_ db: AgentHistoryDatabase, schema: OpenCodeHistorySchema) throws -> OpenCodeHistoryWatermarks {
        var marks = OpenCodeHistoryWatermarks()
        marks.partRowID = try db.scalarInt64("SELECT max(rowid) FROM part") ?? 0
        marks.messageRowID = try db.scalarInt64("SELECT max(rowid) FROM message") ?? 0
        marks.sessionUpdatedMs = try db.scalarInt64("SELECT max(time_updated) FROM session") ?? 0
        if schema.hasV2 {
            marks.sessionMessageRowID = try db.scalarInt64("SELECT max(rowid) FROM session_message") ?? 0
            marks.sessionUpdatedMs = max(marks.sessionUpdatedMs,
                                         try db.scalarInt64("SELECT max(time_updated) FROM session_v2") ?? 0)
        }
        return marks
    }

    /// Sessions with rows inserted after `marks` or a session row updated after it.
    static func changedSessionIDs(
        _ db: AgentHistoryDatabase,
        schema: OpenCodeHistorySchema,
        after marks: OpenCodeHistoryWatermarks
    ) throws -> Set<String> {
        var ids = Set<String>()
        ids.formUnion(try db.query("SELECT DISTINCT session_id FROM part WHERE rowid > ?", [.integer(marks.partRowID)]) { $0.string(0) })
        ids.formUnion(try db.query("SELECT DISTINCT session_id FROM message WHERE rowid > ?", [.integer(marks.messageRowID)]) { $0.string(0) })
        ids.formUnion(try db.query("SELECT id FROM session WHERE time_updated > ?", [.integer(marks.sessionUpdatedMs)]) { $0.string(0) })
        if schema.hasV2 {
            ids.formUnion(try db.query("SELECT DISTINCT session_id FROM session_message WHERE rowid > ?",
                                       [.integer(marks.sessionMessageRowID)]) { $0.string(0) })
            ids.formUnion(try db.query("SELECT id FROM session_v2 WHERE time_updated > ?",
                                       [.integer(marks.sessionUpdatedMs)]) { $0.string(0) })
        }
        return ids
    }

    /// Per-session newest `time_updated` over every table; nil when the session has no rows.
    static func lastChange(_ db: AgentHistoryDatabase, schema: OpenCodeHistorySchema, sessionID: String) throws -> Int64? {
        try tails(db, schema: schema, sessionID: sessionID).lastChange
    }

    /// One reconcile chunk: newest `time_updated` per session among `table` rows with
    /// `fromRowID < rowid <= toRowID`.
    static func lastChangeChunk(
        _ db: AgentHistoryDatabase,
        table: ContentTable,
        fromRowID: Int64,
        toRowID: Int64
    ) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        try db.query(
            "SELECT session_id, max(time_updated) FROM \(table.rawValue) WHERE rowid > ? AND rowid <= ? GROUP BY session_id",
            [.integer(fromRowID), .integer(toRowID)]
        ) { row in
            result[row.string(0)] = row.int64(1)
        }
        return result
    }

    enum ContentTable: String, CaseIterable, Sendable {
        case part, message, sessionMessage = "session_message"
    }

    /// Every session id with its session-row `time_updated` (max over both generations).
    static func sessionRowChanges(_ db: AgentHistoryDatabase, schema: OpenCodeHistorySchema) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        try db.query("SELECT id, max(time_updated) FROM \(sessionUnion(schema)) GROUP BY id") { row in
            result[row.string(0)] = row.int64(1)
        }
        return result
    }

    /// The next backfill page, newest first: sessions keyed by their session-row change time,
    /// at or below the pass target, strictly after the `(lastChange, id)` keyset position.
    static func backfillPage(
        _ db: AgentHistoryDatabase,
        schema: OpenCodeHistorySchema,
        targetMs: Int64,
        after position: OpenCodeHistoryKeyset?,
        limit: Int
    ) throws -> [OpenCodeHistoryKeyset] {
        let afterClause = position == nil ? "" : "AND (lc < ?2 OR (lc = ?2 AND id < ?3))"
        var bindings: [AgentHistoryValue] = [.integer(targetMs)]
        if let position {
            bindings.append(.integer(position.lastChangeMs))
            bindings.append(.text(position.id))
        }
        bindings.append(.integer(Int64(max(limit, 1))))
        let limitIndex = bindings.count
        return try db.query(
            """
            SELECT id, lc FROM (SELECT id, max(time_updated) AS lc FROM \(sessionUnion(schema)) GROUP BY id)
            WHERE lc <= ?1 \(afterClause)
            ORDER BY lc DESC, id DESC LIMIT ?\(limitIndex)
            """,
            bindings
        ) { OpenCodeHistoryKeyset(lastChangeMs: $0.int64(1), id: $0.string(0)) }
    }

    /// Session ids that are not a child in either generation.
    static func nonChildSessionIDs(_ db: AgentHistoryDatabase, schema: OpenCodeHistorySchema) throws -> [String] {
        let union = schema.hasV2
            ? "(SELECT id, parent_id FROM session UNION ALL SELECT id, parent_id FROM session_v2)"
            : "(SELECT id, parent_id FROM session)"
        return try db.query(
            "SELECT id FROM \(union) GROUP BY id HAVING max(parent_id IS NOT NULL) = 0"
        ) { $0.string(0) }
    }

    private static func sessionUnion(_ schema: OpenCodeHistorySchema) -> String {
        schema.hasV2
            ? "(SELECT id, time_updated FROM session UNION ALL SELECT id, time_updated FROM session_v2)"
            : "(SELECT id, time_updated FROM session)"
    }

    // MARK: - Session content

    /// Reads one session from both generations; nil when neither has a session row.
    static func loadSession(
        _ db: AgentHistoryDatabase,
        schema: OpenCodeHistorySchema,
        sessionID: String
    ) throws -> OpenCodeHistorySessionContent? {
        let v1 = try sessionRow(db, table: "session", columns: schema.sessionColumns, sessionID: sessionID)
        let v2 = schema.hasV2
            ? try sessionRow(db, table: "session_v2", columns: schema.sessionV2Columns, sessionID: sessionID)
            : nil
        guard v1 != nil || v2 != nil else {
            return nil
        }
        let tails = try tails(db, schema: schema, sessionID: sessionID)
        var content = OpenCodeHistorySessionContent(
            v1: v1,
            v2: v2,
            v1TailMs: tails.v1,
            v2TailMs: tails.v2,
            lastChangeMs: max(tails.lastChange ?? 0, v1?.updatedMs ?? 0, v2?.updatedMs ?? 0)
        )
        let isChild = v1?.parentID != nil || v2?.parentID != nil
        guard !isChild else {
            return content
        }
        if v1 != nil {
            content.v1Messages = try v1Messages(db, sessionID: sessionID)
        }
        if v2 != nil {
            content.v2Messages = try v2Messages(db, sessionID: sessionID)
        }
        return content
    }

    private static func sessionRow(
        _ db: AgentHistoryDatabase,
        table: String,
        columns: Set<String>,
        sessionID: String
    ) throws -> OpenCodeHistorySessionRow? {
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let model = columns.contains("model") ? "CASE WHEN json_valid(model) THEN model END" : "NULL"
        return try db.queryOne(
            """
            SELECT id, parent_id, directory, \(column("title")), \(column("version")),
                   time_created, time_updated, \(column("time_archived")),
                   json_extract(\(model), '$.providerID'), json_extract(\(model), '$.id'),
                   json_extract(\(model), '$.variant')
            FROM \(table) WHERE id = ?
            """,
            [.text(sessionID)]
        ) { row in
            OpenCodeHistorySessionRow(
                id: row.string(0),
                parentID: nonEmpty(row.optionalString(1)),
                directory: nonEmpty(row.optionalString(2)),
                title: row.optionalString(3),
                version: row.optionalString(4),
                createdMs: row.optionalInt64(5),
                updatedMs: row.optionalInt64(6),
                archivedMs: row.optionalInt64(7),
                modelProvider: nonEmpty(row.optionalString(8)),
                modelID: nonEmpty(row.optionalString(9)),
                modelVariant: nonEmpty(row.optionalString(10))
            )
        }
    }

    private static func tails(
        _ db: AgentHistoryDatabase,
        schema: OpenCodeHistorySchema,
        sessionID: String
    ) throws -> (v1: Int64?, v2: Int64?, lastChange: Int64?) {
        let v2Column = schema.hasV2 ? "(SELECT max(time_updated) FROM session_message WHERE session_id = ?1)" : "NULL"
        let v2Session = schema.hasV2 ? "(SELECT time_updated FROM session_v2 WHERE id = ?1)" : "NULL"
        let row = try db.queryOne(
            """
            SELECT (SELECT max(time_updated) FROM message WHERE session_id = ?1),
                   (SELECT max(time_updated) FROM part WHERE session_id = ?1),
                   \(v2Column),
                   (SELECT time_updated FROM session WHERE id = ?1),
                   \(v2Session)
            """,
            [.text(sessionID)]
        ) { row in (0..<5).map { row.optionalInt64(Int32($0)) } } ?? Array(repeating: nil, count: 5)
        return ([row[0], row[1]].compactMap { $0 }.max(), row[2], row.compactMap { $0 }.max())
    }

    /// v1: one message row per turn; its `text` parts (minus `synthetic`) are the text and its
    /// `tool` parts the tool calls.
    private static func v1Messages(_ db: AgentHistoryDatabase, sessionID: String) throws -> [OpenCodeHistoryMessage] {
        var messages: [OpenCodeHistoryMessage] = []
        var indexByID: [String: Int] = [:]
        try db.query(
            """
            SELECT id, time_created, time_updated, json_extract(data, '$.role'),
                   COALESCE(json_extract(data, '$.providerID'), json_extract(data, '$.model.providerID')),
                   COALESCE(json_extract(data, '$.modelID'), json_extract(data, '$.model.modelID')),
                   json_extract(data, '$.variant')
            FROM message WHERE session_id = ? AND json_valid(data)
            ORDER BY time_created, id
            """,
            [.text(sessionID)]
        ) { row in
            let kind: OpenCodeHistoryMessage.Kind
            switch row.optionalString(3) {
            case "user": kind = .user
            case "assistant": kind = .assistant
            default: return
            }
            indexByID[row.string(0)] = messages.count
            messages.append(OpenCodeHistoryMessage(
                id: row.string(0), kind: kind,
                createdMs: row.int64(1), updatedMs: row.int64(2),
                modelProvider: nonEmpty(row.optionalString(4)),
                modelID: nonEmpty(row.optionalString(5)),
                variant: nonEmpty(row.optionalString(6))
            ))
        }
        try db.query(
            """
            SELECT message_id, time_updated, json_extract(data, '$.type'), json_extract(data, '$.text'),
                   json_extract(data, '$.synthetic'), json_extract(data, '$.tool'),
                   json_extract(data, '$.state.input.command'), json_extract(data, '$.state.input.filePath'),
                   json_extract(data, '$.state.input.patchText'),
                   CASE WHEN json_extract(data, '$.state.input.command') LIKE ?2
                        THEN json_extract(data, '$.state.output') END
            FROM part WHERE session_id = ?1 AND json_valid(data)
              AND json_extract(data, '$.type') IN ('text', 'tool')
            ORDER BY message_id, id
            """,
            [.text(sessionID), .text(gitCommitOutputPattern)]
        ) { row in
            guard let index = indexByID[row.string(0)] else { return }
            if row.optionalString(2) == "text" {
                guard row.optionalInt64(4) ?? 0 == 0, let text = row.optionalString(3) else { return }
                messages[index].texts.append(text)
            } else if let name = row.optionalString(5) {
                messages[index].tools.append(OpenCodeHistoryToolCall(
                    name: name,
                    command: row.optionalString(6),
                    filePath: row.optionalString(7),
                    patchText: row.optionalString(8),
                    output: row.optionalString(9)
                ))
            }
        }
        return messages
    }

    /// v2: one `session_message` row per item. `user` carries `data.text`, `assistant` a
    /// `content` array of `text`/`tool` items, `shell` a typed `!command`. `synthetic`,
    /// `system`, `compaction` and `idle` rows are never indexed.
    private static func v2Messages(_ db: AgentHistoryDatabase, sessionID: String) throws -> [OpenCodeHistoryMessage] {
        var messages: [OpenCodeHistoryMessage] = []
        var indexByID: [String: Int] = [:]
        try db.query(
            """
            SELECT id, type, time_created, time_updated, json_extract(data, '$.text'),
                   json_extract(data, '$.model.providerID'), json_extract(data, '$.model.id'),
                   json_extract(data, '$.model.variant'), json_extract(data, '$.command')
            FROM session_message WHERE session_id = ? AND type IN ('user', 'assistant', 'shell') AND json_valid(data)
            ORDER BY time_created, id
            """,
            [.text(sessionID)]
        ) { row in
            var message: OpenCodeHistoryMessage
            let id = row.string(0)
            switch row.optionalString(1) {
            case "user":
                message = OpenCodeHistoryMessage(id: id, kind: .user, createdMs: row.int64(2), updatedMs: row.int64(3))
                if let text = row.optionalString(4) { message.texts.append(text) }
            case "assistant":
                message = OpenCodeHistoryMessage(
                    id: id, kind: .assistant, createdMs: row.int64(2), updatedMs: row.int64(3),
                    modelProvider: nonEmpty(row.optionalString(5)),
                    modelID: nonEmpty(row.optionalString(6)),
                    variant: nonEmpty(row.optionalString(7))
                )
            case "shell":
                message = OpenCodeHistoryMessage(id: id, kind: .shell, createdMs: row.int64(2), updatedMs: row.int64(3))
                if let command = row.optionalString(8) {
                    message.tools.append(OpenCodeHistoryToolCall(name: "shell", command: command, filePath: nil,
                                                                 patchText: nil, output: nil))
                }
            default:
                return
            }
            indexByID[id] = messages.count
            messages.append(message)
        }
        try db.query(
            """
            SELECT m.id, json_extract(c.value, '$.type'), json_extract(c.value, '$.text'),
                   json_extract(c.value, '$.name'), json_extract(c.value, '$.state.input.command'),
                   json_extract(c.value, '$.state.input.filePath'), json_extract(c.value, '$.state.input.patchText'),
                   CASE WHEN json_extract(c.value, '$.state.input.command') LIKE ?2
                        THEN COALESCE(json_extract(c.value, '$.state.metadata.output'),
                                      json_extract(c.value, '$.state.content')) END
            FROM session_message m, json_each(m.data, '$.content') c
            WHERE m.session_id = ?1 AND m.type = 'assistant' AND json_valid(m.data)
              AND json_extract(c.value, '$.type') IN ('text', 'tool')
            ORDER BY m.time_created, m.id, c.key
            """,
            [.text(sessionID), .text(gitCommitOutputPattern)]
        ) { row in
            guard let index = indexByID[row.string(0)] else { return }
            if row.optionalString(1) == "text" {
                if let text = row.optionalString(2) { messages[index].texts.append(text) }
            } else if let name = row.optionalString(3) {
                messages[index].tools.append(OpenCodeHistoryToolCall(
                    name: name,
                    command: row.optionalString(4),
                    filePath: row.optionalString(5),
                    patchText: row.optionalString(6),
                    output: row.optionalString(7)
                ))
            }
        }
        return messages
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// A backfill keyset position: the session-row change time and id of the last session read.
struct OpenCodeHistoryKeyset: Codable, Equatable, Sendable {
    let lastChangeMs: Int64
    let id: String
}
