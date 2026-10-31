import Foundation

/// Indexes opencode v1 and v2 sessions from `<root>/opencode.db`, read in place through short
/// read-only snapshots (`AgentHistoryDatabase.readExternalSnapshot`); the file is never written,
/// copied or checkpointed.
///
/// The whole database is one `.database` unit (`db`). Each `ingest` call does one step of a
/// small state machine kept in `cursor.adapterState` (`OpenCodeHistoryAdapterState`):
/// - **Full pass** (first run, `.fromStart`, or a stored rowid above the current maximum after a
///   delete or VACUUM): sessions newest first by keyset over `(lastChange DESC, id DESC)`, with
///   the target watermarks fixed when the pass starts; `sessionsPerBatch` sessions per call.
/// - **Incremental poll**: sessions with rows past the rowid watermarks of `part`, `message` and
///   `session_message`, or a session row whose `time_updated` passed the watermark; plus the hot
///   set (sessions touched in the last 10 minutes), whose in-place updates keep their rowids and
///   are found by re-reading each one's newest `time_updated`.
/// - **Reconcile** (every 15 minutes): a full `GROUP BY session_id` scan in 20k-rowid chunks,
///   each its own read transaction, re-queues sessions whose newest change moved and removes
///   sessions that are gone.
///
/// Every ingested session is replaced whole (`replaceContentOf`). Messages are the union of both
/// generations, deduped by message id (newer `time_updated` wins), in `(time_created, id)` order.
/// Child sessions are never stored (D13). Excluded and tombstoned sessions are reported per
/// session in `batch.rejected` (this unit holds many sessions, so the unit itself is never
/// rejected) and purged through `removedNativeIDs`.
///
/// Confined to the indexer queue: no mutable state lives on the instance, so no lock is needed.
final class OpenCodeHistorySource: AgentHistorySource, @unchecked Sendable {
    static let unitKey = "db"
    static let databaseFileName = "opencode.db"
    static let hotWindowMs: Int64 = 10 * 60 * 1_000
    static let reconcileIntervalMs: Int64 = 15 * 60 * 1_000
    static let reconcileChunkRows: Int64 = 20_000
    static let defaultSessionsPerBatch = 20
    /// SQLite VM steps between cancellation checks while one session is read.
    static let progressCheckInstructions: Int32 = 10_000

    let root: AgentHistorySourceRoot
    let adapterVersion = 1
    var agent: AgentHistoryAgent { .opencode }

    private let sessionsPerBatch: Int
    private let now: @Sendable () -> Int64

    init(
        root: AgentHistorySourceRoot,
        sessionsPerBatch: Int = OpenCodeHistorySource.defaultSessionsPerBatch,
        now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
    ) {
        self.root = root
        self.sessionsPerBatch = max(sessionsPerBatch, 1)
        self.now = now
    }

    var databasePath: String { root.path + "/" + Self.databaseFileName }

    var watchPaths: [String] { [root.path] }

    func discoverUnits() throws -> [AgentHistoryUnit] {
        guard let identity = AgentHistoryFileIdentity.stat(path: databasePath) else {
            return []
        }
        return [AgentHistoryUnit(key: Self.unitKey, path: databasePath, kind: .database,
                                 identity: identity, nativeSessionID: nil)]
    }

    /// `opencode.db` and its `-wal` map to the database; `log/`, `snapshot/` and the rest are noise.
    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        path == databasePath || path == databasePath + "-wal" ? .database(Self.unitKey) : nil
    }

    /// Database units are re-polled whenever asked (A-6); what changed is the adapter's business.
    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        guard let cursor else {
            return .new
        }
        guard unit.identity != nil else {
            return .missing
        }
        return .append(fromOffset: 0, nextSeq: cursor.nextSeq)
    }

    /// Opening the database before consent is not allowed (D11).
    func estimatedSessionCount() -> Int? {
        nil
    }

    /// Ids of non-child sessions that still exist upstream; nil when the database is missing or
    /// its schema is unknown (nothing can be said about deletions then).
    func existingNativeIDs() throws -> Set<String>? {
        guard AgentHistoryFileIdentity.stat(path: databasePath) != nil else {
            return nil
        }
        let ids: [String]? = try AgentHistoryDatabase.readExternalSnapshot(url: URL(fileURLWithPath: databasePath)) { db in
            guard case let .supported(schema) = try OpenCodeHistorySchema.probe(db) else {
                return nil
            }
            return try OpenCodeHistoryQueries.nonChildSessionIDs(db, schema: schema)
        }
        guard let ids else {
            return nil
        }
        return Set(ids.compactMap { agent.normalizedSessionID($0) })
    }

    // MARK: - Ingest

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        let identity = AgentHistoryFileIdentity.stat(path: unit.path)
        let base = cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key)
        var batch = AgentHistoryIngestBatch(cursor: base, hasMore: false)
        guard identity != nil else {
            batch.problem = .rootMissing
            return batch
        }

        var state = mode == .fromStart ? OpenCodeHistoryAdapterState() : OpenCodeHistoryAdapterState.decode(cursor?.adapterState)
        let url = URL(fileURLWithPath: unit.path)
        let nowMs = now()

        let detection: Detection
        do {
            detection = try detect(url: url, state: state, nowMs: nowMs)
        } catch {
            return finish(batch: &batch, failedWith: error, cursor: base)
        }
        guard case let .supported(schema, current, changed) = detection else {
            if case let .unsupported(reason) = detection {
                batch.problem = .unsupportedSchema(reason)
            }
            return batch
        }

        if state.backfill == nil {
            if let stored = state.watermarks, !stored.isAhead(of: current) {
                state.enqueue(changed)
                state.watermarks = current
            } else {
                state.startFullPass(target: current)
            }
        }

        if state.backfill == nil, state.isReconcileDue(nowMs: nowMs) {
            do {
                if try reconcile(url: url, schema: schema, current: current, state: &state, batch: &batch, context: context) {
                    state.lastReconcileAtMs = nowMs
                }
            } catch {
                AgentHistoryLog.indexer.info("opencode reconcile deferred")
            }
        }

        var stopped = false
        do {
            stopped = try ingestNextSessions(url: url, schema: schema, state: &state, batch: &batch,
                                             context: context, nowMs: nowMs)
        } catch {
            stopped = true
            batch.problem = Self.problem(for: error)
        }

        batch.hasMore = state.backfill != nil || !state.pending.isEmpty
        if stopped, batch.problem != nil {
            batch.hasMore = false
        }
        var next = base.advanced(identity: identity, byteOffset: 0, nextSeq: 0, fingerprint: nil,
                                 adapterState: state.encoded())
        next.watermark = state.watermarks?.sessionUpdatedMs
        batch.cursor = next
        AgentHistoryLog.indexer.debug(
            "opencode batch sessions=\(batch.sessions.count, privacy: .public) messages=\(batch.messages.count, privacy: .public) removed=\(batch.removedNativeIDs.count, privacy: .public) more=\(batch.hasMore, privacy: .public)"
        )
        return batch
    }

    // MARK: - Steps

    private enum Detection {
        case supported(OpenCodeHistorySchema, current: OpenCodeHistoryWatermarks, changed: [String])
        case unsupported(String)
    }

    /// One snapshot: schema, current watermarks, and (when incremental) the changed and hot
    /// sessions. Pure, so a retried snapshot cannot double-apply anything.
    private func detect(url: URL, state: OpenCodeHistoryAdapterState, nowMs: Int64) throws -> Detection {
        try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
            let schema: OpenCodeHistorySchema
            switch try OpenCodeHistorySchema.probe(db) {
            case let .unsupported(reason):
                return .unsupported(reason)
            case let .supported(probed):
                schema = probed
            }
            let current = try OpenCodeHistoryQueries.watermarks(db, schema: schema)
            guard state.backfill == nil, let stored = state.watermarks, !stored.isAhead(of: current) else {
                return .supported(schema, current: current, changed: [])
            }
            var changed = try OpenCodeHistoryQueries.changedSessionIDs(db, schema: schema, after: stored)
            for (id, last) in state.lastChange where last >= nowMs - Self.hotWindowMs && !changed.contains(id) {
                let latest = try OpenCodeHistoryQueries.lastChange(db, schema: schema, sessionID: id)
                if latest.map({ $0 > last }) ?? true {
                    changed.insert(id)
                }
            }
            return .supported(schema, current: current, changed: changed.sorted())
        }
    }

    /// Full `GROUP BY` scan in rowid chunks. Returns false when cancelled part-way.
    private func reconcile(
        url: URL,
        schema: OpenCodeHistorySchema,
        current: OpenCodeHistoryWatermarks,
        state: inout OpenCodeHistoryAdapterState,
        batch: inout AgentHistoryIngestBatch,
        context: AgentHistoryIngestContext
    ) throws -> Bool {
        var latest: [String: Int64] = [:]
        let tables: [(OpenCodeHistoryQueries.ContentTable, Int64)] = [
            (.part, current.partRowID), (.message, current.messageRowID),
        ] + (schema.hasV2 ? [(.sessionMessage, current.sessionMessageRowID)] : [])
        for (table, maxRowID) in tables {
            var from: Int64 = 0
            while from < maxRowID {
                if context.isCancelled() { return false }
                let to = from + Self.reconcileChunkRows
                let chunk = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
                    try OpenCodeHistoryQueries.lastChangeChunk(db, table: table, fromRowID: from, toRowID: to)
                }
                latest.merge(chunk, uniquingKeysWith: max)
                from = to
            }
        }
        let sessionRows = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
            try OpenCodeHistoryQueries.sessionRowChanges(db, schema: schema)
        }

        var moved: [String] = []
        for (id, rowChange) in sessionRows {
            let last = max(rowChange, latest[id] ?? rowChange)
            if state.lastChange[id].map({ last > $0 }) ?? true {
                moved.append(id)
            }
        }
        state.enqueue(moved.sorted())
        for id in state.lastChange.keys where sessionRows[id] == nil {
            state.lastChange[id] = nil
            state.pending.removeAll { $0 == id }
            if let nativeID = agent.normalizedSessionID(id) {
                batch.removedNativeIDs.insert(nativeID)
            }
        }
        return true
    }

    /// Reads the next sessions of the full pass or the pending queue into `batch`. Returns true
    /// when it stopped early (cancelled or a read failed); the unread sessions stay queued.
    private func ingestNextSessions(
        url: URL,
        schema: OpenCodeHistorySchema,
        state: inout OpenCodeHistoryAdapterState,
        batch: inout AgentHistoryIngestBatch,
        context: AgentHistoryIngestContext,
        nowMs: Int64
    ) throws -> Bool {
        var page: [OpenCodeHistoryKeyset] = []
        if let backfill = state.backfill {
            page = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
                try OpenCodeHistoryQueries.backfillPage(db, schema: schema, targetMs: backfill.target.sessionUpdatedMs,
                                                        after: backfill.after, limit: sessionsPerBatch)
            }
        } else {
            page = state.pending.prefix(sessionsPerBatch).map { OpenCodeHistoryKeyset(lastChangeMs: 0, id: $0) }
        }

        var sourceBytes = 0
        var processed = 0
        for entry in page {
            if context.isCancelled() {
                return true
            }
            if processed > 0, batch.messages.count >= context.limits.messages || sourceBytes >= context.limits.sourceBytes {
                break
            }
            do {
                sourceBytes += try ingestSession(id: entry.id, url: url, schema: schema, state: &state,
                                                 batch: &batch, context: context)
            } catch let error as AgentHistoryDatabaseError where error.kind == .interrupted {
                return true
            }
            processed += 1
            state.markProcessed(entry)
        }

        if var backfill = state.backfill, processed == page.count, page.count < sessionsPerBatch {
            backfill.after = nil
            state.watermarks = backfill.target
            state.backfill = nil
            state.lastReconcileAtMs = nowMs
        }
        return false
    }

    /// Reads one session and adds it to `batch`; returns the indexed text's byte count.
    private func ingestSession(
        id: String,
        url: URL,
        schema: OpenCodeHistorySchema,
        state: inout OpenCodeHistoryAdapterState,
        batch: inout AgentHistoryIngestBatch,
        context: AgentHistoryIngestContext
    ) throws -> Int {
        guard let nativeID = agent.normalizedSessionID(id) else {
            batch.diagnostics.skippedSessions[id] = .invalidSessionID
            return 0
        }
        let isCancelled = context.isCancelled
        let content = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
            db.setProgressHandler(everyInstructions: Self.progressCheckInstructions, isCancelled)
            return try OpenCodeHistoryQueries.loadSession(db, schema: schema, sessionID: id)
        }
        guard let content else {
            state.lastChange[id] = nil
            batch.removedNativeIDs.insert(nativeID)
            return 0
        }
        state.lastChange[id] = content.lastChangeMs
        return OpenCodeHistorySessionBuilder.add(content, nativeID: nativeID, to: &batch, context: context)
    }

    // MARK: - Errors

    private func finish(
        batch: inout AgentHistoryIngestBatch,
        failedWith error: Error,
        cursor: AgentHistoryCursor
    ) -> AgentHistoryIngestBatch {
        if let error = error as? AgentHistoryDatabaseError, error.kind == .interrupted {
            batch.hasMore = true
        } else {
            batch.problem = Self.problem(for: error)
        }
        batch.cursor = cursor
        return batch
    }

    static func problem(for error: Error) -> AgentHistorySourceProblem {
        guard let error = error as? AgentHistoryDatabaseError else {
            return .unreadableDatabase(code: 1)
        }
        AgentHistoryLog.indexer.info("opencode read failed code=\(error.code, privacy: .public)")
        return error.kind == .busy ? .busy : .unreadableDatabase(code: error.code)
    }
}

/// The opencode adapter's cursor state (`AgentHistoryCursor.adapterState`, JSON).
struct OpenCodeHistoryAdapterState: Codable, Equatable, Sendable {
    struct FullPass: Codable, Equatable, Sendable {
        /// Watermarks when the pass started; adopted when it ends.
        var target: OpenCodeHistoryWatermarks
        var after: OpenCodeHistoryKeyset?
    }

    /// nil until the first full pass completed.
    var watermarks: OpenCodeHistoryWatermarks?
    var backfill: FullPass?
    /// Session ids found changed, waiting for an ingest call.
    var pending: [String] = []
    /// Newest `time_updated` per session seen at its last ingest (hot set and reconcile).
    var lastChange: [String: Int64] = [:]
    var lastReconcileAtMs: Int64?

    static func decode(_ data: Data?) -> OpenCodeHistoryAdapterState {
        guard let data, let state = try? JSONDecoder().decode(Self.self, from: data) else {
            return OpenCodeHistoryAdapterState()
        }
        return state
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    mutating func startFullPass(target: OpenCodeHistoryWatermarks) {
        backfill = FullPass(target: target, after: nil)
        pending = []
    }

    mutating func enqueue(_ ids: [String]) {
        var queued = Set(pending)
        for id in ids where queued.insert(id).inserted {
            pending.append(id)
        }
    }

    mutating func markProcessed(_ entry: OpenCodeHistoryKeyset) {
        if backfill != nil {
            backfill?.after = entry
        } else {
            pending.removeAll { $0 == entry.id }
        }
    }

    func isReconcileDue(nowMs: Int64) -> Bool {
        guard watermarks != nil else { return false }
        return lastReconcileAtMs.map { nowMs - $0 >= OpenCodeHistorySource.reconcileIntervalMs } ?? true
    }
}
