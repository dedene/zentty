import Foundation

struct PaneFocusHistory: Equatable, Sendable {
    private(set) var backStack: [WorklaneStore.PaneReference]
    private(set) var forwardStack: [WorklaneStore.PaneReference]
    private let maxDepth: Int

    init(maxDepth: Int = 100) {
        self.backStack = []
        self.forwardStack = []
        self.maxDepth = maxDepth
    }

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    /// Record the current pane reference before transitioning to a new one.
    /// Clears the forward stack (browser model).
    mutating func record(_ reference: WorklaneStore.PaneReference) {
        backStack.append(reference)
        forwardStack.removeAll()

        if backStack.count > maxDepth {
            backStack.removeFirst(backStack.count - maxDepth)
        }
    }

    /// Navigate back, skipping closed panes. Pushes current onto forward stack.
    /// Returns the target pane reference, or nil if no valid entry exists.
    mutating func navigateBack(
        current: WorklaneStore.PaneReference,
        allPaneIDs: Set<WorklaneStore.PaneReference>
    ) -> WorklaneStore.PaneReference? {
        while let entry = backStack.popLast() {
            if allPaneIDs.contains(entry) {
                forwardStack.append(current)
                return entry
            }
        }
        return nil
    }

    /// Navigate forward, skipping closed panes. Pushes current onto back stack.
    /// Returns the target pane reference, or nil if no valid entry exists.
    mutating func navigateForward(
        current: WorklaneStore.PaneReference,
        allPaneIDs: Set<WorklaneStore.PaneReference>
    ) -> WorklaneStore.PaneReference? {
        while let entry = forwardStack.popLast() {
            if allPaneIDs.contains(entry) {
                backStack.append(current)
                return entry
            }
        }
        return nil
    }
}
