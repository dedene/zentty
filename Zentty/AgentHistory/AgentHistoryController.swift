import Foundation

/// What the controller hands every indexer it creates, so published status and snapshots reach it.
struct AgentHistoryIndexerCallbacks: Sendable {
    let onStatusChange: @MainActor @Sendable (AgentHistoryStatus) -> Void
    let onSnapshotChange: @MainActor @Sendable (AgentHistoryMetadataSnapshot) -> Void
}

/// The app-level owner of Agent History (§3.9): reads consent from `state.json`, starts the
/// indexer a few seconds after launch, pushes config changes to it, turns it off (keeping or
/// deleting the index) and stops it on quit.
///
/// Main-actor confined. Everything that touches disk (`state.json`, stopping the indexer,
/// deleting the directory) runs on a serial utility queue, so the main thread never waits on
/// I/O; `stop()` at quit is the one exception and waits at most a second (A-7). Status,
/// snapshot, storage, exclusions and the allow flag are mirrored under a lock for other threads.
@MainActor
final class AgentHistoryController: Sendable {
    typealias IndexerFactory = (
        AgentHistoryStorage, AgentHistoryStateStore, AgentHistoryIndexerConfiguration, AgentHistoryIndexerCallbacks
    ) -> AgentHistoryIndexer
    typealias StatusObserver = @MainActor (AgentHistoryStatus) -> Void
    typealias SnapshotObserver = @MainActor (AgentHistoryMetadataSnapshot) -> Void

    static let shared = AgentHistoryController()

    private let launchDelay: TimeInterval
    private let makeSources: @Sendable () -> [any AgentHistorySource]
    private let makeIndexer: IndexerFactory
    private let mirror = AgentHistoryControllerMirror()
    /// The search engine over `storageInstance`, built on first use (`+Search.swift`).
    nonisolated let searchEngineCache = AgentHistorySearchEngineCache()
    private let controlQueue = DispatchQueue(label: "be.zenjoy.zentty.agent-history.control", qos: .utility)

    private var configStore: AppConfigStore?
    private var configObserverID: UUID?
    private var paths: AgentHistoryPaths?
    private var storageInstance: AgentHistoryStorage?
    private var configSection = AppConfig.AgentHistory.default
    /// False from a launch with an unreadable config.toml until a readable one loads
    /// (`AppConfigStore.isUsingFallbackDefaults`). The excluded folders are unknown then, so the
    /// indexer stays stopped and nothing can be searched: exclusions fail closed.
    private var isConfigReadable = true
    /// The last `state.json` contents read or written; nil until the first load.
    private var persistedState: AgentHistoryState?
    private var stateStore: AgentHistoryStateStore?
    private(set) var indexer: AgentHistoryIndexer?
    /// Bumped per indexer, so a stopped indexer's late publishes are ignored.
    private var indexerGeneration: UInt64 = 0
    /// Bumped by every user-driven state change, so a slower launch read never overrides it.
    private var stateChangeSequence: UInt64 = 0
    private(set) var isLaunchStartScheduled = false
    private var statusObservers: [UUID: StatusObserver] = [:]
    private var snapshotObservers: [UUID: SnapshotObserver] = [:]

    private(set) var status = AgentHistoryStatus.off
    private(set) var metadataSnapshot = AgentHistoryMetadataSnapshot.empty

    init(
        launchDelay: TimeInterval = 5,
        makeSources: @escaping @Sendable () -> [any AgentHistorySource] = { AgentHistorySourceFactory.makeSources() },
        makeIndexer: IndexerFactory? = nil
    ) {
        self.launchDelay = launchDelay
        self.makeSources = makeSources
        self.makeIndexer = makeIndexer ?? { storage, stateStore, configuration, callbacks in
            AgentHistoryIndexer(
                storage: storage,
                stateStore: stateStore,
                makeSources: makeSources,
                configuration: configuration,
                onStatusChange: callbacks.onStatusChange,
                onSnapshotChange: callbacks.onSnapshotChange
            )
        }
    }

    // MARK: - Thread-safe reads

    nonisolated var threadSafeStatus: AgentHistoryStatus { mirror.status }
    nonisolated var threadSafeSnapshot: AgentHistoryMetadataSnapshot { mirror.snapshot }
    /// The running index's storage (readers for search and IPC); nil while the indexer is off.
    nonisolated var storage: AgentHistoryStorage? { mirror.storage }
    nonisolated var allowsAgentsAllProjects: Bool { mirror.allowsAgentsAllProjects }
    /// The configured excluded folders, canonicalized on first use off the caller's thread.
    nonisolated var exclusions: AgentHistoryExclusionMatcher { mirror.exclusions }
    /// The agents the persisted state has on. Search gates on it so turning an agent off hides
    /// it at once, before its purge has run (which a full disk or standby can delay).
    nonisolated var enabledAgents: Set<AgentHistoryAgent> { mirror.enabledAgents }

    // MARK: - Lifecycle

    /// Stores references and observes config changes. No I/O.
    func configure(configStore: AppConfigStore, paths: AgentHistoryPaths) {
        guard self.configStore == nil else {
            return
        }
        self.configStore = configStore
        self.paths = paths
        storageInstance = AgentHistoryStorage(paths: paths)
        applyConfig(configStore.current.agentHistory, isReadable: !configStore.isUsingFallbackDefaults)
        configObserverID = configStore.addObserver { [weak self, weak configStore] config in
            let section = config.agentHistory
            let isReadable = !(configStore?.isUsingFallbackDefaults ?? false)
            Task { @MainActor in
                self?.applyConfig(section, isReadable: isReadable)
            }
        }
    }

    /// After `launchDelay`, reads `state.json` off-main and starts the indexer only when Agent
    /// History is on, consented and has at least one agent. `completion` (tests) gets whether
    /// it started.
    func scheduleStartAfterLaunch(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard paths != nil, !isLaunchStartScheduled else {
            completion?(false)
            return
        }
        isLaunchStartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.loadStateAndStart(completion: completion)
            }
        }
    }

    /// Stops the indexer at quit: waits at most a second for in-flight work (A-7).
    func stop() {
        guard let indexer = detachIndexer() else {
            return
        }
        indexer.stop()
        storageInstance?.readers.closeAll()
        publishOffStatus()
    }

    // MARK: - Observers

    @discardableResult
    func addStatusObserver(_ handler: @escaping StatusObserver) -> UUID {
        let id = UUID()
        statusObservers[id] = handler
        return id
    }

    @discardableResult
    func addSnapshotObserver(_ handler: @escaping SnapshotObserver) -> UUID {
        let id = UUID()
        snapshotObservers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        statusObservers[id] = nil
        snapshotObservers[id] = nil
    }

    // MARK: - Control

    /// Which agents have history on this Mac, stat-only and off-main (D11).
    func detectSources(_ completion: @escaping @MainActor ([AgentHistoryDetectedSource]) -> Void) {
        let makeSources = self.makeSources
        let deliver = AgentHistoryMainDelivery(completion)
        DispatchQueue.global(qos: .userInitiated).async {
            let results = AgentHistoryDiscoveryProbe.detect(
                sources: makeSources(),
                candidatePaths: AgentHistoryRootLocator().candidatePaths(for:)
            )
            deliver.send(results)
        }
    }

    /// Records consent for `agents` (the others off) and starts indexing now. When `state.json`
    /// already holds consent (the caller saw the status before it loaded) it only turns History
    /// on: the saved per-agent choices and the consent date stay.
    func enable(agents: Set<AgentHistoryAgent>) {
        updateState { state in
            state.enabled = true
            guard state.consentedAt == nil else {
                return
            }
            state.consentedAt = Date()
            for agent in AgentHistoryAgent.allCases {
                state.setSource(agent, enabled: agents.contains(agent))
            }
        }
    }

    /// Off stops the indexer and keeps the index; on starts it again when consented.
    func setEnabled(_ enabled: Bool) {
        updateState { $0.enabled = enabled }
    }

    /// Off purges that agent's rows (D4); on reads its sources again from the start.
    func setAgentEnabled(_ agent: AgentHistoryAgent, _ enabled: Bool) {
        updateState { $0.setSource(agent, enabled: enabled) }
    }

    /// Stops the indexer, then either deletes the whole directory and the consent (D8) or just
    /// turns Agent History off. `completion` runs on main once done, with what happened.
    ///
    /// The delete holds exclusive lifecycle ownership (`AgentHistoryStorage.withExclusiveOwnership`)
    /// from before the directory goes until consent is reset. While another Zentty instance runs
    /// Agent History on the same index (owning it or standing by to take over) nothing is
    /// deleted, consent stays, this instance's indexer starts again and the outcome is
    /// `.refusedAnotherInstance`.
    func disable(deleteIndex: Bool, completion: @escaping @MainActor (AgentHistoryDisableOutcome) -> Void) {
        guard let storage = storageInstance else {
            completion(.failed)
            return
        }
        stateChangeSequence &+= 1
        let indexer = detachIndexer()
        let deliver = AgentHistoryMainDelivery<(AgentHistoryLoadedState, AgentHistoryDisableOutcome)> {
            [weak self] loaded, outcome in
            self?.applyState(loaded)
            completion(outcome)
        }
        withStateStore { store in
            // Releases this instance's writer and presence locks: they would refuse the delete too.
            indexer?.stopAndWait()
            storage.readers.closeAll()
            let outcome: AgentHistoryDisableOutcome
            if deleteIndex {
                outcome = Self.deleteEverything(storage: storage, store: store)
            } else {
                Self.write(store) { $0.enabled = false }
                outcome = .turnedOff
            }
            deliver.send((AgentHistoryLoadedState(store: store, state: store.current), outcome))
        }
    }

    func rebuildIndex() {
        indexer?.rebuild()
    }

    func restoreAllRemovedSessions() {
        indexer?.restoreAllRemovedSessions()
    }

    func removeSession(_ key: AgentHistorySessionKey) {
        indexer?.removeSession(key)
    }

    /// Counts one open on the indexer's queue; dropped while the indexer is off.
    func recordOpen(sessionRowID: Int64, atMs: Int64) {
        indexer?.recordOpen(sessionRowID: sessionRowID, atMs: atMs)
    }

    // MARK: - State

    private func loadStateAndStart(completion: (@MainActor (Bool) -> Void)?) {
        let sequence = stateChangeSequence
        let deliver = AgentHistoryMainDelivery<AgentHistoryLoadedState> { [weak self] loaded in
            guard let self else {
                completion?(false)
                return
            }
            // A user change made while this read was in flight is newer; keep it.
            if sequence == self.stateChangeSequence {
                self.applyState(loaded)
            }
            completion?(self.indexer != nil)
        }
        withStateStore { store in
            deliver.send(AgentHistoryLoadedState(store: store, state: store.current))
        }
    }

    /// Writes `state.json` off-main, then applies the written state on main.
    private func updateState(_ mutate: @escaping @Sendable (inout AgentHistoryState) -> Void) {
        stateChangeSequence &+= 1
        let deliver = AgentHistoryMainDelivery<AgentHistoryLoadedState> { [weak self] loaded in
            self?.applyState(loaded)
        }
        withStateStore { store in
            Self.write(store, mutate)
            deliver.send(AgentHistoryLoadedState(store: store, state: store.current))
        }
    }

    /// Removes the directory and resets consent under exclusive ownership. On the control queue.
    private nonisolated static func deleteEverything(
        storage: AgentHistoryStorage,
        store: AgentHistoryStateStore
    ) -> AgentHistoryDisableOutcome {
        do {
            return try storage.withExclusiveOwnership { () -> AgentHistoryDisableOutcome in
                var outcome = AgentHistoryDisableOutcome.deleted
                do {
                    try storage.removeEverything()
                } catch {
                    AgentHistoryLog.indexer.error("Agent History couldn't delete its index directory")
                    outcome = .failed
                }
                // Still owned: no instance starts on the index before consent is gone.
                store.resetAfterDelete()
                return outcome
            }
        } catch let error as AgentHistoryDatabaseError where error.kind == .busy {
            AgentHistoryLog.indexer.info("Agent History kept its index: another Zentty instance is using it")
            return .refusedAnotherInstance
        } catch {
            AgentHistoryLog.indexer.error("Agent History couldn't take ownership of its index to delete it")
            return .failed
        }
    }

    private nonisolated static func write(
        _ store: AgentHistoryStateStore,
        _ mutate: (inout AgentHistoryState) -> Void
    ) {
        do {
            try store.update(mutate)
        } catch {
            AgentHistoryLog.indexer.error("Agent History couldn't save its state file")
        }
    }

    /// Runs `body` on the control queue with the state store, created there on first use
    /// (creating it reads `state.json`).
    private func withStateStore(_ body: @escaping @Sendable (AgentHistoryStateStore) -> Void) {
        guard let paths else {
            return
        }
        let mirror = self.mirror
        controlQueue.async {
            body(mirror.stateStore(fileURL: paths.stateURL))
        }
    }

    /// Brings the indexer in line with `next`: purges agents that went off (D4, also when that
    /// stops the indexer or none runs), pushes the new configuration, and starts or stops it
    /// when Agent History was turned on or off.
    private func applyState(_ loaded: AgentHistoryLoadedState) {
        let next = loaded.state
        let previous = persistedState
        persistedState = next
        mirror.enabledAgents = next.enabledAgents
        stateStore = loaded.store
        let removed = previous.map { $0.enabledAgents.subtracting(next.enabledAgents) } ?? []
        guard let indexer else {
            // A new indexer purges every agent that is off when it starts.
            if !startIfAllowed() {
                purgeWithoutIndexer(removed)
                publishOffStatus()
            }
            return
        }
        // Queued before any stop, so the purge runs before the teardown.
        for agent in AgentHistoryAgent.allCases where removed.contains(agent) {
            indexer.purgeSource(agent: agent)
        }
        guard Self.allowsIndexing(next) else {
            stopOffMain(indexer)
            return
        }
        indexer.update(configuration: configuration(for: next))
    }

    /// On the control queue, behind any stop still tearing down.
    private func purgeWithoutIndexer(_ agents: Set<AgentHistoryAgent>) {
        guard !agents.isEmpty, let storage = storageInstance else {
            return
        }
        controlQueue.async {
            AgentHistoryIndexer.purgeSourcesWithoutIndexer(agents, storage: storage)
        }
    }

    private static func allowsIndexing(_ state: AgentHistoryState) -> Bool {
        state.enabled && state.consentedAt != nil && !state.enabledAgents.isEmpty
    }

    private func configuration(for state: AgentHistoryState) -> AgentHistoryIndexerConfiguration {
        AgentHistoryIndexerConfiguration(enabledAgents: state.enabledAgents, excludedFolders: configSection.excludedFolders)
    }

    private func applyConfig(_ section: AppConfig.AgentHistory, isReadable: Bool) {
        mirror.setConfig(section)
        let becameReadable = isReadable && !isConfigReadable
        isConfigReadable = isReadable
        guard section != configSection || becameReadable else {
            return
        }
        configSection = section
        if let indexer, let persistedState {
            indexer.update(configuration: configuration(for: persistedState))
        } else if becameReadable, persistedState != nil, !startIfAllowed() {
            publishOffStatus()
        }
        // Behind `mirror.setConfig`, so an open palette that re-runs its query on this status
        // already searches with the new exclusions.
        if status.excludedFolders != section.excludedFolders {
            setStatus(status)
        }
    }

    // MARK: - Indexer

    @discardableResult
    private func startIfAllowed() -> Bool {
        guard indexer == nil else {
            return true
        }
        guard isConfigReadable, let state = persistedState, Self.allowsIndexing(state),
              let stateStore, let storage = storageInstance else {
            return false
        }
        indexerGeneration &+= 1
        let generation = indexerGeneration
        let callbacks = AgentHistoryIndexerCallbacks(
            onStatusChange: { [weak self] status in
                self?.receive(status, generation: generation)
            },
            onSnapshotChange: { [weak self] snapshot in
                self?.receive(snapshot, generation: generation)
            }
        )
        storage.readers.reopen()
        let indexer = makeIndexer(storage, stateStore, configuration(for: state), callbacks)
        self.indexer = indexer
        mirror.storage = storage
        // Behind any previous indexer's teardown on the control queue, so two writers never
        // overlap. The indexer purges agents that are off when it starts (D4).
        controlQueue.async {
            indexer.start()
        }
        AgentHistoryLog.indexer.info("Agent History controller started the indexer")
        return true
    }

    /// Forgets the current indexer (its late publishes are ignored) and hides the index. Revokes
    /// the reader pool, so an engine handed out earlier reads nothing until the next start.
    private func detachIndexer() -> AgentHistoryIndexer? {
        let detached = indexer
        indexer = nil
        indexerGeneration &+= 1
        mirror.storage = nil
        storageInstance?.readers.revoke()
        if !metadataSnapshot.sessions.isEmpty || metadataSnapshot.generation != 0 {
            setSnapshot(.empty)
        }
        return detached
    }

    /// The control queue waits for the whole teardown, so a start queued after it never runs
    /// next to this indexer's writer.
    private func stopOffMain(_ indexer: AgentHistoryIndexer) {
        _ = detachIndexer()
        let storage = storageInstance
        controlQueue.async {
            indexer.stopAndWait()
            storage?.readers.closeAll()
        }
        publishOffStatus()
    }

    /// Waits until everything queued on the control queue (stops, starts, purges) has run.
    func drainControlQueueForTesting() {
        controlQueue.sync {}
    }

    private func receive(_ next: AgentHistoryStatus, generation: UInt64) {
        guard generation == indexerGeneration, indexer != nil else {
            return
        }
        setStatus(next)
    }

    private func receive(_ next: AgentHistoryMetadataSnapshot, generation: UInt64) {
        guard generation == indexerGeneration, indexer != nil else {
            return
        }
        setSnapshot(next)
    }

    // MARK: - Publishing

    /// The status while no indexer runs: the persisted state, plus the index on disk (kept when
    /// History is off) as last known until `recountOffStatus` has looked again.
    private func publishOffStatus() {
        publishOffStatus(state: persistedState, disk: nil)
        recountOffStatus()
    }

    private func publishOffStatus(state: AgentHistoryState?, disk: AgentHistoryOffDiskFacts?) {
        var next = AgentHistoryStatus.off
        if let state {
            next.isStateLoaded = true
            next.isEnabled = state.enabled
            next.hasConsented = state.consentedAt != nil
            next.enabledAgents = state.enabledAgents
            if !isConfigReadable, Self.allowsIndexing(state) {
                next.state = .paused(.configUnreadable, nil)
            }
        }
        next.excludedFolders = configSection.excludedFolders
        next.indexExists = disk?.indexExists ?? status.indexExists
        next.indexSizeBytes = disk?.indexSizeBytes ?? status.indexSizeBytes
        next.removedSessionCount = disk?.removedSessionCount ?? status.removedSessionCount
        next.revision = status.revision
        guard next != status else {
            return
        }
        next.revision = status.revision &+ 1
        setStatus(next)
    }

    /// Looks at the index file, its size and the removed-sessions list on the control queue
    /// (behind any stop or delete still running) and publishes them while no indexer runs, so
    /// Settings can delete an index that History being off kept. Before the launch read it also
    /// reads `state.json` for the status (it starts nothing), so Settings opened right after
    /// launch shows the real consent.
    func recountOffStatus() {
        guard let storage = storageInstance else {
            return
        }
        let generation = indexerGeneration
        let deliver = AgentHistoryMainDelivery<(AgentHistoryState, AgentHistoryOffDiskFacts)> { [weak self] state, disk in
            guard let self, self.indexer == nil, generation == self.indexerGeneration else {
                return
            }
            self.publishOffStatus(state: self.persistedState ?? state, disk: disk)
        }
        withStateStore { store in
            deliver.send((store.current, AgentHistoryOffDiskFacts(storage: storage)))
        }
    }

    private func setStatus(_ next: AgentHistoryStatus) {
        var next = next
        next.excludedFolders = configSection.excludedFolders
        // Indexer revisions restart at 1 per instance; the controller's never go back.
        if next.revision <= status.revision {
            next.revision = status.revision &+ 1
        }
        status = next
        mirror.status = next
        for handler in Array(statusObservers.values) {
            handler(next)
        }
    }

    private func setSnapshot(_ next: AgentHistoryMetadataSnapshot) {
        metadataSnapshot = next
        mirror.snapshot = next
        for handler in Array(snapshotObservers.values) {
            handler(next)
        }
    }
}

/// What `disable(deleteIndex:completion:)` did.
enum AgentHistoryDisableOutcome: Equatable, Sendable {
    /// Agent History is off; the index is kept.
    case turnedOff
    /// The directory and the consent are gone.
    case deleted
    /// Another Zentty instance runs Agent History on this index (owner or standby): nothing was
    /// deleted, consent is kept. Quitting it, or turning Agent History off there, lets it through.
    case refusedAnotherInstance
    /// The directory could not be deleted (or locked for it). Consent is reset only when the
    /// delete was attempted.
    case failed
}

/// The index on disk while no indexer runs. Read on the control queue.
private struct AgentHistoryOffDiskFacts: Sendable {
    let indexExists: Bool
    let indexSizeBytes: Int64
    /// nil when `removals.json` can't be read: the last known count stays.
    let removedSessionCount: Int?

    init(storage: AgentHistoryStorage) {
        indexExists = FileManager.default.fileExists(atPath: storage.paths.databaseURL.path)
        indexSizeBytes = indexExists ? storage.diskUsageBytes() : 0
        removedSessionCount = try? AgentHistoryRemovalLedger(fileURL: storage.paths.removalsURL).tombstones().count
    }
}

/// `state.json` as read or written on the control queue, with the store that holds it.
private struct AgentHistoryLoadedState: Sendable {
    let store: AgentHistoryStateStore
    let state: AgentHistoryState
}

/// Delivers one value to a main-actor closure from any thread, in `DispatchQueue.main` order.
private struct AgentHistoryMainDelivery<Value: Sendable>: @unchecked Sendable {
    private let body: @MainActor (Value) -> Void

    init(_ body: @escaping @MainActor (Value) -> Void) {
        self.body = body
    }

    func send(_ value: Value) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body(value)
            }
        }
    }
}

/// What other threads read from the controller, and the lazily created state store.
final class AgentHistoryControllerMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus = AgentHistoryStatus.off
    private var storedSnapshot = AgentHistoryMetadataSnapshot.empty
    private var storedStorage: AgentHistoryStorage?
    private var excludedFolders: [String] = []
    private var cachedExclusions: AgentHistoryExclusionMatcher?
    private var allowsAll = false
    private var storedEnabledAgents: Set<AgentHistoryAgent> = []
    /// Guarded separately: creating the store reads the file, which must not hold up `lock`.
    private let stateStoreLock = NSLock()
    private var store: AgentHistoryStateStore?

    var status: AgentHistoryStatus {
        get { withLock { storedStatus } }
        set { withLock { storedStatus = newValue } }
    }

    var snapshot: AgentHistoryMetadataSnapshot {
        get { withLock { storedSnapshot } }
        set { withLock { storedSnapshot = newValue } }
    }

    var storage: AgentHistoryStorage? {
        get { withLock { storedStorage } }
        set { withLock { storedStorage = newValue } }
    }

    var allowsAgentsAllProjects: Bool {
        withLock { allowsAll }
    }

    var enabledAgents: Set<AgentHistoryAgent> {
        get { withLock { storedEnabledAgents } }
        set { withLock { storedEnabledAgents = newValue } }
    }

    var exclusions: AgentHistoryExclusionMatcher {
        let folders = withLock { () -> [String]? in
            cachedExclusions == nil ? excludedFolders : nil
        }
        guard let folders else {
            return withLock { cachedExclusions } ?? AgentHistoryExclusionMatcher(folders: [])
        }
        // Canonicalizing may resolve symlinks (disk), so it runs outside the lock.
        let matcher = AgentHistoryExclusionMatcher(folders: folders)
        withLock {
            if excludedFolders == folders {
                cachedExclusions = matcher
            }
        }
        return matcher
    }

    func setConfig(_ section: AppConfig.AgentHistory) {
        withLock {
            allowsAll = section.allowAgentsAllProjects
            if excludedFolders != section.excludedFolders {
                excludedFolders = section.excludedFolders
                cachedExclusions = nil
            }
        }
    }

    func stateStore(fileURL: URL) -> AgentHistoryStateStore {
        stateStoreLock.lock()
        defer { stateStoreLock.unlock() }
        if let store {
            return store
        }
        let created = AgentHistoryStateStore(fileURL: fileURL)
        store = created
        return created
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
