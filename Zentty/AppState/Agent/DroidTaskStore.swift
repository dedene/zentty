import Darwin
import Foundation

/// Lightweight file-based task counter for Droid sessions.
///
/// Droid does not expose dedicated ``TaskCreated`` / ``TaskCompleted`` hooks
/// like Claude Code. Zentty tracks the exact visible to-do list when Droid
/// calls ``TodoWrite`` and falls back to sub-droid ``Task`` / ``SubagentStop``
/// events when no to-do list is available. This store persists per-session
/// counts across short-lived hook-bridge invocations.
final class DroidTaskStore {
    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        stateURL: URL,
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        let env = processInfo.environment
        if let overridePath = env["ZENTTY_DROID_TASK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent("Zentty", isDirectory: true)
                .appendingPathComponent("droid-task-sessions.json", isDirectory: false)
        } else {
            stateURL = fileManager.temporaryDirectory.appendingPathComponent("zentty-droid-task-sessions.json")
        }
        self.init(stateURL: stateURL, fileManager: fileManager)
    }

    /// Record a new sub-droid task being created. Returns the updated progress.
    func taskCreated(sessionID: String) throws -> PaneAgentTaskProgress? {
        try withLockedState { state in
            let key = normalized(sessionID)
            guard !key.isEmpty else { return nil }
            var entry = state.sessions[key] ?? SessionEntry()
            guard entry.source != .todo else {
                return entry.progress
            }
            entry.source = .subagent
            entry.totalCount += 1
            entry.updatedAt = Date().timeIntervalSince1970
            state.sessions[key] = entry
            return entry.progress
        }
    }

    /// Record a sub-droid task completing. Returns the updated progress.
    func taskCompleted(sessionID: String) throws -> PaneAgentTaskProgress? {
        try withLockedState { state in
            let key = normalized(sessionID)
            guard !key.isEmpty else { return nil }
            var entry = state.sessions[key] ?? SessionEntry()
            guard entry.source != .todo else {
                return entry.progress
            }
            entry.source = .subagent
            entry.doneCount = min(entry.doneCount + 1, entry.totalCount)
            entry.updatedAt = Date().timeIntervalSince1970
            state.sessions[key] = entry
            return entry.progress
        }
    }

    /// Replace progress with an exact to-do snapshot.
    func updateProgress(sessionID: String, doneCount: Int, totalCount: Int) throws -> PaneAgentTaskProgress? {
        try withLockedState { state in
            let key = normalized(sessionID)
            guard !key.isEmpty else { return nil }
            guard totalCount > 0 else {
                state.sessions.removeValue(forKey: key)
                // Optional taskProgress cannot distinguish "clear" from "unchanged";
                // a complete sentinel overwrites and hides stale visible counts.
                return PaneAgentTaskProgress(doneCount: 1, totalCount: 1)
            }

            var entry = state.sessions[key] ?? SessionEntry()
            entry.source = .todo
            entry.totalCount = totalCount
            entry.doneCount = min(max(doneCount, 0), totalCount)
            entry.updatedAt = Date().timeIntervalSince1970
            state.sessions[key] = entry
            return entry.progress
        }
    }

    /// Retrieve current task progress for a session.
    func taskProgress(sessionID: String?) throws -> PaneAgentTaskProgress? {
        guard let key = normalizedOptional(sessionID) else { return nil }
        return try withLockedState { state in
            state.sessions[key]?.progress
        }
    }

    /// Remove tracking data for a session.
    func clearSession(sessionID: String?) throws {
        guard let key = normalizedOptional(sessionID) else { return }
        try withLockedState { state in
            state.sessions.removeValue(forKey: key)
        }
    }

    // MARK: - Internals

    private struct StoreFile: Codable {
        var sessions: [String: SessionEntry] = [:]
    }

    struct SessionEntry: Codable {
        var source: ProgressSource = .subagent
        var totalCount: Int = 0
        var doneCount: Int = 0
        var updatedAt: TimeInterval = 0

        var progress: PaneAgentTaskProgress? {
            PaneAgentTaskProgress(doneCount: doneCount, totalCount: totalCount)
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = (try? container.decodeIfPresent(ProgressSource.self, forKey: .source)) ?? .subagent
            totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
            doneCount = try container.decodeIfPresent(Int.self, forKey: .doneCount) ?? 0
            updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        }
    }

    enum ProgressSource: String, Codable {
        case subagent
        case todo
    }

    @discardableResult
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

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
