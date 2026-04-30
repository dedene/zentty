import Foundation
import os

private let worklaneReorderLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneReorder")

extension WorklaneStore {
    @discardableResult
    func moveWorklane(id: WorklaneID, toIndex: Int) -> Bool {
        guard let fromIndex = worklanes.firstIndex(where: { $0.id == id }) else {
            worklaneReorderLogger.warning("Ignoring worklane move for unknown id \(id.rawValue, privacy: .public)")
            return false
        }

        guard toIndex >= 0, toIndex < worklanes.count else {
            worklaneReorderLogger.warning(
                "Ignoring worklane move for id \(id.rawValue, privacy: .public) to invalid index \(toIndex, privacy: .public)"
            )
            return false
        }

        guard fromIndex != toIndex else {
            return false
        }

        let moved = worklanes.remove(at: fromIndex)
        worklanes.insert(moved, at: toIndex)
        notify(.worklaneListChanged)
        return true
    }

    @discardableResult
    func reorderWorklanes(to newOrder: [WorklaneID]) -> Bool {
        let currentOrder = worklanes.map(\.id)
        guard newOrder != currentOrder else {
            return false
        }

        guard newOrder.count == currentOrder.count,
              Set(newOrder) == Set(currentOrder),
              Set(newOrder).count == newOrder.count else {
            worklaneReorderLogger.warning("Ignoring invalid worklane reorder permutation")
            return false
        }

        let worklanesByID = Dictionary(uniqueKeysWithValues: worklanes.map { ($0.id, $0) })
        worklanes = newOrder.compactMap { worklanesByID[$0] }
        notify(.worklaneListChanged)
        return true
    }
}
