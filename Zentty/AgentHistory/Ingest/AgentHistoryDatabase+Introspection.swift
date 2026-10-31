import Foundation
import SQLite3

/// Schema probes and snapshot reads for other agents' databases (Codex `state_5`, opencode).
/// Their schemas change between CLI versions, so adapters check what exists before building a
/// query instead of failing on a missing column. The probes are plain reads and work on every
/// connection mode, including `.externalReadOnly`.
extension AgentHistoryDatabase {
    /// Column names of `table` (via `PRAGMA table_info`), or an empty set when there is no such
    /// table or view. The name is bound, never interpolated into SQL.
    func columns(of table: String) throws -> Set<String> {
        Set(try query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) })
    }

    /// Whether a table or view named `name` exists in the main schema. Indexes and triggers do not count.
    func tableExists(_ name: String) throws -> Bool {
        try queryOne(
            "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ? LIMIT 1",
            [.text(name)]
        ) { _ in true } ?? false
    }

    /// Opens another agent's database read-only, runs `body` in one short read transaction, and
    /// closes the connection. `body` must not keep the database or its rows.
    ///
    /// A WAL database whose `-wal` file is absent (its writer closed cleanly) cannot be read by a
    /// plain read-only connection: SQLite would have to create `-wal`/`-shm` next to it. That case
    /// opens with `immutable=1`, which reads the main file only and creates nothing; afterwards the
    /// file is re-checked, and if a `-wal` appeared or the file changed during the read, the result
    /// is discarded and the read runs again on a regular read-only connection. A second unstable
    /// immutable read throws `.busy` so the caller retries later.
    static func readExternalSnapshot<T>(
        url: URL,
        busyTimeoutMilliseconds: Int32 = 250,
        _ body: (AgentHistoryDatabase) throws -> T
    ) throws -> T {
        for attempt in 1...2 {
            let before = ExternalDatabaseFileState(path: url.path)
            let immutable = before.needsImmutableOpen
            let database = try openExternalReadOnly(
                url: url,
                busyTimeoutMilliseconds: busyTimeoutMilliseconds,
                immutable: immutable
            )
            let result: T
            do {
                result = try database.readTransaction { try body(database) }
            } catch {
                database.close()
                throw error
            }
            database.close()
            guard immutable, ExternalDatabaseFileState(path: url.path) != before else { return result }
            AgentHistoryLog.indexer.info(
                "External database changed during an immutable read attempt=\(attempt, privacy: .public)"
            )
        }
        throw AgentHistoryDatabaseError(kind: .busy, code: SQLITE_BUSY, extendedCode: SQLITE_BUSY,
                                        message: "database changed during an immutable read")
    }
}

/// What `readExternalSnapshot` compares before and after an immutable read: the main file's
/// identity, size and mtime, whether its header says WAL, and whether `-wal` exists.
private struct ExternalDatabaseFileState: Equatable {
    private static let headerMagic = Array("SQLite format 3\0".utf8)

    let exists: Bool
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedNanoseconds: Int64
    let isWALDatabase: Bool
    let walExists: Bool

    /// A WAL-mode database with no `-wal`: plain read-only opens fail on it.
    var needsImmutableOpen: Bool { exists && isWALDatabase && !walExists }

    init(path: String) {
        var info = stat()
        if stat(path, &info) == 0 {
            exists = true
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            isWALDatabase = Self.headerSaysWAL(path: path)
        } else {
            exists = false
            device = 0
            inode = 0
            size = 0
            modifiedNanoseconds = 0
            isWALDatabase = false
        }
        var walInfo = stat()
        walExists = stat(path + "-wal", &walInfo) == 0
    }

    /// Header bytes 18/19 (file format write/read version) are 2 for WAL mode.
    private static func headerSaysWAL(path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: 20)
        let count = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, 20, 0) }
        guard count == 20, Array(header[0..<16]) == headerMagic else { return false }
        return header[18] == 2 || header[19] == 2
    }
}
