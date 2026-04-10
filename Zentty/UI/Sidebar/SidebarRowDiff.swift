import Foundation

/// Computes the structural difference between two ordered sidebar summary
/// arrays. Both arrays use `WorklaneID` as a stable, unique identifier.
///
/// The diff distinguishes four mutation categories:
///
/// - **Removals** — IDs present in `old` but absent in `new`. Must be
///   processed before insertions so the stack's index math stays stable.
/// - **Insertions** — IDs present in `new` but absent in `old`. Indices
///   refer to positions in the `new` array.
/// - **Moves** — IDs present in both arrays but at different indices.
///   After removals and insertions, `NSStackView.insertArrangedSubview(_:at:)`
///   handles reorder inside an animation block.
/// - **Updates** — IDs present in both arrays at the same position (or
///   after a move) whose summary has changed. The existing button is reused
///   and re-configured in-place.
///
/// Complexity: O(n) where n = max(old.count, new.count), using an ID→index
/// map. No LCS or Myers diff — the list is short (<100 worklanes) and
/// identity is stable.
struct SidebarRowDiff {
    struct Insertion {
        let index: Int
        let summary: WorklaneSidebarSummary
    }

    struct Removal {
        /// Index in the **old** array (and the old stack arrangement).
        let index: Int
        let worklaneID: WorklaneID
    }

    struct Move {
        let worklaneID: WorklaneID
        /// Index in the **old** array.
        let fromIndex: Int
        /// Index in the **new** array.
        let toIndex: Int
    }

    struct Update {
        /// Index in the **new** array.
        let index: Int
        let worklaneID: WorklaneID
        let summary: WorklaneSidebarSummary
    }

    let removals: [Removal]
    let insertions: [Insertion]
    let moves: [Move]
    let updates: [Update]

    /// Whether the diff describes any structural change (add/remove/move).
    /// When false, only in-place updates (or nothing at all) are needed.
    var hasStructuralChange: Bool {
        !removals.isEmpty || !insertions.isEmpty || !moves.isEmpty
    }

    /// Compute the diff between two ordered summary arrays.
    ///
    /// - Parameters:
    ///   - old: The current sidebar summary list (before mutation).
    ///   - new: The target sidebar summary list (after mutation).
    /// - Returns: A diff describing how to transition from `old` to `new`.
    static func compute(
        old: [WorklaneSidebarSummary],
        new: [WorklaneSidebarSummary]
    ) -> SidebarRowDiff {
        let oldMap: [WorklaneID: Int] = Dictionary(
            uniqueKeysWithValues: old.enumerated().map { ($0.element.worklaneID, $0.offset) }
        )
        let newMap: [WorklaneID: Int] = Dictionary(
            uniqueKeysWithValues: new.enumerated().map { ($0.element.worklaneID, $0.offset) }
        )

        // Removals: in old but not in new.
        var removals: [Removal] = []
        for (oldIndex, summary) in old.enumerated() {
            if newMap[summary.worklaneID] == nil {
                removals.append(Removal(index: oldIndex, worklaneID: summary.worklaneID))
            }
        }

        // Insertions: in new but not in old.
        var insertions: [Insertion] = []
        for (newIndex, summary) in new.enumerated() {
            if oldMap[summary.worklaneID] == nil {
                insertions.append(Insertion(index: newIndex, summary: summary))
            }
        }

        // Moves + Updates: in both, check position and content.
        var moves: [Move] = []
        var updates: [Update] = []
        for (newIndex, summary) in new.enumerated() {
            guard let oldIndex = oldMap[summary.worklaneID] else {
                continue // Already captured as an insertion.
            }

            if oldIndex != newIndex {
                moves.append(Move(
                    worklaneID: summary.worklaneID,
                    fromIndex: oldIndex,
                    toIndex: newIndex
                ))
            }

            if old[oldIndex] != summary {
                updates.append(Update(
                    index: newIndex,
                    worklaneID: summary.worklaneID,
                    summary: summary
                ))
            }
        }

        return SidebarRowDiff(
            removals: removals,
            insertions: insertions,
            moves: moves,
            updates: updates
        )
    }
}
