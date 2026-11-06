import Foundation

struct AgentHistoryIndexerConfiguration: Sendable, Equatable {
    var enabledAgents: Set<AgentHistoryAgent>
    var excludedFolders: [String]
    var fileEventLatency: TimeInterval = 2.0
    var limits = AgentHistoryIngestLimits()
}

/// A flag set once from any thread (stop) and read by adapters through `context.isCancelled`.
final class AgentHistoryCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// What the indexer knows about one source while it runs. Confined to the indexer queue.
final class AgentHistoryIndexerSourceState {
    let source: any AgentHistorySource
    let id: Int64
    /// Units from the last discovery, refreshed one by one as they are processed.
    var units: [String: AgentHistoryUnit] = [:]
    /// Mirror of the persisted cursors, updated after every commit.
    var cursors: [String: AgentHistoryCursor]
    var discoveryProblem: AgentHistorySourceProblem?
    /// The last problem each unit's batch reported (`batch.problem`); cleared by a clean batch.
    var unitProblems: [String: AgentHistorySourceProblem] = [:]
    /// Sessions skipped for a reason the user did not choose (invalid id, unreadable, format).
    var skippedSessionIDs: Set<String> = []
    var skippedRecords = 0
    var discovered = 0
    var indexed = 0
    var lastScanAt: Date?
    var countersDirty = true
    /// When a full reconcile first found the root missing; cleared once it is back. The source
    /// is purged only when a later full reconcile, `schedule.interval` on, still misses it.
    var rootMissingSince: Date?
    /// Missing units (keys) held back by the mass-deletion guard until the next full reconcile.
    var deferredMissingUnits: Set<String>?
    /// Vanished database sessions (native ids) held back by the mass-deletion guard.
    var deferredVanishedIDs: Set<String>?
    /// The adapter version to store once the source has drained after a version bump.
    var pendingAdapterVersion: Int?

    init(source: any AgentHistorySource, id: Int64, cursors: [String: AgentHistoryCursor]) {
        self.source = source
        self.id = id
        self.cursors = cursors
    }

    /// Discovery problems win; otherwise the problem of the first unit (by key) that has one.
    var problem: AgentHistorySourceProblem? {
        if let discoveryProblem {
            return discoveryProblem
        }
        return unitProblems.min { $0.key < $1.key }?.value
    }
}

/// Builds and maintains the Agent History index.
///
/// Everything below runs on one serial utility queue (`queueLabel`): the writer connection, the
/// store, the sources, the work queue and the snapshot builder (§3.19). Each batch is one
/// `queue.async` step, so `stop`, configuration changes and other writes interleave with a long
/// backfill. Every batch commits its rows and the unit's cursor in one transaction: a failure
/// before the commit leaves the previous cursor, and the retry re-reads the same slice.
///
/// Status and snapshot are published to main (`onStatusChange`, `onSnapshotChange`) at most
/// once a second, immediately on a state change and when the visible sessions first reach 50;
/// `currentStatus` / `currentSnapshot` are readable from any thread.
///
/// One instance runs once: after `stop` it ignores every call. Create a new one to restart.
final class AgentHistoryIndexer: @unchecked Sendable {
    static let queueLabel = "be.zenjoy.zentty.agent-history.indexer"
    /// Larger units are rewritten in normal batch commits instead of one transaction (A-8).
    static let defaultWholeUnitReplaceMaxBytes: Int64 = 64 << 20
    static let snapshotPublishThreshold = 50
    /// Unchanged units classified per step before yielding the queue.
    static let unchangedUnitsPerStep = 256
    static let backfillCompletedMetaKey = "backfill_completed_at"
    static let busyRetryDelay: TimeInterval = 1

    enum Lifecycle: Equatable {
        /// `standby`: another instance owns the index; retried every `standbyRetryInterval`.
        case idle, standby, running, failed, stopped
    }

    let queue = DispatchQueue(label: AgentHistoryIndexer.queueLabel, qos: .utility)
    let storage: AgentHistoryStorage
    let stateStore: AgentHistoryStateStore
    let makeSources: @Sendable () -> [any AgentHistorySource]
    let systemConditions: any AgentHistorySystemConditions
    let now: @Sendable () -> Date
    let onStatusChange: @MainActor @Sendable (AgentHistoryStatus) -> Void
    let onSnapshotChange: @MainActor @Sendable (AgentHistoryMetadataSnapshot) -> Void
    let cancellation = AgentHistoryCancellationFlag()
    let redactor = AgentHistoryRedactor.shared
    let repositories = RepositoryIdentityCache()

    // MARK: Queue-confined state

    var lifecycle: Lifecycle = .idle
    var configuration: AgentHistoryIndexerConfiguration
    /// Held from start to stop (`AgentHistoryWriterLock`); released on failure.
    var writerLock: AgentHistoryWriterLock?
    /// Held from start to stop, standby and failure included (`AgentHistoryPresenceLock`), so
    /// another instance's "Delete Index" never runs while this one may write or rebuild.
    var presenceLock: AgentHistoryPresenceLock?
    var writer: AgentHistoryDatabase?
    var store: AgentHistoryStore?
    var tokenizer: AgentHistoryTokenizer?
    var admission = AgentHistoryAdmission.admitAll
    var sourceStates: [Int64: AgentHistoryIndexerSourceState] = [:]
    var sourceOrder: [Int64] = []
    var workQueue = AgentHistoryWorkQueue()
    var snapshotBuilder = AgentHistoryMetadataSnapshotBuilder()
    var backfillEstimator = AgentHistoryBackfillEstimator()
    /// Sessions already indexed when the current backfill was scheduled.
    var backfillBaseline = 0
    var snapshotDirty = false
    var state: AgentHistoryIndexerState = .off
    /// Persisted: a full backfill finished once (the snapshot is complete).
    var isBackfillComplete = false
    /// In this run: the work queue drained once, so later work no longer reads as backfill.
    var hasDrainedOnce = false
    /// Units seen `.missing`, with the time they were first seen so (A-21). Deletion is the
    /// reconcile's job; here a moved unit is looked up again once.
    var missingSince: [AgentHistoryUnitRef: Date] = [:]
    var missingRechecked: Set<AgentHistoryUnitRef> = []
    var stepScheduled = false
    var schedule = AgentHistoryReconcileSchedule()
    var lastPublishUptime: TimeInterval?
    var lastPublishedStateName: String?
    var trailingPublishScheduled = false
    var reachedSnapshotThreshold = false
    var lastUpdatedAt: Date?
    var revision: UInt64 = 0
    /// Rewrites too large for one transaction, in progress; a WAL checkpoint follows the last batch.
    var batchedRewrites: Set<AgentHistoryUnitRef> = []
    /// Set before `start()` (tests shrink it).
    var wholeUnitReplaceMaxBytes = AgentHistoryIndexer.defaultWholeUnitReplaceMaxBytes
    /// Runs inside each commit transaction right before the cursor is saved; throwing rolls the
    /// batch back. Set before `start()`.
    var beforeCursorSaveForTesting: ((AgentHistoryUnitRef) throws -> Void)?
    /// Runs inside the carry-over restore transaction; throwing makes the restore fail.
    var beforeCarryOverRestoreForTesting: (() throws -> Void)?
    /// Runs inside a standby read, between the sessions and the tombstones; throwing fails it.
    var afterStandbySessionsReadForTesting: (() throws -> Void)?
    /// How long `start` waits for the writer lock before standing by. Set before `start()`.
    var writerLockWait: TimeInterval = 2
    /// How often a standby indexer tries to take over. Set before `start()`.
    var standbyRetryInterval: TimeInterval = 15
    var standbyRetryScheduled = false

    // MARK: Writes (AgentHistoryIndexer+Writes.swift)

    /// Tombstones and usage read before a rebuild, written into the new index once it opens.
    var pendingCarryOver: AgentHistoryRebuildCarryOver?
    /// Agents turned off whose rows are not deleted yet (`runPendingSourcePurges`).
    var pendingSourcePurges: Set<AgentHistoryAgent> = []
    /// Runs inside each source purge transaction; throwing makes the purge fail.
    var beforeSourcePurgeForTesting: ((AgentHistoryAgent) throws -> Void)?
    /// Database units that have not been read cleanly since the admission rules tightened; when
    /// the rules relax first, they are read again from the start.
    var admissionPendingUnits: Set<AgentHistoryUnitRef> = []

    // MARK: Conditions (AgentHistoryIndexer+Conditions.swift)

    /// SQLite reported a full disk: nothing writes until a retry finds space again.
    var isDiskFull = false
    var diskFullRetryScheduled = false
    /// A write or read found the index corrupt; recovery runs on the next queue turn.
    var corruptionRecoveryPending = false
    /// Mid-run recoveries in this run; past `maxCorruptionRecoveriesPerRun` the indexer fails.
    var corruptionRecoveries = 0

    // MARK: Freshness (AgentHistoryIndexer+Events.swift)

    var fileEventStream: FileEventStream?
    /// Longest canonical path first.
    var watchRoots: [AgentHistoryWatchRoot] = []
    var streamRefreshScheduled = false
    var streamRestartRequested = false
    var lastDatabasePollAt: [AgentHistoryUnitRef: Date] = [:]
    var pendingDatabasePolls: Set<AgentHistoryUnitRef> = []
    /// Event keys discovery did not list, with when that was checked.
    var unknownEventUnitsCheckedAt: [AgentHistoryUnitRef: Date] = [:]
    var periodicTimer: (any DispatchSourceTimer)?
    var wakeReconcileScheduled = false

    // MARK: Published (lock-protected)

    private let publishedLock = NSLock()
    private var publishedStatus = AgentHistoryStatus.off
    private var publishedSnapshot = AgentHistoryMetadataSnapshot.empty

    init(
        storage: AgentHistoryStorage,
        stateStore: AgentHistoryStateStore,
        makeSources: @escaping @Sendable () -> [any AgentHistorySource],
        configuration: AgentHistoryIndexerConfiguration,
        systemConditions: any AgentHistorySystemConditions = LiveAgentHistorySystemConditions(),
        now: @escaping @Sendable () -> Date = Date.init,
        onStatusChange: @escaping @MainActor @Sendable (AgentHistoryStatus) -> Void,
        onSnapshotChange: @escaping @MainActor @Sendable (AgentHistoryMetadataSnapshot) -> Void
    ) {
        self.storage = storage
        self.stateStore = stateStore
        self.makeSources = makeSources
        self.configuration = configuration
        self.systemConditions = systemConditions
        self.now = now
        self.onStatusChange = onStatusChange
        self.onSnapshotChange = onSnapshotChange
    }

    // MARK: - Public API

    /// Opens the index, publishes the stored sessions at once, then backfills newest first.
    func start() {
        queue.async { [self] in
            startOnQueue()
        }
    }

    /// Cancels in-flight work (a whole-unit transaction rolls back), closes the writer and
    /// publishes `.off`. Waits at most `timeout` for the queue (A-7); never blocks longer.
    func stop(timeout: TimeInterval = 1.0) {
        cancellation.set()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            teardownOnQueue()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            AgentHistoryLog.indexer.info("Agent History indexer stop timed out; teardown continues in the background")
        }
    }

    /// Cancels in-flight work and waits for the teardown to finish, however long the current
    /// step takes. Never on main: the controller's control queue uses it so the next indexer
    /// starts only once this one has closed its writer.
    func stopAndWait() {
        cancellation.set()
        queue.sync {
            teardownOnQueue()
        }
    }

    func update(configuration: AgentHistoryIndexerConfiguration) {
        queue.async { [self] in
            applyConfiguration(configuration)
        }
    }

    /// Re-discovers one source (or all, a full reconcile), queues every unit that changed and
    /// mirrors upstream deletions (see `AgentHistoryIndexer+Reconcile.swift`).
    func requestReconcile(sourceID: Int64? = nil) {
        queue.async { [self] in
            guard lifecycle == .running else {
                return
            }
            reconcileAndContinue(sourceIDs: sourceID.map { [$0] } ?? sourceOrder, isFull: sourceID == nil)
        }
    }

    var currentSnapshot: AgentHistoryMetadataSnapshot {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedSnapshot
    }

    var currentStatus: AgentHistoryStatus {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedStatus
    }

    func storePublished(status: AgentHistoryStatus?, snapshot: AgentHistoryMetadataSnapshot?) {
        publishedLock.lock()
        if let status {
            publishedStatus = status
        }
        if let snapshot {
            publishedSnapshot = snapshot
        }
        publishedLock.unlock()
    }

    // MARK: - Testing

    /// Runs every queued step on the calling thread (through the queue) until the work queue is
    /// empty or only paused backfill is left, then the idle bookkeeping, then publishes without
    /// throttling so `currentStatus` / `currentSnapshot` are current on return.
    func drainSynchronouslyForTesting() {
        queue.sync { [self] in
            while lifecycle == .running, !cancellation.isSet {
                if processNext() {
                    continue
                }
                if !becomeIdle() {
                    break
                }
            }
            if lifecycle == .running {
                publish(force: true)
            }
        }
    }

    var isWriterOpenForTesting: Bool {
        queue.sync { writer?.isOpen ?? false }
    }

    var sourceIDsForTesting: [Int64] {
        queue.sync { sourceOrder }
    }

    /// Handles file events as if the stream delivered them, synchronously on the queue.
    func handleFileEventsForTesting(_ events: [FileEvent]) {
        queue.sync {
            handleFileEvents(events)
        }
    }

    /// Canonical paths the FSEvents stream watches right now (empty when it is not running).
    var watchedPathsForTesting: [String] {
        queue.sync { fileEventStream?.watchedPaths ?? [] }
    }

    // MARK: - Lifecycle on the queue

    func startOnQueue() {
        guard lifecycle == .idle || lifecycle == .standby, !cancellation.isSet else {
            return
        }
        guard lifecycle != .standby || savedStateAllowsTakeover() else {
            return
        }
        guard acquirePresenceLockOrStandBy(), acquireWriterLockOrStandBy() else {
            return
        }
        lifecycle = .running
        setState(.starting)
        publish(force: true)

        // Before the index opens: an open that quarantines the old file leaves this list as
        // the only record of what the user removed.
        let recordedRemovals: [AgentHistoryRebuildCarryOver.Tombstone]
        do {
            recordedRemovals = try removalLedger.tombstones()
        } catch {
            AgentHistoryLog.indexer.error("Agent History could not read the removed-sessions list; not indexing")
            fail(.removalsUnreadable)
            return
        }

        let handle: AgentHistoryWriterHandle
        do {
            handle = try storage.openWriter()
        } catch let error as AgentHistoryDatabaseError {
            fail(Self.failureReason(for: error))
            return
        } catch {
            AgentHistoryLog.indexer.error("Agent History indexer could not open the index outside SQLite")
            fail(.openFailed(code: -1))
            return
        }
        writer = handle.database
        tokenizer = handle.tokenizer
        let store = AgentHistoryStore(database: handle.database, now: now)
        self.store = store

        do {
            try adoptRecordedRemovals(recordedRemovals, store: store)
            restorePendingCarryOver(into: store)
            admission = AgentHistoryAdmission(
                exclusions: AgentHistoryExclusionMatcher(folders: configuration.excludedFolders),
                tombstones: try tombstonesInForce(store: store)
            )
            snapshotBuilder.replaceAll(try store.allVisibleSessionSummaries())
            snapshotDirty = true
            isBackfillComplete = try store.meta(Self.backfillCompletedMetaKey) != nil
            reachedSnapshotThreshold = snapshotBuilder.count >= Self.snapshotPublishThreshold
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History indexer could not load the index \(error.description, privacy: .public)")
            fail(error.isCorruption ? .corrupt : .openFailed(code: error.code))
            return
        } catch {
            fail(.openFailed(code: -1))
            return
        }
        AgentHistoryLog.indexer.info("Agent History indexer started sessions=\(self.snapshotBuilder.count, privacy: .public)")

        purgeSourcesOfDisabledAgents()
        activateSources(makeSources(), includeStoredRoots: true)
        reconcileStoredExclusions()
        let conditionsQueue = queue
        systemConditions.startObserving { [weak self] in
            conditionsQueue.async {
                self?.conditionsChanged()
            }
        }
        startFreshness()
        updateProgressState()
        publish(force: true)
        scheduleStep()
    }

    func teardownOnQueue() {
        guard lifecycle != .stopped else {
            return
        }
        lifecycle = .stopped
        systemConditions.stopObserving()
        stopFreshness()
        writer?.close()
        writer = nil
        store = nil
        releaseWriterLock()
        presenceLock?.release()
        presenceLock = nil
        workQueue = AgentHistoryWorkQueue()
        setState(.off)
        publish(force: true)
        AgentHistoryLog.indexer.info("Agent History indexer stopped")
    }

    func fail(_ reason: AgentHistoryFailureReason) {
        systemConditions.stopObserving()
        stopFreshness()
        writer?.close()
        writer = nil
        store = nil
        // Another instance may manage where this one failed; Rebuild takes the lock again.
        releaseWriterLock()
        lifecycle = .failed
        setState(.failed(reason))
        publish(force: true)
    }

    static func failureReason(for error: AgentHistoryDatabaseError) -> AgentHistoryFailureReason {
        if case .schemaTooNew(let found) = error.kind {
            return .newerSchema(found: found)
        }
        if error.isCorruption {
            return .corrupt
        }
        return .openFailed(code: error.code)
    }

    func applyConfiguration(_ next: AgentHistoryIndexerConfiguration) {
        let previous = configuration
        configuration = next
        guard lifecycle == .running, store != nil else {
            if next.enabledAgents != previous.enabledAgents {
                refreshStandbySnapshot()
            }
            return
        }
        if next.excludedFolders != previous.excludedFolders {
            applyExclusionChange(from: previous.excludedFolders, to: next.excludedFolders)
        }
        if next.enabledAgents != previous.enabledAgents {
            // Turned off here (not through `purgeSource`): purge them the same way (D4).
            for agent in previous.enabledAgents.subtracting(next.enabledAgents) {
                deactivateSources(of: agent)
                pendingSourcePurges.insert(agent)
            }
            let added = next.enabledAgents.subtracting(previous.enabledAgents)
            pendingSourcePurges.subtract(added)
            runPendingSourcePurges()
            if !added.isEmpty {
                activateSources(makeSources().filter { added.contains($0.agent) })
            }
            scheduleStreamRefresh()
        }
        if next.fileEventLatency != previous.fileEventLatency {
            scheduleStreamRefresh(force: true)
        }
        updateProgressState()
        publish(force: true)
        scheduleStep()
    }

    /// Low power or thermal state changed: refresh the pause and resume the step loop.
    func conditionsChanged() {
        guard lifecycle == .running else {
            return
        }
        updateProgressState()
        publish()
        scheduleStep()
    }
}
