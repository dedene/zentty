import Foundation

struct ClosedPaneStack: Equatable, Sendable {
    static let defaultCapacity: Int = 10
    static let defaultExpiry: TimeInterval = 60 * 60

    private(set) var entries: [ClosedPaneEntry]
    let capacity: Int
    let expiry: TimeInterval

    init(capacity: Int = ClosedPaneStack.defaultCapacity, expiry: TimeInterval = ClosedPaneStack.defaultExpiry) {
        self.entries = []
        self.capacity = max(1, capacity)
        self.expiry = max(0, expiry)
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    mutating func push(_ entry: ClosedPaneEntry, now: Date = Date()) {
        prune(now: now)
        entries.append(entry)
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    mutating func popLatest(now: Date = Date()) -> ClosedPaneEntry? {
        prune(now: now)
        return entries.popLast()
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-expiry)
        entries.removeAll { $0.closedAt < cutoff }
    }

    func peek(now: Date = Date()) -> ClosedPaneEntry? {
        let cutoff = now.addingTimeInterval(-expiry)
        return entries.last(where: { $0.closedAt >= cutoff })
    }
}
