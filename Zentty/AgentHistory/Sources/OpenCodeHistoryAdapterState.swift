import Foundation

/// High-water marks of one poll. Rowids catch inserts (`time_updated` on `session` misses
/// message activity); `sessionUpdatedMs` catches renames and archiving.
struct OpenCodeHistoryWatermarks: Codable, Equatable, Sendable {
    var partRowID: Int64 = 0
    var messageRowID: Int64 = 0
    var sessionMessageRowID: Int64 = 0
    var sessionUpdatedMs: Int64 = 0

    /// A stored rowid above the current maximum: the newest rows were deleted (or a VACUUM
    /// renumbered them), and new rows may reuse rowids at or below the stored marks.
    func isAhead(of current: OpenCodeHistoryWatermarks) -> Bool {
        partRowID > current.partRowID
            || messageRowID > current.messageRowID
            || sessionMessageRowID > current.sessionMessageRowID
    }

    /// Per table, the lower of these marks and `current`: the "after" position that still finds
    /// rows inserted past whichever maximum survived.
    func clamped(to current: OpenCodeHistoryWatermarks) -> OpenCodeHistoryWatermarks {
        OpenCodeHistoryWatermarks(
            partRowID: min(partRowID, current.partRowID),
            messageRowID: min(messageRowID, current.messageRowID),
            sessionMessageRowID: min(sessionMessageRowID, current.sessionMessageRowID),
            sessionUpdatedMs: min(sessionUpdatedMs, current.sessionUpdatedMs)
        )
    }
}

/// What the hot set and the reconcile compare per session: the newest `time_updated` (catches
/// inserts and in-place edits) and the content signature (catches deleted rows, which move
/// neither a timestamp nor, below the table maximum, a rowid watermark).
struct OpenCodeHistoryChangeMarks: Equatable, Sendable {
    var lastChangeMs: Int64?
    var contentSignature: Int64
}

/// A backfill keyset position: the session-row change time and id of the last session read.
struct OpenCodeHistoryKeyset: Codable, Equatable, Sendable {
    let lastChangeMs: Int64
    let id: String
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
    /// Sessions the admission rejected (excluded folder, tombstone), with their newest change at
    /// that read. Kept apart from `lastChange` so they are read again when the rules relax.
    var rejected: [String: Int64] = [:]
    /// Content signature per admitted session at its last ingest
    /// (`OpenCodeHistoryQueries.contentSignatureTerm`). Deleting a row that is not a table's
    /// newest moves no watermark and no timestamp; only this value changes. A state written
    /// before this field existed fails to decode, so a full pass records it for every session.
    var contentSignatures: [String: Int64] = [:]
    /// `OpenCodeHistorySource.admissionSignature` of the rules last applied; a different value
    /// re-checks every session the change could affect.
    var admissionSignature: Int64?
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

    /// Newest change recorded for a session, admitted or rejected.
    func knownChange(_ id: String) -> Int64? {
        lastChange[id] ?? rejected[id]
    }

    /// Records a read session as admitted or rejected (never both). Only admitted sessions keep
    /// a content signature: a rejected one has no indexed text a deletion could leave behind.
    mutating func record(_ id: String, lastChangeMs: Int64, contentSignature: Int64?, rejected isRejected: Bool) {
        lastChange[id] = isRejected ? nil : lastChangeMs
        rejected[id] = isRejected ? lastChangeMs : nil
        contentSignatures[id] = isRejected ? nil : contentSignature
    }

    /// True when `marks` show the session changed since it was recorded: a newer change, or
    /// (for an admitted session) rows added or deleted without one.
    func hasChanged(_ id: String, since marks: OpenCodeHistoryChangeMarks) -> Bool {
        guard let known = knownChange(id), let latest = marks.lastChangeMs, latest <= known else {
            return true
        }
        return contentSignatures[id].map { $0 != marks.contentSignature } ?? false
    }

    /// Drops everything known about a session that no longer exists upstream.
    mutating func forget(_ id: String) {
        lastChange[id] = nil
        rejected[id] = nil
        contentSignatures[id] = nil
        pending.removeAll { $0 == id }
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
