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

/// Loads and writes `state.json`. A missing or unreadable file reads as the disabled default;
/// a corrupt one is logged and replaced by the next `update`. Top-level keys this build doesn't
/// know are preserved across writes so an older build never strips a newer build's fields.
///
/// `state` and `extraFields` are confined to `queue` (serial,
/// `be.zenjoy.zentty.agent-history.state`); `observers` is guarded by `observerLock`.
/// Observers are always called on the main queue, in update order.
/// Never call `current` or `update` from inside an `update` closure (the queue is not reentrant).
final class AgentHistoryStateStore: @unchecked Sendable {
    typealias Observer = @MainActor (AgentHistoryState) -> Void

    let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.agent-history.state", qos: .utility)
    private var state: AgentHistoryState
    private var extraFields: [String: Any]
    private let observerLock = NSLock()
    private var observers: [UUID: Observer] = [:]

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let loaded = Self.load(from: fileURL, fileManager: fileManager)
        self.state = loaded.state
        self.extraFields = loaded.extraFields
    }

    var current: AgentHistoryState {
        queue.sync { state }
    }

    /// Applies `mutate`, writes the file atomically with mode 0600, then notifies observers on main.
    /// On a write failure the in-memory state is unchanged and the error is rethrown.
    func update(_ mutate: (inout AgentHistoryState) -> Void) throws {
        try queue.sync {
            var next = state
            mutate(&next)
            try write(next, extraFields: extraFields)
            state = next
            notifyObservers(next)
        }
    }

    /// Called after the AgentHistory directory was deleted (D8): back to the disabled default,
    /// consent included. Removes a leftover `state.json` but never recreates the directory.
    func resetAfterDelete() {
        queue.sync {
            state = AgentHistoryState()
            extraFields = [:]
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
        let data = try Self.encode(state, extraFields: extraFields)
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        // Private temp file first, so the content is never readable by others before the rename.
        let temporaryURL = directoryURL.appendingPathComponent(".state-\(UUID().uuidString).tmp", isDirectory: false)
        guard fileManager.createFile(atPath: temporaryURL.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
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

    private static func load(from url: URL, fileManager: FileManager) -> (state: AgentHistoryState, extraFields: [String: Any]) {
        guard fileManager.fileExists(atPath: url.path) else {
            return (AgentHistoryState(), [:])
        }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(decodeDate)
            let state = try decoder.decode(AgentHistoryState.self, from: data)
            return (state, object.filter { !knownKeys.contains($0.key) })
        } catch {
            AgentHistoryLog.indexer.error("Agent History state file is unreadable; using defaults")
            return (AgentHistoryState(), [:])
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
