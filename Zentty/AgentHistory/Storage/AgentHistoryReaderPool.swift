import Foundation

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
/// close at once, checked-out ones close when they come back.
final class AgentHistoryReaderPool: @unchecked Sendable {
    let databaseURL: URL
    let readerCount: Int

    private let busyTimeoutMilliseconds: Int32
    private let availabilityBox: AgentHistoryAvailabilityBox
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var generation: UInt64 = 0
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
    /// `.ready` (a newer schema reads as `.schemaTooNew`, A-16), or the open error. The progress
    /// handler is always cleared when the connection comes back.
    func withReader<T>(_ body: (AgentHistoryDatabase) throws -> T) throws -> T {
        if let error = availabilityBox.unavailableError() { throw error }

        slots.wait()
        defer { slots.signal() }

        if let error = availabilityBox.unavailableError() { throw error }
        let (database, checkoutGeneration) = try checkOut()

        var keep = true
        defer { checkIn(database, generation: checkoutGeneration, keep: keep) }
        do {
            return try body(database)
        } catch let error as AgentHistoryDatabaseError where error.isCorruption {
            keep = false
            throw error
        }
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

    var openConnectionCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return idle.count + checkedOut.count
    }

    // MARK: - Internals

    private func checkOut() throws -> (AgentHistoryDatabase, UInt64) {
        lock.lock()
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
    static func schemaTooNew(found version: Int32) -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(
            kind: .schemaTooNew(found: version),
            code: 0,
            extendedCode: 0,
            message: "schema version \(version) is newer than \(AgentHistorySchema.currentVersion)"
        )
    }
}
