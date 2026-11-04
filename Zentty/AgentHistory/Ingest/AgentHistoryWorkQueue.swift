import Foundation

/// One ingest unit of one source (the source id is the `sources` row id, never the
/// placeholder `0` adapters put in fresh cursors).
struct AgentHistoryUnitRef: Hashable, Sendable {
    let sourceID: Int64
    let unitKey: String
}

/// The indexer's pending work, newest first. Four lanes, popped in this order:
/// 1. live: units touched by file events or database polls, FIFO;
/// 2. live continuations: live units that hit a batch limit and have more to read;
/// 3. backfill continuations: backfill units that hit a batch limit (finish a started unit
///    before opening the next one, so a big transcript doesn't stay half-indexed);
/// 4. backfill: discovered or changed units, newest `mtimeNs` first (ties keep enqueue order).
///
/// A unit sits in at most one lane. Live work promotes a unit out of the backfill lanes;
/// backfill work never demotes a unit that is already queued live. Not thread-safe: the
/// indexer owns it on its serial queue.
struct AgentHistoryWorkQueue: Sendable {
    enum Tier: Sendable, Equatable {
        case live
        case backfill
    }

    private struct BackfillEntry: Sendable {
        let ref: AgentHistoryUnitRef
        let mtimeNs: Int64
        let sequence: UInt64
    }

    private var live: [AgentHistoryUnitRef] = []
    private var liveContinuations: [AgentHistoryUnitRef] = []
    private var backfillContinuations: [AgentHistoryUnitRef] = []

    /// Sorted ascending by `(mtimeNs, -sequence)`, so `popLast()` yields the newest unit and,
    /// among equal mtimes, the one enqueued first. Entries whose ref is no longer in
    /// `backfillPending` (or whose sequence no longer matches) are stale and skipped.
    private var backfillHeap: [BackfillEntry] = []
    private var backfillPending: [AgentHistoryUnitRef: (sequence: UInt64, mtimeNs: Int64)] = [:]
    private var nextSequence: UInt64 = 0

    /// Units handed to backfill since this queue was created: the stable total behind the
    /// progress bar. Units dropped from the queue without being processed come off it again.
    private(set) var backfillScheduled = 0

    init() {}

    var liveCount: Int { live.count + liveContinuations.count }
    var backfillCount: Int { backfillPending.count + backfillContinuations.count }
    /// Scheduled units that left the queue for good, whatever they turned out to hold.
    var backfillFinished: Int { max(0, backfillScheduled - backfillCount) }
    var isEmpty: Bool { liveCount == 0 && backfillCount == 0 }

    /// Queues a unit for live processing. Ignored when it is already queued live; a unit
    /// waiting in either backfill lane moves here.
    mutating func enqueueLive(_ ref: AgentHistoryUnitRef) {
        if live.contains(ref) || liveContinuations.contains(ref) {
            return
        }
        removeFromBackfillLanes(ref)
        live.append(ref)
    }

    /// Queues units for backfill, newest `mtimeNs` first. Units already queued live or as a
    /// backfill continuation are left where they are; a unit already in the backfill lane
    /// takes the new mtime.
    mutating func enqueueBackfill(_ items: [(ref: AgentHistoryUnitRef, mtimeNs: Int64)]) {
        guard !items.isEmpty else {
            return
        }
        var appended = false
        for item in items {
            let ref = item.ref
            if live.contains(ref) || liveContinuations.contains(ref) || backfillContinuations.contains(ref) {
                continue
            }
            if backfillPending[ref]?.mtimeNs == item.mtimeNs {
                continue
            }
            if backfillPending[ref] == nil {
                backfillScheduled += 1
            }
            let sequence = nextSequence
            nextSequence &+= 1
            backfillPending[ref] = (sequence, item.mtimeNs)
            backfillHeap.append(BackfillEntry(ref: ref, mtimeNs: item.mtimeNs, sequence: sequence))
            appended = true
        }
        if appended {
            compactBackfillIfNeeded()
            backfillHeap.sort(by: Self.popsLater)
        }
    }

    /// Marks a unit that hit a batch limit as having more to read at `tier`'s continuation
    /// lane. A backfill continuation never demotes a unit already queued live.
    mutating func setContinuation(_ ref: AgentHistoryUnitRef, tier: Tier) {
        switch tier {
        case .live:
            if liveContinuations.contains(ref) {
                return
            }
            live.removeAll { $0 == ref }
            removeFromBackfillLanes(ref)
            liveContinuations.append(ref)
        case .backfill:
            if live.contains(ref) || liveContinuations.contains(ref) || backfillContinuations.contains(ref) {
                return
            }
            backfillPending[ref] = nil
            backfillContinuations.append(ref)
        }
    }

    /// Next unit to process, or `nil` when nothing is runnable. With `allowBackfill == false`
    /// (backfill paused) only the live lanes are consulted; backfill work stays queued.
    mutating func popNext(allowBackfill: Bool) -> (ref: AgentHistoryUnitRef, tier: Tier)? {
        if !live.isEmpty {
            return (live.removeFirst(), .live)
        }
        if !liveContinuations.isEmpty {
            return (liveContinuations.removeFirst(), .live)
        }
        guard allowBackfill else {
            return nil
        }
        if !backfillContinuations.isEmpty {
            return (backfillContinuations.removeFirst(), .backfill)
        }
        while let entry = backfillHeap.popLast() {
            guard backfillPending[entry.ref]?.sequence == entry.sequence else {
                continue
            }
            backfillPending[entry.ref] = nil
            return (entry.ref, .backfill)
        }
        return nil
    }

    /// Drops every queued unit of a source (source turned off, deleted or rebuilt).
    mutating func removeAll(sourceID: Int64) {
        let queuedBefore = backfillCount
        defer { backfillScheduled = max(0, backfillScheduled - (queuedBefore - backfillCount)) }
        live.removeAll { $0.sourceID == sourceID }
        liveContinuations.removeAll { $0.sourceID == sourceID }
        backfillContinuations.removeAll { $0.sourceID == sourceID }
        backfillPending = backfillPending.filter { $0.key.sourceID != sourceID }
        backfillHeap.removeAll { $0.ref.sourceID == sourceID }
    }

    private mutating func removeFromBackfillLanes(_ ref: AgentHistoryUnitRef) {
        backfillContinuations.removeAll { $0 == ref }
        backfillPending[ref] = nil
    }

    /// Stale entries are skipped lazily on pop; drop them once they outnumber live ones so a
    /// long session of promotions and re-enqueues doesn't grow the array without bound.
    private mutating func compactBackfillIfNeeded() {
        guard backfillHeap.count > 2 * backfillPending.count + 64 else {
            return
        }
        backfillHeap.removeAll { backfillPending[$0.ref]?.sequence != $0.sequence }
    }

    private static func popsLater(_ lhs: BackfillEntry, _ rhs: BackfillEntry) -> Bool {
        if lhs.mtimeNs != rhs.mtimeNs {
            return lhs.mtimeNs < rhs.mtimeNs
        }
        return lhs.sequence > rhs.sequence
    }
}
