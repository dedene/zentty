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
    /// opens with `immutable=1`, which reads the main file only and creates nothing.
    ///
    /// Every read is re-checked afterwards and counts as unstable when
    /// - immutable: the main file or its `-wal` changed (a writer appeared or checkpointed);
    /// - regular: the `-wal` seen before the open vanished or was replaced (the writer closed
    ///   between the check and the open, so the open met the no-`-wal` state above).
    /// An unstable result is discarded, and so is an error thrown by an unstable read (a torn
    /// read, or the open failing in that window); the read runs once more, choosing the mode
    /// from the new state. Two unstable reads throw `.busy` so the caller retries later. Errors
    /// from a stable read propagate as-is. Sidecar files are never deleted here: one that this
    /// read may have created cannot be told apart from one a writer just created.
    static func readExternalSnapshot<T>(
        url: URL,
        busyTimeoutMilliseconds: Int32 = 250,
        _ body: (AgentHistoryDatabase) throws -> T
    ) throws -> T {
        for attempt in 1...2 {
            let before = ExternalDatabaseFileState(path: url.path)
            let immutable = before.needsImmutableOpen
            let outcome: Result<T, Error>
            do {
                let database = try openExternalReadOnly(
                    url: url,
                    busyTimeoutMilliseconds: busyTimeoutMilliseconds,
                    immutable: immutable
                )
                defer { database.close() }
                outcome = .success(try database.readTransaction { try body(database) })
            } catch {
                outcome = .failure(error)
            }
            let after = ExternalDatabaseFileState(path: url.path)
            guard before.isUnstableRead(immutable: immutable, after: after) else {
                return try outcome.get()
            }
            AgentHistoryLog.indexer.info(
                "External database changed during a read immutable=\(immutable, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        }
        throw AgentHistoryDatabaseError(kind: .busy, code: SQLITE_BUSY, extendedCode: SQLITE_BUSY,
                                        message: "database changed during the read")
    }
}

/// What `readExternalSnapshot` compares before and after a read: the main file's identity,
/// size and mtime, whether its header says WAL, and whether (and as which inode) `-wal` exists.
private struct ExternalDatabaseFileState: Equatable {
    private static let headerMagic = Array("SQLite format 3\0".utf8)

    let exists: Bool
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedNanoseconds: Int64
    let isWALDatabase: Bool
    let walExists: Bool
    let walInode: UInt64

    /// A WAL-mode database with no `-wal`: plain read-only opens fail on it.
    var needsImmutableOpen: Bool { exists && isWALDatabase && !walExists }

    /// Immutable reads need the whole state unchanged. Regular reads only need the `-wal` seen
    /// before the open to still be the same file: a live writer may checkpoint freely.
    func isUnstableRead(immutable: Bool, after: ExternalDatabaseFileState) -> Bool {
        if immutable {
            return after != self
        }
        return walExists && (!after.walExists || after.walInode != walInode)
    }

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
        walInode = walExists ? UInt64(walInfo.st_ino) : 0
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
