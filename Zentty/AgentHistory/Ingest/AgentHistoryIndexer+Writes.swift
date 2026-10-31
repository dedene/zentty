import Foundation

/// User-driven writes: exclusions, tombstones, opens, rebuild and source purge. All of them run
/// on the indexer queue, between batches, so they never race the step loop.
///
/// Tightening the rules (a new exclusion, a removed session) deletes the stored rows at once and
/// marks single-session units rejected, so they are skipped until their file is replaced.
/// Database units (opencode `db`, Codex `state`) hold many sessions and are never rejected as a
/// whole; they are polled right away instead, so the adapter records the rules it was read under
/// and re-admits the sessions when the rules relax. Relaxing the rules (an exclusion lifted,
/// Restore All) forgets every rejected cursor, so those units are read again from the start, and
/// reconciles.
extension AgentHistoryIndexer {
    /// `meta` key: the canonical excluded folders (JSON array) the index was last written under.
    static let excludedFoldersMetaKey = "excluded_folders"

    // MARK: - Public API

    /// Tombstones a session: its rows go (in every source of that agent), its single-session
    /// units are marked rejected, and later reads skip it. `completion` runs on main with false
    /// when nothing could be written.
    func removeSession(_ key: AgentHistorySessionKey, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            let removed = removeSessionOnQueue(key)
            guard let completion else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(removed)
                }
            }
        }
    }

    /// Deletes every tombstone and reads the removed sessions again.
    func restoreAllRemovedSessions() {
        queue.async { [self] in
            restoreAllOnQueue()
        }
    }

    /// Counts one open (resume, jump or fork) and refreshes that session's summary.
    func recordOpen(sessionRowID: Int64, atMs: Int64) {
        queue.async { [self] in
            recordOpenOnQueue(sessionRowID: sessionRowID, atMs: atMs)
        }
    }

    /// Replaces the index with a fresh file and re-ingests everything, keeping tombstones and
    /// usage. Also the way out of a failed index (corrupt, newer schema).
    func rebuild() {
        queue.async { [self] in
            rebuildOnQueue()
        }
    }

    /// Turns one agent off (D4): its sessions and cursors go, its `sources` rows are disabled and
    /// its sources stop being read until a configuration enables the agent again.
    func purgeSource(agent: AgentHistoryAgent) {
        queue.async { [self] in
            purgeSourceOnQueue(agent: agent)
        }
    }

    // MARK: - Exclusions

    /// Routes a change of excluded folders: new folders purge at once, lifted folders re-read
    /// what they held back.
    func applyExclusionChange(from previous: [String], to next: [String]) {
        let before = Set(AgentHistoryExclusionMatcher(folders: previous).canonicalFolders)
        let matcher = AgentHistoryExclusionMatcher(folders: next)
        let after = Set(matcher.canonicalFolders)
        guard before != after else {
            return
        }
        admission = AgentHistoryAdmission(exclusions: matcher, tombstones: admission.tombstones)
        if !after.subtracting(before).isEmpty {
            purgeExcludedSessions()
            pollDatabaseUnits(agent: nil)
        }
        if !before.subtracting(after).isEmpty {
            readRejectedUnitsAgain()
        }
        persistExclusions()
    }

    /// At start: compares the excluded folders with the ones the index was last written under
    /// (the setting can change while the indexer is off). Lifted folders re-read what they held
    /// back; new ones were purged by the start reconcile, and database units are flagged so a
    /// relax before their next clean read restarts them.
    func reconcileStoredExclusions() {
        guard let store else {
            return
        }
        let current = Set(admission.exclusions.canonicalFolders)
        var stored: Set<String>?
        do {
            stored = try store.meta(Self.excludedFoldersMetaKey)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                .map(Set.init)
        } catch {
            logWriteFailure(error, action: "read the stored exclusions")
            return
        }
        if let stored {
            if !current.subtracting(stored).isEmpty {
                flagDatabaseUnitsPending(agent: nil)
            }
            if !stored.subtracting(current).isEmpty {
                readRejectedUnitsAgain()
            }
        }
        persistExclusions()
    }

    func persistExclusions() {
        guard let store else {
            return
        }
        let folders = admission.exclusions.canonicalFolders.sorted()
        guard let data = try? JSONEncoder().encode(folders), let text = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try store.setMeta(Self.excludedFoldersMetaKey, text)
        } catch {
            logWriteFailure(error, action: "store the exclusions")
        }
    }

    // MARK: - Tombstones

    func removeSessionOnQueue(_ key: AgentHistorySessionKey) -> Bool {
        guard lifecycle == .running, !isWritingSuspended, let writer, let store else {
            return false
        }
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        do {
            let (rowIDs, rejectedUnits) = try writer.transaction { () -> ([Int64], [Int64: [String]]) in
                let stored = try store.database.query(
                    """
                    SELECT s.source_id, s.unit_key FROM sessions s JOIN sources src ON src.id = s.source_id
                    WHERE src.agent = ? AND s.native_id = ? AND s.unit_key IS NOT NULL
                    """,
                    [.text(key.agent.rawValue), .text(key.nativeID)]
                ) { (sourceID: $0.int64(0), unitKey: $0.string(1)) }
                let rowIDs = try store.addTombstone(key, removedAtMs: nowMs)
                var units: [Int64: Set<String>] = [:]
                for row in stored where isSingleSessionUnit(sourceID: row.sourceID, unitKey: row.unitKey) {
                    units[row.sourceID, default: []].insert(row.unitKey)
                }
                // Units of this session that were never indexed are rejected up front too.
                for (sourceID, sourceState) in sourceStates where sourceState.source.agent == key.agent {
                    for unit in sourceState.units.values where unit.kind != .database {
                        guard let raw = unit.nativeSessionID,
                              (key.agent.normalizedSessionID(raw) ?? raw) == key.nativeID else {
                            continue
                        }
                        units[sourceID, default: []].insert(unit.key)
                    }
                }
                let sorted = units.mapValues { $0.sorted() }
                for (sourceID, unitKeys) in sorted {
                    try store.markCursorsRejected(sourceID: sourceID, unitKeys: unitKeys)
                }
                return (rowIDs, sorted)
            }
            markRejectedInCache(rejectedUnits)
            var tombstones = admission.tombstones
            tombstones.insert(key)
            admission = AgentHistoryAdmission(exclusions: admission.exclusions, tombstones: tombstones)
            removeFromSnapshot(rowIDs)
            for sourceState in sourceStates.values where sourceState.source.agent == key.agent {
                sourceState.countersDirty = true
            }
            AgentHistoryLog.indexer.info(
                "Agent History removed a session agent=\(key.agent.rawValue, privacy: .public) rows=\(rowIDs.count, privacy: .public)"
            )
        } catch {
            logWriteFailure(error, action: "remove session")
            return false
        }
        pollDatabaseUnits(agent: key.agent)
        updateProgressState()
        publish(force: true)
        scheduleStep()
        return true
    }

    func restoreAllOnQueue() {
        guard lifecycle == .running, !isWritingSuspended, let writer, let store else {
            return
        }
        do {
            let count = try writer.transaction { try store.removeAllTombstones() }
            admission = AgentHistoryAdmission(exclusions: admission.exclusions, tombstones: [])
            AgentHistoryLog.indexer.info("Agent History restored removed sessions count=\(count, privacy: .public)")
        } catch {
            logWriteFailure(error, action: "restore removed sessions")
            return
        }
        readRejectedUnitsAgain()
        updateProgressState()
        publish(force: true)
        scheduleStep()
    }

    // MARK: - Re-admission

    /// The rules relaxed: forget rejected cursors (those units read again from byte 0; units
    /// still rejected are rejected again), restart database units whose adapter may not have
    /// seen the stricter rules, then reconcile so every unit is classified again.
    func readRejectedUnitsAgain() {
        guard let writer, let store else {
            return
        }
        let stale = admissionPendingUnits
        do {
            try writer.transaction {
                try store.clearRejectedCursors()
                for ref in stale.sorted(by: { ($0.sourceID, $0.unitKey) < ($1.sourceID, $1.unitKey) }) {
                    try store.deleteCursor(sourceID: ref.sourceID, unitKey: ref.unitKey)
                }
            }
        } catch {
            logWriteFailure(error, action: "clear rejected cursors")
            return
        }
        admissionPendingUnits = []
        for sourceState in sourceStates.values {
            sourceState.cursors = sourceState.cursors.filter { !$0.value.isRejected }
        }
        for ref in stale {
            sourceStates[ref.sourceID]?.cursors[ref.unitKey] = nil
        }
        reconcile(sourceIDs: sourceOrder, isFull: false)
    }

    /// Reads every database unit (of one agent, or all) once, now, in this queue turn, so the
    /// adapter applies the rules that just tightened before anything can relax them again
    /// (opencode keeps per-session admission in its cursor). A unit whose read did not finish
    /// cleanly stays in `admissionPendingUnits` and is re-read from the start when rules relax.
    func pollDatabaseUnits(agent: AgentHistoryAgent?) {
        for ref in flagDatabaseUnitsPending(agent: agent) where !isWritingSuspended {
            _ = process(ref, tier: .live)
        }
    }

    /// Adds every read database unit (of one agent, or all) to `admissionPendingUnits`; returns
    /// them. A unit never read is skipped: its first read applies the current rules anyway.
    @discardableResult
    func flagDatabaseUnitsPending(agent: AgentHistoryAgent?) -> [AgentHistoryUnitRef] {
        var refs: [AgentHistoryUnitRef] = []
        for id in sourceOrder {
            guard let sourceState = sourceStates[id], agent == nil || sourceState.source.agent == agent else {
                continue
            }
            for unit in sourceState.units.values.sorted(by: { $0.key < $1.key })
            where unit.kind == .database && sourceState.cursors[unit.key] != nil {
                refs.append(AgentHistoryUnitRef(sourceID: id, unitKey: unit.key))
            }
        }
        admissionPendingUnits.formUnion(refs)
        return refs
    }

    // MARK: - Opens

    func recordOpenOnQueue(sessionRowID: Int64, atMs: Int64) {
        guard lifecycle == .running, !isWritingSuspended, let store else {
            return
        }
        do {
            guard try store.recordOpen(sessionID: sessionRowID, atMs: atMs) else {
                return
            }
            let summaries = try store.sessionSummaries(rowIDs: [sessionRowID])
            snapshotBuilder.upsert(summaries)
            snapshotDirty = true
        } catch {
            logWriteFailure(error, action: "record open")
            return
        }
        publish()
    }

    // MARK: - Source purge

    func purgeSourceOnQueue(agent: AgentHistoryAgent) {
        configuration.enabledAgents.remove(agent)
        guard lifecycle == .running, let writer, let store else {
            return
        }
        let removedIDs: [Int64]
        do {
            removedIDs = try writer.transaction { () -> [Int64] in
                var removed: [Int64] = []
                for row in try store.sources() where row.agent == agent {
                    removed += try store.deleteSessions(sourceID: row.id)
                    try store.deleteCursors(sourceID: row.id)
                    try store.setSourceEnabled(id: row.id, false)
                }
                return removed
            }
        } catch {
            logWriteFailure(error, action: "purge source")
            return
        }
        for id in sourceOrder {
            guard let sourceState = sourceStates[id], sourceState.source.agent == agent else {
                continue
            }
            workQueue.removeAll(sourceID: id)
            sourceStates[id] = nil
            missingSince = missingSince.filter { $0.key.sourceID != id }
            missingRechecked = missingRechecked.filter { $0.sourceID != id }
            batchedRewrites = batchedRewrites.filter { $0.sourceID != id }
            admissionPendingUnits = admissionPendingUnits.filter { $0.sourceID != id }
            forgetEventState(sourceID: id)
        }
        sourceOrder.removeAll { sourceStates[$0] == nil }
        removeFromSnapshot(removedIDs)
        AgentHistoryLog.indexer.info(
            "Agent History purged source agent=\(agent.rawValue, privacy: .public) sessions=\(removedIDs.count, privacy: .public)"
        )
        scheduleStreamRefresh()
        updateProgressState()
        publish(force: true)
        scheduleStep()
    }

    // MARK: - Helpers

    func isSingleSessionUnit(sourceID: Int64, unitKey: String) -> Bool {
        guard let unit = sourceStates[sourceID]?.units[unitKey] else {
            return false
        }
        return unit.kind != .database
    }

    func markRejectedInCache(_ units: [Int64: [String]]) {
        for (sourceID, unitKeys) in units {
            guard let sourceState = sourceStates[sourceID] else {
                continue
            }
            for key in unitKeys {
                var cursor = sourceState.cursors[key] ?? AgentHistoryCursor(sourceID: sourceID, unitKey: key)
                cursor.isRejected = true
                sourceState.cursors[key] = cursor
            }
        }
    }

    func removeFromSnapshot(_ rowIDs: [Int64]) {
        guard !rowIDs.isEmpty else {
            return
        }
        snapshotBuilder.remove(rowIDs: rowIDs)
        snapshotDirty = true
        lastUpdatedAt = now()
    }

    func logWriteFailure(_ error: any Error, action: String) {
        guard let databaseError = error as? AgentHistoryDatabaseError else {
            AgentHistoryLog.indexer.error("Agent History could not \(action, privacy: .public) outside SQLite")
            return
        }
        AgentHistoryLog.indexer.error(
            "Agent History could not \(action, privacy: .public) \(databaseError.description, privacy: .public)"
        )
        handleStorageFailure(databaseError)
    }
}
