import Foundation

protocol HistoryRankKeyed {
    var key: HistoryRankKey { get }
}

/// Keeps the best `capacity` elements by `HistoryRankKey` in O(n log k). The root is the worst
/// kept element, so a newcomer only has to beat it.
struct HistoryBoundedRankHeap<Element: HistoryRankKeyed> {
    let capacity: Int
    private var storage: [Element] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func offer(_ element: Element) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(element)
            siftUp(storage.count - 1)
        } else if element.key.ranks(before: storage[0].key) {
            storage[0] = element
            siftDown(0)
        }
    }

    /// Best first.
    func sorted() -> [Element] {
        storage.sorted { $0.key.ranks(before: $1.key) }
    }

    /// Heap order: a parent ranks after (is worse than) its children.
    private func isWorse(_ lhs: Int, _ rhs: Int) -> Bool {
        storage[rhs].key.ranks(before: storage[lhs].key)
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(child, parent) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var worst = parent
            if left < storage.count, isWorse(left, worst) { worst = left }
            if right < storage.count, isWorse(right, worst) { worst = right }
            guard worst != parent else { return }
            storage.swapAt(parent, worst)
            parent = worst
        }
    }
}
