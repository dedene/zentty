import Darwin
import Foundation
import os

private let subagentRegistryLogger = Logger(subsystem: "be.zenjoy.zentty", category: "AgentSubagentRegistry")

/// File-backed registry of live subagents per pane, shared by the Claude,
/// Codex, and Grok hook adapters.
///
/// Hook invocations are short-lived processes, so the set of running
/// subagents has to survive between `SubagentStart` and `SubagentStop`. The
/// registry is keyed by pane (tool + worklane + pane) rather than by session
/// id because Codex sub-threads report their own thread ids, and only the
/// pane is stable across parent and child hooks.
///
/// The parent's turn ending is *not* a retirement signal: Claude Code runs
/// Agent tool calls asynchronously, so the parent routinely goes idle with
/// subagents still working. Entries leave the registry on `SubagentStop`, or
/// when their transcript on disk stops being written (liveness pruning), or
/// after `staleEntryWindow` as a last resort.
final class AgentSubagentRegistryStore {
    struct Key: Equatable {
        let tool: String
        let worklaneID: WorklaneID
        let paneID: PaneID

        var rawValue: String {
            "\(tool)|\(worklaneID.rawValue)|\(paneID.rawValue)"
        }

        /// Tools whose parent turn does not outlive its children, so a child
        /// transcript that stops being written is the only finish signal
        /// short of its stop hook. Codex is not listed: its parent turn ends
        /// after every sub-thread and `clear` retires the set, while a
        /// sub-thread parked between turns keeps a quiet rollout file.
        static let toolsWithObservableTranscriptLiveness: Set<String> = ["claude", "grok"]

        /// Whether a quiet transcript retires this pane's entries.
        var transcriptIsLivenessSignal: Bool {
            Self.toolsWithObservableTranscriptLiveness.contains(tool)
        }
    }

    /// Entries older than this are dropped on read: a `SubagentStop` that never
    /// arrived should not pin a badge to the sidebar forever. Only reached by
    /// entries whose transcript cannot be observed (or whose tool opts out of
    /// transcript liveness, see `Key.transcriptIsLivenessSignal`).
    static let staleEntryWindow: TimeInterval = 6 * 60 * 60

    /// An entry whose transcript exists but has not been written for this long
    /// is treated as finished. A child parked in a long tool call can trip
    /// this; its next hook re-registers it. Only applied to tools whose
    /// transcript is a liveness signal (`Key.transcriptIsLivenessSignal`).
    static let transcriptQuietWindow: TimeInterval = 15 * 60

    /// How many liveness-pruned ids a pane remembers, so a late stop hook
    /// from a retired child is recognised instead of retiring a sibling.
    static let prunedIDMemory = 32

    /// Where the registry lives; exposed so tests can check the resolution.
    let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    /// Last write time of a subagent transcript, `nil` when it does not exist
    /// (or cannot be read), in which case the entry is kept.
    private let transcriptModificationDate: (String) -> Date?

    init(
        stateURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        transcriptModificationDate: ((String) -> Date?)? = nil
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.now = now
        self.transcriptModificationDate = transcriptModificationDate ?? { path in
            (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        self.encoder.outputFormatting = [.sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        self.init(environment: processInfo.environment, fileManager: fileManager)
    }

    convenience init(
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        if let overridePath = environment["ZENTTY_SUBAGENT_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        // Under XCTest (same detection as main.swift) the adapters' default
        // store must never touch the real registry: tests that call an adapter
        // without injecting a store would otherwise write fixture pane keys
        // into ~/Library/Application Support. One file per test process keeps
        // parallel runners apart.
        if environment["XCTestConfigurationFilePath"] != nil {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.init(stateURL: directory.appendingPathComponent("agent-subagent-sessions.json", isDirectory: false), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent(ZenttyBuildFlavor.current.libraryFolderName, isDirectory: true)
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

    /// Record a running subagent. Re-running for a known id merges the new
    /// facts (model, transcript) and keeps the original start time; running it
    /// for an id that liveness pruning already retired simply re-registers it.
    @discardableResult
    func start(key: Key, entry subagent: PaneAgentSubagentEntry) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            prune(&entry, key: key)
            let existing = entry.subagentsByID[subagent.id]
            entry.forgetPruned(subagent.id)
            entry.subagentsByID[subagent.id] = SubagentRecord(
                entry: Self.merged(existing?.entry, with: subagent),
                startedAt: existing?.startedAt ?? now().timeIntervalSince1970
            )
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            subagentRegistryLogger.info(
                "subagent \(existing == nil ? "start" : "update", privacy: .public) key=\(key.rawValue, privacy: .public) id=\(subagent.id, privacy: .public) type=\(subagent.agentType ?? "-", privacy: .public) count=\(entry.subagentsByID.count, privacy: .public)"
            )
            return entry.summary
        }
    }

    /// Retire a subagent. An explicit id that matches nothing is a no-op (the
    /// entry was already retired, or belongs to a child we never saw start).
    /// Without an id the longest-running subagent goes; `retireOldestWhenUnknown`
    /// extends that fallback to an id the adapter only guessed (a child's
    /// session id standing in for a missing subagent id), so a stop hook
    /// always retires something when the guess misses. A guess that names a
    /// child liveness pruning already retired is a no-op: that stop is late,
    /// not misattributed, and must not take a live sibling with it.
    @discardableResult
    func stop(key: Key, subagentID: String?, retireOldestWhenUnknown: Bool = false) throws -> PaneAgentSubagentSummary {
        try stop(key: key, subagentID: subagentID, retireOldestWhenUnknown: retireOldestWhenUnknown, requiresTrackedID: false) ?? .empty
    }

    /// Internal Claude forks emit a stop without a start. Distinguish them
    /// from registered workers atomically, including workers retired by the
    /// quiet-transcript heuristic while a long tool was still finishing.
    /// Recovery uses the existing bounded history of 32 pruned ids: older
    /// forgotten workers wait for real parent activity to signal a resume.
    /// Anonymous stops can only retire a currently registered worker.
    func stopIfTracked(key: Key, subagentID: String?) throws -> PaneAgentSubagentSummary? {
        try stop(key: key, subagentID: subagentID, retireOldestWhenUnknown: false, requiresTrackedID: true)
    }

    private func stop(
        key: Key,
        subagentID: String?,
        retireOldestWhenUnknown: Bool,
        requiresTrackedID: Bool
    ) throws -> PaneAgentSubagentSummary? {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            let subagentID = normalizedOptional(subagentID)
            if requiresTrackedID, let subagentID,
               entry.subagentsByID[subagentID] == nil, !entry.wasPruned(subagentID) {
                return nil
            }
            prune(&entry, key: key)
            var removedID: String?
            if let subagentID, entry.subagentsByID.removeValue(forKey: subagentID) != nil {
                removedID = subagentID
            } else if subagentID == nil || (retireOldestWhenUnknown && !entry.wasPruned(subagentID)),
                      let oldest = entry.subagentsByID.min(by: { $0.value.startedAt < $1.value.startedAt }) {
                // No (trustworthy) id on the stop hook: retire the
                // longest-running subagent.
                entry.subagentsByID.removeValue(forKey: oldest.key)
                removedID = oldest.key
            }
            if requiresTrackedID, subagentID == nil, removedID == nil {
                state.panes[key.rawValue] = entry
                return nil
            }
            if requiresTrackedID, let subagentID {
                // A remembered worker can wake its parent once; a repeated
                // stop after the parent finishes must not wake it again.
                entry.forgetPruned(subagentID)
            }
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            subagentRegistryLogger.info(
                "subagent stop key=\(key.rawValue, privacy: .public) id=\(subagentID ?? "-", privacy: .public) removed=\(removedID ?? "none", privacy: .public) count=\(entry.subagentsByID.count, privacy: .public)"
            )
            return entry.summary
        }
    }

    /// Current snapshot, or `nil` when nothing was ever recorded for the pane
    /// so callers can leave the payload field untouched.
    func summary(key: Key) throws -> PaneAgentSubagentSummary? {
        try prunedSummary(key: key)?.summary
    }

    /// Like `summary(key:)`, also reporting whether this read retired anything,
    /// so callers can tell a fresh "now empty" from a long-standing one.
    func prunedSummary(key: Key) throws -> (summary: PaneAgentSubagentSummary, retired: Bool)? {
        try withLockedState { state in
            guard var entry = state.panes[key.rawValue] else { return nil }
            let retired = prune(&entry, key: key)
            if retired {
                state.panes[key.rawValue] = entry
            }
            return (entry.summary, retired)
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

    /// Drop every subagent for the pane and return the explicit empty summary
    /// to broadcast. Only for tools whose parent turn provably outlives every
    /// subagent; Claude's does not (see the type comment).
    @discardableResult
    func clear(key: Key) throws -> PaneAgentSubagentSummary {
        try withLockedState { state in
            var entry = state.panes[key.rawValue] ?? PaneEntry()
            let dropped = entry.subagentsByID.count
            entry.subagentsByID.removeAll()
            entry.prunedIDs = nil
            entry.updatedAt = now().timeIntervalSince1970
            state.panes[key.rawValue] = entry
            subagentRegistryLogger.info(
                "subagent clear key=\(key.rawValue, privacy: .public) dropped=\(dropped, privacy: .public)"
            )
            return .empty
        }
    }

    /// Forget the pane entirely (session ended).
    func remove(key: Key) throws {
        try withLockedState { state in
            let dropped = state.panes[key.rawValue]?.subagentsByID.count ?? 0
            state.panes.removeValue(forKey: key.rawValue)
            subagentRegistryLogger.info(
                "subagent remove key=\(key.rawValue, privacy: .public) dropped=\(dropped, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    /// Retire entries that are provably finished (transcript exists and went
    /// quiet, for tools where that means anything) or hopelessly old. Returns
    /// whether anything changed.
    @discardableResult
    private func prune(_ entry: inout PaneEntry, key: Key) -> Bool {
        let current = now().timeIntervalSince1970
        let staleCutoff = current - Self.staleEntryWindow
        let quietCutoff = current - Self.transcriptQuietWindow
        var retired: [(id: String, reason: String)] = []
        for (id, record) in entry.subagentsByID {
            if key.transcriptIsLivenessSignal,
               let path = record.entry.transcriptPath, let modifiedAt = transcriptModificationDate(path) {
                // Observable transcript: it being written is the liveness signal.
                if modifiedAt.timeIntervalSince1970 < quietCutoff, record.startedAt < quietCutoff {
                    retired.append((id, "quiet-transcript"))
                }
            } else if record.startedAt < staleCutoff {
                retired.append((id, "stale"))
            }
        }
        guard !retired.isEmpty else { return false }
        for item in retired {
            entry.subagentsByID.removeValue(forKey: item.id)
            entry.rememberPruned(item.id)
            let remaining = entry.subagentsByID.count
            subagentRegistryLogger.info(
                "subagent retire key=\(key.rawValue, privacy: .public) id=\(item.id, privacy: .public) reason=\(item.reason, privacy: .public) count=\(remaining, privacy: .public)"
            )
        }
        return true
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
        /// Ids liveness pruning retired, most recent last. Optional so state
        /// files written before it existed still decode.
        var prunedIDs: [String]?

        var summary: PaneAgentSubagentSummary {
            PaneAgentSubagentSummary(entries: subagentsByID.values.map(\.entry))
        }

        func wasPruned(_ id: String?) -> Bool {
            guard let id else { return false }
            return prunedIDs?.contains(id) ?? false
        }

        mutating func rememberPruned(_ id: String) {
            var ids = prunedIDs ?? []
            ids.removeAll { $0 == id }
            ids.append(id)
            if ids.count > AgentSubagentRegistryStore.prunedIDMemory {
                ids.removeFirst(ids.count - AgentSubagentRegistryStore.prunedIDMemory)
            }
            prunedIDs = ids
        }

        mutating func forgetPruned(_ id: String) {
            prunedIDs?.removeAll { $0 == id }
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
            // The path recorded at start is the one the hook spelled out; a
            // later hook may only carry a derived guess, so the first wins.
            transcriptPath: existing?.transcriptPath ?? update.transcriptPath
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
