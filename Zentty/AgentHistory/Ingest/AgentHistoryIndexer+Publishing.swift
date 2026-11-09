import Foundation

/// State, counters and the throttled hand-off of status and snapshot to main. Indexer queue only.
extension AgentHistoryIndexer {
    // MARK: - State

    func setState(_ next: AgentHistoryIndexerState) {
        if next.logName != state.logName {
            AgentHistoryLog.indexer.info(
                "Agent History indexer state \(self.state.logName, privacy: .public) -> \(next.logName, privacy: .public)"
            )
            ZenttyBreadcrumbs.record(
                category: "zentty.agent_history",
                message: "indexer \(next.logName)"
            )
        }
        state = next
    }

    /// Counts queued units on both sides, so the total stays put: a unit can hold no visible
    /// session (an empty transcript) or many (opencode's database), and mixing those with
    /// sessions already indexed made the total drift while the bar moved.
    var progress: AgentHistoryBackfillProgress {
        AgentHistoryBackfillProgress(
            indexedSessions: backfillBaseline + workQueue.backfillFinished,
            totalSessions: backfillBaseline + workQueue.backfillScheduled
        )
    }

    /// Keeps `.backfilling` / `.paused` progress current while work is queued. A full disk
    /// pauses everything; low power and heat pause only while backfill is waiting. After the
    /// queue drained once in this run, new work (reconciles, live events) keeps `.watching`.
    func updateProgressState() {
        guard lifecycle == .running else {
            return
        }
        switch state {
        case .off, .failed:
            return
        case .starting, .backfilling, .paused, .watching:
            break
        }
        if let reason = pauseReason, reason == .diskFull || workQueue.backfillCount > 0 {
            backfillEstimator.reset()
            setState(.paused(reason, progress))
        } else if hasDrainedOnce {
            if case .paused = state {
                setState(.watching)
            }
        } else {
            setState(.backfilling(progressWithEstimate()))
        }
    }

    private func progressWithEstimate() -> AgentHistoryBackfillProgress {
        var current = progress
        let uptime = ProcessInfo.processInfo.systemUptime
        backfillEstimator.record(indexed: current.indexedSessions, at: uptime)
        current.estimatedSecondsRemaining = backfillEstimator.secondsRemaining(
            sessionsLeft: current.totalSessions - current.indexedSessions,
            at: uptime
        )
        return current
    }

    /// True once, when the visible sessions first reach `snapshotPublishThreshold`.
    func crossedSnapshotThreshold() -> Bool {
        guard !reachedSnapshotThreshold, snapshotBuilder.count >= Self.snapshotPublishThreshold else {
            return false
        }
        reachedSnapshotThreshold = true
        return true
    }

    // MARK: - Publishing

    /// Hands status (and the snapshot, when it changed) to main: at most once per
    /// `schedule.publishInterval`, immediately when forced or when the state kind changed.
    /// A throttled call schedules one trailing publish.
    func publish(force: Bool = false) {
        let stateName = state.logName
        let uptime = ProcessInfo.processInfo.systemUptime
        let immediate = force || stateName != lastPublishedStateName
        if !immediate, let last = lastPublishUptime, uptime - last < schedule.publishInterval {
            scheduleTrailingPublish(after: schedule.publishInterval - (uptime - last))
            return
        }
        lastPublishUptime = uptime
        lastPublishedStateName = stateName

        refreshCounters()
        var status = makeStatus()
        let snapshot = snapshotDirty
            ? snapshotBuilder.build(isComplete: isBackfillComplete, removals: admission.removals)
            : nil
        snapshotDirty = false

        var previous = currentStatus
        previous.revision = status.revision
        if snapshot == nil, previous == status {
            return
        }
        revision &+= 1
        status.revision = revision
        storePublished(status: status, snapshot: snapshot)

        let onStatusChange = self.onStatusChange
        let onSnapshotChange = self.onSnapshotChange
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let snapshot {
                    onSnapshotChange(snapshot)
                }
                onStatusChange(status)
            }
        }
    }

    func scheduleTrailingPublish(after delay: TimeInterval) {
        guard !trailingPublishScheduled else {
            return
        }
        trailingPublishScheduled = true
        queue.asyncAfter(deadline: .now() + max(delay, 0.01)) { [weak self] in
            guard let self else {
                return
            }
            trailingPublishScheduled = false
            guard lifecycle == .running else {
                return
            }
            publish()
        }
    }

    func makeStatus() -> AgentHistoryStatus {
        let persisted = stateStore.current
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = persisted.enabled
        status.hasConsented = persisted.consentedAt != nil
        status.enabledAgents = configuration.enabledAgents
        status.state = state
        status.sources = sourceOrder.compactMap { sourceStates[$0].map(health(of:)) }
        status.indexedSessions = snapshotBuilder.count
        status.removedSessionCount = admission.tombstones.count
        status.removedKeys = admission.tombstones
        status.indexExists = FileManager.default.fileExists(atPath: storage.paths.databaseURL.path)
        status.indexSizeBytes = status.indexExists ? storage.diskUsageBytes() : 0
        status.lastUpdatedAt = lastUpdatedAt
        status.tokenizer = tokenizer
        status.isBackfillComplete = isBackfillComplete
        status.revision = currentStatus.revision
        return status
    }

    func health(of sourceState: AgentHistoryIndexerSourceState) -> AgentHistorySourceHealth {
        let problem = sourceState.problem
        return AgentHistorySourceHealth(
            agent: sourceState.source.agent,
            root: sourceState.source.root.path,
            isDefaultRoot: sourceState.source.root.isDefault,
            isEnabled: true,
            discovered: sourceState.discovered,
            indexed: sourceState.indexed,
            skipped: sourceState.skippedSessionIDs.count,
            problem: problem,
            lastError: problem.map(Self.describe),
            lastScanAt: sourceState.lastScanAt
        )
    }

    // MARK: - Counters

    /// Recounts `indexed` / `discovered` for sources that changed since the last count.
    /// `discovered` = file units found, or (for databases) stored plus skipped sessions.
    func refreshCounters() {
        guard let store else {
            return
        }
        for id in sourceOrder {
            guard let sourceState = sourceStates[id], sourceState.countersDirty else {
                continue
            }
            let indexed = (try? store.sessionCount(sourceID: id)) ?? sourceState.indexed
            let fileUnits = sourceState.units.values.reduce(0) { $0 + ($1.kind == .database ? 0 : 1) }
            sourceState.indexed = indexed
            sourceState.discovered = max(fileUnits, indexed + sourceState.skippedSessionIDs.count)
        }
    }

    /// Writes `discovered` / `indexed` / `skipped`, the scan time and the last problem of every
    /// source that changed into its `sources` row.
    func persistCounters() {
        guard let store else {
            return
        }
        refreshCounters()
        for id in sourceOrder where !isWritingSuspended {
            guard let sourceState = sourceStates[id], sourceState.countersDirty else {
                continue
            }
            let scannedAt = sourceState.lastScanAt ?? now()
            do {
                try beforeHousekeepingWriteForTesting?(.counters)
                try store.updateSourceHealth(
                    id: id,
                    discovered: sourceState.discovered,
                    indexed: sourceState.indexed,
                    skipped: sourceState.skippedSessionIDs.count,
                    lastScanAt: Int64((scannedAt.timeIntervalSince1970 * 1_000).rounded()),
                    lastError: sourceState.problem.map(Self.describe)
                )
                sourceState.countersDirty = false
            } catch {
                logWriteFailure(error, action: "save the source counters")
                continue
            }
            AgentHistoryLog.indexer.info(
                "Agent History source agent=\(sourceState.source.agent.rawValue, privacy: .public) discovered=\(sourceState.discovered, privacy: .public) indexed=\(sourceState.indexed, privacy: .public) skipped=\(sourceState.skippedSessionIDs.count, privacy: .public) skippedRecords=\(sourceState.skippedRecords, privacy: .public)"
            )
        }
    }

    /// A short, path-free reason for `sources.last_error` and Settings.
    static func describe(_ problem: AgentHistorySourceProblem) -> String {
        switch problem {
        case .rootMissing: return "Folder not found"
        case .permissionDenied: return "Permission denied"
        case .busy: return "Database busy"
        case .unreadableDatabase(let code): return "Database unreadable (\(code))"
        case .unsupportedFormat(let reason): return "\(reason) not supported yet"
        case .unsupportedSchema(let reason): return "Unsupported database schema (\(reason))"
        case .metadataFromTranscripts: return "Thread catalog unavailable; using transcripts"
        case .discoveryFailed: return "Could not list sessions"
        }
    }
}
