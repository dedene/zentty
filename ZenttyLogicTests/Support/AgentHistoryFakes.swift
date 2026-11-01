import AppKit
@testable import Zentty

// Fakes for the Agent History palette's service seams (`AgentHistoryPaletteServices`).

/// Records control calls; `status` is set by the test and pushed to observers with `publish`.
@MainActor
final class FakeAgentHistoryControl: AgentHistoryControlling {
    /// Off with `state.json` read (never consented); set `.off` itself for "not read yet".
    var status: AgentHistoryStatus = {
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        return status
    }()
    var detectedSources: [AgentHistoryDetectedSource] = []
    /// Holds `detectSources` completions until `releaseDetections()`, like the real probe that
    /// answers later from a background queue.
    var holdsDetection = false
    private var pendingDetections: [@MainActor ([AgentHistoryDetectedSource]) -> Void] = []
    var disableOutcome = AgentHistoryDisableOutcome.turnedOff
    /// What `setEnabled` and `setAgentEnabled` answer.
    var stateChangeOutcome = AgentHistoryStateChangeOutcome.saved
    private(set) var refreshCount = 0
    private(set) var enabledAgents: [Set<AgentHistoryAgent>] = []
    private(set) var setEnabledCalls: [Bool] = []
    private(set) var setAgentEnabledCalls: [AgentHistoryAgent: Bool] = [:]
    private(set) var disableCalls: [Bool] = []
    private(set) var rebuildCount = 0
    private(set) var restoreAllCount = 0
    private(set) var removedKeys: [AgentHistorySessionKey] = []
    private var observers: [UUID: @MainActor (AgentHistoryStatus) -> Void] = [:]

    var observerCount: Int { observers.count }

    func publish(_ status: AgentHistoryStatus) {
        self.status = status
        for observer in observers.values {
            observer(status)
        }
    }

    @discardableResult
    func addStatusObserver(_ handler: @escaping @MainActor (AgentHistoryStatus) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }
    func refreshStatus() { refreshCount += 1 }
    func detectSources(_ completion: @escaping @MainActor ([AgentHistoryDetectedSource]) -> Void) {
        guard holdsDetection else {
            completion(detectedSources)
            return
        }
        pendingDetections.append(completion)
    }

    func releaseDetections() {
        let pending = pendingDetections
        pendingDetections.removeAll()
        pending.forEach { $0(detectedSources) }
    }
    func enable(agents: Set<AgentHistoryAgent>) { enabledAgents.append(agents) }
    func setEnabled(_ enabled: Bool, completion: @escaping @MainActor (AgentHistoryStateChangeOutcome) -> Void) {
        setEnabledCalls.append(enabled)
        completion(stateChangeOutcome)
    }
    func setAgentEnabled(
        _ agent: AgentHistoryAgent,
        _ enabled: Bool,
        completion: @escaping @MainActor (AgentHistoryStateChangeOutcome) -> Void
    ) {
        setAgentEnabledCalls[agent] = enabled
        completion(stateChangeOutcome)
    }
    func disable(deleteIndex: Bool, completion: @escaping @MainActor (AgentHistoryDisableOutcome) -> Void) {
        disableCalls.append(deleteIndex)
        completion(disableOutcome)
    }
    func rebuildIndex() { rebuildCount += 1 }
    func restoreAllRemovedSessions() { restoreAllCount += 1 }
    func removeSession(_ key: AgentHistorySessionKey) { removedKeys.append(key) }
}

/// A cancellable that remembers it was cancelled.
@MainActor
final class FakeAgentHistoryToken: AgentHistoryCancellable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

/// Synchronous tiers return canned values; asynchronous calls are held until the test completes
/// them, so ordering and cancellation are under the test's control.
@MainActor
final class FakeAgentHistorySearch: AgentHistorySearchServicing {
    struct PendingContent {
        let query: HistoryQuery
        let excluding: Set<Int64>
        let token: FakeAgentHistoryToken
        let completion: @MainActor (Result<HistoryContentResponse, Error>) -> Void
    }

    struct PendingLoad<Value> {
        let sessionID: Int64
        let token: FakeAgentHistoryToken
        let completion: @MainActor (Result<Value, Error>) -> Void
    }

    var recent: [AgentHistorySessionSummary] = []
    var summariesByKey: [AgentHistorySessionKey: AgentHistorySessionSummary] = [:]
    var sessionCount = 0
    var currentTokenizer = AgentHistoryTokenizer.trigram
    var metadataResults: (HistoryQuery) -> [HistoryMetadataResult] = { _ in [] }
    private(set) var metadataQueries: [HistoryQuery] = []
    private(set) var recentScopes: [AgentHistoryScope] = []
    private(set) var pendingContent: [PendingContent] = []
    private(set) var pendingPreviews: [PendingLoad<HistoryPreview>] = []
    private(set) var pendingTranscripts: [PendingLoad<HistoryTranscript>] = []

    func recentSessions(scope: AgentHistoryScope, limit: Int) -> [AgentHistorySessionSummary] {
        recentScopes.append(scope)
        return Array(recent.prefix(limit))
    }

    func sessions(for keys: [AgentHistorySessionKey]) -> [AgentHistorySessionSummary] {
        keys.compactMap { summariesByKey[$0] }
    }

    func indexedSessionCount(scope: AgentHistoryScope) -> Int { sessionCount }
    func tokenizer() -> AgentHistoryTokenizer { currentTokenizer }

    func metadataHits(for query: HistoryQuery, context: HistorySearchContext, limit: Int) -> HistoryMetadataResponse {
        metadataQueries.append(query)
        let results = Array(metadataResults(query).prefix(limit))
        return HistoryMetadataResponse(query: query, generation: 0, results: results, elapsed: 0)
    }

    func searchContent(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excluding sessionIDs: Set<Int64>,
        completion: @escaping @MainActor (Result<HistoryContentResponse, Error>) -> Void
    ) -> AgentHistoryCancellable {
        let token = FakeAgentHistoryToken()
        pendingContent.append(PendingContent(query: query, excluding: sessionIDs, token: token, completion: completion))
        return token
    }

    func loadPreview(
        _ sessionID: Int64,
        query: HistoryQuery,
        completion: @escaping @MainActor (Result<HistoryPreview, Error>) -> Void
    ) -> AgentHistoryCancellable {
        let token = FakeAgentHistoryToken()
        pendingPreviews.append(PendingLoad(sessionID: sessionID, token: token, completion: completion))
        return token
    }

    func loadTranscript(
        _ sessionID: Int64,
        query: HistoryQuery,
        completion: @escaping @MainActor (Result<HistoryTranscript, Error>) -> Void
    ) -> AgentHistoryCancellable {
        let token = FakeAgentHistoryToken()
        pendingTranscripts.append(PendingLoad(sessionID: sessionID, token: token, completion: completion))
        return token
    }
}

/// Returns scripted outcomes and records every launch.
@MainActor
final class FakeAgentHistoryLaunch: AgentHistoryLaunchServicing {
    struct Launch: Equatable {
        let source: AgentHistoryResumeSource
        let intent: AgentHistoryLaunchIntent
        let folderChoice: AgentHistoryFolderChoice?
    }

    var snapshot = LiveAgentSessionSnapshot.empty
    var outcome = AgentHistoryLaunchOutcome.recreatingWorktree
    var availability: (AgentHistoryResumeSource) -> AgentHistoryResumeAvailability = {
        AgentHistoryResumeCommandBuilder.availability(for: $0)
    }
    private(set) var launches: [Launch] = []
    private var liveHandlers: [ObjectIdentifier: @MainActor () -> Void] = [:]

    func liveSnapshot() -> LiveAgentSessionSnapshot { snapshot }

    func observeLiveSessions(_ handler: @escaping @MainActor () -> Void) -> AgentHistoryCancellable {
        let token = FakeAgentHistoryToken()
        let id = ObjectIdentifier(token)
        liveHandlers[id] = handler
        return AgentHistoryCancellableBlock { [weak self] in
            token.cancel()
            self?.liveHandlers[id] = nil
        }
    }

    /// Replaces the snapshot and notifies observers.
    func publishLive(_ snapshot: LiveAgentSessionSnapshot) {
        self.snapshot = snapshot
        for handler in liveHandlers.values {
            handler()
        }
    }

    func resumePlan(for source: AgentHistoryResumeSource) -> AgentHistoryResumeAvailability {
        availability(source)
    }

    func launch(
        _ source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        folderChoice: AgentHistoryFolderChoice?
    ) -> AgentHistoryLaunchOutcome {
        launches.append(Launch(source: source, intent: intent, folderChoice: folderChoice))
        return outcome
    }
}

/// Fires scheduled work only when the test advances its clock.
@MainActor
final class ManualAgentHistoryScheduler: AgentHistoryScheduling {
    private struct Entry {
        let fireAt: TimeInterval
        let order: Int
        let work: AgentHistoryScheduledWork
    }

    private(set) var now: TimeInterval = 0
    private var entries: [Entry] = []
    private var nextOrder = 0

    var pendingCount: Int { entries.count }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AgentHistoryCancellable {
        let scheduled = AgentHistoryScheduledWork(work)
        entries.append(Entry(fireAt: now + max(0, delay), order: nextOrder, work: scheduled))
        nextOrder += 1
        return AgentHistoryCancellableBlock { [weak self] in
            scheduled.cancel()
            self?.entries.removeAll { $0.work === scheduled }
        }
    }

    /// Runs every item due by `now + interval`, in due order (ties by scheduling order).
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = entries.filter({ $0.fireAt <= target }).min(by: { ($0.fireAt, $0.order) < ($1.fireAt, $1.order) }) {
            entries.removeAll { $0.work === next.work }
            now = next.fireAt
            next.work.fire()
        }
        now = target
    }
}

enum AgentHistoryTestPasteboard {
    /// A uniquely named pasteboard; never the system one. Released by the caller's teardown.
    @MainActor
    static func make() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("zentty-agent-history-test-\(UUID().uuidString)"))
    }
}
