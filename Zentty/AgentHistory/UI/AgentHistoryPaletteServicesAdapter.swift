import AppKit

/// Builds one window's palette services over the real app: the shared history controller, its
/// search engine, the launcher and the config store. The only place that touches the general
/// pasteboard, Finder and Claude Code's settings; tests inject fakes instead.
@MainActor
enum AgentHistoryPaletteServicesAdapter {
    static func make(
        controller: AgentHistoryController,
        host: MainWindowController,
        configStore: AppConfigStore
    ) -> AgentHistoryPaletteServices {
        AgentHistoryPaletteServices(
            control: controller,
            search: AgentHistorySearchAdapter(controller: controller),
            launch: AgentHistoryLaunchAdapter(host: host, usageRecorder: controller),
            excludedFolders: { [weak configStore] in
                configStore?.current.agentHistory.excludedFolders ?? []
            },
            setExcludedFolders: { [weak configStore] folders in
                try saveExcludedFolders(folders, to: configStore)
            },
            claudeRetention: {
                ClaudeRetentionSettings.status(configDirectory: ClaudeRetentionSettings.defaultConfigDirectory())
            },
            raiseClaudeRetention: {
                try ClaudeRetentionSettings.raiseRetention(configDirectory: ClaudeRetentionSettings.defaultConfigDirectory())
            },
            pasteboard: .general,
            revealInFinder: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            now: Date.init
        )
    }

    /// Saves the folders to config.toml. A write-protected config (a file that can't be parsed)
    /// only keeps the change in memory, and the file's empty list would win after a relaunch, so
    /// that counts as a failure too.
    static func saveExcludedFolders(_ folders: [String], to configStore: AppConfigStore?) throws {
        do {
            guard let configStore else { throw AgentHistoryExcludedFoldersSaveError.notSaved }
            try configStore.update { $0.agentHistory.excludedFolders = folders }
            if configStore.isWriteProtected {
                throw AgentHistoryExcludedFoldersSaveError.notSaved
            }
        } catch {
            AgentHistoryLog.indexer.error("Agent History couldn't save its excluded folders")
            throw error
        }
    }
}

enum AgentHistoryExcludedFoldersSaveError: Error, Equatable {
    case notSaved
}

// MARK: - Search

/// The palette's search seam over `AgentHistoryController.searchEngine`. The engine is looked
/// up on every call: it is nil while Agent History is off or the index isn't ready, and a new
/// one replaces it when the storage changes. Without an engine everything is empty, and loads
/// fail with `indexUnavailable`.
///
/// The metadata tier runs on main (in-memory snapshot). Content searches run on the engine's
/// search queue; previews and transcripts on a reader queue of their own, so a slow content
/// search never holds up the preview. Completions arrive on main, once, never after `cancel()`.
@MainActor
final class AgentHistorySearchAdapter: AgentHistorySearchServicing {
    nonisolated static let readQueue = DispatchQueue(
        label: "be.zenjoy.zentty.agent-history.palette-reads",
        qos: .userInitiated
    )

    private let engine: @Sendable () -> HistorySearchEngine?
    private var contentGeneration: UInt64 = 0

    init(engine: @escaping @Sendable () -> HistorySearchEngine?) {
        self.engine = engine
    }

    convenience init(controller: AgentHistoryController) {
        self.init(engine: { controller.searchEngine })
    }

    func recentSessions(scope: AgentHistoryScope, limit: Int) -> [AgentHistorySessionSummary] {
        engine()?.metadataIndex.recent(limit: limit, scope: scope) ?? []
    }

    func sessions(for keys: [AgentHistorySessionKey]) -> [AgentHistorySessionSummary] {
        engine()?.metadataIndex.sessions(for: keys) ?? []
    }

    func indexedSessionCount(scope: AgentHistoryScope) -> Int {
        engine()?.metadataIndex.sessionCount(scope: scope) ?? 0
    }

    func tokenizer() -> AgentHistoryTokenizer {
        engine()?.tokenizer ?? .none
    }

    func metadataHits(for query: HistoryQuery, context: HistorySearchContext, limit: Int) -> HistoryMetadataResponse {
        guard let engine = engine() else {
            return HistoryMetadataResponse(query: query, generation: 0, results: [], elapsed: 0)
        }
        return engine.metadataIndex.search(query, context: context, limit: limit)
    }

    func searchContent(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excluding sessionIDs: Set<Int64>,
        completion: @escaping @MainActor (Result<HistoryContentResponse, Error>) -> Void
    ) -> AgentHistoryCancellable {
        contentGeneration &+= 1
        let cancellation = HistorySearchCancellation(generation: contentGeneration)
        let token = AgentHistorySearchToken(cancellation: cancellation)
        guard let engine = engine() else {
            let empty = HistoryContentResponse(
                query: query, generation: cancellation.generation, results: [], enrichments: [:],
                mode: .fts, truncated: false, elapsed: 0)
            token.deliverOnNextTurn(.success(empty), to: completion)
            return token
        }
        engine.searchContentAsync(
            query,
            context: context,
            excludingSessionIDs: sessionIDs,
            cancellation: cancellation
        ) { result in
            token.deliver(result, to: completion)
        }
        return token
    }

    func loadPreview(
        _ sessionID: Int64,
        query: HistoryQuery,
        completion: @escaping @MainActor (Result<HistoryPreview, Error>) -> Void
    ) -> AgentHistoryCancellable {
        read(completion: completion) { engine in
            try engine.preview(sessionID: sessionID, query: query)
        }
    }

    func loadTranscript(
        _ sessionID: Int64,
        query: HistoryQuery,
        completion: @escaping @MainActor (Result<HistoryTranscript, Error>) -> Void
    ) -> AgentHistoryCancellable {
        read(completion: completion) { engine in
            try engine.transcript(sessionID: sessionID, query: query)
        }
    }

    private func read<Value: Sendable>(
        completion: @escaping @MainActor (Result<Value, Error>) -> Void,
        _ body: @escaping @Sendable (HistorySearchEngine) throws -> Value
    ) -> AgentHistoryCancellable {
        guard let engine = engine() else {
            let token = AgentHistorySearchToken(cancellation: nil)
            token.deliverOnNextTurn(.failure(HistorySearchError.indexUnavailable("off")), to: completion)
            return token
        }
        return Self.runRead(on: Self.readQueue, completion: completion) { try body(engine) }
    }

    /// Runs one read on `queue` (serial). A read cancelled while it waits its turn is skipped:
    /// holding ↓ through the list would otherwise queue a preview and a transcript per row, and
    /// the row the user stops on would wait for every stale one.
    static func runRead<Value: Sendable>(
        on queue: DispatchQueue,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void,
        _ work: @escaping @Sendable () throws -> Value
    ) -> AgentHistorySearchToken {
        let cancellation = HistorySearchCancellation()
        let token = AgentHistorySearchToken(cancellation: cancellation)
        queue.async {
            let result: Result<Value, Error> = cancellation.isCancelled
                ? .failure(HistorySearchError.cancelled)
                : Result { try work() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    token.deliver(result, to: completion)
                }
            }
        }
        return token
    }
}

/// One search or load: delivers at most one result, none after `cancel()`. Cancelling a content
/// search also interrupts its SQLite query; a cancelled read that hasn't started never runs.
@MainActor
final class AgentHistorySearchToken: AgentHistoryCancellable {
    private let cancellation: HistorySearchCancellation?
    private var isFinished = false

    init(cancellation: HistorySearchCancellation?) {
        self.cancellation = cancellation
    }

    func cancel() {
        isFinished = true
        cancellation?.cancel()
    }

    func deliver<Value>(_ result: Result<Value, Error>, to completion: @MainActor (Result<Value, Error>) -> Void) {
        guard !isFinished else { return }
        isFinished = true
        completion(result)
    }

    /// Never synchronously: the caller stores the token before any result arrives.
    func deliverOnNextTurn<Value: Sendable>(
        _ result: Result<Value, Error>,
        to completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.deliver(result, to: completion)
            }
        }
    }
}

// MARK: - Launch

/// The palette's launch seam: the launcher for ↩ / ⌘↩ and folder choices, and a live-session
/// index over every window's worklanes, watched only while a palette observes it.
@MainActor
final class AgentHistoryLaunchAdapter: AgentHistoryLaunchServicing {
    private let launcher: AgentHistoryLauncher
    private let liveIndex: LiveAgentSessionIndex
    private var observers: [UUID: @MainActor () -> Void] = [:]

    init(launcher: AgentHistoryLauncher, liveIndex: LiveAgentSessionIndex) {
        self.launcher = launcher
        self.liveIndex = liveIndex
    }

    /// Weak to `host`: the window owns these services.
    convenience init(host: MainWindowController, usageRecorder: (any AgentHistoryUsageRecording)?) {
        let liveIndex = LiveAgentSessionIndex(
            sources: { [weak host] in host?.agentHistorySources ?? [] },
            preferredWindowID: { [weak host] in host?.windowID }
        )
        let launcher = AgentHistoryLauncher(
            hosts: { [weak host] in host?.agentHistoryHosts ?? [] },
            presentingHost: { [weak host] in host },
            liveIndex: liveIndex,
            usageRecorder: usageRecorder
        )
        self.init(launcher: launcher, liveIndex: liveIndex)
    }

    func liveSnapshot() -> LiveAgentSessionSnapshot {
        // While observed, the index keeps itself current.
        if observers.isEmpty {
            liveIndex.refreshNow()
        }
        return liveIndex.snapshot
    }

    func observeLiveSessions(_ handler: @escaping @MainActor () -> Void) -> AgentHistoryCancellable {
        let id = UUID()
        observers[id] = handler
        if observers.count == 1 {
            liveIndex.onChange = { [weak self] _ in
                self?.notifyObservers()
            }
            liveIndex.start()
        }
        return AgentHistoryCancellableBlock { [weak self] in
            self?.removeObserver(id)
        }
    }

    func resumePlan(for source: AgentHistoryResumeSource) -> AgentHistoryResumeAvailability {
        launcher.resumePlan(for: source)
    }

    func launch(
        _ source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        folderChoice: AgentHistoryFolderChoice?
    ) -> AgentHistoryLaunchOutcome {
        guard let folderChoice else {
            return launcher.perform(intent, source: source)
        }
        return launcher.resume(source, intent: intent, folderChoice: folderChoice)
    }

    private func notifyObservers() {
        for handler in Array(observers.values) {
            handler()
        }
    }

    private func removeObserver(_ id: UUID) {
        guard observers.removeValue(forKey: id) != nil, observers.isEmpty else { return }
        liveIndex.stop()
        liveIndex.onChange = nil
    }
}
