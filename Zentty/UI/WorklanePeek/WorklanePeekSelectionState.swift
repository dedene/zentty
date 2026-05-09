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

/// A linear, wrap-around traversal of every pane in the workspace, ordered the
/// same way `WorklaneStore.paneReferencesInSidebarOrder` orders them: each
/// worklane in `worklanes` order, then each pane in `paneStripState.panes`
/// order.
///
/// Built once when the Worklane Peek opens, then queried for next/previous
/// hops. Stepping past the last reference cycles to the first, and vice versa.
struct WorklanePeekTraversal: Equatable {
    let references: [WorklaneStore.PaneReference]

    /// Build the traversal by mirroring `WorklaneStore.paneReferencesInSidebarOrder`.
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

    static func opening(at reference: WorklaneStore.PaneReference) -> Self {
        Self(current: reference, original: reference)
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
