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
    init(url: URL, timeout: TimeInterval) throws {
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
                                                    message: "another process is setting up the index")
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
