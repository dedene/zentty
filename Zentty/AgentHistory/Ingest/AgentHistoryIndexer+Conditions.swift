import Foundation

/// Pauses and storage failures. Indexer queue only.
///
/// - Low power and thermal pressure (`systemConditions.pauseReason`) pause the backfill lane;
///   live events and database polls keep running. State `.paused(reason, progress)`.
/// - `SQLITE_FULL` pauses everything (`.paused(.diskFull)`): the failed transaction has rolled
///   back, the unit is re-queued first, and every `schedule.diskFullRetry` the indexer checks
///   the volume; once more than `diskFullResumeMinimumBytes` are free it resumes (an unknown
///   amount resumes too, and SQLite reports again if it is still full).
/// - Corruption found mid-run: close the writer, move the file aside (`index.corrupt-*`), open a
///   fresh index and reconcile every source from scratch, at most
///   `maxCorruptionRecoveriesPerRun` times before failing with `.corrupt`. Tombstones and usage
///   are carried into the fresh index like a rebuild's (`AgentHistoryIndexer+CarryOver.swift`).
extension AgentHistoryIndexer {
    static let diskFullResumeMinimumBytes: Int64 = 200_000_000
    static let maxCorruptionRecoveriesPerRun = 3

    /// The pause in force: a full disk wins over the machine's conditions.
    var pauseReason: AgentHistoryPauseReason? {
        isDiskFull ? .diskFull : systemConditions.pauseReason
    }

    /// True while nothing may write: the disk is full or a corruption recovery is pending.
    var isWritingSuspended: Bool {
        isDiskFull || corruptionRecoveryPending
    }

    /// Turns a full disk into the disk-full pause and corruption into a recovery. Other errors
    /// are left to the caller (logged, retried on the next pass).
    func handleStorageFailure(_ error: AgentHistoryDatabaseError) {
        if error.kind == .full {
            enterDiskFull()
        } else if error.isCorruption {
            scheduleCorruptionRecovery()
        }
    }

    // MARK: - Full disk

    func enterDiskFull() {
        guard lifecycle == .running else {
            return
        }
        if !isDiskFull {
            isDiskFull = true
            AgentHistoryLog.indexer.error("Agent History paused: the disk is full")
        }
        setState(.paused(.diskFull, progress))
        publish(force: true)
        scheduleDiskFullRetry()
    }

    func scheduleDiskFullRetry() {
        guard lifecycle == .running, isDiskFull, !diskFullRetryScheduled else {
            return
        }
        diskFullRetryScheduled = true
        queue.asyncAfter(wallDeadline: .now() + schedule.diskFullRetry) { [weak self] in
            guard let self else {
                return
            }
            diskFullRetryScheduled = false
            retryAfterDiskFull()
        }
    }

    func retryAfterDiskFull() {
        guard lifecycle == .running, !cancellation.isSet, isDiskFull else {
            return
        }
        let available = systemConditions.availableCapacity(forVolumeAt: storage.paths.directoryURL)
        if let available, available <= Self.diskFullResumeMinimumBytes {
            scheduleDiskFullRetry()
            return
        }
        isDiskFull = false
        AgentHistoryLog.indexer.info(
            "Agent History resuming after a full disk availableBytes=\(available ?? -1, privacy: .public)"
        )
        updateProgressState()
        publish(force: true)
        scheduleStep()
    }

    // MARK: - Corruption

    /// Stops all work now; the recovery runs on the next queue turn, so the caller unwinds first.
    func scheduleCorruptionRecovery() {
        guard lifecycle == .running, !corruptionRecoveryPending else {
            return
        }
        corruptionRecoveryPending = true
        queue.async { [weak self] in
            self?.recoverFromCorruption()
        }
    }

    /// Close, quarantine, reopen, full reconcile (through `startOnQueue`).
    func recoverFromCorruption() {
        corruptionRecoveryPending = false
        guard lifecycle == .running, !cancellation.isSet else {
            return
        }
        corruptionRecoveries += 1
        AgentHistoryLog.indexer.error(
            "Agent History index corrupt mid-run; moving it aside and rebuilding attempt=\(self.corruptionRecoveries, privacy: .public)"
        )
        // Removals and usage outlive the corrupt file (what it still yields, plus this run's).
        pendingCarryOver = collectCarryOver()
        systemConditions.stopObserving()
        stopFreshness()
        writer?.close()
        writer = nil
        store = nil
        guard corruptionRecoveries <= Self.maxCorruptionRecoveriesPerRun else {
            fail(.corrupt)
            return
        }
        do {
            try storage.readers.fenced { try storage.quarantineCorruptDatabase() }
        } catch {
            AgentHistoryLog.indexer.error("Agent History could not move the corrupt index aside")
            fail(.corrupt)
            return
        }
        resetForReopen()
        lifecycle = .idle
        startOnQueue()
    }

    /// Forgets everything that described the old file; the snapshot generation keeps counting.
    func resetForReopen() {
        sourceStates = [:]
        sourceOrder = []
        workQueue = AgentHistoryWorkQueue()
        snapshotBuilder.replaceAll([])
        snapshotDirty = true
        isBackfillComplete = false
        hasDrainedOnce = false
        reachedSnapshotThreshold = false
        missingSince = [:]
        missingRechecked = []
        batchedRewrites = []
        admissionPendingUnits = []
        isDiskFull = false
        tokenizer = nil
        admission = .admitAll
    }
}
