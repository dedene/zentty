import Foundation

@MainActor
protocol PaneFocusHistoryDebounceHandle: AnyObject {
    func cancel()
}

@MainActor
private final class TaskPaneFocusHistoryDebounceHandle: PaneFocusHistoryDebounceHandle {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

@MainActor
final class PaneFocusHistoryController {
    typealias DebounceScheduler = @MainActor (
        _ interval: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any PaneFocusHistoryDebounceHandle

    private(set) var history = PaneFocusHistory()
    private var pendingEntry: WorklaneStore.PaneReference?
    private var debounceHandle: (any PaneFocusHistoryDebounceHandle)?
    private let debounceInterval: TimeInterval
    private let scheduleDebounce: DebounceScheduler

    var onChange: (() -> Void)?

    init(
        debounceInterval: TimeInterval = 0.5,
        scheduleDebounce: @escaping DebounceScheduler = PaneFocusHistoryController.defaultDebounceScheduler
    ) {
        self.debounceInterval = debounceInterval
        self.scheduleDebounce = scheduleDebounce
    }

    /// Schedule a focus change to be recorded after the debounce interval.
    /// The `previous` reference is the pane that was focused before the transition.
    func recordFocusChange(from previous: WorklaneStore.PaneReference) {
        debounceHandle?.cancel()
        pendingEntry = previous

        guard debounceInterval > 0 else {
            commitPending()
            return
        }

        debounceHandle = scheduleDebounce(debounceInterval) { [weak self] in
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
        debounceHandle?.cancel()
        debounceHandle = nil
        pendingEntry = nil
    }

    private func commitPending() {
        guard let entry = pendingEntry else { return }
        pendingEntry = nil
        debounceHandle = nil
        history.record(entry)
        onChange?()
    }

    private static func defaultDebounceScheduler(
        interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any PaneFocusHistoryDebounceHandle {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            operation()
        }
        return TaskPaneFocusHistoryDebounceHandle(task: task)
    }
}
