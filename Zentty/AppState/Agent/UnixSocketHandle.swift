import Darwin
import Foundation

/// RAII-style owner for a raw POSIX file descriptor (typically an `AF_UNIX`
/// socket). It exists to collapse the hand-rolled `close(fd)` / `unlink(path)`
/// bookkeeping that otherwise has to be repeated across every early-return
/// error branch while a listener socket is being set up.
///
/// Guarantees:
/// - **Close-once.** The descriptor is closed at most once — on the first
///   `close()` or on `deinit` — and the stored descriptor is invalidated to
///   `-1` afterward, so a second `close()` is a silent no-op.
/// - **Optional path unlink.** A listener socket bound to a filesystem path can
///   register that path via `unlinkPathOnClose(_:)`. The path is `unlink`ed
///   (once) whenever the handle closes *while it still owns* the descriptor,
///   i.e. on an error/teardown before ownership is transferred elsewhere.
/// - **Explicit ownership transfer.** When a longer-lived owner takes over the
///   descriptor's lifetime — e.g. a `DispatchSource` cancel handler that will
///   `close()` it itself — call `takeOwnership()` to relinquish. After that the
///   handle owns nothing and neither closes the fd nor unlinks the path.
///
/// Not thread-safe: callers confine a handle to a single queue/thread for the
/// duration of setup, exactly as the raw fd was confined before.
final class UnixSocketHandle {
    /// The owned descriptor, or `-1` once closed or relinquished.
    private(set) var fileDescriptor: Int32

    /// Socket path to `unlink` when this handle closes while still owning the
    /// descriptor. `nil` for non-listener descriptors or once relinquished.
    private var unlinkPath: String?

    /// Wrap an already-created descriptor. `fileDescriptor` should be `>= 0`.
    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Create a new socket and wrap it. Throws `POSIXError` (from `errno`) if
    /// `socket()` fails, matching the previous inline behavior.
    convenience init(domain: Int32, type: Int32, protocol proto: Int32) throws {
        let descriptor = socket(domain, type, proto)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        self.init(fileDescriptor: descriptor)
    }

    /// `true` while the handle still owns a live descriptor.
    var isValid: Bool { fileDescriptor >= 0 }

    /// Register a socket path to be `unlink`ed if this handle closes while it
    /// still owns the descriptor. Use for listener sockets after `bind`ing so a
    /// failure part-way through setup cleans up the bound socket file, matching
    /// the old `close(fd); unlink(path)` error branches.
    func unlinkPathOnClose(_ path: String) {
        unlinkPath = path
    }

    /// Relinquish ownership of the descriptor to a new owner, returning the raw
    /// value. After this call the handle no longer closes the fd or unlinks the
    /// path, so the new owner is solely responsible for closing it exactly once.
    @discardableResult
    func takeOwnership() -> Int32 {
        let descriptor = fileDescriptor
        fileDescriptor = -1
        unlinkPath = nil
        return descriptor
    }

    /// Close the descriptor (once) and, if one was registered, `unlink` the
    /// socket path. Idempotent: a no-op once closed or relinquished.
    func close() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
        if let unlinkPath {
            unlink(unlinkPath)
            self.unlinkPath = nil
        }
    }

    deinit {
        close()
    }
}
