import Foundation

/// Where one live agent session runs: a pane in some window, with the names the UI shows for it.
struct LiveAgentSessionLocation: Equatable, Sendable {
    /// How the pane revealed the session; lower is stronger evidence.
    enum MatchSource: Int, Comparable, Sendable {
        case status = 0
        case metadata = 1
        case reducer = 2

        static func < (lhs: MatchSource, rhs: MatchSource) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let key: AgentHistorySessionKey
    let windowID: WindowID
    let worklaneID: WorklaneID
    let paneID: PaneID
    let tool: AgentTool
    /// The id as the pane reported it; `key.nativeID` is the normalized form.
    let rawSessionID: String
    let pid: Int32
    let paneDisplayName: String
    let worklaneDisplayName: String
    let windowTitle: String
    let workingDirectory: String?
    let updatedAt: Date
    let matchSource: MatchSource
}

/// Every live session, keyed by history key. Each key's locations are ordered best first.
struct LiveAgentSessionSnapshot: Equatable, Sendable {
    static let empty = LiveAgentSessionSnapshot(locationsByKey: [:])

    let locationsByKey: [AgentHistorySessionKey: [LiveAgentSessionLocation]]

    func primaryLocation(for key: AgentHistorySessionKey) -> LiveAgentSessionLocation? {
        locationsByKey[key]?.first
    }

    func isLive(_ key: AgentHistorySessionKey) -> Bool {
        primaryLocation(for: key) != nil
    }

    var liveKeys: Set<AgentHistorySessionKey> {
        Set(locationsByKey.compactMap { key, locations in locations.isEmpty ? nil : key })
    }

    /// One location per live session, most recently updated first.
    var allPrimaryLocations: [LiveAgentSessionLocation] {
        locationsByKey.values
            .compactMap(\.first)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                if lhs.key.agent != rhs.key.agent {
                    return lhs.key.agent.rawValue < rhs.key.agent.rawValue
                }
                return lhs.key.nativeID < rhs.key.nativeID
            }
    }
}

/// Keeps a `LiveAgentSessionSnapshot` current for every window's worklane store.
///
/// Main-actor confined. Store changes that can move a session (pane structure, auxiliary
/// state, worklane list, active worklane) schedule one rebuild on the next main-queue turn,
/// so a burst of changes costs one rebuild and at most one `onChange`.
@MainActor
final class LiveAgentSessionIndex {
    private(set) var snapshot: LiveAgentSessionSnapshot = .empty
    var onChange: ((LiveAgentSessionSnapshot) -> Void)?

    private let sources: () -> [MenuBarWorklaneSource]
    private let preferredWindowID: () -> WindowID?
    private let isProcessAlive: (Int32) -> Bool
    private var subscriptions: [WindowID: (store: WorklaneStore, subscription: WorklaneChangeSubscription)] = [:]
    private var isStarted = false
    private var isRefreshPending = false

    init(
        sources: @escaping () -> [MenuBarWorklaneSource],
        preferredWindowID: @escaping () -> WindowID?,
        isProcessAlive: @escaping (Int32) -> Bool = SessionRestoreDraftExporter.defaultIsProcessAlive
    ) {
        self.sources = sources
        self.preferredWindowID = preferredWindowID
        self.isProcessAlive = isProcessAlive
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshNow()
    }

    func stop() {
        isStarted = false
        isRefreshPending = false
        for entry in subscriptions.values {
            entry.store.unsubscribe(entry.subscription)
        }
        subscriptions.removeAll()
    }

    /// Rebuilds the snapshot now. While started, it also picks up windows opened or closed
    /// since the last rebuild.
    func refreshNow() {
        isRefreshPending = false
        let currentSources = sources()
        if isStarted {
            reconcileSubscriptions(with: currentSources)
        }
        let next = LiveAgentSessionSnapshotBuilder.snapshot(
            from: currentSources,
            preferredWindowID: preferredWindowID(),
            isProcessAlive: isProcessAlive
        )
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    static func isRelevant(_ change: WorklaneChange) -> Bool {
        switch change {
        case .paneStructure, .floats, .auxiliaryStateUpdated, .worklaneListChanged, .activeWorklaneChanged:
            return true
        case .focusChanged, .layoutResized, .volatileAgentTitleUpdated, .teamAnchorsChanged, .historyChanged:
            return false
        }
    }

    private func handle(_ change: WorklaneChange) {
        guard isStarted, Self.isRelevant(change), !isRefreshPending else { return }
        isRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingRefresh()
        }
    }

    private func flushPendingRefresh() {
        guard isStarted, isRefreshPending else { return }
        refreshNow()
    }

    private func reconcileSubscriptions(with sources: [MenuBarWorklaneSource]) {
        let sourceWindowIDs = Set(sources.map(\.windowID))
        for windowID in subscriptions.keys where !sourceWindowIDs.contains(windowID) {
            if let entry = subscriptions.removeValue(forKey: windowID) {
                entry.store.unsubscribe(entry.subscription)
            }
        }

        for source in sources {
            if let existing = subscriptions[source.windowID] {
                guard existing.store !== source.worklaneStore else { continue }
                existing.store.unsubscribe(existing.subscription)
            }
            let subscription = source.worklaneStore.subscribe { [weak self] change in
                self?.handle(change)
            }
            subscriptions[source.windowID] = (store: source.worklaneStore, subscription: subscription)
        }
    }
}

extension AgentHistoryResumeSource {
    /// A live pane's session. It has no index row, so opens are not recorded for it.
    init(live: LiveAgentSessionLocation) {
        self.init(
            sessionRowID: nil,
            agent: live.key.agent,
            nativeSessionID: live.key.nativeID,
            title: live.paneDisplayName,
            workingDirectory: live.workingDirectory,
            repoRoot: nil,
            mainRepoRoot: nil,
            branch: nil,
            model: nil,
            effort: nil,
            generation: nil,
            sourceRoot: nil
        )
    }
}
