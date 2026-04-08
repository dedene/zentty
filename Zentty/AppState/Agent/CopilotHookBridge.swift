import Foundation

struct CopilotHookInput {
    enum Event {
        case sessionStart
        case sessionEnd
        case userPromptSubmitted
        case preToolUse
        case postToolUse
        case errorOccurred
    }

    let event: Event
    let cwd: String?
    let prompt: String?
    let reason: String?
    let toolName: String?
    let toolArgs: String?
    let errorMessage: String?
}

enum CopilotHookBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "copilot-hook" else {
            return nil
        }

        let defaultHookEventName = mappedHookEventName(from: arguments.dropFirst(2).first)

        do {
            let input = try parseInput(
                readStandardInput(),
                defaultHookEventName: defaultHookEventName
            )
            guard currentTargetIfAvailable(from: environment) != nil else {
                return EXIT_SUCCESS
            }

            for payload in try makePayloads(from: input, environment: environment) {
                AgentStatusHelper.post(payload)
            }
            return EXIT_SUCCESS
        } catch {
            AgentStatusHelper.writeError(error)
            return EXIT_FAILURE
        }
    }

    static func parseInput(
        _ data: Data,
        defaultHookEventName: String? = nil
    ) throws -> CopilotHookInput {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        // Copilot CLI does not emit a hook_event_name field on stdin. We rely on the
        // subcommand passed to `copilot-hook <event>` instead.
        guard let rawHookEventName = defaultHookEventName,
              let event = parseEvent(rawHookEventName) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        let errorObject = jsonObject["error"] as? [String: Any]
        let errorMessage = errorObject.flatMap {
            firstString(in: $0, keys: ["message", "name"])
        }

        return CopilotHookInput(
            event: event,
            cwd: firstString(in: jsonObject, keys: ["cwd", "current_working_directory", "currentWorkingDirectory"]),
            prompt: firstString(in: jsonObject, keys: ["prompt", "initialPrompt", "initial_prompt"]),
            reason: firstString(in: jsonObject, keys: ["reason"]),
            toolName: firstString(in: jsonObject, keys: ["toolName", "tool_name"]),
            toolArgs: firstString(in: jsonObject, keys: ["toolArgs", "tool_args"]),
            errorMessage: errorMessage
        )
    }

    static func makePayloads(
        from input: CopilotHookInput,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let target = try currentTarget(from: environment)

        switch input.event {
        case .sessionStart:
            var payloads: [AgentStatusPayload] = []
            if let pid = parseCopilotPID(from: environment) {
                payloads.append(
                    pidPayload(
                        windowID: target.windowID,
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        pid: pid
                    )
                )
            }
            // Seed agentStatus at .idle so the normalizer's copilot OSC
            // special case can promote to .running when libghostty reports
            // terminal-progress activity, and drop back to idle when quiet.
            payloads.append(
                lifecyclePayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .idle,
                    text: nil,
                    interactionKind: .none,
                    cwd: input.cwd
                )
            )
            return payloads

        case .userPromptSubmitted:
            // No-op. Copilot emits OSC 9;4 when the LLM starts working;
            // PanePresentationNormalizer promotes to .running from there.
            return []

        case .preToolUse:
            guard isUserQuestionTool(input.toolName) else {
                return []
            }
            let questionText = extractQuestionText(from: input.toolArgs) ?? "Copilot is asking a question"
            return [
                lifecyclePayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: questionText,
                    interactionKind: .question,
                    cwd: input.cwd
                ),
            ]

        case .postToolUse:
            guard isUserQuestionTool(input.toolName) else {
                return []
            }
            // User answered the question; clear .needsInput back to .idle so
            // OSC can drive Running during Copilot's follow-up processing.
            return [
                lifecyclePayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .idle,
                    text: nil,
                    interactionKind: .none,
                    cwd: input.cwd
                ),
            ]

        case .errorOccurred:
            return []

        case .sessionEnd:
            // Emit a clear-status payload (lifecycle + state nil) to remove
            // the session entirely. AgentStatusPayload.clearsStatus handles it.
            return [
                clearSessionPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    cwd: input.cwd
                ),
            ]
        }
    }

    private static func mappedHookEventName(from rawSubcommand: String?) -> String? {
        switch rawSubcommand?.lowercased() {
        case "session-start":
            return "sessionStart"
        case "session-end":
            return "sessionEnd"
        case "user-prompt-submitted":
            return "userPromptSubmitted"
        case "pre-tool-use":
            return "preToolUse"
        case "post-tool-use":
            return "postToolUse"
        case "error-occurred":
            return "errorOccurred"
        default:
            return nil
        }
    }

    private static func parseEvent(_ rawValue: String) -> CopilotHookInput.Event? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch normalized {
        case "sessionstart":
            return .sessionStart
        case "sessionend":
            return .sessionEnd
        case "userpromptsubmitted":
            return .userPromptSubmitted
        case "pretooluse":
            return .preToolUse
        case "posttooluse":
            return .postToolUse
        case "erroroccurred":
            return .errorOccurred
        default:
            return nil
        }
    }

    private static func isUserQuestionTool(_ name: String?) -> Bool {
        guard let normalized = name?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") else {
            return false
        }
        // Matches: askuserquestiontool, askuserquestion, ask_user_question, etc.
        return normalized.contains("askuserquestion")
    }

    private static func extractQuestionText(from toolArgs: String?) -> String? {
        guard let toolArgs,
              let data = toolArgs.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let object = jsonObject as? [String: Any] else {
            return nil
        }
        return firstString(in: object, keys: ["question", "prompt", "message", "title"])
    }

    private static func lifecyclePayload(
        windowID: WindowID?,
        worklaneID: WorklaneID,
        paneID: PaneID,
        state: PaneAgentState,
        text: String?,
        interactionKind: PaneAgentInteractionKind,
        cwd: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.copilot.displayName,
            text: text,
            lifecycleEvent: .update,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }

    private static func clearSessionPayload(
        windowID: WindowID?,
        worklaneID: WorklaneID,
        paneID: PaneID,
        cwd: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: nil,
            origin: .explicitHook,
            toolName: AgentTool.copilot.displayName,
            text: nil,
            lifecycleEvent: .update,
            interactionKind: .none,
            confidence: .explicit,
            sessionID: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }

    private static func pidPayload(
        windowID: WindowID?,
        worklaneID: WorklaneID,
        paneID: PaneID,
        pid: Int32
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .pid,
            state: nil,
            pid: pid,
            pidEvent: .attach,
            origin: .explicitHook,
            toolName: AgentTool.copilot.displayName,
            text: nil,
            sessionID: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private static func parseCopilotPID(from environment: [String: String]) -> Int32? {
        guard let rawPID = environment["ZENTTY_COPILOT_PID"] else {
            return nil
        }
        return Int32(rawPID)
    }

    private static func currentTarget(from environment: [String: String]) throws -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"] else {
            throw AgentStatusPayloadError.missingWorklaneID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }
        return ((environment["ZENTTY_WINDOW_ID"]).map(WindowID.init), WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func currentTargetIfAvailable(from environment: [String: String]) -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID)? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return ((environment["ZENTTY_WINDOW_ID"]).map(WindowID.init), WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func readStandardInput() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
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
