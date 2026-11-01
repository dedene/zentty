import Foundation
import SQLite3

enum AgentHistoryAvailability: Equatable, Sendable {
    case ready
    /// The index was written by a newer Zentty. Nothing reads or writes it (D14); the file is left
    /// untouched until the user rebuilds or deletes it.
    case readOnlyNewerSchema(found: Int32)
    case unavailable(AgentHistoryDatabaseError.Kind)
}

enum AgentHistoryOpenOutcome: Equatable, Sendable {
    case opened
    case created
    case migrated(from: Int32)
    case recoveredFromCorruption
    case tokenizerChanged(from: AgentHistoryTokenizer?, to: AgentHistoryTokenizer)
}

struct AgentHistoryWriterHandle: Sendable {
    let database: AgentHistoryDatabase
    let tokenizer: AgentHistoryTokenizer
    /// In order: `.recoveredFromCorruption` (if the old file was moved aside), then one of
    /// `.created` / `.opened` / `.migrated`, then `.tokenizerChanged` (if FTS was rebuilt).
    let outcomes: [AgentHistoryOpenOutcome]
}

/// Owns the on-disk lifecycle of the Agent History index: directory, permissions, schema
/// creation and migration, corruption quarantine, newer-schema refusal, and the reader pool.
///
/// Confinement: `openWriter`, `quarantineCorruptDatabase` and `removeIndexFiles` run on the
/// indexer queue (the writer's owner) while holding the writer lock (`acquireWriterLock`), so
/// another instance's writer never loses its files. `removeEverything` runs only inside
/// `withExclusiveOwnership` (no indexer runs anywhere). `availability`, `tokenizer` and
/// `readers` are safe from any thread (lock-protected).
final class AgentHistoryStorage: @unchecked Sendable {
    struct Options: Sendable {
        var readerCount = 3
        var busyTimeoutMilliseconds: Int32 = 2_000
        /// Forces a tokenizer instead of probing (tests, and a fallback switch).
        var tokenizerOverride: AgentHistoryTokenizer? = nil
        /// How long `openWriter` waits for another process to finish setting up the index.
        var setupLockTimeout: TimeInterval = 30
        /// Runs after the schema snapshot asked for a create or migrate, before the write lock is
        /// taken. Tests use it to let another writer get there first.
        var beforeSchemaWriteForTesting: (@Sendable () -> Void)? = nil
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    let paths: AgentHistoryPaths
    let options: Options
    let readers: AgentHistoryReaderPool

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let appVersion: String
    private let availabilityBox = AgentHistoryAvailabilityBox()

    init(
        paths: AgentHistoryPaths,
        options: Options = .init(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        appVersion: String = AgentHistoryStorage.bundleVersion
    ) {
        self.paths = paths
        self.options = options
        self.fileManager = fileManager
        self.now = now
        self.appVersion = appVersion
        self.readers = AgentHistoryReaderPool(
            databaseURL: paths.databaseURL,
            readerCount: options.readerCount,
            busyTimeoutMilliseconds: options.busyTimeoutMilliseconds,
            availabilityBox: availabilityBox
        )
    }

    private(set) var availability: AgentHistoryAvailability {
        get { availabilityBox.availability }
        set { availabilityBox.update(availability: newValue) }
    }

    /// The tokenizer of the open index; nil until `openWriter` succeeds.
    var tokenizer: AgentHistoryTokenizer? { availabilityBox.tokenizer }

    // MARK: - Writer

    /// Opens (creating, migrating or recovering as needed) the index for writing.
    ///
    /// - A missing or empty file gets schema v1.
    /// - A corrupt, non-SQLite or foreign file is moved aside (`index.corrupt-<date>.sqlite`) and
    ///   replaced once (`.recoveredFromCorruption`).
    /// - An index with a newer schema is never opened for writing: availability becomes
    ///   `.readOnlyNewerSchema` and this throws `.schemaTooNew`; the file's bytes do not change.
    /// - A tokenizer different from the stored one rebuilds the FTS tables only.
    /// - All of this runs under the cross-process setup lock (`AgentHistorySetupLock`); another
    ///   process holding it past `Options.setupLockTimeout` makes this throw `.busy`.
    func openWriter() throws -> AgentHistoryWriterHandle {
        do {
            let handle = try withSetupLock { try openWriter(recovered: false) }
            availabilityBox.update(availability: .ready, tokenizer: handle.tokenizer)
            tightenFilePermissions()
            AgentHistoryLog.indexer.info(
                "Agent History index open tokenizer=\(handle.tokenizer.rawValue, privacy: .public) outcomes=\(handle.outcomes.count, privacy: .public)"
            )
            return handle
        } catch let error as AgentHistoryDatabaseError {
            if case .schemaTooNew(let found) = error.kind {
                availabilityBox.update(availability: .readOnlyNewerSchema(found: found), tokenizer: nil)
                AgentHistoryLog.indexer.error("Agent History index has newer schema version=\(found, privacy: .public)")
            } else {
                availabilityBox.update(availability: .unavailable(error.kind), tokenizer: nil)
                AgentHistoryLog.indexer.error("Agent History index open failed \(error.description, privacy: .public)")
            }
            throw error
        } catch {
            // Anything else (a file operation outside SQLite) still leaves no writer: readers must
            // not keep serving the file this open gave up on.
            availabilityBox.update(availability: .unavailable(.cantOpen), tokenizer: nil)
            AgentHistoryLog.indexer.error("Agent History index open failed outside SQLite")
            throw error
        }
    }

    /// Takes exclusive ownership of the index for writing (see `AgentHistoryWriterLock`). Throws
    /// `.busy` when another indexer keeps it past `timeout`. The lock file sits beside the index
    /// directory, so this never creates the directory (`openWriter` does).
    func acquireWriterLock(timeout: TimeInterval) throws -> AgentHistoryWriterLock {
        try ensureLockDirectory()
        return try AgentHistoryWriterLock(url: paths.writerLockURL, timeout: timeout)
    }

    /// Marks a running indexer, owner or standby (`AgentHistoryPresenceLock`, shared). Busy only
    /// while another instance deletes the index. Never creates the index directory.
    func acquirePresenceLock(timeout: TimeInterval) throws -> AgentHistoryPresenceLock {
        try ensureLockDirectory()
        return try AgentHistoryPresenceLock(url: paths.presenceLockURL, timeout: timeout, exclusive: false)
    }

    /// Exclusive lifecycle ownership for "Delete Index" (D8): the presence lock exclusively (no
    /// indexer, owner or standby, runs on this index in any instance) and the writer lock (no
    /// indexer-less purge is writing), both held across `body`. Deleting the directory and
    /// resetting consent therefore finish before any instance can start on the index again, and
    /// the lock files outlive the directory (they sit beside it). Stop this process's indexer
    /// first: its own presence counts too. Throws `.busy`, without running `body`, when another
    /// instance keeps either lock past `timeout`. Never creates the index directory.
    func withExclusiveOwnership<T>(timeout: TimeInterval = 1, _ body: () throws -> T) throws -> T {
        try ensureLockDirectory()
        let presence = try AgentHistoryPresenceLock(url: paths.presenceLockURL, timeout: timeout, exclusive: true)
        defer { presence.release() }
        let writer = try AgentHistoryWriterLock(url: paths.writerLockURL, timeout: timeout)
        defer { writer.release() }
        return try body()
    }

    /// Creates the directory that holds the lock files (the index directory's parent).
    private func ensureLockDirectory() throws {
        do {
            try fileManager.createDirectory(at: paths.lockDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw AgentHistoryDatabaseError(kind: .cantOpen, code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                                            message: "cannot create the lock directory")
        }
    }

    /// Creates the directory and holds the cross-process setup lock (`AgentHistorySetupLock`)
    /// around `body`: header peek, create, migrate and quarantine all happen under it.
    private func withSetupLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try ensureDirectory()
        } catch {
            throw AgentHistoryDatabaseError(kind: .cantOpen, code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                                            message: "cannot create index directory")
        }
        let lock = try AgentHistorySetupLock(url: paths.lockURL, timeout: options.setupLockTimeout)
        defer { lock.unlock() }
        return try body()
    }

    private func openWriter(recovered: Bool) throws -> AgentHistoryWriterHandle {
        let prefix: [AgentHistoryOpenOutcome] = recovered ? [.recoveredFromCorruption] : []

        // Read the header without SQLite first, so an index from a newer Zentty is never opened
        // read-write (opening could change its journal mode) and a non-SQLite file never gets a WAL.
        switch peekHeader() {
        case .missing:
            // Orphaned -wal/-shm next to a missing database would be replayed into the new one.
            removeIfPresent(paths.walURL)
            removeIfPresent(paths.shmURL)
            fileManager.createFile(atPath: paths.databaseURL.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
        case .empty:
            break
        case .notSQLite:
            return try recover(from: AgentHistoryDatabaseError(
                kind: .notADatabase, code: SQLITE_NOTADB, extendedCode: SQLITE_NOTADB, message: "not a database"
            ), recovered: recovered)
        case .header(let applicationID, let userVersion):
            if applicationID == AgentHistorySchema.applicationID, userVersion > AgentHistorySchema.currentVersion {
                throw AgentHistoryDatabaseError.schemaTooNew(found: userVersion)
            }
        }

        let database: AgentHistoryDatabase
        do {
            database = try AgentHistoryDatabase(
                url: paths.databaseURL,
                mode: .readWrite,
                busyTimeoutMilliseconds: options.busyTimeoutMilliseconds
            )
        } catch let error as AgentHistoryDatabaseError where error.isCorruption {
            return try recover(from: error, recovered: recovered)
        }

        do {
            let outcomes = try prepareSchema(database)
            let tokenizer = try AgentHistorySchema.storedTokenizer(database) ?? .none
            return AgentHistoryWriterHandle(database: database, tokenizer: tokenizer, outcomes: prefix + outcomes)
        } catch let error as AgentHistoryDatabaseError {
            database.close()
            if case .schemaTooNew = error.kind { throw error }
            if Self.shouldQuarantine(error) {
                return try recover(from: error, recovered: recovered)
            }
            throw error
        }
    }

    /// Creates, migrates or checks the schema on an open writer. Throws `.schemaTooNew`, an
    /// `unusableIndex` error for foreign files, or whatever SQLite reports.
    private func prepareSchema(_ database: AgentHistoryDatabase) throws -> [AgentHistoryOpenOutcome] {
        // One snapshot: three separate reads could straddle another writer's commit and see
        // `user_version` 0 next to its new tables.
        let seen = try database.readTransaction { try SchemaState(database) }
        try seen.validate()
        let wanted = options.tokenizerOverride ?? AgentHistorySchema.probeTokenizer(database)
        var outcomes: [AgentHistoryOpenOutcome] = []

        if seen.version == AgentHistorySchema.currentVersion {
            outcomes.append(.opened)
        } else {
            options.beforeSchemaWriteForTesting?()
            let outcome = try database.transaction { () throws -> AgentHistoryOpenOutcome in
                // Decide again under the write lock: another writer may have created or migrated
                // the index since the snapshot, and running `createVersion1` over its tables would
                // fail in a way that looks quarantine-worthy.
                let state = try SchemaState(database)
                try state.validate()
                if state.version == 0 {
                    try AgentHistorySchema.createVersion1(database, tokenizer: wanted, now: now(), appVersion: appVersion)
                    try database.setUserVersion(AgentHistorySchema.currentVersion)
                    try database.setApplicationID(AgentHistorySchema.applicationID)
                    return .created
                }
                if state.version < AgentHistorySchema.currentVersion {
                    try AgentHistorySchema.migrate(database, from: state.version, tokenizer: wanted, now: now(),
                                                   appVersion: appVersion)
                    try database.setUserVersion(AgentHistorySchema.currentVersion)
                    return .migrated(from: state.version)
                }
                return .opened
            }
            if outcome == .created { return [.created] }
            outcomes.append(outcome)
        }

        let stored = try AgentHistorySchema.storedTokenizer(database)
        if stored != wanted {
            do {
                try AgentHistorySchema.rebuildFullText(database, to: wanted)
            } catch let error as AgentHistoryDatabaseError where !Self.shouldQuarantine(error) {
                throw error
            } catch {
                // A DROP that fails (an FTS table built with a tokenizer this SQLite lacks) leaves
                // only a full rebuild.
                throw Self.unusableIndex()
            }
            outcomes.append(.tokenizerChanged(from: stored, to: wanted))
        }
        return outcomes
    }

    /// Moves the unusable file aside and opens a fresh index, once.
    private func recover(from error: AgentHistoryDatabaseError, recovered: Bool) throws -> AgentHistoryWriterHandle {
        guard !recovered else { throw error }
        AgentHistoryLog.indexer.error(
            "Agent History index unusable code=\(error.code, privacy: .public)/\(error.extendedCode, privacy: .public); moving it aside"
        )
        do {
            try readers.fenced { try quarantineCorruptDatabase() }
        } catch {
            // Permission denied, a read-only volume, a locked file: the unusable index stays put.
            throw AgentHistoryDatabaseError(kind: .cantOpen, code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                                            message: "cannot move the unusable index aside")
        }
        return try openWriter(recovered: true)
    }

    /// Corruption, a foreign file, or a plain SQL error against our own schema (a missing table, an
    /// FTS tokenizer this SQLite lacks). Busy, full, read-only and I/O conditions are transient or
    /// environmental: they never cost the user their index.
    private static func shouldQuarantine(_ error: AgentHistoryDatabaseError) -> Bool {
        switch error.kind {
        case .corrupt, .notADatabase:
            return true
        case .other:
            return error.code == SQLITE_ERROR
        case .full, .busy, .readOnly, .cantOpen, .constraint, .interrupted, .schemaTooNew, .misuse:
            return false
        }
    }

    /// The header fields and object count that decide create / migrate / open / refuse.
    private struct SchemaState {
        let applicationID: Int32
        let version: Int32
        let objectCount: Int64

        init(_ database: AgentHistoryDatabase) throws {
            applicationID = try database.applicationID()
            version = try database.userVersion()
            objectCount = try database.scalarInt64("SELECT count(*) FROM sqlite_master") ?? 0
        }

        /// Throws `.schemaTooNew` for a newer index of ours and `unusableIndex` for a foreign file.
        func validate() throws {
            let ours = AgentHistorySchema.applicationID
            if applicationID == ours, version > AgentHistorySchema.currentVersion {
                throw AgentHistoryDatabaseError.schemaTooNew(found: version)
            }
            let isForeign = (applicationID != 0 && applicationID != ours)
                || (version == 0 && objectCount > 0)
                || (applicationID == 0 && version != 0)
            if isForeign {
                throw AgentHistoryStorage.unusableIndex()
            }
        }
    }

    fileprivate static func unusableIndex() -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: .notADatabase, code: SQLITE_NOTADB, extendedCode: SQLITE_NOTADB,
                                  message: "not an Agent History index")
    }

    // MARK: - Files

    /// Creates the directory with mode 0700 and excludes it from Time Machine (D6).
    func ensureDirectory() throws {
        let directoryURL = paths.directoryURL
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        // `createDirectory` leaves an existing directory's mode alone.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        // The index holds conversation text: a backup would outlive "Delete Index". Best effort.
        var excludedURL = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try excludedURL.setResourceValues(values)
        } catch {
            AgentHistoryLog.indexer.error("Agent History couldn't exclude the index from backups")
        }
    }

    /// Renames `index.sqlite` to `index.corrupt-<date>.sqlite`, removes its -wal/-shm and every
    /// older corrupt copy (D7). The writer must be closed.
    func quarantineCorruptDatabase() throws {
        var keptName: String?
        if fileManager.fileExists(atPath: paths.databaseURL.path) {
            let destination = paths.corruptDatabaseURL(at: now())
            removeIfPresent(destination)
            try fileManager.moveItem(at: paths.databaseURL, to: destination)
            keptName = destination.lastPathComponent
        }
        removeIfPresent(paths.walURL)
        removeIfPresent(paths.shmURL)

        let names = (try? fileManager.contentsOfDirectory(atPath: paths.directoryURL.path)) ?? []
        for name in names where AgentHistoryPaths.isCorruptCopyName(name) && name != keptName {
            removeIfPresent(paths.directoryURL.appendingPathComponent(name, isDirectory: false))
        }
    }

    /// Removes `index.sqlite` and its -wal/-shm; keeps `state.json`. Readers are fenced while the
    /// files go (see `AgentHistoryReaderPool.fenced`).
    func removeIndexFiles() throws {
        try readers.fenced {
            for url in [paths.databaseURL, paths.walURL, paths.shmURL] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        availabilityBox.update(availability: .ready, tokenizer: nil)
    }

    /// Removes the whole directory (index, corrupt copies, `state.json`) with readers fenced.
    /// Only inside `withExclusiveOwnership`: another instance may otherwise still write here.
    func removeEverything() throws {
        try readers.fenced {
            if fileManager.fileExists(atPath: paths.directoryURL.path) {
                try fileManager.removeItem(at: paths.directoryURL)
            }
        }
        availabilityBox.update(availability: .ready, tokenizer: nil)
    }

    /// Bytes on disk of the database and its -wal/-shm.
    func diskUsageBytes() -> Int64 {
        [paths.databaseURL, paths.walURL, paths.shmURL].reduce(into: Int64(0)) { total, url in
            if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
    }

    // MARK: - Internals

    private enum Header {
        case missing, empty, notSQLite
        case header(applicationID: Int32, userVersion: Int32)
    }

    /// Reads the 100-byte SQLite header. In WAL mode the header can lag the WAL, so the SQL checks
    /// in `prepareSchema` still run; this only keeps us from opening files we must not touch.
    private func peekHeader() -> Header {
        let path = paths.databaseURL.path
        guard fileManager.fileExists(atPath: path) else { return .missing }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .empty }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 100)) ?? Data()
        if bytes.isEmpty { return .empty }
        let magic = Data("SQLite format 3\u{0}".utf8)
        guard bytes.count == 100, bytes.prefix(16) == magic else { return .notSQLite }
        return .header(applicationID: Self.bigEndianInt32(bytes, at: 68),
                       userVersion: Self.bigEndianInt32(bytes, at: 60))
    }

    private static func bigEndianInt32(_ data: Data, at offset: Int) -> Int32 {
        let start = data.startIndex + offset
        let value = data[start ..< start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int32(bitPattern: value)
    }

    /// SQLite gives -wal/-shm the database's mode, but a file created before the 0600 pre-create
    /// (or by an older build) may be wider. Best effort.
    private func tightenFilePermissions() {
        for url in [paths.databaseURL, paths.walURL, paths.shmURL] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                AgentHistoryLog.indexer.error("Agent History couldn't restrict index file permissions")
            }
        }
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            AgentHistoryLog.indexer.error("Agent History couldn't remove an index file")
        }
    }
}
