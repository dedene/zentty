import Foundation
import OSLog

private let companionDashboardLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionDashboard")

// MARK: - State source seam

/// Supplies the live worklane/pane rows for a dashboard snapshot. Implemented by
/// `AppDelegate` (the discovery walk); faked in tests so the feed's diffing and
/// debouncing can be exercised without real windows.
@MainActor
protocol CompanionDashboardStateProviding: AnyObject {
    func companionDashboardWorklanes() -> [CompanionDashboardWorklane]
}

// MARK: - Subscription token

/// Opaque handle returned by `addSubscriber`, used to unregister on disconnect.
struct CompanionDashboardSubscriptionToken: Hashable, Sendable {
    fileprivate let id: UUID
}

// MARK: - Status → wire mapping

/// Pure mapping from the app's agent state to the wire `CompanionPaneSummary`.
/// Kept free of AppKit so it is unit-testable in `ZenttyLogicTests`.
enum CompanionDashboardMapping {
    static func paneState(from state: PaneAgentState) -> CompanionPaneState {
        switch state {
        case .starting: return .starting
        case .running: return .running
        case .needsInput: return .needsInput
        case .unresolvedStop: return .unresolvedStop
        case .idle: return .idle
        }
    }

    static func interactionKind(from kind: PaneAgentInteractionKind) -> CompanionInteractionKind {
        switch kind {
        case .none: return .none
        case .approval: return .approval
        case .question: return .question
        case .decision: return .decision
        case .auth: return .auth
        case .genericInput: return .genericInput
        }
    }

    static func summary(
        paneID: String,
        worklaneID: String,
        title: String,
        status: PaneAgentStatus
    ) -> CompanionPaneSummary {
        let state = paneState(from: status.state)
        let kind = interactionKind(from: status.interactionKind)
        let requiresAttention = kind != .none
            || status.state == .needsInput
            || status.state == .unresolvedStop
        let progress = status.taskProgress.map {
            CompanionTaskProgress(completed: $0.doneCount, total: $0.totalCount)
        }
        // A Conversation tab exists only where a transcript adapter does; v1
        // ships Claude Code, and only once a session id is known.
        let hasTranscript = status.tool == .claudeCode && status.sessionID != nil

        return CompanionPaneSummary(
            paneId: paneID,
            worklaneId: worklaneID,
            title: title,
            tool: status.tool.displayName,
            state: state,
            interactionKind: kind,
            requiresHumanAttention: requiresAttention,
            workingDirectory: status.workingDirectory ?? "",
            sessionId: status.sessionID,
            hasTranscript: hasTranscript,
            taskProgress: progress
        )
    }
}

// MARK: - Feed

/// Builds `dashboard.snapshot` from live state and pushes `dashboard.delta` to
/// subscribed sessions on debounced status changes. `@MainActor`: it reads the
/// window/worklane graph, which is main-actor-confined.
@MainActor
final class CompanionDashboardFeed {
    static let defaultDebounce: TimeInterval = 0.2

    private weak var provider: CompanionDashboardStateProviding?
    private let debounceInterval: TimeInterval
    private var subscribers: [CompanionDashboardSubscriptionToken: (CompanionDashboardDelta) -> Void] = [:]
    /// Last serialized summary per pane id, for diffing deltas.
    private var lastSummaries: [String: CompanionPaneSummary] = [:]
    private var debounceTask: Task<Void, Never>?

    init(
        provider: CompanionDashboardStateProviding,
        debounceInterval: TimeInterval = CompanionDashboardFeed.defaultDebounce
    ) {
        self.provider = provider
        self.debounceInterval = debounceInterval
    }

    // MARK: Snapshot

    /// Builds a full snapshot and re-baselines the diff state to it, so the next
    /// delta is computed against exactly what a subscriber was just handed.
    func makeSnapshot() -> CompanionDashboardSnapshot {
        let worklanes = provider?.companionDashboardWorklanes() ?? []
        lastSummaries = Self.index(worklanes)
        return CompanionDashboardSnapshot(worklanes: worklanes)
    }

    // MARK: Subscription

    func addSubscriber(_ handler: @escaping (CompanionDashboardDelta) -> Void) -> CompanionDashboardSubscriptionToken {
        let token = CompanionDashboardSubscriptionToken(id: UUID())
        subscribers[token] = handler
        return token
    }

    func removeSubscriber(_ token: CompanionDashboardSubscriptionToken) {
        subscribers.removeValue(forKey: token)
        if subscribers.isEmpty {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    var hasSubscribers: Bool { !subscribers.isEmpty }

    // MARK: Change signal

    /// Called (debounced) whenever agent status may have changed. Coalesces
    /// bursts into one recompute + delta per `debounceInterval`.
    func scheduleRecompute() {
        guard hasSubscribers else { return }
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            let nanoseconds = UInt64(interval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.recomputeAndEmit()
        }
    }

    /// Recomputes immediately, bypassing the debounce (tests, or an explicit
    /// flush). No-op with no subscribers.
    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        recomputeAndEmit()
    }

    private func recomputeAndEmit() {
        guard hasSubscribers else { return }
        let worklanes = provider?.companionDashboardWorklanes() ?? []
        let current = Self.index(worklanes)

        var updated: [CompanionPaneSummary] = []
        for (paneId, summary) in current where lastSummaries[paneId] != summary {
            updated.append(summary)
        }
        let removed = lastSummaries.keys.filter { current[$0] == nil }

        lastSummaries = current
        guard !updated.isEmpty || !removed.isEmpty else { return }

        // Deterministic ordering keeps deltas stable for tests and clients.
        updated.sort { $0.paneId < $1.paneId }
        let delta = CompanionDashboardDelta(updated: updated, removedPaneIds: removed.sorted())
        for handler in subscribers.values {
            handler(delta)
        }
    }

    private static func index(_ worklanes: [CompanionDashboardWorklane]) -> [String: CompanionPaneSummary] {
        var result: [String: CompanionPaneSummary] = [:]
        for worklane in worklanes {
            for pane in worklane.panes {
                result[pane.paneId] = pane
            }
        }
        return result
    }
}
