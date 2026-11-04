import Foundation
import SQLite3

/// Availability and tokenizer shared by `AgentHistoryStorage` and its reader pool.
/// Every member is guarded by `lock`, so any thread may read or update it.
final class AgentHistoryAvailabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAvailability: AgentHistoryAvailability = .ready
    private var storedTokenizer: AgentHistoryTokenizer?

    var availability: AgentHistoryAvailability {
        lock.lock()
        defer { lock.unlock() }
        return storedAvailability
    }

    var tokenizer: AgentHistoryTokenizer? {
        lock.lock()
        defer { lock.unlock() }
        return storedTokenizer
    }

    func update(availability: AgentHistoryAvailability, tokenizer: AgentHistoryTokenizer?) {
        lock.lock()
        storedAvailability = availability
        storedTokenizer = tokenizer
        lock.unlock()
    }

    func update(availability: AgentHistoryAvailability) {
        lock.lock()
        storedAvailability = availability
        lock.unlock()
    }

    /// The error a reader throws while the index is not `.ready`; nil when it is.
    func unavailableError() -> AgentHistoryDatabaseError? {
        switch availability {
        case .ready:
            return nil
        case .readOnlyNewerSchema(let found):
            return .schemaTooNew(found: found)
        case .unavailable(let kind):
            return AgentHistoryDatabaseError(kind: kind, code: 0, extendedCode: 0, message: "index unavailable")
        }
    }
}

/// A small pool of `.readOnly` connections to the index for search, transcript loads and IPC.
///
/// Thread-safe: `withReader` may be called from any thread and blocks until a connection is free
/// (at most `readerCount` are checked out). A connection is owned by exactly one caller while
/// checked out (the `AgentHistoryDatabase` confinement rule); the pool's own bookkeeping is
/// guarded by `lock`. Connections open lazily. `closeAll()` bumps the generation: idle connections
/// close at once, checked-out ones close when they come back. `fenced` does the same around a file
/// operation and refuses new checkouts until it ends, so no connection to a removed or moved file
/// is ever pooled.
///
/// `revoke()` (Agent History turned off, or its index deleted) shuts every reader out until
/// `reopen()`: checkouts throw `.revoked`, connections in use are interrupted and closed on return,
/// and a read that was in flight throws `.revoked` instead of returning what it read. A handle to
/// the pool obtained earlier (a search engine) therefore cannot reopen the index while it is off.
final class AgentHistoryReaderPool: @unchecked Sendable {
    let databaseURL: URL
    let readerCount: Int

    private let busyTimeoutMilliseconds: Int32
    private let availabilityBox: AgentHistoryAvailabilityBox
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var fenceDepth = 0
    private var revoked = false
    /// Bumped by every `revoke()`; a read that saw another value at its start throws `.revoked`.
    private var storedRevocationEpoch: UInt64 = 0
    private var idle: [AgentHistoryDatabase] = []
    private var checkedOut: [ObjectIdentifier: AgentHistoryDatabase] = [:]

    init(
        databaseURL: URL,
        readerCount: Int,
        busyTimeoutMilliseconds: Int32,
        availabilityBox: AgentHistoryAvailabilityBox
    ) {
        self.databaseURL = databaseURL
        self.readerCount = max(1, readerCount)
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.availabilityBox = availabilityBox
        self.slots = DispatchSemaphore(value: max(1, readerCount))
    }

    deinit {
        for database in idle { database.close() }
    }

    /// Runs `body` with a read-only connection. Throws the availability error when the index is not
    /// `.ready` (a newer schema reads as `.schemaTooNew`, A-16), `.revoked` when the pool was
    /// revoked before or during the read, or the open error. The progress handler is always
    /// cleared when the connection comes back.
    func withReader<T>(_ body: (AgentHistoryDatabase) throws -> T) throws -> T {
        let epoch = try admissionEpoch()
        if let error = availabilityBox.unavailableError() { throw error }

        slots.wait()
        defer { slots.signal() }

        if let error = availabilityBox.unavailableError() { throw error }
        let (database, checkoutGeneration) = try checkOut(epoch: epoch)

        var keep = true
        defer { checkIn(database, generation: checkoutGeneration, keep: keep) }
        let result: T
        do {
            result = try body(database)
        } catch {
            if let error = error as? AgentHistoryDatabaseError, error.isCorruption {
                keep = false
            }
            // An interrupt from `revoke()` reads as the revocation, not as a database fault.
            try throwIfRevoked(since: epoch)
            throw error
        }
        try throwIfRevoked(since: epoch)
        return result
    }

    /// Shuts every reader out until `reopen()`: new checkouts throw `.revoked`, idle connections
    /// close now, checked-out ones are interrupted and closed when they come back, and reads in
    /// flight throw `.revoked`. Cheap and non-blocking, so it may run on main.
    func revoke() {
        lock.lock()
        revoked = true
        storedRevocationEpoch &+= 1
        generation &+= 1
        let closing = idle
        idle.removeAll()
        for database in checkedOut.values {
            database.interrupt()
        }
        lock.unlock()
        for database in closing {
            database.close()
        }
    }

    /// Lets readers in again after `revoke()`. Reads that started before stay revoked.
    func reopen() {
        lock.lock()
        revoked = false
        lock.unlock()
    }

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    /// Changes with every `revoke()`; an async read compares it before delivering its result.
    var revocationEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedRevocationEpoch
    }

    /// Interrupts every checked-out connection. Meant for shutdown; query cancellation uses the
    /// progress handler.
    func interruptAll() {
        lock.lock()
        defer { lock.unlock() }
        for database in checkedOut.values {
            database.interrupt()
        }
    }

    /// Closes idle connections now and checked-out ones when they are returned.
    func closeAll() {
        lock.lock()
        generation &+= 1
        let closing = idle
        idle.removeAll()
        lock.unlock()
        for database in closing {
            database.close()
        }
    }

    /// Runs `body` (removing or moving the index files) with the pool fenced: idle connections close
    /// now, checked-out ones when they come back, and `withReader` throws `.busy` until `body`
    /// returns. A reader that got past the fence check just before it closed still opens under the
    /// old generation, so it is closed on return instead of pooled against a deleted file.
    func fenced<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        fenceDepth += 1
        generation &+= 1
        let closing = idle
        idle.removeAll()
        lock.unlock()
        for database in closing {
            database.close()
        }
        defer {
            lock.lock()
            fenceDepth -= 1
            lock.unlock()
        }
        return try body()
    }

    var openConnectionCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return idle.count + checkedOut.count
    }

    // MARK: - Internals

    /// The revocation epoch a read starts under; throws `.revoked` while the pool is revoked.
    private func admissionEpoch() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if revoked { throw AgentHistoryDatabaseError.revoked() }
        return storedRevocationEpoch
    }

    private func throwIfRevoked(since epoch: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        if revoked || storedRevocationEpoch != epoch { throw AgentHistoryDatabaseError.revoked() }
    }

    private func checkOut(epoch: UInt64) throws -> (AgentHistoryDatabase, UInt64) {
        lock.lock()
        if revoked || storedRevocationEpoch != epoch {
            lock.unlock()
            throw AgentHistoryDatabaseError.revoked()
        }
        if fenceDepth > 0 {
            lock.unlock()
            throw AgentHistoryDatabaseError(kind: .busy, code: SQLITE_BUSY, extendedCode: SQLITE_BUSY,
                                            message: "index files are being replaced")
        }
        let checkoutGeneration = generation
        if let reused = idle.popLast() {
            checkedOut[ObjectIdentifier(reused)] = reused
            lock.unlock()
            return (reused, checkoutGeneration)
        }
        lock.unlock()

        let database = try AgentHistoryDatabase(
            url: databaseURL,
            mode: .readOnly,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        do {
            let version = try database.userVersion()
            if version > AgentHistorySchema.currentVersion {
                availabilityBox.update(availability: .readOnlyNewerSchema(found: version))
                throw AgentHistoryDatabaseError.schemaTooNew(found: version)
            }
        } catch {
            database.close()
            throw error
        }

        lock.lock()
        if revoked || storedRevocationEpoch != epoch {
            // Revoked while this connection was opening: it never reaches the caller.
            lock.unlock()
            database.close()
            throw AgentHistoryDatabaseError.revoked()
        }
        checkedOut[ObjectIdentifier(database)] = database
        lock.unlock()
        return (database, checkoutGeneration)
    }

    private func checkIn(_ database: AgentHistoryDatabase, generation checkoutGeneration: UInt64, keep: Bool) {
        database.setProgressHandler(everyInstructions: 0, nil)
        if database.isInTransaction {
            // A body that left a read transaction open must not pin a snapshot for the next caller.
            _ = try? database.execute("ROLLBACK")
        }

        lock.lock()
        checkedOut[ObjectIdentifier(database)] = nil
        let reuse = keep && checkoutGeneration == generation && database.isOpen
        if reuse {
            idle.append(database)
        }
        lock.unlock()

        if !reuse {
            database.close()
        }
    }
}

extension AgentHistoryDatabaseError {
    static func revoked() -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: .revoked, code: 0, extendedCode: 0, message: "Agent History is off")
    }

    static func schemaTooNew(found version: Int32) -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(
            kind: .schemaTooNew(found: version),
            code: 0,
            extendedCode: 0,
            message: "schema version \(version) is newer than \(AgentHistorySchema.currentVersion)"
        )
    }
}
