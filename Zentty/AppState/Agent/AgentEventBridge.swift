import Foundation
import os

private let agentEventBridgeLogger = Logger(subsystem: "be.zenjoy.zentty", category: "AgentEventBridge")

struct AgentEventInput {
    let event: String
    let agentName: String?
    let agentPID: Int32?
    let sessionID: String?
    let parentSessionID: String?
    let stateText: String?
    let stopCandidate: Bool
    let interactionKind: String?
    let interactionText: String?
    let progressDone: Int?
    let progressTotal: Int?
    let artifactKind: String?
    let artifactLabel: String?
    let artifactURL: String?
    let workingDirectory: String?
}

enum AgentEventBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "agent-event" else {
            return nil
        }

        return run(
            arguments: arguments,
            environment: environment,
            inputData: readStandardInput(),
            post: { payload in
                AgentStatusHelper.post(payload)
            },
            writeError: AgentStatusHelper.writeError
        )
    }

    static func run(
        arguments: [String],
        environment: [String: String],
        inputData: Data,
        post: (AgentStatusPayload) -> Void = { _ in },
        writeError: (Error) -> Void = { _ in }
    ) -> Int32 {
        let remaining = Array(arguments.dropFirst(2))
        let adapter = parseAdapterFlag(remaining)
        let positionalArgs = remaining.filter { !$0.hasPrefix("--adapter=") }
        let adapterLabel = adapter ?? "(default)"
        agentEventBridgeLogger.debug("run adapter=\(adapterLabel, privacy: .public) bytes=\(inputData.count)")
        do {
            let payloads: [AgentStatusPayload]
            switch adapter {
            case "claude":
                payloads = try claudeAdapter(data: inputData, environment: environment)
            case "copilot":
                let eventName = positionalArgs.first
                payloads = try copilotAdapter(data: inputData, defaultEventName: eventName, environment: environment)
            case "codex":
                let eventName = positionalArgs.first
                payloads = try codexAdapter(data: inputData, defaultEventName: eventName, environment: environment)
            case "codex-notify":
                payloads = try codexNotifyAdapter(data: inputData, environment: environment)
            case "gemini":
                payloads = try geminiAdapter(data: inputData, environment: environment)
            case "cursor":
                payloads = try cursorAdapter(data: inputData, environment: environment)
            case .none:
                let input = try parseInput(inputData)
                payloads = try makePayloads(from: input, environment: environment)
            case let name?:
                throw AgentStatusPayloadError.invalidArguments("Unknown adapter: \(name)")
            }
            agentEventBridgeLogger.debug("run adapter=\(adapterLabel, privacy: .public) produced \(payloads.count) payload(s)")
            for payload in payloads {
                post(payload)
            }
            return EXIT_SUCCESS
        } catch {
            agentEventBridgeLogger.error("run adapter=\(adapterLabel, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            if adapter == "claude" {
                return EXIT_SUCCESS
            }
            writeError(error)
            return EXIT_FAILURE
        }
    }

    private static func parseAdapterFlag(_ arguments: [String]) -> String? {
        for arg in arguments {
            if arg.hasPrefix("--adapter=") {
                let value = String(arg.dropFirst("--adapter=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: - Parsing

    static func parseInput(_ data: Data) throws -> AgentEventInput {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        guard let version = json["version"] as? Int, version == 1 else {
            throw AgentStatusPayloadError.invalidArguments("Unsupported or missing protocol version.")
        }

        guard let event = json["event"] as? String, !event.isEmpty else {
            throw AgentStatusPayloadError.invalidArguments("Missing event field.")
        }

        let agent = json["agent"] as? [String: Any]
        let session = json["session"] as? [String: Any]
        let state = json["state"] as? [String: Any]
        let interaction = state?["interaction"] as? [String: Any]
        let progress = json["progress"] as? [String: Any]
        let artifact = json["artifact"] as? [String: Any]
        let context = json["context"] as? [String: Any]

        return AgentEventInput(
            event: event,
            agentName: firstString(in: agent, keys: ["name"]),
            agentPID: firstInt32(in: agent, keys: ["pid"]),
            sessionID: firstString(in: session, keys: ["id"]),
            parentSessionID: firstString(in: session, keys: ["parentId"]),
            stateText: firstString(in: state, keys: ["text"]),
            stopCandidate: (state?["stopCandidate"] as? Bool) ?? false,
            interactionKind: firstString(in: interaction, keys: ["kind"]),
            interactionText: firstString(in: interaction, keys: ["text"]),
            progressDone: firstInt(in: progress, keys: ["done"]),
            progressTotal: firstInt(in: progress, keys: ["total"]),
            artifactKind: firstString(in: artifact, keys: ["kind"]),
            artifactLabel: firstString(in: artifact, keys: ["label"]),
            artifactURL: firstString(in: artifact, keys: ["url"]),
            workingDirectory: firstString(in: context, keys: ["workingDirectory"])
        )
    }

    // MARK: - Payload Construction

    static func makePayloads(
        from input: AgentEventInput,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let target = try currentTarget(from: environment)
        let toolName = input.agentName
        let taskProgress = PaneAgentTaskProgress(
            doneCount: input.progressDone ?? 0,
            totalCount: input.progressTotal ?? 0
        )
        let artifactURL = try input.artifactURL.flatMap { urlString -> URL? in
            guard let url = URL(string: urlString) else {
                throw AgentStatusPayloadError.invalidArtifactURL(urlString)
            }
            return url
        }

        switch input.event {
        case "session.start":
            var payloads: [AgentStatusPayload] = []
            if let pid = input.agentPID {
                payloads.append(AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    signalKind: .pid,
                    state: nil,
                    pid: pid,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: nil,
                    sessionID: input.sessionID,
                    parentSessionID: input.parentSessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ))
            }
            payloads.append(AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                signalKind: .lifecycle,
                state: .starting,
                origin: .explicitHook,
                toolName: toolName,
                text: input.stateText,
                confidence: .explicit,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: input.workingDirectory
            ))
            return payloads

        case "session.end":
            var payloads: [AgentStatusPayload] = [
                AgentStatusPayload(
                    windowID: target.windowID,
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    signalKind: .lifecycle,
                    state: nil,
                    origin: .explicitHook,
                    toolName: toolName,
                    text: nil,
                    sessionID: input.sessionID,
                    parentSessionID: input.parentSessionID,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
            ]
            payloads.append(AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                signalKind: .pid,
                state: nil,
                pid: nil,
                pidEvent: .clear,
                origin: .explicitHook,
                toolName: toolName,
                text: nil,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ))
            return payloads

        case "agent.running":
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .running,
                origin: .explicitHook,
                toolName: toolName,
                text: input.stateText,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                taskProgress: taskProgress,
                artifactKind: input.artifactKind.flatMap(WorklaneArtifactKind.init(rawValue:)),
                artifactLabel: input.artifactLabel,
                artifactURL: artifactURL,
                agentWorkingDirectory: input.workingDirectory
            )]

        case "agent.idle":
            let lifecycleEvent: AgentLifecycleEvent = input.stopCandidate ? .stopCandidate : .update
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: toolName,
                text: input.stateText,
                lifecycleEvent: lifecycleEvent,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                taskProgress: taskProgress,
                artifactKind: input.artifactKind.flatMap(WorklaneArtifactKind.init(rawValue:)),
                artifactLabel: input.artifactLabel,
                artifactURL: artifactURL,
                agentWorkingDirectory: input.workingDirectory
            )]

        case "agent.needs-input":
            let interactionKind = input.interactionKind
                .flatMap(PaneAgentInteractionKind.init(rawValue:))
                ?? .genericInput
            let text = input.interactionText ?? input.stateText
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .needsInput,
                origin: .explicitHook,
                toolName: toolName,
                text: text,
                interactionKind: interactionKind,
                confidence: .explicit,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                taskProgress: taskProgress,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: input.workingDirectory
            )]

        case "agent.input-resolved":
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .running,
                origin: .explicitHook,
                toolName: toolName,
                text: input.stateText,
                interactionKind: .none,
                confidence: .explicit,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                taskProgress: taskProgress,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: input.workingDirectory
            )]

        case "task.progress":
            return [AgentStatusPayload(
                windowID: target.windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                state: .running,
                origin: .explicitHook,
                toolName: toolName,
                text: input.stateText,
                confidence: .explicit,
                sessionID: input.sessionID,
                parentSessionID: input.parentSessionID,
                taskProgress: taskProgress,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: input.workingDirectory
            )]

        default:
            throw AgentStatusPayloadError.invalidArguments("Unknown event: \(input.event)")
        }
    }

    // MARK: - Helpers

    static func currentTarget(
        from environment: [String: String]
    ) throws -> (windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"] else {
            throw AgentStatusPayloadError.missingWorklaneID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }
        return (environment["ZENTTY_WINDOW_ID"].map(WindowID.init), WorklaneID(worklaneID), PaneID(paneID))
    }

    static func readStandardInput() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    static func firstString(in object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
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

    static func firstInt(in object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
            if let value = object[key] as? Int {
                return value
            }
        }
        return nil
    }

    static func firstInt32(in object: [String: Any]?, keys: [String]) -> Int32? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? NSNumber {
                return value.int32Value
            }
            if let value = object[key] as? Int {
                return Int32(value)
            }
        }
        return nil
    }
}
