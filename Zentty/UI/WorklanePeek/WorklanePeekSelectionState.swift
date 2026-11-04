import Foundation

/// Direction of a pane-level step in the Worklane Peek.
enum WorklanePeekDirection: Equatable {
    case forward
    case backward

    var offset: Int {
        switch self {
        case .forward: return 1
        case .backward: return -1
        }
    }
}

/// Direction of a spatial gesture while Worklane Peek is open.
///
/// Unlike Ctrl+Tab traversal, spatial navigation is clamped to the visible
/// grid: left/right move between pane columns, and up/down move inside a
/// vertical split before crossing to the adjacent worklane.
enum WorklanePeekSpatialDirection: Equatable {
    case left
    case right
    case up
    case down
}

/// A linear, wrap-around traversal of every strip pane in the workspace: each
/// worklane in `worklanes` order, then each pane in `paneStripState.panes`
/// order. Unlike `WorklaneStore.paneReferencesInSidebarOrder` it skips
/// floats on purpose: the peek shows strip thumbnails only, so a float has no
/// rect to highlight.
///
/// Built once when the Worklane Peek opens, then queried for next/previous
/// hops. Stepping past the last reference cycles to the first, and vice versa.
struct WorklanePeekTraversal: Equatable {
    let references: [WorklaneStore.PaneReference]

    /// Build the strip-only traversal (see the type comment).
    static func from(worklanes: [WorklaneState]) -> Self {
        let references = worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map { pane in
                WorklaneStore.PaneReference(worklaneID: worklane.id, paneID: pane.id)
            }
        }
        return Self(references: references)
    }

    func index(of reference: WorklaneStore.PaneReference) -> Int? {
        references.firstIndex(of: reference)
    }

    /// Entry point when the starting worklane has no strip panes (float-only):
    /// the first strip pane of the next worklane going `direction`, wrapping.
    /// Nil when no other worklane has strip panes.
    func entry(
        leaving worklaneID: WorklaneID,
        worklaneOrder: [WorklaneID],
        direction: WorklanePeekDirection
    ) -> WorklaneStore.PaneReference? {
        guard let startIndex = worklaneOrder.firstIndex(of: worklaneID) else {
            return nil
        }
        let count = worklaneOrder.count
        for step in 1..<max(count, 1) {
            let candidateID = worklaneOrder[(startIndex + direction.offset * step + count * step) % count]
            let lane = references.filter { $0.worklaneID == candidateID }
            if let reference = direction == .forward ? lane.first : lane.last {
                return reference
            }
        }
        return nil
    }

    func step(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekDirection
    ) -> WorklaneStore.PaneReference? {
        guard !references.isEmpty,
              let currentIndex = index(of: reference)
        else { return nil }

        let count = references.count
        let nextIndex = (currentIndex + direction.offset + count) % count
        return references[nextIndex]
    }

    /// Whether stepping in `direction` from `reference` would wrap around
    /// the extreme of the list (last → first or first → last). Used by the
    /// view layer to decide between a smooth camera pan and a hard cut.
    func wrapsAround(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekDirection
    ) -> Bool {
        guard let currentIndex = index(of: reference) else { return false }
        switch direction {
        case .forward: return currentIndex == references.count - 1
        case .backward: return currentIndex == 0
        }
    }

    /// Whether stepping in `direction` from `reference` would cross from one
    /// worklane into a different one. Used by the view layer to trigger the
    /// camera pan animation.
    func crossesWorklaneBoundary(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekDirection
    ) -> Bool {
        guard let next = step(from: reference, direction: direction) else { return false }
        return next.worklaneID != reference.worklaneID
    }
}

/// Snapshot of the current selection in peek.
///
/// `original` is captured at the moment peek opens (after any
/// just-fired instant worklane switch). Escape restores focus to it; releasing
/// Ctrl commits `current`.
struct WorklanePeekSelectionState: Equatable {
    var current: WorklaneStore.PaneReference
    let original: WorklaneStore.PaneReference
    /// Where the highlight started. Differs from `original` when a float had
    /// focus (peek highlights strip panes only).
    var start: WorklaneStore.PaneReference

    init(current: WorklaneStore.PaneReference, original: WorklaneStore.PaneReference) {
        self.current = current
        self.original = original
        self.start = current
    }

    /// What releasing Ctrl commits: an untouched highlight keeps the original
    /// focus (so a focused float isn't swapped for its strip neighbour).
    var committed: WorklaneStore.PaneReference {
        current == start ? original : current
    }

    static func opening(at reference: WorklaneStore.PaneReference) -> Self {
        Self(current: reference, original: reference)
    }

    /// Highlight starts on a strip pane, but Escape restores `original`, the
    /// real keyboard focus (which may be a float).
    static func opening(
        at reference: WorklaneStore.PaneReference,
        restoring original: WorklaneStore.PaneReference
    ) -> Self {
        Self(current: reference, original: original)
    }

    func advancing(
        by direction: WorklanePeekDirection,
        traversal: WorklanePeekTraversal
    ) -> Self {
        guard let next = traversal.step(from: current, direction: direction) else {
            return self
        }
        var copy = self
        copy.current = next
        return copy
    }
}

enum WorklanePeekSpatialNavigator {
    static func target(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekSpatialDirection,
        worklanes: [WorklaneState]
    ) -> WorklaneStore.PaneReference? {
        guard
            let worklaneIndex = worklanes.firstIndex(where: { $0.id == reference.worklaneID })
        else { return nil }

        let worklane = worklanes[worklaneIndex]
        guard
            let columnIndex = worklane.paneStripState.columns.firstIndex(where: { column in
                column.panes.contains(where: { $0.id == reference.paneID })
            })
        else { return nil }

        switch direction {
        case .left, .right:
            return horizontalTarget(
                from: reference,
                direction: direction,
                worklane: worklane,
                columnIndex: columnIndex
            )
        case .up, .down:
            return verticalTarget(
                from: reference,
                direction: direction,
                worklanes: worklanes,
                worklaneIndex: worklaneIndex,
                columnIndex: columnIndex
            )
        }
    }

    private static func horizontalTarget(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekSpatialDirection,
        worklane: WorklaneState,
        columnIndex: Int
    ) -> WorklaneStore.PaneReference? {
        let offset = direction == .right ? 1 : -1
        let targetIndex = columnIndex + offset
        guard worklane.paneStripState.columns.indices.contains(targetIndex) else {
            return nil
        }
        let targetColumn = worklane.paneStripState.columns[targetIndex]
        guard let paneID = targetColumn.lastFocusedPaneID ?? targetColumn.focusedPaneID ?? targetColumn.panes.first?.id
        else { return nil }
        let target = WorklaneStore.PaneReference(worklaneID: worklane.id, paneID: paneID)
        return target == reference ? nil : target
    }

    private static func verticalTarget(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekSpatialDirection,
        worklanes: [WorklaneState],
        worklaneIndex: Int,
        columnIndex: Int
    ) -> WorklaneStore.PaneReference? {
        let worklane = worklanes[worklaneIndex]
        let column = worklane.paneStripState.columns[columnIndex]
        let offset = direction == .down ? 1 : -1

        if let paneIndex = column.panes.firstIndex(where: { $0.id == reference.paneID }) {
            let targetPaneIndex = paneIndex + offset
            if column.panes.indices.contains(targetPaneIndex) {
                return WorklaneStore.PaneReference(
                    worklaneID: worklane.id,
                    paneID: column.panes[targetPaneIndex].id
                )
            }
        }

        let targetWorklaneIndex = worklaneIndex + offset
        guard worklanes.indices.contains(targetWorklaneIndex) else {
            return nil
        }
        let targetWorklane = worklanes[targetWorklaneIndex]
        guard let paneID = targetWorklane.paneStripState.focusedPaneID ?? targetWorklane.paneStripState.panes.first?.id
        else { return nil }
        let target = WorklaneStore.PaneReference(worklaneID: targetWorklane.id, paneID: paneID)
        return target == reference ? nil : target
    }
}

struct WorklanePeekPaneGeometry: Equatable {
    let reference: WorklaneStore.PaneReference
    let frame: CGRect
}

struct WorklanePeekSpatialNavigationResult: Equatable {
    let target: WorklaneStore.PaneReference
    let transition: WorklanePeekSelectionTransition
}

struct WorklanePeekSpatialSelectionResolver {
    let traversal: WorklanePeekTraversal
    let paneGeometries: [WorklanePeekPaneGeometry]

    func target(
        from reference: WorklaneStore.PaneReference,
        direction: WorklanePeekSpatialDirection
    ) -> WorklanePeekSpatialNavigationResult? {
        guard let current = paneGeometries.first(where: { $0.reference == reference }) else {
            return nil
        }

        switch direction {
        case .left, .right:
            return horizontalTarget(from: current, direction: direction)
        case .up, .down:
            return verticalTarget(from: current, direction: direction)
        }
    }

    private func horizontalTarget(
        from current: WorklanePeekPaneGeometry,
        direction: WorklanePeekSpatialDirection
    ) -> WorklanePeekSpatialNavigationResult? {
        let sameWorklane = paneGeometries.filter {
            $0.reference.worklaneID == current.reference.worklaneID
                && $0.reference != current.reference
        }
        guard !sameWorklane.isEmpty else { return nil }

        let currentMidX = current.frame.midX
        let candidates = sameWorklane.filter { geometry in
            direction == .right
                ? geometry.frame.midX > currentMidX
                : geometry.frame.midX < currentMidX
        }

        if let nearest = candidates.min(by: { horizontalDistance($0, from: current) < horizontalDistance($1, from: current) }) {
            return .init(target: nearest.reference, transition: .animated)
        }

        let wrapped = direction == .right
            ? sameWorklane.min(by: { $0.frame.midX < $1.frame.midX })
            : sameWorklane.max(by: { $0.frame.midX < $1.frame.midX })
        return wrapped.map { .init(target: $0.reference, transition: .hardCut) }
    }

    private func verticalTarget(
        from current: WorklanePeekPaneGeometry,
        direction: WorklanePeekSpatialDirection
    ) -> WorklanePeekSpatialNavigationResult? {
        let currentMidY = current.frame.midY
        let candidates = paneGeometries.filter { geometry in
            geometry.reference != current.reference
                && (direction == .down
                    ? geometry.frame.midY < currentMidY
                    : geometry.frame.midY > currentMidY)
        }

        if let nearest = candidates.min(by: { verticalScore($0, from: current) < verticalScore($1, from: current) }) {
            return .init(target: nearest.reference, transition: .animated)
        }

        guard let currentIndex = traversal.index(of: current.reference),
              !traversal.references.isEmpty
        else { return nil }
        let wrappedIndex = direction == .down ? 0 : traversal.references.count - 1
        guard wrappedIndex != currentIndex else { return nil }
        return .init(target: traversal.references[wrappedIndex], transition: .hardCut)
    }

    private func horizontalDistance(
        _ candidate: WorklanePeekPaneGeometry,
        from current: WorklanePeekPaneGeometry
    ) -> CGFloat {
        abs(candidate.frame.midX - current.frame.midX) * 10
            + abs(candidate.frame.midY - current.frame.midY)
    }

    private func verticalScore(
        _ candidate: WorklanePeekPaneGeometry,
        from current: WorklanePeekPaneGeometry
    ) -> CGFloat {
        abs(candidate.frame.midY - current.frame.midY) * 10
            + abs(candidate.frame.midX - current.frame.midX)
    }
}
