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
    /// Nothing is ever created or changed beside the agent's database. The open mode follows the
    /// sidecar files found before the open:
    /// - no `-wal` on a WAL database (its writer closed cleanly): a plain read-only connection
    ///   would have to create `-wal`/`-shm`, so the main file is read with `immutable=1`;
    /// - `-wal` present but `-shm` missing (lost to a cleanup tool, copy or sync): a plain
    ///   read-only connection would create `-shm` next to the database, and `immutable=1` would
    ///   drop the commits still in `-wal`. The main file and `-wal` are copied into a private
    ///   0700 directory (an APFS clone when possible, else a full copy capped by `copyPolicy`)
    ///   and the copy is read and then removed. Over the cap the read throws `.busy`;
    /// - otherwise (rollback journal, or `-wal` and `-shm` both present): a plain `mode=ro` open.
    ///
    /// Every read is re-checked afterwards and counts as unstable when
    /// - immutable: the main file or its sidecars changed (a writer appeared or checkpointed);
    /// - private copy: the main file or its sidecars changed while they were being copied;
    /// - regular: the `-wal` seen before the open vanished or was replaced (the writer closed
    ///   between the check and the open, so the open met the no-`-wal` state above).
    /// An unstable result is discarded, and so is an error thrown by an unstable read (a torn
    /// read, or the open failing in that window); the read runs once more, choosing the mode
    /// from the new state. Two unstable reads throw `.busy` so the caller retries later. Errors
    /// from a stable read propagate as-is.
    static func readExternalSnapshot<T>(
        url: URL,
        busyTimeoutMilliseconds: Int32 = 250,
        copyPolicy: ExternalSnapshotCopyPolicy = .standard,
        _ body: (AgentHistoryDatabase) throws -> T
    ) throws -> T {
        for attempt in 1...2 {
            let before = ExternalDatabaseFileState(path: url.path)
            let strategy = before.openStrategy
            let outcome: Result<T, Error>
            let stable: Bool
            switch strategy {
            case .regular, .immutable:
                let immutable = strategy == .immutable
                outcome = Result {
                    try readOnce(url: url, busyTimeoutMilliseconds: busyTimeoutMilliseconds, immutable: immutable, body)
                }
                stable = !before.isUnstableRead(immutable: immutable, after: ExternalDatabaseFileState(path: url.path))
            case .privateCopy:
                (outcome, stable) = try readPrivateCopy(
                    of: url, before: before, policy: copyPolicy,
                    busyTimeoutMilliseconds: busyTimeoutMilliseconds, body
                )
            }
            if stable {
                return try outcome.get()
            }
            AgentHistoryLog.indexer.info(
                "External database changed during a read mode=\(strategy.logName, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        }
        throw changedDuringRead
    }

    private static var changedDuringRead: AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: .busy, code: SQLITE_BUSY, extendedCode: SQLITE_BUSY,
                                  message: "database changed during the read")
    }

    private static func readOnce<T>(
        url: URL,
        busyTimeoutMilliseconds: Int32,
        immutable: Bool,
        _ body: (AgentHistoryDatabase) throws -> T
    ) throws -> T {
        let database = try openExternalReadOnly(url: url, busyTimeoutMilliseconds: busyTimeoutMilliseconds,
                                                immutable: immutable)
        defer { database.close() }
        return try database.readTransaction { try body(database) }
    }

    /// Copies the main file and `-wal` into a private directory and reads the copy there, where
    /// SQLite may create its `-shm`. The copy is stable when the originals did not change while
    /// being copied; after that nothing else can write to it. A copy over the cap throws `.busy`.
    private static func readPrivateCopy<T>(
        of url: URL,
        before: ExternalDatabaseFileState,
        policy: ExternalSnapshotCopyPolicy,
        busyTimeoutMilliseconds: Int32,
        _ body: (AgentHistoryDatabase) throws -> T
    ) throws -> (Result<T, Error>, stable: Bool) {
        let copy: ExternalDatabasePrivateCopy
        do {
            copy = try ExternalDatabasePrivateCopy(of: url, expectedBytes: before.size + before.walSize, policy: policy)
        } catch let error as AgentHistoryDatabaseError where error.kind == .busy {
            throw error // over the copy cap: retrying now would not help
        } catch {
            return (.failure(error), stable: ExternalDatabaseFileState(path: url.path) == before)
        }
        defer { copy.remove() }
        guard ExternalDatabaseFileState(path: url.path) == before else {
            return (.failure(changedDuringRead), stable: false)
        }
        return (Result {
            try readOnce(url: copy.databaseURL, busyTimeoutMilliseconds: busyTimeoutMilliseconds, immutable: false, body)
        }, stable: true)
    }
}

/// How `readExternalSnapshot` copies a WAL database whose `-shm` is missing.
struct ExternalSnapshotCopyPolicy: Sendable {
    /// Parent of the private per-read directory (0700, removed after the read). Created 0700
    /// when missing; its own parent never is.
    var parentDirectory: URL
    /// Cap on main file + `-wal` bytes for a full data copy. APFS clones share blocks with the
    /// originals, cost no space up front, and are not capped.
    var fullCopyByteLimit: Int64
    /// Tests turn cloning off to exercise the full-copy path and its cap.
    var allowsClone: Bool

    static let standardFullCopyByteLimit: Int64 = 256 * 1024 * 1024
    /// Name prefix of each per-read directory (`mkdtemp` adds six characters).
    static let directoryPrefix = "zentty-agent-history-read."

    /// The temp directory. Only for callers with no index directory (tests, tools); the indexer
    /// uses `index(_:)`.
    static let standard = ExternalSnapshotCopyPolicy(
        parentDirectory: FileManager.default.temporaryDirectory,
        fullCopyByteLimit: standardFullCopyByteLimit,
        allowsClone: true
    )

    /// Copies go to `AgentHistory/snapshots/`: "Delete Index" removes them with the directory,
    /// and `AgentHistoryStorage.openWriter` sweeps any a crash left behind.
    static func index(_ paths: AgentHistoryPaths) -> ExternalSnapshotCopyPolicy {
        ExternalSnapshotCopyPolicy(
            parentDirectory: paths.snapshotsDirectoryURL,
            fullCopyByteLimit: standardFullCopyByteLimit,
            allowsClone: true
        )
    }
}

/// A private copy of an external database and its `-wal`, named so SQLite pairs them.
private struct ExternalDatabasePrivateCopy {
    let directory: URL
    let databaseURL: URL

    init(of source: URL, expectedBytes: Int64, policy: ExternalSnapshotCopyPolicy) throws {
        try Self.ensureParent(policy.parentDirectory)
        var template = Array(policy.parentDirectory
            .appendingPathComponent(ExternalSnapshotCopyPolicy.directoryPrefix + "XXXXXX").path.utf8CString)
        // mkdtemp(3) creates the directory with mode 0700.
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw Self.copyError("could not create a private snapshot directory", errno: errno)
        }
        directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        databaseURL = directory.appendingPathComponent("snapshot.sqlite")
        do {
            let pairs = [(source.path, databaseURL.path), (source.path + "-wal", databaseURL.path + "-wal")]
            var cloned = false
            if policy.allowsClone {
                cloned = pairs.allSatisfy { clonefile($0.0, $0.1, UInt32(CLONE_NOOWNERCOPY)) == 0 }
            }
            if !cloned {
                guard expectedBytes <= policy.fullCopyByteLimit else {
                    throw AgentHistoryDatabaseError(
                        kind: .busy, code: SQLITE_BUSY, extendedCode: SQLITE_BUSY,
                        message: "database without -shm is too large to copy (\(expectedBytes) bytes)"
                    )
                }
                for (from, to) in pairs {
                    unlink(to)
                    guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                        throw Self.copyError("could not copy the database", errno: errno)
                    }
                }
            }
        } catch {
            remove()
            throw error
        }
    }

    /// Removes the private directory, including the `-shm` SQLite created there. A failure is
    /// logged; `AgentHistoryStorage.openWriter` sweeps leftovers inside the index directory.
    func remove() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            let code = (error as NSError).code
            AgentHistoryLog.indexer.error("Agent History couldn't remove a database snapshot code=\(code, privacy: .public)")
        }
    }

    /// Creates the parent (0700) when it is missing. Only the last component: a missing index
    /// directory (deleted while a read ran) is never recreated here.
    private static func ensureParent(_ parent: URL) throws {
        guard mkdir(parent.path, 0o700) == 0 || errno == EEXIST else {
            throw copyError("could not create the snapshots directory", errno: errno)
        }
    }

    private static func copyError(_ message: String, errno code: Int32) -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: .cantOpen, code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                                  message: "\(message): \(String(cString: strerror(code)))")
    }
}

/// How `readExternalSnapshot` opens an external database (see its documentation).
private enum ExternalOpenStrategy {
    case regular, immutable, privateCopy

    var logName: String {
        switch self {
        case .regular: "regular"
        case .immutable: "immutable"
        case .privateCopy: "privateCopy"
        }
    }
}

/// What `readExternalSnapshot` compares before and after a read: the main file's identity,
/// size and mtime, whether its header says WAL, `-wal`'s identity, size and mtime, and whether
/// `-shm` exists.
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
    let walSize: Int64
    let walModifiedNanoseconds: Int64
    let shmExists: Bool

    /// - A WAL database with no `-wal`: plain read-only opens fail on it.
    /// - A `-wal` with no `-shm`: a plain read-only open creates `-shm` beside the database.
    var openStrategy: ExternalOpenStrategy {
        guard exists, isWALDatabase || walExists else { return .regular }
        if !walExists { return .immutable }
        return shmExists ? .regular : .privateCopy
    }

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
            modifiedNanoseconds = Self.nanoseconds(info.st_mtimespec)
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
        walSize = walExists ? Int64(walInfo.st_size) : 0
        walModifiedNanoseconds = walExists ? Self.nanoseconds(walInfo.st_mtimespec) : 0
        var shmInfo = stat()
        shmExists = stat(path + "-shm", &shmInfo) == 0
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
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
