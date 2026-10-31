import Foundation
import SQLite3

/// Thin wrapper over one SQLite connection.
///
/// Confinement: one owner at a time (system SQLite is built THREADSAFE=2, multi-thread).
/// Every member except `interrupt()` must be called by the current owner only;
/// `interrupt()` may be called from any thread and is serialized against `close()`.
final class AgentHistoryDatabase: @unchecked Sendable {
    enum Mode: Sendable {
        /// The Agent History index, opened by the indexer.
        case readWrite
        /// The Agent History index, opened by a reader in the pool.
        case readOnly
        /// Another agent's database. Never changes journal mode, never checkpoints.
        case externalReadOnly
    }

    /// `.delete` exists for test fixtures that need a rollback-journal database. Production uses `.wal`.
    enum JournalMode: Sendable { case wal, delete }

    static let statementCacheLimit = 64

    let url: URL
    let mode: Mode

    private let handleLock = NSLock()
    private var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]
    private var statementsInUse: Set<String> = []
    private var savepointDepth = 0
    private var progressHandlerBox: ProgressHandlerBox?

    init(url: URL, mode: Mode, busyTimeoutMilliseconds: Int32, journalMode: JournalMode = .wal) throws {
        self.url = url
        self.mode = mode

        let target: String
        var flags: Int32
        switch mode {
        case .readWrite:
            target = Self.pathWithResolvedParent(url)
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW
        case .readOnly:
            target = Self.readOnlyURI(forPath: Self.pathWithResolvedParent(url))
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW
        case .externalReadOnly:
            target = Self.readOnlyURI(forPath: url.path)
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        }
        flags |= SQLITE_OPEN_EXRESCODE

        var opened: OpaquePointer?
        let openCode = sqlite3_open_v2(target, &opened, flags, nil)
        guard openCode == SQLITE_OK, let opened else {
            let error = AgentHistoryDatabaseError.from(code: openCode, db: opened)
            sqlite3_close_v2(opened)
            throw error
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)

        do {
            try execute(Self.setupPragmas(mode: mode, journalMode: journalMode))
            if mode == .readWrite {
                // `PRAGMA journal_mode` reports the mode it ended up in rather than failing.
                let wanted = journalMode == .wal ? "wal" : "delete"
                let actual = try withStatement("PRAGMA journal_mode", [], cached: false) { statement, db -> String? in
                    let code = sqlite3_step(statement)
                    guard code == SQLITE_ROW else {
                        if code == SQLITE_DONE { return nil }
                        throw AgentHistoryDatabaseError.from(code: code, db: db)
                    }
                    return AgentHistoryRow(statement: statement).string(0)
                }
                if actual?.lowercased() != wanted {
                    throw AgentHistoryDatabaseError(kind: .other, code: SQLITE_ERROR, extendedCode: SQLITE_ERROR,
                                                    message: "journal_mode is \(actual ?? "unknown")")
                }
            }
        } catch {
            close()
            throw error
        }
    }

    /// Opens another program's database read-only (`mode=ro` URI): never creates the file,
    /// never sets `journal_mode`, never checkpoints. Keep read transactions short.
    static func openExternalReadOnly(url: URL, busyTimeoutMilliseconds: Int32 = 250) throws -> AgentHistoryDatabase {
        try AgentHistoryDatabase(url: url, mode: .externalReadOnly, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        handleLock.lock()
        defer { handleLock.unlock() }
        return handle != nil
    }

    func close() {
        handleLock.lock()
        let closing = handle
        handle = nil
        handleLock.unlock()
        guard let closing else { return }

        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        statementCache.removeAll()
        statementsInUse.removeAll()
        sqlite3_progress_handler(closing, 0, nil, nil)
        progressHandlerBox = nil
        savepointDepth = 0
        let code = sqlite3_close_v2(closing)
        if code != SQLITE_OK {
            AgentHistoryLog.indexer.error("SQLite close failed code=\(code, privacy: .public)")
        }
    }

    /// Cancels the statement running on this connection. Safe from any thread; meant for shutdown.
    /// Query cancellation uses `setProgressHandler` instead.
    func interrupt() {
        handleLock.lock()
        defer { handleLock.unlock() }
        if let handle {
            sqlite3_interrupt(handle)
        }
    }

    // MARK: - Statements

    /// Runs one or more statements without bindings. Meant for DDL and pragmas.
    func execute(_ sql: String) throws {
        let db = try openHandle()
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw AgentHistoryDatabaseError.from(code: code, db: db) }
    }

    func run(_ sql: String, _ bindings: [AgentHistoryValue] = []) throws {
        try withStatement(sql, bindings) { statement, db in
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return }
                if code != SQLITE_ROW { throw AgentHistoryDatabaseError.from(code: code, db: db) }
            }
        }
    }

    @discardableResult
    func query<T>(_ sql: String, _ bindings: [AgentHistoryValue] = [], map: (AgentHistoryRow) throws -> T) throws -> [T] {
        try withStatement(sql, bindings) { statement, db in
            var results: [T] = []
            let row = AgentHistoryRow(statement: statement)
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return results }
                guard code == SQLITE_ROW else { throw AgentHistoryDatabaseError.from(code: code, db: db) }
                results.append(try map(row))
            }
        }
    }

    func queryOne<T>(_ sql: String, _ bindings: [AgentHistoryValue] = [], map: (AgentHistoryRow) throws -> T) throws -> T? {
        try withStatement(sql, bindings) { statement, db in
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw AgentHistoryDatabaseError.from(code: code, db: db) }
            return try map(AgentHistoryRow(statement: statement))
        }
    }

    /// First column of the first row; nil when there is no row or the value is NULL.
    func scalarInt64(_ sql: String, _ bindings: [AgentHistoryValue] = []) throws -> Int64? {
        try queryOne(sql, bindings) { $0.optionalInt64(0) } ?? nil
    }

    func explainQueryPlan(_ sql: String, _ bindings: [AgentHistoryValue] = []) throws -> [String] {
        try withStatement("EXPLAIN QUERY PLAN " + sql, bindings, cached: false) { statement, db in
            var details: [String] = []
            let row = AgentHistoryRow(statement: statement)
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return details }
                guard code == SQLITE_ROW else { throw AgentHistoryDatabaseError.from(code: code, db: db) }
                details.append(row.string(3))
            }
        }
    }

    var cachedStatementCount: Int { statementCache.count }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    // MARK: - Transactions

    var isInTransaction: Bool {
        guard let handle else { return false }
        return sqlite3_get_autocommit(handle) == 0
    }

    /// `BEGIN IMMEDIATE … COMMIT`; nested calls become `SAVEPOINT sp_<n>`. A throwing body
    /// rolls back its own level only and rethrows.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if isInTransaction {
            return try savepoint(body)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            rollbackIfActive()
            throw error
        }
    }

    /// `BEGIN DEFERRED … COMMIT` for a consistent snapshot on read-only connections.
    /// Inside an open transaction the body simply runs in it.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        if isInTransaction {
            return try body()
        }
        try execute("BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            rollbackIfActive()
            throw error
        }
    }

    private func savepoint<T>(_ body: () throws -> T) throws -> T {
        savepointDepth += 1
        defer { savepointDepth -= 1 }
        let name = "sp_\(savepointDepth)"
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            if isInTransaction {
                _ = try? execute("ROLLBACK TO \(name)")
                _ = try? execute("RELEASE \(name)")
            }
            throw error
        }
    }

    private func rollbackIfActive() {
        guard isInTransaction else { return }
        do {
            try execute("ROLLBACK")
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("SQLite rollback failed \(error.description, privacy: .public)")
        } catch {}
    }

    // MARK: - Header fields

    func userVersion() throws -> Int32 {
        Int32(truncatingIfNeeded: try scalarInt64("PRAGMA user_version") ?? 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    func applicationID() throws -> Int32 {
        Int32(truncatingIfNeeded: try scalarInt64("PRAGMA application_id") ?? 0)
    }

    func setApplicationID(_ id: Int32) throws {
        try execute("PRAGMA application_id = \(id)")
    }

    // MARK: - Progress handler

    /// Installs a cancellation check that SQLite calls every `everyInstructions` VM steps; returning
    /// true aborts the running statement with `.interrupted`. Passing nil removes the handler.
    func setProgressHandler(everyInstructions: Int32, _ shouldAbort: (@Sendable () -> Bool)?) {
        guard let handle else { return }
        guard let shouldAbort else {
            sqlite3_progress_handler(handle, 0, nil, nil)
            progressHandlerBox = nil
            return
        }
        let box = ProgressHandlerBox(shouldAbort: shouldAbort)
        sqlite3_progress_handler(handle, max(1, everyInstructions), { context in
            guard let context else { return 0 }
            let box = Unmanaged<ProgressHandlerBox>.fromOpaque(context).takeUnretainedValue()
            return box.shouldAbort() ? 1 : 0
        }, Unmanaged.passUnretained(box).toOpaque())
        // Retained here for as long as SQLite holds the unretained pointer.
        progressHandlerBox = box
    }

    // MARK: - Internals

    private func openHandle() throws -> OpaquePointer {
        guard let handle else { throw AgentHistoryDatabaseError.closed() }
        return handle
    }

    /// Prepares (or reuses) `sql`, binds, runs `body`, then resets the statement so it releases
    /// its read snapshot. A statement already in use (re-entrant query) gets a one-off copy.
    private func withStatement<T>(
        _ sql: String,
        _ bindings: [AgentHistoryValue],
        cached: Bool = true,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let db = try openHandle()
        let useCache = cached && !statementsInUse.contains(sql)
        let statement: OpaquePointer
        if useCache, let existing = statementCache[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            statement = existing
        } else {
            statement = try prepare(sql, db: db, persistent: useCache)
            if useCache {
                evictCacheIfFull()
                statementCache[sql] = statement
            }
        }

        if useCache { statementsInUse.insert(sql) }
        defer {
            if useCache {
                statementsInUse.remove(sql)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                sqlite3_finalize(statement)
            }
        }
        try bind(bindings, to: statement, db: db)
        return try body(statement, db)
    }

    private func prepare(_ sql: String, db: OpaquePointer, persistent: Bool) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let flags: UInt32 = persistent ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
        let code = sqlite3_prepare_v3(db, sql, -1, flags, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw AgentHistoryDatabaseError.from(code: code == SQLITE_OK ? SQLITE_MISUSE : code, db: db)
        }
        return statement
    }

    private func evictCacheIfFull() {
        guard statementCache.count >= Self.statementCacheLimit else { return }
        for (sql, statement) in statementCache where !statementsInUse.contains(sql) {
            sqlite3_finalize(statement)
            statementCache[sql] = nil
        }
    }

    private func bind(_ bindings: [AgentHistoryValue], to statement: OpaquePointer, db: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let number):
                code = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                code = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                var text = text
                code = text.withUTF8 { bytes in
                    // A nil base address would bind NULL; bind an empty string explicitly.
                    guard let base = bytes.baseAddress, !bytes.isEmpty else {
                        return sqlite3_bind_text(statement, index, "", 0, Self.transientDestructor())
                    }
                    return base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                        sqlite3_bind_text(statement, index, $0, Int32(bytes.count), Self.transientDestructor())
                    }
                }
            case .blob(let data):
                if data.isEmpty {
                    code = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    code = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor())
                    }
                }
            }
            guard code == SQLITE_OK else { throw AgentHistoryDatabaseError.from(code: code, db: db) }
        }
    }

    /// `SQLITE_TRANSIENT`: SQLite copies the bound bytes before the call returns.
    static func transientDestructor() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    static func readOnlyURI(forPath path: String) -> String {
        "file:\(percentEncodedPath(path))?mode=ro"
    }

    /// `SQLITE_OPEN_NOFOLLOW` rejects a symlink anywhere in the path, and system locations such as
    /// `/var` → `/private/var` are symlinks. Resolve the parent directory with `realpath(3)` (not
    /// `URL.resolvingSymlinksInPath`, which strips `/private` again) so NOFOLLOW still refuses a
    /// symlinked database file itself.
    static func pathWithResolvedParent(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        guard let resolved = realpath(parent, nil) else { return url.path }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(url.lastPathComponent).path
    }

    private static func percentEncodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%;")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static func setupPragmas(mode: Mode, journalMode: JournalMode) -> String {
        switch mode {
        case .readWrite:
            return """
                PRAGMA trusted_schema = OFF;
                PRAGMA journal_mode = \(journalMode == .wal ? "WAL" : "DELETE");
                PRAGMA synchronous = NORMAL;
                PRAGMA foreign_keys = ON;
                PRAGMA temp_store = MEMORY;
                PRAGMA journal_size_limit = 67108864;
                PRAGMA cache_size = -16000;
                """
        case .readOnly:
            return """
                PRAGMA query_only = 1;
                PRAGMA temp_store = MEMORY;
                PRAGMA trusted_schema = OFF;
                """
        case .externalReadOnly:
            return "PRAGMA query_only = 1;"
        }
    }
}

/// Holds the progress-handler closure that the C callback reaches through an unretained pointer.
private final class ProgressHandlerBox: @unchecked Sendable {
    let shouldAbort: @Sendable () -> Bool
    init(shouldAbort: @escaping @Sendable () -> Bool) { self.shouldAbort = shouldAbort }
}
