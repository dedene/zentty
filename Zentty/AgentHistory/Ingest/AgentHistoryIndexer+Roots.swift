import Foundation

/// Which roots the indexer reads. Indexer queue only.
///
/// - `makeSources()` (the root locator) runs at start and again on every full reconcile, so a
///   root that appears while Zentty runs (a first Codex or Grok run) is registered and read
///   without a relaunch. A source whose registration failed (busy) is retried the same way.
/// - A `sources` row of an enabled agent whose root the locator no longer reports (deleted
///   while Zentty was quit, or an env-configured root of a launch without that variable) gets an
///   inactive placeholder: it is treated like a missing root, so the first full reconcile
///   records it, one `schedule.interval` later its rows are purged and the row is disabled.
///   Until then Settings lists it as "Folder not found". If the locator reports the root again
///   first, a real source replaces the placeholder and keeps the rows.
extension AgentHistoryIndexer {
    /// Registers each source of an enabled agent (a `sources` row per root, a placeholder taking
    /// over an inactive stored row), loads its cursors and reconciles it (queues its changed
    /// units, mirrors deletions). A source whose stored adapter version differs from the
    /// adapter's loses its cursors, so every unit with rows is replaced whole; the new version is
    /// stored once the source has drained (`becomeIdle`).
    func activateSources(_ sources: [any AgentHistorySource], includeStoredRoots: Bool = false) {
        var activated = registerSources(sources)
        if includeStoredRoots {
            activated += registerInactiveStoredRoots()
        }
        if !activated.isEmpty {
            reconcile(sourceIDs: activated, isFull: true, locatesRoots: false)
        }
    }

    /// Full reconciles: sources the locator reports now that are not active yet. Returns the
    /// ids registered (to be reconciled by the caller).
    func registerNewlyLocatedSources() -> [Int64] {
        let active = Set(sourceStates.values.filter { !$0.isInactive }.map { RootKey($0.source.root) })
        let fresh = makeSources().filter { source in
            configuration.enabledAgents.contains(source.agent) && !active.contains(RootKey(source.root))
        }
        guard !fresh.isEmpty else {
            return []
        }
        let registered = registerSources(fresh)
        if !registered.isEmpty {
            AgentHistoryLog.indexer.info("Agent History found new roots count=\(registered.count, privacy: .public)")
        }
        return registered
    }

    /// Upserts each source's row and builds its state; returns the ids that became active.
    /// Sources of agents that are off, and rows already active, are skipped.
    func registerSources(_ sources: [any AgentHistorySource]) -> [Int64] {
        guard let store else {
            return []
        }
        var activated: [Int64] = []
        for source in sources where configuration.enabledAgents.contains(source.agent) {
            let row: AgentHistorySourceRow
            let cursors: [String: AgentHistoryCursor]
            var pendingAdapterVersion: Int?
            do {
                row = try store.upsertSource(
                    agent: source.agent, root: source.root.path, currentAdapterVersion: source.adapterVersion
                )
                if let existing = sourceStates[row.id], !existing.isInactive {
                    continue
                }
                if row.adapterVersion != source.adapterVersion {
                    try store.deleteCursors(sourceID: row.id)
                    pendingAdapterVersion = source.adapterVersion
                    AgentHistoryLog.indexer.info(
                        "Agent History adapter version changed agent=\(source.agent.rawValue, privacy: .public) from=\(row.adapterVersion, privacy: .public) to=\(source.adapterVersion, privacy: .public); re-ingesting"
                    )
                }
                cursors = try store.cursors(sourceID: row.id)
                if !row.enabled {
                    try store.setSourceEnabled(id: row.id, true)
                }
            } catch let error as AgentHistoryDatabaseError {
                // Retried by the next full reconcile (the source is not active yet).
                AgentHistoryLog.indexer.error(
                    "Agent History could not register \(source.agent.rawValue, privacy: .public) source \(error.description, privacy: .public)"
                )
                if error.kind != .busy {
                    handleStorageFailure(error)
                }
                continue
            } catch {
                continue
            }
            let sourceState = AgentHistoryIndexerSourceState(source: source, id: row.id, cursors: cursors)
            sourceState.pendingAdapterVersion = pendingAdapterVersion
            if sourceStates[row.id] == nil {
                sourceOrder.append(row.id)
            }
            sourceStates[row.id] = sourceState
            activated.append(row.id)
        }
        return activated
    }

    /// Placeholders for enabled rows of enabled agents that no source claimed. A row without
    /// sessions has nothing to purge: it is only disabled.
    func registerInactiveStoredRoots() -> [Int64] {
        guard let writer, let store else {
            return []
        }
        var placeholders: [Int64] = []
        do {
            for row in try store.sources()
            where row.enabled && configuration.enabledAgents.contains(row.agent) && sourceStates[row.id] == nil {
                guard try store.sessionCount(sourceID: row.id) > 0 else {
                    try writer.transaction {
                        try store.deleteCursors(sourceID: row.id)
                        try store.setSourceEnabled(id: row.id, false)
                    }
                    continue
                }
                let placeholder = AgentHistoryInactiveSource(
                    root: AgentHistorySourceRoot(agent: row.agent, path: row.root, isDefault: false)
                )
                let sourceState = AgentHistoryIndexerSourceState(source: placeholder, id: row.id, cursors: [:])
                sourceState.discoveryProblem = .rootMissing
                sourceStates[row.id] = sourceState
                sourceOrder.append(row.id)
                placeholders.append(row.id)
            }
        } catch {
            logWriteFailure(error, action: "check stored roots")
        }
        if !placeholders.isEmpty {
            AgentHistoryLog.indexer.info(
                "Agent History stored roots not found count=\(placeholders.count, privacy: .public); purging after the grace period"
            )
        }
        return placeholders
    }

    /// After a placeholder's rows were purged: the row is disabled and the source forgotten.
    func retireInactiveSource(_ sourceState: AgentHistoryIndexerSourceState) {
        guard sourceState.isInactive else {
            return
        }
        let id = sourceState.id
        do {
            try store?.setSourceEnabled(id: id, false)
        } catch {
            logWriteFailure(error, action: "disable a stored root")
        }
        sourceStates[id] = nil
        sourceOrder.removeAll { $0 == id }
        missingSince = missingSince.filter { $0.key.sourceID != id }
        missingRechecked = missingRechecked.filter { $0.sourceID != id }
        workQueue.removeAll(sourceID: id)
    }

    /// `(agent, root)`, the identity of a `sources` row.
    struct RootKey: Hashable {
        let agent: AgentHistoryAgent
        let path: String

        init(_ root: AgentHistorySourceRoot) {
            agent = root.agent
            path = root.path
        }
    }
}

extension AgentHistoryIndexerSourceState {
    /// A stored root the locator no longer reports (see `AgentHistoryIndexer+Roots.swift`).
    var isInactive: Bool {
        source is AgentHistoryInactiveSource
    }
}

/// Stands in for a stored root the locator no longer reports. It lists nothing and is never
/// read; the indexer treats its root as missing.
final class AgentHistoryInactiveSource: AgentHistorySource {
    let root: AgentHistorySourceRoot

    init(root: AgentHistorySourceRoot) {
        self.root = root
    }

    var agent: AgentHistoryAgent { root.agent }
    var adapterVersion: Int { 0 }
    var watchPaths: [String] { [] }

    func discoverUnits() throws -> [AgentHistoryUnit] {
        []
    }

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        nil
    }

    func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit {
        AgentHistoryUnit(key: unit.key, path: unit.path, kind: unit.kind, identity: nil, nativeSessionID: unit.nativeSessionID)
    }

    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        .missing
    }

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        throw CancellationError()
    }

    func estimatedSessionCount() -> Int? {
        nil
    }
}
