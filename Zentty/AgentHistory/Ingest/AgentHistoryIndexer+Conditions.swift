import Foundation

/// Pauses and storage failures. Indexer queue only.
///
/// - Low power and thermal pressure (`systemConditions.pauseReason`) pause the backfill lane;
///   live events and database polls keep running. State `.paused(reason, progress)`.
/// - `SQLITE_FULL` pauses everything (`.paused(.diskFull)`): the failed transaction has rolled
///   back, the unit is re-queued first, and every `schedule.diskFullRetry` the indexer checks
///   the volume; once more than `diskFullResumeMinimumBytes` are free it resumes (an unknown
///   amount resumes too, and SQLite reports again if it is still full).
/// - Another Zentty instance owns the index (`AgentHistoryWriterLock`): stand by read-only,
///   `.paused(.anotherInstance)`, show the stored sessions and try to take over every
///   `standbyRetryInterval`.
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
        runPendingSourcePurges()
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
        recordCarriedRemovals()
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

    // MARK: - Index ownership

    /// True once this indexer marks itself present (now, or already). Busy only while another
    /// instance deletes the index: stand by and try again. Any other failure fails the indexer.
    func acquirePresenceLockOrStandBy() -> Bool {
        if presenceLock?.isHeld == true {
            return true
        }
        do {
            presenceLock = try storage.acquirePresenceLock(timeout: writerLockWait)
            return true
        } catch let error as AgentHistoryDatabaseError where error.kind == .busy {
            enterStandby()
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History could not lock the index \(error.description, privacy: .public)")
            fail(Self.failureReason(for: error))
        } catch {
            fail(.openFailed(code: -1))
        }
        return false
    }

    /// True when this indexer owns the index (now, or already). A busy lock means another
    /// instance indexes: stand by. Any other failure fails the indexer.
    func acquireWriterLockOrStandBy() -> Bool {
        if writerLock?.isHeld == true {
            return true
        }
        do {
            writerLock = try storage.acquireWriterLock(timeout: writerLockWait)
            if lifecycle == .standby {
                AgentHistoryLog.indexer.info("Agent History took over the index from another instance")
            }
            return true
        } catch let error as AgentHistoryDatabaseError where error.kind == .busy {
            enterStandby()
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History could not lock the index \(error.description, privacy: .public)")
            fail(Self.failureReason(for: error))
        } catch {
            fail(.openFailed(code: -1))
        }
        return false
    }

    func releaseWriterLock() {
        writerLock?.release()
        writerLock = nil
    }

    func enterStandby() {
        if lifecycle != .standby {
            lifecycle = .standby
            AgentHistoryLog.indexer.info("Agent History index owned by another instance; standing by")
        }
        loadStandbySnapshot()
        setState(.paused(.anotherInstance, nil))
        publish(force: true)
        scheduleStandbyRetry()
    }

    /// The sessions the owning instance stored, read through the reader pool. Agents turned off
    /// here are left out: a standby never purges, and the owner may not have purged them yet.
    func loadStandbySnapshot() {
        do {
            let enabledAgents = configuration.enabledAgents
            let (stored, isComplete) = try storage.readers.withReader { database in
                let store = AgentHistoryStore(database: database, now: now)
                return (try store.allVisibleSessionSummaries(), try store.meta(Self.backfillCompletedMetaKey) != nil)
            }
            let summaries = stored.filter { enabledAgents.contains($0.agent) }
            if Set(summaries) != Set(snapshotBuilder.allSessions) || isComplete != isBackfillComplete {
                snapshotBuilder.replaceAll(summaries)
                isBackfillComplete = isComplete
                snapshotDirty = true
            }
        } catch {
            AgentHistoryLog.indexer.info("Agent History standby could not read the index yet")
        }
    }

    /// The agent selection changed while standing by: re-read the snapshot under it at once.
    func refreshStandbySnapshot() {
        guard lifecycle == .standby else {
            return
        }
        loadStandbySnapshot()
        publish(force: true)
    }

    /// A standby indexer runs with the configuration its controller had when it started, maybe
    /// long ago; another instance may have turned History or agents off since. Before taking
    /// over it re-reads `state.json`: agents now off are left out (and purged once it owns the
    /// index), and while History is off or unconsented it keeps standing by, writing nothing,
    /// until its controller stops it.
    func savedStateAllowsTakeover() -> Bool {
        let saved = stateStore.reload()
        let allowed = configuration.enabledAgents.intersection(saved.enabledAgents)
        if allowed != configuration.enabledAgents {
            configuration.enabledAgents = allowed
            refreshStandbySnapshot()
        }
        guard saved.enabled, saved.consentedAt != nil, !allowed.isEmpty else {
            AgentHistoryLog.indexer.info("Agent History standby not taking over: turned off in another instance")
            scheduleStandbyRetry()
            return false
        }
        return true
    }

    func scheduleStandbyRetry() {
        guard !standbyRetryScheduled else {
            return
        }
        standbyRetryScheduled = true
        queue.asyncAfter(deadline: .now() + standbyRetryInterval) { [weak self] in
            guard let self else {
                return
            }
            standbyRetryScheduled = false
            guard lifecycle == .standby, !cancellation.isSet else {
                return
            }
            startOnQueue()
        }
    }
}
