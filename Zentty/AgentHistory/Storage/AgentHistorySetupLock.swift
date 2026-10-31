import Darwin
import Foundation
import SQLite3

/// An exclusive `flock` on `index.lock` beside the index, held while `openWriter` creates,
/// migrates or quarantines the index. Zentty instances of one flavor share the directory: without
/// the lock two of them could both see a missing or empty file, and one could move aside (and
/// delete the WAL of) an index the other had just built.
///
/// `flock` locks belong to the open file description, so two locks in one process exclude each
/// other too: a holder must not take it again. Confinement: the indexer queue, like `openWriter`.
final class AgentHistorySetupLock {
    private var descriptor: Int32

    /// Waits up to `timeout` for the lock. Throws `.busy` when another holder keeps it that long and
    /// `.cantOpen` when the lock file can't be opened.
    init(url: URL, timeout: TimeInterval, busyMessage: String = "another process is setting up the index") throws {
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw AgentHistoryDatabaseError(kind: .cantOpen, code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                                            message: "cannot open the index lock file")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            guard failure == EWOULDBLOCK, Date() < deadline else {
                Darwin.close(fd)
                if failure == EWOULDBLOCK {
                    throw AgentHistoryDatabaseError(kind: .busy, code: SQLITE_BUSY, extendedCode: SQLITE_BUSY,
                                                    message: busyMessage)
                }
                throw AgentHistoryDatabaseError(kind: .cantOpen, code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                                                message: "cannot lock the index lock file")
            }
            usleep(20_000)
        }
        descriptor = fd
    }

    deinit {
        unlock()
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

/// Exclusive ownership of the index for writing: an `flock` on `index.writer.lock`, held by one
/// indexer from start to stop. Zentty instances of one flavor share the index; only the holder
/// opens a writer, rebuilds, quarantines or purges, so no instance ever deletes or renames files
/// another one is writing (a second instance would keep committing to an unlinked inode and,
/// on close, remove the new index's WAL by path). The others wait read-only (standby).
///
/// Like the setup lock it excludes other holders in this process too, so an indexer that is
/// still tearing down keeps the next one out. Thread-safe.
final class AgentHistoryWriterLock: @unchecked Sendable {
    private let lock = NSLock()
    private var held: AgentHistorySetupLock?

    /// Waits up to `timeout`; throws `.busy` when another indexer owns the index.
    init(url: URL, timeout: TimeInterval) throws {
        held = try AgentHistorySetupLock(url: url, timeout: timeout,
                                         busyMessage: "another Zentty is indexing")
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held != nil
    }

    /// Idempotent.
    func release() {
        lock.lock()
        let released = held
        held = nil
        lock.unlock()
        released?.unlock()
    }

    deinit {
        release()
    }
}
