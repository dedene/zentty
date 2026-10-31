import Foundation

/// Reconcile: mirror what disappeared upstream, conservatively. Indexer queue only.
///
/// Per source:
/// - discovery fails or the root is gone → record the problem and delete nothing; only a root
///   still missing on a full reconcile `schedule.interval` after the first one purges the source;
/// - a unit with a cursor that discovery no longer lists is deleted once it has been missing for
///   `schedule.missingGrace` (A-21), unless the mass-deletion guard holds it;
/// - database sources: stored sessions that `existingNativeIDs()` no longer reports are deleted
///   under the same guard;
/// - the folder-exclusion purge runs again (idempotent).
///
/// The mass-deletion guard: more than `massDeletionMinimum` and more than half of the source
/// would go at once → defer, and delete only what is still gone on the next full reconcile.
/// Renamed units need no special case: the upsert re-points `unit_key`, so deleting the old key
/// matches no session and usage (`opens`) survives.
extension AgentHistoryIndexer {
    static let massDeletionMinimum = 20

    // MARK: - Entry points

    /// `locatesRoots` (default: `isFull`) first asks the locator for roots that appeared (see
    /// `AgentHistoryIndexer+Roots.swift`); they are reconciled with the rest.
    func reconcile(sourceIDs: [Int64], isFull: Bool, locatesRoots: Bool? = nil) {
        // The recovery reopens the index and reconciles everything itself.
        guard !corruptionRecoveryPending else {
            return
        }
        runPendingSourcePurges()
        var sourceIDs = sourceIDs
        if locatesRoots ?? isFull {
            sourceIDs += registerNewlyLocatedSources().filter { !sourceIDs.contains($0) }
        }
        for id in sourceIDs {
            if let sourceState = sourceStates[id] {
                reconcile(sourceState, isFull: isFull)
            }
        }
        purgeExcludedSessions()
        if isFull {
            schedule.recordReconcile(at: now())
        }
        // A root may have appeared or gone; the stream follows on a later queue turn.
        scheduleStreamRefresh()
    }

    func reconcile(_ sourceState: AgentHistoryIndexerSourceState, isFull: Bool) {
        if sourceState.isInactive {
            sourceState.lastScanAt = now()
            sourceState.discoveryProblem = .rootMissing
            handleMissingRoot(sourceState, isFull: isFull)
            return
        }
        let discovered = discover(sourceState)
        guard FileManager.default.fileExists(atPath: sourceState.source.root.path) else {
            sourceState.discoveryProblem = .rootMissing
            handleMissingRoot(sourceState, isFull: isFull)
            return
        }
        sourceState.rootMissingSince = nil
        guard discovered else {
            return
        }
        reconcileMissingUnits(sourceState, isFull: isFull)
        reconcileVanishedSessions(sourceState, isFull: isFull)
    }

    // MARK: - Missing root

    /// Never deletes on the first sighting: a volume may be unmounted or a tool mid-migration.
    func handleMissingRoot(_ sourceState: AgentHistoryIndexerSourceState, isFull: Bool) {
        guard isFull else {
            return
        }
        let current = now()
        guard let since = sourceState.rootMissingSince else {
            sourceState.rootMissingSince = current
            return
        }
        guard current.timeIntervalSince(since) >= schedule.interval else {
            return
        }
        guard let writer, let store else {
            return
        }
        let sourceID = sourceState.id
        do {
            let removed = try writer.transaction { () -> [Int64] in
                let removed = try store.deleteSessions(sourceID: sourceID)
                try store.deleteCursors(sourceID: sourceID)
                return removed
            }
            sourceState.cursors = [:]
            sourceState.units = [:]
            sourceState.deferredMissingUnits = nil
            sourceState.deferredVanishedIDs = nil
            workQueue.removeAll(sourceID: sourceID)
            missingSince = missingSince.filter { $0.key.sourceID != sourceID }
            missingRechecked = missingRechecked.filter { $0.sourceID != sourceID }
            didDelete(sourceState, rowIDs: removed)
            AgentHistoryLog.indexer.info(
                "Agent History purged source with missing root agent=\(sourceState.source.agent.rawValue, privacy: .public) sessions=\(removed.count, privacy: .public)"
            )
            retireInactiveSource(sourceState)
        } catch {
            logDeletionFailure(error, sourceState)
        }
    }

    // MARK: - Missing units

    func reconcileMissingUnits(_ sourceState: AgentHistoryIndexerSourceState, isFull: Bool) {
        let present = Set(sourceState.units.filter { $0.value.identity != nil }.keys)
        var known = Set(sourceState.cursors.keys)
        for ref in missingSince.keys where ref.sourceID == sourceState.id {
            known.insert(ref.unitKey)
        }
        for key in present {
            clearMissing(AgentHistoryUnitRef(sourceID: sourceState.id, unitKey: key))
        }
        let current = now()
        var candidates: Set<String> = []
        for key in known.subtracting(present) {
            let ref = AgentHistoryUnitRef(sourceID: sourceState.id, unitKey: key)
            noteMissing(ref)
            if let since = missingSince[ref], schedule.isMissingGraceOver(firstSeenMissingAt: since, now: current) {
                candidates.insert(key)
            }
        }
        guard !candidates.isEmpty else {
            sourceState.deferredMissingUnits = nil
            return
        }

        // Weigh each unit by its stored sessions (a missing database unit holds many).
        let sessionsByUnit = (try? sessionCountsByUnit(sourceID: sourceState.id)) ?? [:]
        let weight = { (keys: Set<String>) in keys.reduce(0) { $0 + max(1, sessionsByUnit[$1] ?? 0) } }
        let total = max(known.union(present).count, sessionsByUnit.values.reduce(0, +))
        let deletable = guardMassDeletion(
            candidates, weight: weight(candidates), total: total, isFull: isFull,
            deferred: &sourceState.deferredMissingUnits, sourceState: sourceState, kind: "units"
        )
        guard !deletable.isEmpty else {
            return
        }
        deleteMissingUnits(sourceState, keys: deletable)
    }

    func deleteMissingUnits(_ sourceState: AgentHistoryIndexerSourceState, keys: Set<String>) {
        guard let writer, let store else {
            return
        }
        let sourceID = sourceState.id
        do {
            let removed = try writer.transaction { () -> [Int64] in
                var removed: [Int64] = []
                for key in keys.sorted() {
                    removed += try store.deleteSessions(sourceID: sourceID, unitKey: key)
                    try store.deleteCursor(sourceID: sourceID, unitKey: key)
                }
                return removed
            }
            for key in keys {
                sourceState.cursors[key] = nil
                sourceState.units[key] = nil
                sourceState.unitProblems[key] = nil
                clearMissing(AgentHistoryUnitRef(sourceID: sourceID, unitKey: key))
            }
            didDelete(sourceState, rowIDs: removed)
            AgentHistoryLog.indexer.info(
                "Agent History mirrored deleted units agent=\(sourceState.source.agent.rawValue, privacy: .public) units=\(keys.count, privacy: .public) sessions=\(removed.count, privacy: .public)"
            )
        } catch {
            logDeletionFailure(error, sourceState)
        }
    }

    // MARK: - Vanished database sessions

    func reconcileVanishedSessions(_ sourceState: AgentHistoryIndexerSourceState, isFull: Bool) {
        guard let writer, let store else {
            return
        }
        let existing: Set<String>
        do {
            guard let ids = try sourceState.source.existingNativeIDs() else {
                return
            }
            existing = ids
        } catch {
            // Busy or unreadable: say nothing about deletions this time.
            AgentHistoryLog.indexer.info(
                "Agent History could not list existing sessions agent=\(sourceState.source.agent.rawValue, privacy: .public)"
            )
            return
        }
        let sourceID = sourceState.id
        do {
            let indexed = try store.indexedNativeIDs(sourceID: sourceID)
            let vanished = indexed.subtracting(existing)
            guard !vanished.isEmpty else {
                sourceState.deferredVanishedIDs = nil
                return
            }
            let deletable = guardMassDeletion(
                vanished, weight: vanished.count, total: indexed.count, isFull: isFull,
                deferred: &sourceState.deferredVanishedIDs, sourceState: sourceState, kind: "sessions"
            )
            guard !deletable.isEmpty else {
                return
            }
            let removed = try writer.transaction {
                try store.deleteSessions(sourceID: sourceID, nativeIDs: deletable)
            }
            didDelete(sourceState, rowIDs: removed)
            AgentHistoryLog.indexer.info(
                "Agent History mirrored deleted sessions agent=\(sourceState.source.agent.rawValue, privacy: .public) sessions=\(removed.count, privacy: .public)"
            )
        } catch {
            logDeletionFailure(error, sourceState)
        }
    }

    // MARK: - Mass-deletion guard

    /// Returns what may be deleted now. When the candidates are more than
    /// `massDeletionMinimum` and more than half of `total`, they are deferred; a later full
    /// reconcile deletes the deferred ones that are still candidates (new candidates start
    /// their own deferral).
    func guardMassDeletion(
        _ candidates: Set<String>,
        weight: Int,
        total: Int,
        isFull: Bool,
        deferred: inout Set<String>?,
        sourceState: AgentHistoryIndexerSourceState,
        kind: String
    ) -> Set<String> {
        guard weight > Self.massDeletionMinimum, weight * 2 > total else {
            deferred = nil
            return candidates
        }
        guard isFull, let previous = deferred else {
            if deferred == nil {
                deferred = candidates
                AgentHistoryLog.indexer.info(
                    "Agent History deferred a mass deletion agent=\(sourceState.source.agent.rawValue, privacy: .public) kind=\(kind, privacy: .public) count=\(candidates.count, privacy: .public) total=\(total, privacy: .public)"
                )
            }
            return []
        }
        let confirmed = candidates.intersection(previous)
        let fresh = candidates.subtracting(previous)
        deferred = fresh.isEmpty ? nil : fresh
        return confirmed
    }

    // MARK: - Exclusion purge

    /// Deletes stored sessions under an excluded folder and marks their single-session units
    /// rejected (a database unit's shared cursor never is). Idempotent; cheap when nothing
    /// matches.
    func purgeExcludedSessions() {
        let folders = admission.exclusions.canonicalFolders
        guard !folders.isEmpty, let writer, let store else {
            return
        }
        do {
            let rejected = try writer.transaction { () -> [(sourceID: Int64, rowIDs: [Int64], unitKeys: [String])] in
                let removed = try store.deleteSessions(underFolders: folders)
                var bySource: [Int64: (rowIDs: [Int64], unitKeys: [String])] = [:]
                for row in removed {
                    var entry = bySource[row.sourceID] ?? ([], [])
                    entry.rowIDs.append(row.rowID)
                    if let key = row.unitKey,
                       let unit = sourceStates[row.sourceID]?.units[key], unit.kind != .database {
                        entry.unitKeys.append(key)
                    }
                    bySource[row.sourceID] = entry
                }
                for (sourceID, entry) in bySource {
                    try store.markCursorsRejected(sourceID: sourceID, unitKeys: entry.unitKeys)
                }
                return bySource.map { ($0.key, $0.value.rowIDs, $0.value.unitKeys) }
            }
            for entry in rejected {
                guard let sourceState = sourceStates[entry.sourceID] else {
                    snapshotBuilder.remove(rowIDs: entry.rowIDs)
                    snapshotDirty = true
                    continue
                }
                for key in entry.unitKeys {
                    var cursor = sourceState.cursors[key] ?? AgentHistoryCursor(sourceID: entry.sourceID, unitKey: key)
                    cursor.isRejected = true
                    sourceState.cursors[key] = cursor
                }
                didDelete(sourceState, rowIDs: entry.rowIDs)
            }
            let count = rejected.reduce(0) { $0 + $1.rowIDs.count }
            if count > 0 {
                AgentHistoryLog.indexer.info("Agent History purged excluded sessions count=\(count, privacy: .public)")
            }
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.error("Agent History exclusion purge failed \(error.description, privacy: .public)")
            handleStorageFailure(error)
        } catch {}
    }

    // MARK: - Missing-unit bookkeeping

    func noteMissing(_ ref: AgentHistoryUnitRef) {
        if missingSince[ref] == nil {
            missingSince[ref] = now()
        }
    }

    func clearMissing(_ ref: AgentHistoryUnitRef) {
        missingSince[ref] = nil
        missingRechecked.remove(ref)
    }

    /// A unit that went missing may have moved (archived, compressed, renamed): one fresh
    /// discovery per affected source finds it under its new path and queues it. Units still
    /// missing stay on the list; deleting their rows (after the grace period and the
    /// mass-deletion guard) is the reconcile's job. Returns true when it queued work.
    func recheckMissingUnits() -> Bool {
        let unchecked = missingSince.keys.filter { !missingRechecked.contains($0) }
        guard !unchecked.isEmpty else {
            return false
        }
        var queued: [(ref: AgentHistoryUnitRef, mtimeNs: Int64)] = []
        for sourceID in Set(unchecked.map(\.sourceID)) {
            let refs = unchecked.filter { $0.sourceID == sourceID }
            missingRechecked.formUnion(refs)
            guard let sourceState = sourceStates[sourceID],
                  let units = try? sourceState.source.discoverUnits() else {
                continue
            }
            let byKey = Dictionary(units.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for ref in refs {
                guard let unit = byKey[ref.unitKey], unit.identity != nil else {
                    continue
                }
                sourceState.units[ref.unitKey] = unit
                queued.append((ref, unit.identity?.mtimeNs ?? 0))
            }
        }
        workQueue.enqueueBackfill(queued)
        return !queued.isEmpty
    }

    // MARK: - Adapter versions and maintenance

    /// After a version bump the source re-ingested every unit; store the new version now that
    /// the queue drained. A quit before that only repeats the re-ingest on the next start.
    func storePendingAdapterVersions() {
        guard let store else {
            return
        }
        for id in sourceOrder {
            guard let sourceState = sourceStates[id], let version = sourceState.pendingAdapterVersion else {
                continue
            }
            do {
                try store.setAdapterVersion(sourceID: id, version)
                sourceState.pendingAdapterVersion = nil
            } catch let error as AgentHistoryDatabaseError {
                AgentHistoryLog.indexer.error("Agent History adapter version not saved \(error.description, privacy: .public)")
            } catch {}
        }
    }

    /// A rewrite in batch commits grew the WAL by a whole transcript; fold it back (A-8).
    func checkpointAfterBatchedRewrite() {
        guard let writer, !writer.isInTransaction else {
            return
        }
        do {
            _ = try writer.query("PRAGMA wal_checkpoint(PASSIVE)") { $0.int64(0) }
        } catch let error as AgentHistoryDatabaseError {
            AgentHistoryLog.indexer.info("Agent History checkpoint skipped \(error.description, privacy: .public)")
        } catch {}
    }

    // MARK: - Helpers

    func sessionCountsByUnit(sourceID: Int64) throws -> [String: Int] {
        guard let store else {
            return [:]
        }
        let rows = try store.database.query(
            "SELECT unit_key, count(*) FROM sessions WHERE source_id = ? AND unit_key IS NOT NULL GROUP BY unit_key",
            [.integer(sourceID)]
        ) { ($0.string(0), Int($0.int64(1))) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    func didDelete(_ sourceState: AgentHistoryIndexerSourceState, rowIDs: [Int64]) {
        sourceState.countersDirty = true
        guard !rowIDs.isEmpty else {
            return
        }
        snapshotBuilder.remove(rowIDs: rowIDs)
        snapshotDirty = true
        lastUpdatedAt = now()
    }

    func logDeletionFailure(_ error: any Error, _ sourceState: AgentHistoryIndexerSourceState) {
        let databaseError = error as? AgentHistoryDatabaseError
        let description = databaseError?.description ?? "non-SQLite error"
        AgentHistoryLog.indexer.error(
            "Agent History deletion failed agent=\(sourceState.source.agent.rawValue, privacy: .public) \(description, privacy: .public)"
        )
        if let databaseError {
            handleStorageFailure(databaseError)
        }
    }
}
