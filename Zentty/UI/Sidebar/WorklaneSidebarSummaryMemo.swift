import Foundation

/// Remembers the last few sidebar summaries built per worklane.
///
/// One pane's metadata update used to rebuild the summary of every worklane
/// three times over (invalidation check, sidebar render, menu-bar refresh).
/// The inputs are value types, so an unchanged worklane can reuse its previous
/// result and only the worklane that actually changed pays for a rebuild.
///
/// Entries expire after a short while because a summary also reflects on-disk
/// state (which repository a directory belongs to) that the key cannot see.
final class WorklaneSidebarSummaryMemo<Value>: @unchecked Sendable {
    struct Key: Equatable {
        let worklane: WorklaneState
        let isActive: Bool
        let displayOrder: Int
        /// Only set when the override targets this worklane; an override for
        /// another worklane does not change this one's summary.
        let focusOverride: WorklaneSidebarFocusOverride?
        let serverContext: WorklaneServerContext?
        let showsTemporaryFloats: Bool
    }

    private struct Entry {
        let key: Key
        let value: Value
        let expiresAt: TimeInterval
    }

    /// Callers ask for a worklane in a handful of shapes (sidebar render,
    /// menu bar, before/after invalidation check); keep one slot for each.
    private static var entriesPerWorklane: Int { 4 }

    private let timeToLive: TimeInterval
    private let maximumWorklaneCount: Int
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entriesByWorklaneID: [WorklaneID: [Entry]] = [:]
    private var buildCountStorage = 0

    init(
        timeToLive: TimeInterval = 2,
        maximumWorklaneCount: Int = 256,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.timeToLive = timeToLive
        self.maximumWorklaneCount = maximumWorklaneCount
        self.now = now
    }

    /// Number of times `build` ran. Lets tests assert what was reused.
    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buildCountStorage
    }

    func value(for key: Key, build: () -> Value) -> Value {
        let currentTime = now()
        let worklaneID = key.worklane.id

        lock.lock()
        if let entry = entriesByWorklaneID[worklaneID]?.first(where: {
            $0.expiresAt > currentTime && $0.key == key
        }) {
            lock.unlock()
            return entry.value
        }
        lock.unlock()

        let value = build()

        lock.lock()
        buildCountStorage += 1
        if entriesByWorklaneID.count >= maximumWorklaneCount, entriesByWorklaneID[worklaneID] == nil {
            entriesByWorklaneID.removeAll(keepingCapacity: true)
        }
        var entries = (entriesByWorklaneID[worklaneID] ?? []).filter { $0.expiresAt > currentTime }
        if entries.count >= Self.entriesPerWorklane {
            entries.removeFirst(entries.count - Self.entriesPerWorklane + 1)
        }
        entries.append(Entry(key: key, value: value, expiresAt: currentTime + timeToLive))
        entriesByWorklaneID[worklaneID] = entries
        lock.unlock()

        return value
    }

    func removeAll() {
        lock.lock()
        entriesByWorklaneID.removeAll()
        lock.unlock()
    }
}
