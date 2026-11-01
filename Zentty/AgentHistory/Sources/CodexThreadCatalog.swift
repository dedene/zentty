import Foundation

/// One `threads` row of Codex's `state_5.sqlite`, reduced to what Agent History stores.
/// `id` is normalized (`AgentHistoryAgent.codex.normalizedSessionID`); text columns are raw
/// (adapters redact titles before storing them). Empty strings read as nil.
struct CodexThreadRow: Equatable, Sendable {
    let id: String
    /// Names the `.jsonl` file even after Codex compressed it to `<path>.zst`.
    let rolloutPath: String
    let cwd: String?
    let title: String?
    let name: String?
    /// First 200 characters of `first_user_message`.
    let firstUserMessage: String?
    let model: String?
    let effort: String?
    let branch: String?
    let archived: Bool
    let createdAtMs: Int64?
    let updatedAtMs: Int64?
    let isChild: Bool
}

/// Every thread of one catalog read, keyed by normalized thread id.
struct CodexThreadCatalogSnapshot: Equatable, Sendable {
    let rows: [String: CodexThreadRow]

    /// Children by any rule (row flags or `thread_spawn_edges`); never stored (D13).
    var childIDs: Set<String> {
        Set(rows.values.lazy.filter(\.isChild).map(\.id))
    }
}

/// What a catalog lookup produced. `problem` is set whenever metadata falls back to the
/// rollouts' `session_meta` records, or the last good snapshot is reused after a failed read.
struct CodexThreadCatalogLookup: Equatable, Sendable {
    let snapshot: CodexThreadCatalogSnapshot?
    let problem: AgentHistorySourceProblem?
}

/// Reads Codex's thread catalog (`state_5.sqlite`, table `threads`) read-only and caches it by
/// the stat identities of the database and its `-wal`, so polls between Codex writes cost two
/// `stat`s.
///
/// Child threads: `source` is a JSON object with a `subagent` key, `thread_source` is
/// `subagent` or `guardian_review`, `attached_thread_parent_id` is set, or the id appears as
/// `thread_spawn_edges.child_thread_id`.
///
/// Missing database, missing `threads` table or missing `id`/`rollout_path`/`cwd` columns →
/// no snapshot and `.metadataFromTranscripts`. A failed read reports its own problem (`.busy`,
/// `.unreadableDatabase`, …) and reuses the previous snapshot when there is one, else falls
/// back to the transcripts the same way.
///
/// Thread-safe: the cache is guarded by an `NSLock`; reads run under it (the indexer queue is
/// the only caller, so there is no contention).
final class CodexThreadCatalog: @unchecked Sendable {
    static let databaseFileName = "state_5.sqlite"
    static let firstUserMessageLimit = 200
    private static let requiredColumns: Set<String> = ["id", "rollout_path", "cwd"]

    let databasePath: String
    /// Where a private copy goes when `state_5.sqlite` has a `-wal` but no `-shm`.
    let snapshotCopyPolicy: ExternalSnapshotCopyPolicy

    private struct CacheKey: Equatable {
        let database: AgentHistoryFileIdentity
        let wal: AgentHistoryFileIdentity?
    }

    private let lock = NSLock()
    private var cacheKey: CacheKey?
    private var cached: CodexThreadCatalogLookup?
    private var lastGoodSnapshot: CodexThreadCatalogSnapshot?

    init(rootPath: String, snapshotCopyPolicy: ExternalSnapshotCopyPolicy = .standard) {
        databasePath = (rootPath as NSString).appendingPathComponent(Self.databaseFileName)
        self.snapshotCopyPolicy = snapshotCopyPolicy
    }

    func lookup() -> CodexThreadCatalogLookup {
        lock.lock()
        defer { lock.unlock() }

        guard let database = AgentHistoryFileIdentity.stat(path: databasePath) else {
            cacheKey = nil
            cached = nil
            lastGoodSnapshot = nil
            return CodexThreadCatalogLookup(snapshot: nil, problem: .metadataFromTranscripts)
        }
        let key = CacheKey(database: database, wal: AgentHistoryFileIdentity.stat(path: databasePath + "-wal"))
        if key == cacheKey, let cached {
            return cached
        }

        let lookup: CodexThreadCatalogLookup
        do {
            if let snapshot = try readSnapshot() {
                lastGoodSnapshot = snapshot
                lookup = CodexThreadCatalogLookup(snapshot: snapshot, problem: nil)
            } else {
                lastGoodSnapshot = nil
                lookup = CodexThreadCatalogLookup(snapshot: nil, problem: .metadataFromTranscripts)
            }
            cacheKey = key
            cached = lookup
        } catch {
            let problem = Self.problem(for: error)
            AgentHistoryLog.indexer.info("Codex thread catalog read failed: \(String(describing: problem), privacy: .public)")
            // Not cached: the next lookup retries even if the files did not change.
            cacheKey = nil
            cached = nil
            return CodexThreadCatalogLookup(snapshot: lastGoodSnapshot, problem: problem)
        }
        return lookup
    }

    // MARK: - Reading

    /// nil when the schema lacks what the catalog needs.
    private func readSnapshot() throws -> CodexThreadCatalogSnapshot? {
        try AgentHistoryDatabase.readExternalSnapshot(
            url: URL(fileURLWithPath: databasePath), copyPolicy: snapshotCopyPolicy
        ) { database in
            let columns = try database.columns(of: "threads")
            guard Self.requiredColumns.isSubset(of: columns) else {
                return nil
            }
            func column(_ name: String, _ expression: String? = nil) -> String {
                columns.contains(name) ? (expression ?? "\"\(name)\"") : "NULL"
            }
            let sql = """
                SELECT id, rollout_path, cwd,
                  \(column("title")), \(column("name")),
                  \(column("first_user_message", "substr(first_user_message, 1, \(Self.firstUserMessageLimit))")),
                  \(column("model")), \(column("reasoning_effort")), \(column("git_branch")),
                  \(column("archived")),
                  \(column("created_at_ms")), \(column("created_at")),
                  \(column("updated_at_ms")), \(column("updated_at")),
                  \(column("source")), \(column("thread_source")), \(column("attached_thread_parent_id"))
                FROM threads
                """
            var spawnedChildren = Set<String>()
            if try database.tableExists("thread_spawn_edges"),
               try database.columns(of: "thread_spawn_edges").contains("child_thread_id") {
                for raw in try database.query("SELECT child_thread_id FROM thread_spawn_edges", map: { $0.optionalString(0) }) {
                    if let raw, let id = AgentHistoryAgent.codex.normalizedSessionID(raw) {
                        spawnedChildren.insert(id)
                    }
                }
            }

            var rows: [String: CodexThreadRow] = [:]
            try database.query(sql) { row in
                guard let rawID = row.optionalString(0),
                      let id = AgentHistoryAgent.codex.normalizedSessionID(rawID) else {
                    return
                }
                let isChild = spawnedChildren.contains(id)
                    || Self.isSubagentSource(Self.text(row, 14))
                    || ["subagent", "guardian_review"].contains(Self.text(row, 15) ?? "")
                    || Self.text(row, 16) != nil
                rows[id] = CodexThreadRow(
                    id: id,
                    rolloutPath: row.optionalString(1) ?? "",
                    cwd: Self.text(row, 2),
                    title: Self.text(row, 3),
                    name: Self.text(row, 4),
                    firstUserMessage: Self.text(row, 5),
                    model: AgentRootMetadataResolver.normalizedModel(Self.text(row, 6)),
                    effort: Self.text(row, 7),
                    branch: Self.text(row, 8),
                    archived: !row.isNull(9) && row.int64(9) != 0,
                    createdAtMs: row.optionalInt64(10) ?? row.optionalInt64(11).map { $0 &* 1000 },
                    updatedAtMs: row.optionalInt64(12) ?? row.optionalInt64(13).map { $0 &* 1000 },
                    isChild: isChild
                )
            }
            return CodexThreadCatalogSnapshot(rows: rows)
        }
    }

    /// Trimmed text, nil when NULL or blank.
    private static func text(_ row: AgentHistoryRow, _ column: Int32) -> String? {
        guard let value = row.optionalString(column)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// `source` holds a plain string (`cli`, `exec`, `vscode`) or a JSON object; an object with
    /// a `subagent` key marks a child.
    static func isSubagentSource(_ source: String?) -> Bool {
        guard let source, source.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else {
            return false
        }
        return object["subagent"] != nil
    }

    private static func problem(for error: Error) -> AgentHistorySourceProblem {
        guard let error = error as? AgentHistoryDatabaseError else {
            return .unreadableDatabase(code: 0)
        }
        switch error.kind {
        case .busy:
            return .busy
        case .cantOpen, .readOnly:
            return .permissionDenied
        default:
            return .unreadableDatabase(code: error.code)
        }
    }
}
