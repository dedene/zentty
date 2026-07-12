import Foundation
import os

private let cursorAdapterLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CursorAdapter")

// MARK: - Cursor Adapter

extension AgentEventBridge {
    static func cursorAdapter(
        data: Data,
        environment: [String: String],
        taskStore: CursorTaskStore = CursorTaskStore()
    ) throws -> [AgentStatusPayload] {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        guard let hookEventName = JSONKeyAccess.firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard currentTargetIfAvailable(from: environment) != nil else {
            return []
        }

        let target = try currentTarget(from: environment)
        let toolName = AgentTool.cursor.displayName
        let sessionID = JSONKeyAccess.firstString(
            in: jsonObject,
            keys: ["conversation_id", "conversationId", "session_id", "sessionId"]
        )
        let cwd = cursorWorkspaceRoot(from: jsonObject)
        let transcriptPath = JSONKeyAccess.firstString(in: jsonObject, keys: ["transcript_path", "transcriptPath"])
        let hookToolName = JSONKeyAccess.firstString(in: jsonObject, keys: ["tool_name", "toolName", "tool"])
        let toolInput = (jsonObject["tool_input"] as? [String: Any])
            ?? (jsonObject["toolInput"] as? [String: Any])
            ?? (jsonObject["input"] as? [String: Any])
        let pid = parseAgentPID(from: environment, key: "ZENTTY_CURSOR_PID")

        let normalized = hookEventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "sessionstart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(pidPayload(target: target, toolName: toolName, pid: pid, event: .attach, sessionID: sessionID))
            }
            payloads.append(lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .starting,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            ))
            return payloads

        case "beforesubmitprompt":
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                transcriptPath: transcriptPath
            )]

        case "sessionend":
            try taskStore.clearSession(sessionID: sessionID)
            return [
                AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    signalKind: .lifecycle,
                    state: nil,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: nil,
                    sessionID: sessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                pidPayload(target: target, toolName: toolName, pid: nil, event: .clear, sessionID: sessionID),
            ]

        case "stop":
            let status = JSONKeyAccess.firstString(in: jsonObject, keys: ["status"])?.lowercased()
            let taskProgress = try cursorTaskProgress(
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                taskStore: taskStore
            )
            switch status {
            case "error":
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .unresolvedStop,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            case "aborted":
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .stopCandidate,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            case "completed", nil:
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            default:
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .update,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            }

        case "subagentstart", "subagentstop":
            return []

        case "pretooluse", "posttooluse":
            if cursorToolNameIsTodoWrite(hookToolName),
               let sessionID,
               let taskProgress = try cursorApplyTodoWrite(
                sessionID: sessionID,
                toolInput: toolInput,
                taskStore: taskStore
               ) {
                return [lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .running,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                )]
            }
            guard environment["ZENTTY_CURSOR_VERBOSE_HOOKS"] == "1" else {
                return []
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                transcriptPath: transcriptPath
            )]

        case "aftershellexecution":
            let taskProgress = try cursorTaskProgress(
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                taskStore: taskStore
            )
            return [
                lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .running,
                    lifecycleEvent: .toolActivity,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                ),
                lifecyclePayload(
                    target: target,
                    toolName: toolName,
                    state: .idle,
                    lifecycleEvent: .stopCandidate,
                    sessionID: sessionID,
                    cwd: cwd,
                    taskProgress: taskProgress,
                    transcriptPath: transcriptPath
                ),
            ]

        case "posttoolusefailure", "beforeshellexecution":
            guard environment["ZENTTY_CURSOR_VERBOSE_HOOKS"] == "1" else {
                return []
            }
            return [lifecyclePayload(
                target: target,
                toolName: toolName,
                state: .running,
                sessionID: sessionID,
                cwd: cwd,
                taskProgress: try taskStore.taskProgress(sessionID: sessionID),
                transcriptPath: transcriptPath
            )]

        default:
            cursorAdapterLogger.debug("Unhandled cursor hook event: \(normalized, privacy: .public)")
            return []
        }
    }

    private static func cursorWorkspaceRoot(from jsonObject: [String: Any]) -> String? {
        let roots = (jsonObject["workspace_roots"] as? [String]) ?? (jsonObject["workspaceRoots"] as? [String])
        guard let first = roots?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            return nil
        }
        return first
    }

    private static func cursorToolNameIsTodoWrite(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("TodoWrite") == .orderedSame
    }

    private static func cursorTaskProgress(
        sessionID: String?,
        transcriptPath: String?,
        taskStore: CursorTaskStore
    ) throws -> PaneAgentTaskProgress? {
        if let sessionID,
           let transcriptPath,
           let updates = cursorTranscriptTodoUpdates(transcriptPath: transcriptPath, attempts: 5),
           !updates.isEmpty {
            var taskProgress: PaneAgentTaskProgress?
            for update in updates {
                taskProgress = try taskStore.applyTodoWrite(sessionID: sessionID, update: update)
            }
            return taskProgress
        }
        return try taskStore.taskProgress(sessionID: sessionID)
    }

    private static func cursorApplyTodoWrite(
        sessionID: String,
        toolInput: [String: Any]?,
        taskStore: CursorTaskStore
    ) throws -> PaneAgentTaskProgress? {
        if let update = cursorTodoWriteUpdate(toolInput: toolInput) {
            return try taskStore.applyTodoWrite(sessionID: sessionID, update: update)
        }
        guard let todoProgress = droidTodoProgress(toolInput: toolInput) else {
            return nil
        }
        return try taskStore.updateProgress(
            sessionID: sessionID,
            doneCount: todoProgress.doneCount,
            totalCount: todoProgress.totalCount
        )
    }

    private static func cursorTranscriptTodoUpdates(transcriptPath: String, attempts: Int = 1) -> [CursorTodoWriteUpdate]? {
        let attemptCount = max(attempts, 1)
        for attempt in 0..<attemptCount {
            if let updates = cursorTranscriptTodoUpdatesOnce(transcriptPath: transcriptPath), !updates.isEmpty {
                return updates
            }
            if attempt < attemptCount - 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }

    private static func cursorTranscriptTodoUpdatesOnce(transcriptPath: String) -> [CursorTodoWriteUpdate]? {
        guard let text = cursorReadTextFileTail(path: transcriptPath, maxBytes: 256 * 1024) else {
            return nil
        }
        var updates: [CursorTodoWriteUpdate] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            updates.append(contentsOf: cursorTodoWriteUpdates(in: object, depth: 0))
        }
        return updates
    }

    private static func cursorTodoWriteUpdates(in object: [String: Any], depth: Int) -> [CursorTodoWriteUpdate] {
        guard depth < 6 else { return [] }

        if cursorToolNameIsTodoWrite(JSONKeyAccess.firstString(in: object, keys: ["name", "tool_name", "toolName", "tool"])) {
            let toolInput = (object["input"] as? [String: Any])
                ?? (object["tool_input"] as? [String: Any])
                ?? (object["toolInput"] as? [String: Any])
                ?? (object["todos"] == nil ? nil : object)
            if let update = cursorTodoWriteUpdate(toolInput: toolInput) {
                return [update]
            }
        }

        var updates: [CursorTodoWriteUpdate] = []
        for key in ["message", "tool_use", "toolUse", "tool_use_input", "input"] {
            if let nested = object[key] as? [String: Any] {
                updates.append(contentsOf: cursorTodoWriteUpdates(in: nested, depth: depth + 1))
            }
        }

        for key in ["content", "messages"] {
            guard let items = object[key] as? [Any] else { continue }
            for item in items {
                if let nested = item as? [String: Any] {
                    updates.append(contentsOf: cursorTodoWriteUpdates(in: nested, depth: depth + 1))
                }
            }
        }

        return updates
    }

    private static func cursorTodoWriteUpdate(toolInput: [String: Any]?) -> CursorTodoWriteUpdate? {
        guard let toolInput, let todoObjects = toolInput["todos"] as? [[String: Any]] else {
            return nil
        }

        let todos = todoObjects.compactMap { cursorTodoWriteTodo(from: $0) }
        guard !todos.isEmpty || todoObjects.isEmpty else {
            return nil
        }
        let merge = (toolInput["merge"] as? Bool) ?? false
        return CursorTodoWriteUpdate(merge: merge, todos: todos)
    }

    private static func cursorTodoWriteTodo(from object: [String: Any]) -> CursorTodoWriteTodo? {
        let id = JSONKeyAccess.firstString(in: object, keys: ["id"])
        let content = JSONKeyAccess.firstString(in: object, keys: ["content", "text", "title"])
        let status = JSONKeyAccess.firstString(in: object, keys: ["status", "state"]) ?? "pending"
        guard let key = id ?? content else {
            return nil
        }
        return CursorTodoWriteTodo(key: key, content: content, status: status)
    }

    private static func cursorReadTextFileTail(path: String, maxBytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        do {
            let fileSize = try handle.seekToEnd()
            let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            cursorAdapterLogger.debug("Failed to read cursor transcript tail: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Adapter conformance

enum CursorEventAdapter: AgentEventAdapting {
    static let adapterName = "cursor"
    static let suppressesErrors = false
    static func makePayloads(
        data: Data,
        positionalArguments: [String],
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        try AgentEventBridge.cursorAdapter(data: data, environment: environment)
    }
}
