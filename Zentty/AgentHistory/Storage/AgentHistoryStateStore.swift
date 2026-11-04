import Foundation

/// Per-Mac Agent History consent and source choices, persisted as `AgentHistory/state.json`.
/// The index and its consent belong to this Mac, so this never lives in the synced config.
struct AgentHistoryState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = AgentHistoryState.currentVersion
    var enabled: Bool = false
    var consentedAt: Date? = nil
    /// Keyed by `AgentHistoryAgent.rawValue`. Unknown keys (agents from a newer build) are kept.
    var sources: [String: Bool] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case enabled
        case consentedAt
        case sources
    }

    /// A source the user never touched is on.
    func isSourceEnabled(_ agent: AgentHistoryAgent) -> Bool {
        sources[agent.rawValue] ?? true
    }

    mutating func setSource(_ agent: AgentHistoryAgent, enabled: Bool) {
        sources[agent.rawValue] = enabled
    }

    var enabledAgents: Set<AgentHistoryAgent> {
        Set(AgentHistoryAgent.allCases.filter { isSourceEnabled($0) })
    }

    /// True when going from `previous` to this state only takes access away: History stays or
    /// goes off, no agent comes on and no consent is added.
    func onlyRevokesAccess(from previous: AgentHistoryState) -> Bool {
        (!enabled || previous.enabled)
            && enabledAgents.isSubset(of: previous.enabledAgents)
            && (consentedAt == nil || consentedAt == previous.consentedAt)
    }
}

extension AgentHistoryState {
    // In an extension so the memberwise and default initializers stay synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? AgentHistoryState.currentVersion
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        consentedAt = try container.decodeIfPresent(Date.self, forKey: .consentedAt)
        sources = try container.decodeIfPresent([String: Bool].self, forKey: .sources) ?? [:]
    }
}

/// Loads and writes `state.json`. A missing file reads as the disabled default; an unreadable or
/// corrupt one is logged, reads as the default at start and is replaced by the next `update`.
/// Top-level keys this build doesn't know are preserved across writes so an older build never
/// strips a newer build's fields.
///
/// Zentty instances of one flavor share the file. `update` is a read-modify-write under an
/// exclusive `flock` on `AgentHistory.state.lock` (beside the directory, like the index locks, so
/// Delete Index never unlinks it): it re-reads the file and applies only the caller's change,
/// so a stale copy never undoes what another instance saved. `reload` picks up those changes.
///
/// `state`, `extraFields` and `unsavedRevocation` are confined to `queue` (serial,
/// `be.zenjoy.zentty.agent-history.state`); `observers` is guarded by `observerLock`.
/// Observers are always called on the main queue, in update order.
/// Never call `current`, `update` or `reload` from inside an `update` closure (the queue is not
/// reentrant).
final class AgentHistoryStateStore: @unchecked Sendable {
    typealias Observer = @MainActor (AgentHistoryState) -> Void

    static let lockFileSuffix = ".state.lock"
    /// How long `update` waits for another instance's write before going ahead unlocked.
    static let lockTimeout: TimeInterval = 2

    let fileURL: URL
    let lockURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.agent-history.state", qos: .utility)
    private var state: AgentHistoryState
    private var extraFields: [String: Any]
    /// Access taken away in memory that couldn't be saved yet; laid over every re-read until a
    /// write succeeds, so a failed save never lets the file turn it back on.
    private var unsavedRevocation = AgentHistoryRevocation()
    private let observerLock = NSLock()
    private var observers: [UUID: Observer] = [:]

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.lockURL = Self.lockURL(forStateFileAt: fileURL)
        self.fileManager = fileManager
        switch Self.load(from: fileURL, fileManager: fileManager) {
        case .loaded(let state, let extraFields):
            self.state = state
            self.extraFields = extraFields
        case .missing, .unreadable:
            self.state = AgentHistoryState()
            self.extraFields = [:]
        }
    }

    /// `AgentHistory.state.lock` beside the directory that holds `state.json`.
    static func lockURL(forStateFileAt fileURL: URL) -> URL {
        let directoryURL = fileURL.deletingLastPathComponent()
        return directoryURL.deletingLastPathComponent()
            .appendingPathComponent(directoryURL.lastPathComponent + lockFileSuffix, isDirectory: false)
    }

    /// The state as last read or changed here. Call `reload` to see other instances' changes.
    var current: AgentHistoryState {
        queue.sync { state }
    }

    /// A write that failed. `keptInMemory` is true when the change took effect anyway.
    struct UnsavedChange: Error {
        let keptInMemory: Bool
        let underlying: any Error
    }

    /// Re-reads the file under the lock, applies `mutate` to what it holds, writes it atomically
    /// with mode 0600, then notifies observers on main. A write failure throws `UnsavedChange`.
    /// A change that only takes access away (History off, an agent off) still takes effect in
    /// memory, so turning things off never depends on the disk; the next successful write saves
    /// it. Any other change is dropped, so nothing turns on that a restart would undo.
    func update(_ mutate: (inout AgentHistoryState) -> Void) throws {
        try queue.sync {
            let lock = acquireFileLock()
            defer { lock?.unlock() }
            let (base, baseExtras) = freshStateOnQueue()
            var next = base
            mutate(&next)
            do {
                try write(next, extraFields: baseExtras)
            } catch {
                let keepsChange = next.onlyRevokesAccess(from: base)
                if keepsChange {
                    unsavedRevocation.record(from: base, to: next)
                }
                adoptOnQueue(keepsChange ? next : base, extraFields: baseExtras)
                throw UnsavedChange(keptInMemory: keepsChange, underlying: error)
            }
            unsavedRevocation = AgentHistoryRevocation()
            state = next
            extraFields = baseExtras
            notifyObservers(next)
        }
    }

    /// Re-reads the file, so changes another instance saved show here, and notifies observers
    /// when the state changed. A missing file reads as the disabled default (another instance
    /// deleted the index); an unreadable one keeps the last known state. Returns the state.
    @discardableResult
    func reload() -> AgentHistoryState {
        queue.sync {
            let (fresh, extras) = freshStateOnQueue()
            adoptOnQueue(fresh, extraFields: extras)
            return state
        }
    }

    /// Called after the AgentHistory directory was deleted (D8): back to the disabled default,
    /// consent included. Removes a leftover `state.json` but never recreates the directory.
    func resetAfterDelete() {
        queue.sync {
            state = AgentHistoryState()
            extraFields = [:]
            unsavedRevocation = AgentHistoryRevocation()
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    AgentHistoryLog.indexer.error("Agent History couldn't remove its state file")
                }
            }
            notifyObservers(state)
        }
    }

    @discardableResult
    func addObserver(_ handler: @escaping Observer) -> UUID {
        let id = UUID()
        observerLock.lock()
        observers[id] = handler
        observerLock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        observerLock.lock()
        observers.removeValue(forKey: id)
        observerLock.unlock()
    }

    // MARK: - Private

    /// The file as it is now, with this instance's unsaved revocations laid over it. An
    /// unreadable file falls back to the last known state (never to "everything on").
    private func freshStateOnQueue() -> (AgentHistoryState, [String: Any]) {
        var fresh: AgentHistoryState
        let extras: [String: Any]
        switch Self.load(from: fileURL, fileManager: fileManager) {
        case .loaded(let loaded, let loadedExtras):
            fresh = loaded
            extras = loadedExtras
        case .missing:
            fresh = AgentHistoryState()
            extras = [:]
        case .unreadable:
            fresh = state
            extras = extraFields
        }
        unsavedRevocation.apply(to: &fresh)
        return (fresh, extras)
    }

    private func adoptOnQueue(_ next: AgentHistoryState, extraFields nextExtras: [String: Any]) {
        extraFields = nextExtras
        guard next != state else {
            return
        }
        state = next
        notifyObservers(next)
    }

    /// nil when the lock can't be had: the write goes ahead unlocked, so turning things off
    /// never waits on another instance or a lock file it can't open.
    private func acquireFileLock() -> AgentHistorySetupLock? {
        do {
            return try AgentHistorySetupLock(url: lockURL, timeout: Self.lockTimeout,
                                             busyMessage: "another Zentty is saving Agent History state")
        } catch {
            AgentHistoryLog.indexer.error("Agent History couldn't lock its state file; saving without the lock")
            return nil
        }
    }

    /// Runs on `queue`; `main.async` keeps notifications in update order.
    private func notifyObservers(_ state: AgentHistoryState) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.deliver(state)
            }
        }
    }

    @MainActor
    private func deliver(_ state: AgentHistoryState) {
        observerLock.lock()
        let handlers = Array(observers.values)
        observerLock.unlock()
        handlers.forEach { $0(state) }
    }

    private func write(_ state: AgentHistoryState, extraFields: [String: Any]) throws {
        try AgentHistoryPrivateFile.write(Self.encode(state, extraFields: extraFields), to: fileURL,
                                          fileManager: fileManager)
    }

    private static let knownKeys = Set(AgentHistoryState.CodingKeys.allCases.map(\.rawValue))

    static func encode(_ state: AgentHistoryState, extraFields: [String: Any]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(state)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        for (key, value) in extraFields where !knownKeys.contains(key) {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private enum LoadResult {
        case loaded(AgentHistoryState, extraFields: [String: Any])
        case missing
        case unreadable
    }

    private static func load(from url: URL, fileManager: FileManager) -> LoadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(decodeDate)
            let state = try decoder.decode(AgentHistoryState.self, from: data)
            return .loaded(state, extraFields: object.filter { !knownKeys.contains($0.key) })
        } catch {
            AgentHistoryLog.indexer.error("Agent History state file is unreadable")
            return .unreadable
        }
    }

    /// ISO 8601, with or without fractional seconds.
    private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date")
    }
}

/// Access one instance took away without saving it: History off, agents off, consent removed.
private struct AgentHistoryRevocation {
    var historyOff = false
    var consentRemoved = false
    var agentsOff: Set<String> = []

    mutating func record(from previous: AgentHistoryState, to next: AgentHistoryState) {
        historyOff = historyOff || (previous.enabled && !next.enabled)
        consentRemoved = consentRemoved || (previous.consentedAt != nil && next.consentedAt == nil)
        agentsOff.formUnion(previous.enabledAgents.subtracting(next.enabledAgents).map(\.rawValue))
    }

    func apply(to state: inout AgentHistoryState) {
        if historyOff {
            state.enabled = false
        }
        if consentRemoved {
            state.consentedAt = nil
        }
        for key in agentsOff {
            state.sources[key] = false
        }
    }
}
