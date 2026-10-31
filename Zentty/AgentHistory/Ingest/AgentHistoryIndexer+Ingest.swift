import Foundation

/// Discovery, the step loop and batch commits. Indexer queue only.
extension AgentHistoryIndexer {
    enum ProcessOutcome {
        case skipped, wrote
    }

    // MARK: - Discovery

    /// Stat-only listing of a source; every unit whose change is not `.unchanged` goes to the
    /// backfill lane, newest first. A failed discovery records a problem, keeps the previous
    /// unit list and returns false.
    @discardableResult
    func discover(_ sourceState: AgentHistoryIndexerSourceState) -> Bool {
        sourceState.lastScanAt = now()
        sourceState.countersDirty = true
        let units: [AgentHistoryUnit]
        do {
            units = try sourceState.source.discoverUnits()
            sourceState.discoveryProblem = nil
        } catch {
            let rootExists = FileManager.default.fileExists(atPath: sourceState.source.root.path)
            sourceState.discoveryProblem = rootExists ? .discoveryFailed : .rootMissing
            AgentHistoryLog.indexer.info(
                "Agent History discovery failed agent=\(sourceState.source.agent.rawValue, privacy: .public) rootExists=\(rootExists, privacy: .public)"
            )
            return false
        }
        sourceState.units = Dictionary(units.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var pending: [(ref: AgentHistoryUnitRef, mtimeNs: Int64)] = []
        for unit in units {
            if sourceState.source.classifyChange(unit: unit, cursor: sourceState.cursors[unit.key]) == .unchanged {
                continue
            }
            pending.append((AgentHistoryUnitRef(sourceID: sourceState.id, unitKey: unit.key), unit.identity?.mtimeNs ?? 0))
        }
        workQueue.enqueueBackfill(pending)
        AgentHistoryLog.indexer.debug(
            "Agent History discovered agent=\(sourceState.source.agent.rawValue, privacy: .public) units=\(units.count, privacy: .public) queued=\(pending.count, privacy: .public)"
        )
        return true
    }

    // MARK: - Step loop

    /// One `queue.async` per batch so stop, configuration changes and writes interleave.
    func scheduleStep() {
        guard lifecycle == .running, !stepScheduled else {
            return
        }
        stepScheduled = true
        queue.async { [self] in
            stepScheduled = false
            guard lifecycle == .running, !cancellation.isSet else {
                return
            }
            let more = autoreleasepool {
                ZenttyPerformanceSignposts.interval("AgentHistoryBatch") { processNext() }
            }
            if more || becomeIdle() {
                scheduleStep()
            }
        }
    }

    /// Pops units until one batch was written (or `unchangedUnitsPerStep` were skipped).
    /// Returns false when nothing could be popped.
    func processNext() -> Bool {
        let backfillAllowed = pauseReason == nil
        var skipped = 0
        while skipped < Self.unchangedUnitsPerStep {
            // A full disk or a pending corruption recovery stops all work, live included.
            guard lifecycle == .running, !cancellation.isSet, !isWritingSuspended else {
                return false
            }
            guard let next = workQueue.popNext(allowBackfill: backfillAllowed) else {
                if skipped > 0 {
                    updateProgressState()
                }
                return skipped > 0
            }
            if process(next.ref, tier: next.tier) == .wrote {
                updateProgressState()
                publish(force: crossedSnapshotThreshold())
                return true
            }
            skipped += 1
        }
        updateProgressState()
        return true
    }

    /// Queue empty (or only paused backfill left): persist counters, mark the first full
    /// backfill, optimize once, go `.watching`. Returns true when it queued more work.
    @discardableResult
    func becomeIdle() -> Bool {
        guard lifecycle == .running, !corruptionRecoveryPending else {
            return false
        }
        if let reason = pauseReason, reason == .diskFull || workQueue.backfillCount > 0 {
            setState(.paused(reason, progress))
            publish()
            return false
        }
        if recheckMissingUnits() {
            return true
        }
        if pendingCarryOver != nil, let store {
            restorePendingCarryOver(into: store)
        }
        storePendingAdapterVersions()
        persistCounters()
        hasDrainedOnce = true
        if !isBackfillComplete {
            markBackfillComplete()
        }
        setState(.watching)
        publish()
        return false
    }

    // MARK: - Units

    func process(_ ref: AgentHistoryUnitRef, tier: AgentHistoryWorkQueue.Tier) -> ProcessOutcome {
        guard let sourceState = sourceStates[ref.sourceID], let known = sourceState.units[ref.unitKey] else {
            return .skipped
        }
        let unit = sourceState.source.refreshUnit(known)
        sourceState.units[ref.unitKey] = unit
        let cursor = sourceState.cursors[ref.unitKey]
        let change = sourceState.source.classifyChange(unit: unit, cursor: cursor)
        do {
            switch change {
            case .unchanged:
                clearMissing(ref)
                return .skipped
            case .missing:
                noteMissing(ref)
                return .skipped
            case .identityOnly:
                try saveIdentityOnly(sourceState, ref: ref, unit: unit, cursor: cursor)
                clearMissing(ref)
                return .skipped
            case let .append(offset, nextSeq):
                try ingestBatch(sourceState, ref: ref, unit: unit, cursor: cursor,
                                mode: .fromOffset(offset, nextSeq: nextSeq), tier: tier, clearUnitContent: false)
            case .new:
                let hasRows = try store?.hasSessions(sourceID: ref.sourceID, unitKey: ref.unitKey) ?? false
                if unit.kind == .database || !hasRows {
                    try ingestBatch(sourceState, ref: ref, unit: unit, cursor: cursor,
                                    mode: .fromStart, tier: tier, clearUnitContent: false)
                } else {
                    try replaceUnit(sourceState, ref: ref, unit: unit, cursor: cursor, tier: tier)
                }
            case .rewrite:
                if unit.kind == .database {
                    try ingestBatch(sourceState, ref: ref, unit: unit, cursor: cursor,
                                    mode: .fromStart, tier: tier, clearUnitContent: false)
                } else {
                    try replaceUnit(sourceState, ref: ref, unit: unit, cursor: cursor, tier: tier)
                }
            }
            clearMissing(ref)
            return .wrote
        } catch is CancellationError {
            return .skipped
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error(
                "Agent History batch failed agent=\(sourceState.source.agent.rawValue, privacy: .public) \(error.description, privacy: .public)"
            )
            if error.kind == .full {
                // The transaction rolled back; the unit goes first once there is space again.
                workQueue.setContinuation(ref, tier: tier)
            } else if error.kind == .busy {
                retryAfterBusy(ref, tier: tier)
            }
            handleStorageFailure(error)
            return .skipped
        } catch let error as POSIXError where error.code == .ENOENT {
            noteMissing(ref)
            return .skipped
        } catch {
            AgentHistoryLog.indexer.error(
                "Agent History ingest failed agent=\(sourceState.source.agent.rawValue, privacy: .public)"
            )
            return .skipped
        }
    }

    /// The index was busy past its timeout (an outside connection held it): the unit goes back
    /// first after `busyRetryDelay` instead of dropping out until the next reconcile.
    func retryAfterBusy(_ ref: AgentHistoryUnitRef, tier: AgentHistoryWorkQueue.Tier) {
        queue.asyncAfter(deadline: .now() + Self.busyRetryDelay) { [weak self] in
            guard let self, lifecycle == .running, !cancellation.isSet, sourceStates[ref.sourceID] != nil else {
                return
            }
            workQueue.setContinuation(ref, tier: tier)
            updateProgressState()
            scheduleStep()
        }
    }

    /// One adapter batch and its cursor in one transaction. `clearUnitContent` first clears
    /// every session of the unit (a rewrite too large for one transaction, A-8).
    func ingestBatch(
        _ sourceState: AgentHistoryIndexerSourceState,
        ref: AgentHistoryUnitRef,
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        tier: AgentHistoryWorkQueue.Tier,
        clearUnitContent: Bool
    ) throws {
        guard let writer, let store else {
            return
        }
        var batch = try sourceState.source.ingest(unit: unit, cursor: cursor, mode: mode, context: makeContext())
        let rejectsUnit = prepare(&batch, ref: ref, unit: unit, agent: sourceState.source.agent)
        var cleared: Set<Int64> = []
        let (result, saved) = try writer.transaction { () -> (AgentHistoryApplyResult, AgentHistoryCursor) in
            if clearUnitContent {
                cleared = try clearContent(of: ref, store: store)
            }
            let result = try store.apply(batch, sourceID: ref.sourceID, unitKey: unit.key)
            var saved = batch.cursor
            saved.isRejected = rejectsUnit
            try beforeCursorSaveForTesting?(ref)
            try store.saveCursor(saved)
            return (result, saved)
        }
        didCommit(sourceState, ref: ref, result: result, alsoTouched: cleared, batches: [batch], cursor: saved)
        continueIfNeeded(ref, tier: tier, hasMore: batch.hasMore, before: cursor, after: saved)
        if !batch.hasMore, batchedRewrites.remove(ref) != nil {
            checkpointAfterBatchedRewrite()
        }
    }

    /// Rewrite (or a `.new` unit that already has rows): clear the unit's content and read it
    /// from the start in one transaction, so readers see the old rows until the new ones are
    /// complete. Units over `wholeUnitReplaceMaxBytes` fall back to batched commits (A-8).
    func replaceUnit(
        _ sourceState: AgentHistoryIndexerSourceState,
        ref: AgentHistoryUnitRef,
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        tier: AgentHistoryWorkQueue.Tier
    ) throws {
        guard let writer, let store else {
            return
        }
        if (unit.identity?.size ?? 0) > wholeUnitReplaceMaxBytes {
            batchedRewrites.insert(ref)
            try ingestBatch(sourceState, ref: ref, unit: unit, cursor: cursor, mode: .fromStart, tier: tier, clearUnitContent: true)
            return
        }
        let context = makeContext()
        var batches: [AgentHistoryIngestBatch] = []
        var result = AgentHistoryApplyResult()
        var cleared: Set<Int64> = []
        let saved = try writer.transaction { () -> AgentHistoryCursor in
            cleared = try clearContent(of: ref, store: store)
            var current = cursor
            var mode = AgentHistoryIngestMode.fromStart
            var rejectsUnit = false
            while true {
                if cancellation.isSet {
                    throw CancellationError()
                }
                var batch = try sourceState.source.ingest(unit: unit, cursor: current, mode: mode, context: context)
                rejectsUnit = prepare(&batch, ref: ref, unit: unit, agent: sourceState.source.agent) || rejectsUnit
                let applied = try store.apply(batch, sourceID: ref.sourceID, unitKey: unit.key)
                result.touchedSessionIDs.formUnion(applied.touchedSessionIDs)
                result.touchedSessionIDs.subtract(applied.removedSessionIDs)
                result.removedSessionIDs.formUnion(applied.removedSessionIDs)
                batches.append(batch)
                let previous = current
                current = batch.cursor
                if !batch.hasMore || batch.cursor == previous {
                    break
                }
                mode = .fromOffset(batch.cursor.byteOffset, nextSeq: batch.cursor.nextSeq)
            }
            guard var saved = current else {
                throw CancellationError()
            }
            saved.isRejected = rejectsUnit
            try beforeCursorSaveForTesting?(ref)
            try store.saveCursor(saved)
            return saved
        }
        didCommit(sourceState, ref: ref, result: result, alsoTouched: cleared, batches: batches, cursor: saved)
    }

    /// `.identityOnly` (A-6): the content is already indexed under another identity (a
    /// compressed rollout). Only the cursor's identity changes; no rows are written.
    func saveIdentityOnly(
        _ sourceState: AgentHistoryIndexerSourceState,
        ref: AgentHistoryUnitRef,
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?
    ) throws {
        guard let writer, let store, var updated = cursor else {
            return
        }
        updated.sourceID = ref.sourceID
        updated.identity = unit.identity
        try writer.transaction {
            try store.saveCursor(updated)
        }
        sourceState.cursors[ref.unitKey] = updated
    }

    /// Normalizes a batch before it is applied:
    /// - stamps the cursor with the real source id and unit key (adapters start a nil cursor
    ///   at source id 0);
    /// - redacts every title once more (A-9 choke point; idempotent);
    /// - purges every rejected session's stored rows.
    /// Returns true when the whole unit is rejected: only a single-session file unit whose own
    /// session was rejected. Multi-session units (databases) report rejections per session and
    /// their shared cursor is never rejected.
    func prepare(
        _ batch: inout AgentHistoryIngestBatch,
        ref: AgentHistoryUnitRef,
        unit: AgentHistoryUnit,
        agent: AgentHistoryAgent
    ) -> Bool {
        batch.cursor.sourceID = ref.sourceID
        batch.cursor.unitKey = unit.key
        for index in batch.sessions.indices {
            if let title = batch.sessions[index].title {
                batch.sessions[index].title = redactor.redact(title)
            }
        }
        if !batch.rejected.isEmpty {
            batch.removedNativeIDs.formUnion(batch.rejected.keys)
        }
        guard unit.kind != .database, let rawID = unit.nativeSessionID else {
            return false
        }
        return batch.rejected[agent.normalizedSessionID(rawID) ?? rawID] != nil
    }

    /// Clears messages and artifacts of every session stored for the unit; returns their ids
    /// so their summaries are refreshed (or dropped when nothing comes back).
    func clearContent(of ref: AgentHistoryUnitRef, store: AgentHistoryStore) throws -> Set<Int64> {
        let ids = try store.database.query(
            "SELECT id FROM sessions WHERE source_id = ? AND unit_key = ?",
            [.integer(ref.sourceID), .text(ref.unitKey)]
        ) { $0.int64(0) }
        try store.deleteSessionContent(sourceID: ref.sourceID, unitKey: ref.unitKey)
        return Set(ids)
    }

    /// After a commit: cursor cache, snapshot builder, counters, problems.
    func didCommit(
        _ sourceState: AgentHistoryIndexerSourceState,
        ref: AgentHistoryUnitRef,
        result: AgentHistoryApplyResult,
        alsoTouched: Set<Int64>,
        batches: [AgentHistoryIngestBatch],
        cursor: AgentHistoryCursor
    ) {
        sourceState.cursors[ref.unitKey] = cursor
        let touched = result.touchedSessionIDs.union(alsoTouched).subtracting(result.removedSessionIDs)
        if !result.removedSessionIDs.isEmpty {
            snapshotBuilder.remove(rowIDs: result.removedSessionIDs)
            snapshotDirty = true
        }
        if !touched.isEmpty, let store {
            do {
                let summaries = try store.sessionSummaries(rowIDs: touched)
                snapshotBuilder.upsert(summaries)
                snapshotBuilder.remove(rowIDs: touched.subtracting(summaries.map(\.id)))
                snapshotDirty = true
            } catch let error as AgentHistoryDatabaseError {
                AgentHistoryLog.indexer.error("Agent History summary refresh failed \(error.description, privacy: .public)")
                handleStorageFailure(error)
            } catch {}
        }

        for batch in batches {
            for session in batch.sessions {
                sourceState.skippedSessionIDs.remove(session.nativeID)
            }
            for (nativeID, reason) in batch.diagnostics.skippedSessions {
                switch reason {
                case .excluded, .tombstoned, .child:
                    sourceState.skippedSessionIDs.remove(nativeID)
                case .invalidSessionID, .unsupportedFormat, .unreadable:
                    sourceState.skippedSessionIDs.insert(nativeID)
                }
            }
            sourceState.skippedRecords += batch.diagnostics.skippedRecords
        }
        // Database read problems (busy, unreadable, unsupported schema, metadata from
        // transcripts) arrive as `batch.problem` with partial results: keep the rows, show the
        // problem, retry on the next pass.
        sourceState.unitProblems[ref.unitKey] = batches.last?.problem
        if batches.last?.problem == nil {
            // A clean read applied the current admission rules (see `pollDatabaseUnits`).
            admissionPendingUnits.remove(ref)
        }
        sourceState.countersDirty = true
        lastUpdatedAt = now()
    }

    func continueIfNeeded(
        _ ref: AgentHistoryUnitRef,
        tier: AgentHistoryWorkQueue.Tier,
        hasMore: Bool,
        before: AgentHistoryCursor?,
        after: AgentHistoryCursor
    ) {
        guard hasMore else {
            return
        }
        guard after != before else {
            // An adapter that reports more without moving its cursor would loop forever.
            AgentHistoryLog.indexer.error("Agent History batch made no progress; continuation dropped")
            return
        }
        workQueue.setContinuation(ref, tier: tier)
    }

    func makeContext() -> AgentHistoryIngestContext {
        let cancellation = self.cancellation
        return AgentHistoryIngestContext(
            limits: configuration.limits,
            admission: admission,
            repositories: repositories,
            redactor: redactor,
            isCancelled: { cancellation.isSet }
        )
    }

    // MARK: - Backfill completion

    func markBackfillComplete() {
        guard let store else {
            return
        }
        isBackfillComplete = true
        snapshotDirty = true
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try store.setMeta(Self.backfillCompletedMetaKey, String(Int64(now().timeIntervalSince1970 * 1_000)))
            try store.optimize()
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History optimize failed \(error.description, privacy: .public)")
        } catch {}
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        AgentHistoryLog.indexer.info(
            "Agent History backfill complete sessions=\(self.snapshotBuilder.count, privacy: .public) optimizeMs=\(elapsedMs, privacy: .public)"
        )
    }
}
