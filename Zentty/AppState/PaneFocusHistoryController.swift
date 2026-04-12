import Foundation

@MainActor
final class PaneFocusHistoryController {
    private(set) var history = PaneFocusHistory()
    private var pendingEntry: WorklaneStore.PaneReference?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval

    var onChange: (() -> Void)?

    init(debounceInterval: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
    }

    /// Schedule a focus change to be recorded after the debounce interval.
    /// The `previous` reference is the pane that was focused before the transition.
    func recordFocusChange(from previous: WorklaneStore.PaneReference) {
        debounceTask?.cancel()
        pendingEntry = previous

        debounceTask = Task { [weak self, debounceInterval] in
            do {
                try await Task.sleep(for: .seconds(debounceInterval))
            } catch {
                return
            }
            self?.commitPending()
        }
    }

    /// Navigate back. Cancels any pending debounce entry first (mid-debounce cancellation).
    func navigateBack(
        current: WorklaneStore.PaneReference,
        allPaneIDs: Set<WorklaneStore.PaneReference>
    ) -> WorklaneStore.PaneReference? {
        cancelPending()
        let target = history.navigateBack(current: current, allPaneIDs: allPaneIDs)
        onChange?()
        return target
    }

    /// Navigate forward. Cancels any pending debounce entry first.
    func navigateForward(
        current: WorklaneStore.PaneReference,
        allPaneIDs: Set<WorklaneStore.PaneReference>
    ) -> WorklaneStore.PaneReference? {
        cancelPending()
        let target = history.navigateForward(current: current, allPaneIDs: allPaneIDs)
        onChange?()
        return target
    }

    func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingEntry = nil
    }

    private func commitPending() {
        guard let entry = pendingEntry else { return }
        pendingEntry = nil
        debounceTask = nil
        history.record(entry)
        onChange?()
    }
}

extension PaneFocusHistoryController {
    var pendingEntryForTesting: WorklaneStore.PaneReference? {
        pendingEntry
    }

    func replaceHistoryForTesting(_ history: PaneFocusHistory) {
        cancelPending()
        self.history = history
    }

    func commitPendingForTesting() {
        commitPending()
    }
}
