import Foundation

/// Feeds `PaneEventStream` from the windows' worklane stores.
///
/// Every store change schedules one diff for the next main-queue turn, so a
/// burst of changes (or a pane moving between windows, which touches two
/// stores) collapses into a single comparison. Nothing is captured or
/// diffed while no client is subscribed.
@MainActor
final class PaneEventMonitor {
    static let shared = PaneEventMonitor(stream: .shared)

    private struct Source {
        let windowID: WindowID
        weak var store: WorklaneStore?
        let subscription: WorklaneChangeSubscription
    }

    private let stream: PaneEventStream
    private var sources: [Source] = []
    private var baseline: PaneEventSnapshot?
    private var isDiffScheduled = false
    /// Snapshots taken so far. Lets tests check that nothing is captured
    /// while no client listens.
    private(set) var snapshotCountForTesting = 0
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    init(
        stream: PaneEventStream,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async { MainActorShim.assumeIsolated(work) }
        }
    ) {
        self.stream = stream
        self.schedule = schedule
        stream.setSubscribersChangedHandler { [weak self] _ in
            DispatchQueue.main.async {
                MainActorShim.assumeIsolated {
                    self?.scheduleDiff()
                }
            }
        }
    }

    /// Registers a `zentty events` client. Runs on the main thread, hopping
    /// there from the IPC thread, so the baseline is current before the
    /// client can see `stream.ready`: every change after that line is
    /// reported.
    nonisolated static func subscribe(fileDescriptor: Int32, filter: PaneEventTypeFilter) {
        if Thread.isMainThread {
            MainActorShim.assumeIsolated {
                _ = shared.addSubscriber(fileDescriptor: fileDescriptor, filter: filter)
            }
            return
        }
        DispatchQueue.main.sync {
            MainActorShim.assumeIsolated {
                _ = shared.addSubscriber(fileDescriptor: fileDescriptor, filter: filter)
            }
        }
    }

    /// Takes ownership of `fileDescriptor`, like `PaneEventStream.addSubscriber`.
    @discardableResult
    func addSubscriber(fileDescriptor: Int32, filter: PaneEventTypeFilter) -> UUID {
        if stream.hasSubscribers, baseline != nil {
            // Clients already listening get what is pending; the newcomer
            // starts from the state after it.
            flush()
        } else {
            baseline = currentSnapshot()
        }
        return stream.addSubscriber(fileDescriptor: fileDescriptor, filter: filter)
    }

    func attach(windowID: WindowID, store: WorklaneStore) {
        detach(windowID: windowID)
        let subscription = store.subscribe { [weak self] change in
            guard Self.isRelevant(change) else { return }
            self?.scheduleDiff()
        }
        sources.append(Source(windowID: windowID, store: store, subscription: subscription))
        scheduleDiff()
    }

    func detach(windowID: WindowID) {
        let countBefore = sources.count
        sources.removeAll { source in
            guard source.windowID == windowID else { return false }
            source.store?.unsubscribe(source.subscription)
            return true
        }
        if sources.count != countBefore {
            scheduleDiff()
        }
    }

    /// Runs any pending diff now. Exposed for tests.
    func flush() {
        isDiffScheduled = false
        guard stream.hasSubscribers else {
            baseline = nil
            return
        }
        let current = currentSnapshot()
        guard let previous = baseline else {
            baseline = current
            return
        }
        baseline = current
        stream.broadcast(PaneEventSnapshot.diff(from: previous, to: current))
    }

    private func scheduleDiff() {
        guard !isDiffScheduled else { return }
        isDiffScheduled = true
        schedule { [weak self] in
            self?.flush()
        }
    }

    private func currentSnapshot() -> PaneEventSnapshot {
        snapshotCountForTesting += 1
        return PaneEventSnapshot.make(windows: sources.compactMap { source in
            source.store.map {
                (windowID: source.windowID, activeWorklaneID: $0.activeWorklaneID, worklanes: $0.worklanes)
            }
        })
    }

    private static func isRelevant(_ change: WorklaneChange) -> Bool {
        switch change {
        case .paneStructure, .focusChanged, .auxiliaryStateUpdated, .activeWorklaneChanged, .worklaneListChanged:
            return true
        case .layoutResized, .volatileAgentTitleUpdated, .teamAnchorsChanged, .historyChanged:
            return false
        }
    }
}
