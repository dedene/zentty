import Foundation

// MARK: - Shared Adapter Helpers

extension AgentEventBridge {
    static func currentTargetIfAvailable(
        from environment: [String: String]
    ) -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID)? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return (environment["ZENTTY_WINDOW_ID"].map(WindowID.init), WorklaneID(worklaneID), PaneID(paneID))
    }

    static func parseAgentPID(from environment: [String: String], key: String) -> Int32? {
        guard let rawPID = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0 else {
            return nil
        }
        return pid
    }

    static func lifecyclePayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        toolName: String,
        state: PaneAgentState,
        text: String? = nil,
        lifecycleEvent: AgentLifecycleEvent = .update,
        interactionKind: PaneAgentInteractionKind? = nil,
        sessionID: String? = nil,
        cwd: String? = nil,
        taskProgress: PaneAgentTaskProgress? = nil,
        subagents: PaneAgentSubagentSummary? = nil,
        transcriptPath: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            state: state,
            origin: .explicitHook,
            toolName: toolName,
            text: text,
            lifecycleEvent: lifecycleEvent,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: sessionID,
            taskProgress: taskProgress,
            subagents: subagents,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd,
            agentTranscriptPath: transcriptPath
        )
    }

    static func pidPayload(
        target: (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID),
        toolName: String,
        pid: Int32?,
        event: AgentPIDSignalEvent,
        sessionID: String? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            signalKind: .pid,
            state: nil,
            pid: pid,
            pidEvent: event,
            origin: .explicitHook,
            toolName: toolName,
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}

// MARK: - Droid/Cursor Shared Todo Progress

extension AgentEventBridge {
    struct DroidTodoProgressSnapshot {
        let doneCount: Int
        let totalCount: Int
    }

    static func droidTodoProgress(toolInput: [String: Any]?) -> DroidTodoProgressSnapshot? {
        guard let toolInput, let todos = toolInput["todos"] else {
            return nil
        }

        if let todoObjects = todos as? [[String: Any]] {
            return droidTodoProgress(todoObjects: todoObjects)
        }

        if let todoLines = todos as? [String] {
            return droidTodoProgress(todoText: todoLines.joined(separator: "\n"))
        }

        if let todoText = todos as? String {
            return droidTodoProgress(todoText: todoText)
        }

        return nil
    }

    private static func droidTodoProgress(todoObjects: [[String: Any]]) -> DroidTodoProgressSnapshot? {
        guard !todoObjects.isEmpty else {
            return DroidTodoProgressSnapshot(doneCount: 0, totalCount: 0)
        }

        let statuses = todoObjects.compactMap { todo in
            JSONKeyAccess.firstString(in: todo, keys: ["status", "state"])
        }
        guard !statuses.isEmpty else { return nil }

        let doneCount = statuses.filter { droidTodoStatusIsComplete($0) }.count
        return DroidTodoProgressSnapshot(doneCount: doneCount, totalCount: statuses.count)
    }

    private static func droidTodoProgress(todoText: String) -> DroidTodoProgressSnapshot? {
        var totalCount = 0
        var doneCount = 0
        var sawTodoLine = false

        for rawLine in todoText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !line.isEmpty else { continue }
            sawTodoLine = true

            if line.contains("[completed]") || line.contains("[done]") {
                totalCount += 1
                doneCount += 1
            } else if line.contains("[in_progress]")
                || line.contains("[in-progress]")
                || line.contains("[pending]") {
                totalCount += 1
            } else if line.contains("[x]") {
                totalCount += 1
                doneCount += 1
            } else if line.contains("[ ]") {
                totalCount += 1
            }
        }

        guard totalCount > 0 || !sawTodoLine else {
            return nil
        }
        return DroidTodoProgressSnapshot(doneCount: doneCount, totalCount: totalCount)
    }

    private static func droidTodoStatusIsComplete(_ status: String) -> Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done":
            return true
        default:
            return false
        }
    }
}

// MARK: - Subagent enrichment

extension AgentEventBridge {
    /// Attaches the pane's current subagent set to outgoing lifecycle payloads
    /// that do not carry one yet, resolving models that were unknown at
    /// `SubagentStart` (the subagent transcript only reveals its model after
    /// the first response). No-op while the pane has no subagents recorded.
    static func attachSubagents(
        to payloads: [AgentStatusPayload],
        key: AgentSubagentRegistryStore.Key,
        subagentStore: AgentSubagentRegistryStore,
        resolver: (PaneAgentSubagentEntry) -> PaneAgentSubagentEntry?
    ) throws -> [AgentStatusPayload] {
        guard let current = try subagentStore.summary(key: key), !current.isEmpty else {
            return payloads
        }
        let refreshed = try subagentStore.refreshMissingModels(key: key, resolver: resolver) ?? current
        return payloads.map { payload in
            guard payload.signalKind == .lifecycle, payload.state != nil, payload.subagents == nil else {
                return payload
            }
            return payload.with(subagents: refreshed)
        }
    }
}
