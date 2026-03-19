import Darwin
import Foundation

struct ClaudeHookInput {
    let hookEventName: String
    let sessionID: String?
    let message: String?
    let cwd: String?
    let toolName: String?
    let toolInput: [String: Any]
}

struct ClaudeHookSessionRecord: Codable, Equatable {
    let sessionID: String
    var workspaceIDRawValue: String
    var paneIDRawValue: String
    var cwd: String?
    var pid: Int32?
    var lastHumanMessage: String?
    var updatedAt: TimeInterval

    var workspaceID: WorkspaceID {
        WorkspaceID(workspaceIDRawValue)
    }

    var paneID: PaneID {
        PaneID(paneIDRawValue)
    }
}

private struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

final class ClaudeHookSessionStore {
    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        stateURL: URL,
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        let env = processInfo.environment
        if let overridePath = env["ZENTTY_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent("Zentty", isDirectory: true)
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        } else {
            stateURL = fileManager.temporaryDirectory.appendingPathComponent("zentty-claude-hook-sessions.json")
        }
        self.init(stateURL: stateURL, fileManager: fileManager)
    }

    func lookup(sessionID: String) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state in
            state.sessions[normalized(sessionID)]
        }
    }

    func upsert(
        sessionID: String,
        workspaceID: WorkspaceID,
        paneID: PaneID,
        cwd: String?,
        pid: Int32?,
        lastHumanMessage: String? = nil
    ) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalizedSessionID] ?? ClaudeHookSessionRecord(
                sessionID: normalizedSessionID,
                workspaceIDRawValue: workspaceID.rawValue,
                paneIDRawValue: paneID.rawValue,
                cwd: nil,
                pid: nil,
                lastHumanMessage: nil,
                updatedAt: now
            )
            record.workspaceIDRawValue = workspaceID.rawValue
            record.paneIDRawValue = paneID.rawValue
            if let cwd = normalizedOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            if let lastHumanMessage = normalizedOptional(lastHumanMessage) {
                record.lastHumanMessage = lastHumanMessage
            }
            record.updatedAt = now
            state.sessions[normalizedSessionID] = record
        }
    }

    func clearLastHumanMessage(sessionID: String) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            record.lastHumanMessage = nil
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    @discardableResult
    func consume(
        sessionID: String?,
        fallbackWorkspaceID: WorkspaceID?,
        fallbackPaneID: PaneID?
    ) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state in
            if let sessionID = normalizedOptional(sessionID),
               let record = state.sessions.removeValue(forKey: sessionID) {
                return record
            }

            guard let fallbackWorkspaceID, let fallbackPaneID else {
                return nil
            }

            guard let key = state.sessions.first(where: { _, record in
                record.workspaceIDRawValue == fallbackWorkspaceID.rawValue
                    && record.paneIDRawValue == fallbackPaneID.rawValue
            })?.key else {
                return nil
            }

            return state.sessions.removeValue(forKey: key)
        }
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
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

    private func loadState() -> ClaudeHookSessionStoreFile {
        guard let data = try? Data(contentsOf: stateURL) else {
            return ClaudeHookSessionStoreFile()
        }
        return (try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data)) ?? ClaudeHookSessionStoreFile()
    }

    private func saveState(_ state: ClaudeHookSessionStoreFile) throws {
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

enum ClaudeHookBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "claude-hook" else {
            return nil
        }

        do {
            let input = try parseInput(readStandardInput())
            let sessionStore = ClaudeHookSessionStore()
            for payload in try makePayloads(from: input, environment: environment, sessionStore: sessionStore) {
                AgentStatusHelper.post(payload)
            }
            return EXIT_SUCCESS
        } catch {
            AgentStatusHelper.writeError(error)
            return EXIT_FAILURE
        }
    }

    static func parseInput(_ data: Data) throws -> ClaudeHookInput {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = firstString(in: json, keys: ["hook_event_name"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return ClaudeHookInput(
            hookEventName: hookEventName,
            sessionID: firstString(in: json, keys: ["session_id", "sessionId"]),
            message: firstString(in: json, keys: ["message", "body", "text", "prompt", "error", "description"]),
            cwd: extractCurrentWorkingDirectory(from: json),
            toolName: firstString(in: json, keys: ["tool_name", "toolName"]),
            toolInput: (json["tool_input"] as? [String: Any]) ?? [:]
        )
    }

    static func makePayloads(
        from input: ClaudeHookInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> [AgentStatusPayload] {
        switch input.hookEventName {
        case "SessionStart":
            let target = try currentTarget(from: environment)
            let pid = parseClaudePID(from: environment)
            if let sessionID = input.sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    cwd: input.cwd,
                    pid: pid
                )
            }
            guard let pid else {
                return []
            }
            return [
                pidPayload(
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    pid: pid,
                    event: .attach
                ),
            ]

        case "Notification":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let sessionRecord = try lookupRecord(for: input, sessionStore: sessionStore)
            let originalMessage = AgentInteractionClassifier.trimmed(input.message)
            let shouldUseSavedMessage = sessionRecord?.lastHumanMessage != nil
                && AgentInteractionClassifier.isGenericNeedsInputMessage(originalMessage)
            guard AgentInteractionClassifier.requiresHumanInput(message: originalMessage) || shouldUseSavedMessage else {
                return []
            }
            let message = AgentInteractionClassifier.preferredWaitingMessage(
                existing: sessionRecord?.lastHumanMessage,
                candidate: originalMessage
            ) ?? "Claude is waiting for your input"
            return [
                lifecyclePayload(
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: message
                ),
            ]

        case "PermissionRequest":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            let existing = try lookupRecord(for: input, sessionStore: sessionStore)
            let candidateMessage = AgentInteractionClassifier.trimmed(input.message) ?? "Claude needs your approval"
            let message = AgentInteractionClassifier.preferredWaitingMessage(
                existing: existing?.lastHumanMessage,
                candidate: candidateMessage
            ) ?? candidateMessage
            if let sessionID = input.sessionID {
                try sessionStore.upsert(
                    sessionID: sessionID,
                    workspaceID: existing?.workspaceID ?? target.workspaceID,
                    paneID: existing?.paneID ?? target.paneID,
                    cwd: input.cwd ?? existing?.cwd,
                    pid: existing?.pid,
                    lastHumanMessage: message
                )
            }
            return [
                lifecyclePayload(
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: message
                ),
            ]

        case "PreToolUse":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if input.toolName == "AskUserQuestion",
               let sessionID = input.sessionID,
               let question = describeAskUserQuestion(toolInput: input.toolInput) {
                let existing = try lookupRecord(for: input, sessionStore: sessionStore)
                let message = AgentInteractionClassifier.preferredWaitingMessage(
                    existing: existing?.lastHumanMessage,
                    candidate: question
                )
                try sessionStore.upsert(
                    sessionID: sessionID,
                    workspaceID: existing?.workspaceID ?? target.workspaceID,
                    paneID: existing?.paneID ?? target.paneID,
                    cwd: input.cwd ?? existing?.cwd,
                    pid: existing?.pid,
                    lastHumanMessage: message
                )
                return []
            }
            if let sessionID = input.sessionID {
                try sessionStore.clearLastHumanMessage(sessionID: sessionID)
            }
            return [
                lifecyclePayload(
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    state: .running,
                    text: nil
                ),
            ]

        case "UserPromptSubmit", "SubagentStart":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            if let sessionID = input.sessionID {
                try sessionStore.clearLastHumanMessage(sessionID: sessionID)
            }
            return [
                lifecyclePayload(
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    state: .running,
                    text: nil
                ),
            ]

        case "Stop", "SubagentStop":
            let target = try resolvedTarget(for: input, environment: environment, sessionStore: sessionStore)
            return [
                lifecyclePayload(
                    workspaceID: target.workspaceID,
                    paneID: target.paneID,
                    state: .completed,
                    text: nil
                ),
            ]

        case "SessionEnd":
            let current = currentTargetIfAvailable(from: environment)
            let record = try sessionStore.consume(
                sessionID: input.sessionID,
                fallbackWorkspaceID: current?.workspaceID,
                fallbackPaneID: current?.paneID
            )
            guard let record else {
                return []
            }
            return [
                AgentStatusPayload(
                    workspaceID: record.workspaceID,
                    paneID: record.paneID,
                    signalKind: .lifecycle,
                    state: nil,
                    origin: .explicitHook,
                    toolName: AgentTool.claudeCode.displayName,
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                pidPayload(
                    workspaceID: record.workspaceID,
                    paneID: record.paneID,
                    pid: nil,
                    event: .clear
                ),
            ]

        default:
            return []
        }
    }

    private static func currentTarget(from environment: [String: String]) throws -> (workspaceID: WorkspaceID, paneID: PaneID) {
        guard let workspaceID = environment["ZENTTY_WORKSPACE_ID"] else {
            throw AgentStatusPayloadError.missingWorkspaceID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }
        return (WorkspaceID(workspaceID), PaneID(paneID))
    }

    private static func currentTargetIfAvailable(from environment: [String: String]) -> (workspaceID: WorkspaceID, paneID: PaneID)? {
        guard let workspaceID = environment["ZENTTY_WORKSPACE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return (WorkspaceID(workspaceID), PaneID(paneID))
    }

    private static func resolvedTarget(
        for input: ClaudeHookInput,
        environment: [String: String],
        sessionStore: ClaudeHookSessionStore
    ) throws -> (workspaceID: WorkspaceID, paneID: PaneID) {
        if let record = try lookupRecord(for: input, sessionStore: sessionStore) {
            return (record.workspaceID, record.paneID)
        }
        return try currentTarget(from: environment)
    }

    private static func lookupRecord(
        for input: ClaudeHookInput,
        sessionStore: ClaudeHookSessionStore
    ) throws -> ClaudeHookSessionRecord? {
        guard let sessionID = input.sessionID else {
            return nil
        }
        return try sessionStore.lookup(sessionID: sessionID)
    }

    private static func parseClaudePID(from environment: [String: String]) -> Int32? {
        guard let rawPID = environment["ZENTTY_CLAUDE_PID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0 else {
            return nil
        }
        return pid
    }

    private static func lifecyclePayload(
        workspaceID: WorkspaceID,
        paneID: PaneID,
        state: PaneAgentState?,
        text: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            workspaceID: workspaceID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.claudeCode.displayName,
            text: text,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private static func pidPayload(
        workspaceID: WorkspaceID,
        paneID: PaneID,
        pid: Int32?,
        event: AgentPIDSignalEvent
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            workspaceID: workspaceID,
            paneID: paneID,
            signalKind: .pid,
            state: nil,
            pid: pid,
            pidEvent: event,
            origin: .explicitHook,
            toolName: AgentTool.claudeCode.displayName,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private static func readStandardInput() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    private static func describeAskUserQuestion(toolInput: [String: Any]) -> String? {
        guard let questions = toolInput["questions"] as? [[String: Any]],
              let first = questions.first else {
            return nil
        }

        var lines: [String] = []
        if let question = first["question"] as? String, !question.isEmpty {
            lines.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            lines.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                lines.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private static func extractCurrentWorkingDirectory(from object: [String: Any]) -> String? {
        firstString(in: object, keys: ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"])
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
