import Foundation

/// Indexes opencode v1 and v2 sessions from `<root>/opencode.db`, read in place through short
/// read-only snapshots (`AgentHistoryDatabase.readExternalSnapshot`); the file is never written,
/// copied or checkpointed.
///
/// The whole database is one `.database` unit (`db`). Each `ingest` call does one step of a
/// small state machine kept in `cursor.adapterState` (`OpenCodeHistoryAdapterState`):
/// - **Full pass** (first run, `.fromStart`, missing or undecodable state, or a database file
///   that was replaced): sessions newest first by keyset over `(lastChange DESC, id DESC)`, with
///   the target watermarks fixed when the pass starts; `sessionsPerBatch` sessions per call.
/// - **Incremental poll**: sessions with rows past the rowid watermarks of `part`, `message` and
///   `session_message`, or a session row whose `time_updated` passed the watermark; plus the hot
///   set (sessions touched in the last 10 minutes), whose in-place updates keep their rowids and
///   are found by re-reading each one's newest `time_updated`, and whose deleted rows are found
///   by its content signature (count and rowids of its rows; see `contentSignatures`).
/// - **Rowids went backwards** (opencode deleted its newest rows: undo/revert cleanup, deleting
///   the latest session, or a VACUUM renumbering them): the watermarks drop to the current
///   maxima, every hot session is re-read (the deleted rows most likely were its own), and the
///   reconcile runs at once. No full pass.
/// - **Reconcile** (every 15 minutes, or at once after rowids went backwards): a full
///   `GROUP BY session_id` scan in 20k-rowid chunks, each its own read transaction, re-queues
///   sessions whose newest change or content signature moved (opencode's delete-message and
///   delete-part API removes rows without touching the session row) and removes sessions that
///   are gone.
///
/// Every ingested session is replaced whole (`replaceContentOf`). Messages are the union of both
/// generations, deduped by message id (newer `time_updated` wins), in `(time_created, id)` order.
/// Child sessions are never stored (D13). Admission is decided from the session rows before any
/// message is read. Excluded and tombstoned sessions are reported per session in
/// `batch.rejected` (this unit holds many sessions, so the unit itself is never rejected),
/// purged through `removedNativeIDs`, and kept in `state.rejected`; when the exclusions or
/// tombstones change, the sessions they could affect are read again (`applyAdmissionChanges`).
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

    /// Reads one session in an open snapshot (`OpenCodeHistoryQueries.loadSession`); a seam so
    /// tests can make one session fail.
    typealias SessionLoader = @Sendable (
        AgentHistoryDatabase, OpenCodeHistorySchema, String, (OpenCodeHistorySessionContent) -> Bool
    ) throws -> OpenCodeHistorySessionContent?

    private let sessionsPerBatch: Int
    private let now: @Sendable () -> Int64
    private let loadSession: SessionLoader

    init(
        root: AgentHistorySourceRoot,
        sessionsPerBatch: Int = OpenCodeHistorySource.defaultSessionsPerBatch,
        now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) },
        loadSession: @escaping SessionLoader = { db, schema, id, admits in
            try OpenCodeHistoryQueries.loadSession(db, schema: schema, sessionID: id, admits: admits)
        }
    ) {
        self.root = root
        self.sessionsPerBatch = max(sessionsPerBatch, 1)
        self.now = now
        self.loadSession = loadSession
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

        if Self.isReplacement(of: cursor?.identity, by: identity) {
            state.startFullPass(target: current)
        } else if state.backfill == nil {
            if let stored = state.watermarks {
                state.enqueue(changed)
                state.watermarks = current
                if stored.isAhead(of: current) {
                    state.lastReconcileAtMs = nil
                }
            } else {
                state.startFullPass(target: current)
            }
        }

        applyAdmissionChanges(url: url, schema: schema, admission: context.admission, state: &state)

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

    /// A different file now sits at the database path (restored backup, re-created database):
    /// nothing stored about the old one applies.
    static func isReplacement(of stored: AgentHistoryFileIdentity?, by current: AgentHistoryFileIdentity?) -> Bool {
        guard let stored, let current else {
            return false
        }
        return stored.dev != current.dev || stored.ino != current.ino
    }

    /// One snapshot: schema, current watermarks, and (when incremental) the changed and hot
    /// sessions. Pure, so a retried snapshot cannot double-apply anything. When rowids went
    /// backwards, detection runs from the lower of the stored and current maxima per table, and
    /// every hot session counts as changed.
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
            guard state.backfill == nil, let stored = state.watermarks else {
                return .supported(schema, current: current, changed: [])
            }
            let wentBack = stored.isAhead(of: current)
            var changed = try OpenCodeHistoryQueries.changedSessionIDs(db, schema: schema,
                                                                       after: stored.clamped(to: current))
            for (id, last) in state.lastChange where last >= nowMs - Self.hotWindowMs && !changed.contains(id) {
                if wentBack {
                    changed.insert(id)
                    continue
                }
                let marks = try OpenCodeHistoryQueries.changeMarks(db, schema: schema, sessionID: id)
                if state.hasChanged(id, since: marks) {
                    changed.insert(id)
                }
            }
            return .supported(schema, current: current, changed: changed.sorted())
        }
    }

    /// Full `GROUP BY` scan in rowid chunks: per session the newest change and the content
    /// signature (summed over chunks), so rows deleted anywhere in a session are found even when
    /// no timestamp or watermark moved. Returns false when cancelled part-way.
    private func reconcile(
        url: URL,
        schema: OpenCodeHistorySchema,
        current: OpenCodeHistoryWatermarks,
        state: inout OpenCodeHistoryAdapterState,
        batch: inout AgentHistoryIngestBatch,
        context: AgentHistoryIngestContext
    ) throws -> Bool {
        var latest: [String: OpenCodeHistoryChangeMarks] = [:]
        let tables: [(OpenCodeHistoryQueries.ContentTable, Int64)] = [
            (.part, current.partRowID), (.message, current.messageRowID),
        ] + (schema.hasV2 ? [(.sessionMessage, current.sessionMessageRowID)] : [])
        for (table, maxRowID) in tables {
            var from: Int64 = 0
            while from < maxRowID {
                if context.isCancelled() { return false }
                let to = from + Self.reconcileChunkRows
                let chunk = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
                    try OpenCodeHistoryQueries.changeChunk(db, table: table, fromRowID: from, toRowID: to)
                }
                latest.merge(chunk) { old, new in
                    OpenCodeHistoryChangeMarks(lastChangeMs: max(old.lastChangeMs ?? .min, new.lastChangeMs ?? .min),
                                               contentSignature: old.contentSignature &+ new.contentSignature)
                }
                from = to
            }
        }
        let sessionRows = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
            try OpenCodeHistoryQueries.sessionRowChanges(db, schema: schema)
        }

        var moved: [String] = []
        for (id, rowChange) in sessionRows {
            let content = latest[id]
            let marks = OpenCodeHistoryChangeMarks(
                lastChangeMs: max(rowChange, content?.lastChangeMs ?? rowChange),
                contentSignature: content?.contentSignature ?? 0
            )
            if state.hasChanged(id, since: marks) {
                moved.append(id)
            }
        }
        state.enqueue(moved.sorted())
        for id in Set(state.lastChange.keys).union(state.rejected.keys) where sessionRows[id] == nil {
            state.forget(id)
            if let nativeID = agent.normalizedSessionID(id) {
                batch.removedNativeIDs.insert(nativeID)
            }
        }
        return true
    }

    /// Reads the next sessions of the full pass or the pending queue into `batch`. Returns true
    /// when it stopped early (cancelled); the unread sessions stay queued. A session whose own
    /// rows cannot be read is skipped as `.unreadable` and retried only once it changes, so it
    /// never blocks the sessions behind it; database-wide failures (busy, gone, not a database)
    /// are thrown and stop the call.
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
            } catch {
                guard Self.isSessionLocal(error) else {
                    if (error as? AgentHistoryDatabaseError)?.kind == .interrupted {
                        return true
                    }
                    throw error
                }
                skipUnreadable(entry, error: error, url: url, schema: schema, state: &state, batch: &batch, nowMs: nowMs)
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
        let loadSession = loadSession
        let admission = context.admission
        let content = try AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
            db.setProgressHandler(everyInstructions: Self.progressCheckInstructions, isCancelled)
            return try loadSession(db, schema, id) { header in
                admission.decide(agent: .opencode, nativeID: nativeID,
                                 cwd: OpenCodeHistorySessionBuilder.cwd(of: header)) == .admit
            }
        }
        guard let content else {
            state.forget(id)
            batch.removedNativeIDs.insert(nativeID)
            return 0
        }
        let bytes = OpenCodeHistorySessionBuilder.add(content, nativeID: nativeID, to: &batch, context: context)
        state.record(id, lastChangeMs: content.lastChangeMs, contentSignature: content.contentSignature,
                     rejected: batch.rejected[nativeID] != nil)
        return bytes
    }

    /// Records a session whose read failed and remembers its newest change, so the hot set and
    /// the reconcile retry it only after opencode writes to it again. Its stored rows stay.
    private func skipUnreadable(
        _ entry: OpenCodeHistoryKeyset,
        error: Error,
        url: URL,
        schema: OpenCodeHistorySchema,
        state: inout OpenCodeHistoryAdapterState,
        batch: inout AgentHistoryIngestBatch,
        nowMs: Int64
    ) {
        let code = (error as? AgentHistoryDatabaseError)?.code ?? 0
        AgentHistoryLog.indexer.info("opencode session unreadable code=\(code, privacy: .public)")
        batch.diagnostics.skippedSessions[agent.normalizedSessionID(entry.id) ?? entry.id] =
            .unreadable("opencode session read failed (SQLite \(code))")
        let marks = try? AgentHistoryDatabase.readExternalSnapshot(url: url) { db in
            try OpenCodeHistoryQueries.changeMarks(db, schema: schema, sessionID: entry.id)
        }
        let known = max(entry.lastChangeMs, state.knownChange(entry.id) ?? 0)
        state.record(entry.id, lastChangeMs: marks?.lastChangeMs ?? (known > 0 ? known : nowMs),
                     contentSignature: marks?.contentSignature ?? state.contentSignatures[entry.id],
                     rejected: state.rejected[entry.id] != nil)
    }

    // MARK: - Errors

    /// Failures confined to one session's rows (malformed JSON reaching SQL, a corrupt page):
    /// skip that session. Everything else concerns the whole database or the call.
    static func isSessionLocal(_ error: Error) -> Bool {
        guard let error = error as? AgentHistoryDatabaseError else {
            return true
        }
        switch error.kind {
        case .corrupt, .other, .constraint:
            return true
        case .notADatabase, .full, .busy, .readOnly, .cantOpen, .interrupted, .schemaTooNew, .misuse:
            return false
        }
    }

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
