import Darwin
import Foundation

/// File-backed registry of live subagents per pane, shared by the Claude,
/// Codex, and Grok hook adapters.
///
/// Hook invocations are short-lived processes, so the set of running
/// subagents has to survive between `SubagentStart` and `SubagentStop`. The
/// registry is keyed by pane (tool + worklane + pane) rather than by session
/// id because Codex sub-threads report their own thread ids, and only the
/// pane is stable across parent and child hooks.
final class AgentSubagentRegistryStore {
    struct Key: Equatable {
        let tool: String
        let worklaneID: WorklaneID
        let paneID: PaneID

        var rawValue: String {
            "\(tool)|\(worklaneID.rawValue)|\(paneID.rawValue)"
        }
    }

    /// Entries older than this are dropped on read: a `SubagentStop` that never
    /// arrived should not pin a badge to the sidebar forever.
    static let staleEntryWindow: TimeInterval = 6 * 60 * 60

    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date

    init(
        stateURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.now = now
        self.encoder.outputFormatting = [.sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        let env = processInfo.environment
        if let overridePath = env["ZENTTY_SUBAGENT_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent("Zentty", isDirectory: true)
                .appendingPathComponent("agent-subagent-sessions.json", isDirectory: false)
        } else {
            stateURL = fileManager.temporaryDirectory.appendingPathComponent("zentty-agent-subagent-sessions.json")
        }
        self.init(stateURL: stateURL, fileManager: fileManager)
    }

    // MARK: - Root session

    /// Remember the parent session id for a pane so subagent payloads can be
    /// attributed to it even when the hook carries a child thread id.
    func recordRootSession(key: Key, sessionID: String?) throws {
        guard let sessionID = normalizedOptional(sessionID) else { return }
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            entry.rootSessionID = sessionID
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
        }
    }

    func rootSessionID(key: Key) throws -> String? {
        try withLockedState { state in
            state.panes[key.rawValue]?.rootSessionID
        }
    }

    // MARK: - Subagents

    @discardableResult
    func start(key: Key, entry subagent: PaneAgentSubagentEntry) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            entry.prune(before: now().timeIntervalSince1970 - Self.staleEntryWindow)
            let existing = entry.subagentsByID[subagent.id]
            entry.subagentsByID[subagent.id] = SubagentRecord(
                entry: Self.merged(existing?.entry, with: subagent),
                startedAt: existing?.startedAt ?? now().timeIntervalSince1970
            )
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            return entry.summary
        }
    }

    @discardableResult
    func stop(key: Key, subagentID: String?) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            entry.prune(before: now().timeIntervalSince1970 - Self.staleEntryWindow)
            if let subagentID = normalizedOptional(subagentID) {
                entry.subagentsByID.removeValue(forKey: subagentID)
            } else if let oldest = entry.subagentsByID.min(by: { $0.value.startedAt < $1.value.startedAt }) {
                // No id on the stop hook: retire the longest-running subagent.
                entry.subagentsByID.removeValue(forKey: oldest.key)
            }
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            return entry.summary
        }
    }

    /// Current snapshot, or `nil` when nothing was ever recorded for the pane
    /// so callers can leave the payload field untouched.
    func summary(key: Key) throws -> PaneAgentSubagentSummary? {
        try withLockedState { state in
            guard var entry = state.panes[key.rawValue] else { return nil }
            let pruned = entry.prune(before: now().timeIntervalSince1970 - Self.staleEntryWindow)
            if pruned {
                state.panes[key.rawValue] = entry
            }
            return entry.summary
        }
    }

    /// Fill in models (and nicknames) that were unknown at start time. The
    /// resolver runs only for entries still missing a model, so this stays
    /// cheap to call from every hook.
    @discardableResult
    func refreshMissingModels(
        key: Key,
        resolver: (PaneAgentSubagentEntry) -> PaneAgentSubagentEntry?
    ) throws -> PaneAgentSubagentSummary? {
        try withLockedState { state in
            guard var entry = state.panes[key.rawValue], !entry.subagentsByID.isEmpty else { return nil }
            var changed = false
            for (id, record) in entry.subagentsByID where record.entry.model == nil {
                guard let resolved = resolver(record.entry), resolved.model != nil else { continue }
                entry.subagentsByID[id] = SubagentRecord(
                    entry: Self.merged(record.entry, with: resolved),
                    startedAt: record.startedAt
                )
                changed = true
            }
            if changed {
                entry.updatedAt = now().timeIntervalSince1970
                state.panes[key.rawValue] = entry
            }
            return entry.summary
        }
    }

    /// Drop every subagent for the pane (parent turn ended) and return the
    /// explicit empty summary to broadcast.
    @discardableResult
    func clear(key: Key) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            entry.subagentsByID.removeAll()
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            return .empty
        }
    }

    /// Forget the pane entirely (session ended).
    func remove(key: Key) throws {
        try withLockedState { state in
            state.panes.removeValue(forKey: key.rawValue)
        }
    }

    // MARK: - Internals

    private struct SubagentRecord: Codable {
        var entry: PaneAgentSubagentEntry
        var startedAt: TimeInterval
    }

    private struct PaneEntry: Codable {
        var rootSessionID: String?
        var subagentsByID: [String: SubagentRecord] = [:]
        var updatedAt: TimeInterval = 0

        var summary: PaneAgentSubagentSummary {
            PaneAgentSubagentSummary(entries: subagentsByID.values.map(\.entry))
        }

        @discardableResult
        mutating func prune(before cutoff: TimeInterval) -> Bool {
            let stale = subagentsByID.filter { $0.value.startedAt < cutoff }.map(\.key)
            guard !stale.isEmpty else { return false }
            stale.forEach { subagentsByID.removeValue(forKey: $0) }
            return true
        }
    }

    private struct StoreFile: Codable {
        var version: Int = 1
        var panes: [String: PaneEntry] = [:]
    }

    private static func merged(_ existing: PaneAgentSubagentEntry?, with update: PaneAgentSubagentEntry) -> PaneAgentSubagentEntry {
        PaneAgentSubagentEntry(
            id: update.id,
            agentType: update.agentType ?? existing?.agentType,
            model: update.model ?? existing?.model,
            nickname: update.nickname ?? existing?.nickname,
            transcriptPath: update.transcriptPath ?? existing?.transcriptPath
        )
    }

    private func withLockedState<T>(_ body: (inout StoreFile) throws -> T) throws -> T {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: lockURL.path) {
            fileManager.createFile(atPath: lockURL.path, contents: Data())
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        defer { flock(descriptor, LOCK_UN) }

        var state = loadState()
        let result = try body(&state)
        try saveState(state)
        return result
    }

    private func loadState() -> StoreFile {
        guard let data = try? Data(contentsOf: stateURL) else {
            return StoreFile()
        }
        return (try? decoder.decode(StoreFile.self, from: data)) ?? StoreFile()
    }

    private func saveState(_ state: StoreFile) throws {
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
