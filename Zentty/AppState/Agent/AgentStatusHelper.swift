import Darwin
import Foundation

enum AgentStatusHelper {
    private static let wrappedToolNames = ["claude", "codex", "opencode"]

    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        let subcommand = arguments.dropFirst().first
        guard subcommand == "agent-status"
            || subcommand == "agent-signal"
            || subcommand == "codex-hook"
            || subcommand == "opencode-hook"
        else {
            return nil
        }

        if subcommand == "codex-hook" {
            return CodexHookBridge.runIfNeeded(arguments: arguments, environment: environment)
        }

        if subcommand == "opencode-hook" {
            return OpenCodeHookBridge.runIfNeeded(arguments: arguments, environment: environment)
        }

        do {
            let payload: AgentStatusPayload
            if subcommand == "agent-signal" {
                payload = try AgentSignalCommand.parse(arguments: arguments, environment: environment).payload
            } else {
                payload = try AgentStatusCommand.parse(arguments: arguments, environment: environment).payload
            }
            post(payload)
            return EXIT_SUCCESS
        } catch {
            writeError(error)
            return EXIT_FAILURE
        }
    }

    static func binaryPath(in bundle: Bundle = .main) -> String? {
        guard let path = bundle.executableURL?.path, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    static func claudeHookCommand(in bundle: Bundle = .main) -> String? {
        guard let binaryPath = binaryPath(in: bundle) else {
            return nil
        }

        return "\(binaryPath) claude-hook"
    }

    static func agentSignalCommand(in bundle: Bundle = .main) -> String? {
        guard let binaryPath = binaryPath(in: bundle) else {
            return nil
        }

        return "\(binaryPath) agent-signal"
    }

    static func wrapperBinPath(in bundle: Bundle = .main) -> String? {
        validatedDirectoryPath(
            bundle.resourceURL?.appendingPathComponent("bin", isDirectory: true),
            requiredRelativePaths: [
                "claude/claude",
                "codex/codex",
                "opencode/opencode",
                "shared/zentty-agent-wrapper",
            ],
            executableRelativePaths: [
                "claude/claude",
                "codex/codex",
                "opencode/opencode",
                "shared/zentty-agent-wrapper",
            ]
        )
    }

    static func wrapperDirectoryPaths(in bundle: Bundle = .main) -> [String]? {
        guard let rootPath = wrapperBinPath(in: bundle) else {
            return nil
        }

        return wrappedToolNames.map {
            URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
                .path
        }
    }

    static func wrapperSupportDirectoryPath(in bundle: Bundle = .main) -> String? {
        guard let rootPath = wrapperBinPath(in: bundle) else {
            return nil
        }

        return URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .path
    }

    static func enabledWrapperDirectoryPaths(
        in bundle: Bundle = .main,
        processEnvironment: [String: String]
    ) -> [String] {
        guard let wrapperDirectories = wrapperDirectoryPaths(in: bundle) else {
            return []
        }

        let supportDirectory = wrapperSupportDirectoryPath(in: bundle)
        let rootDirectory = wrapperBinPath(in: bundle)
        let excludedDirectories = Set(wrapperDirectories + [supportDirectory, rootDirectory].compactMap { $0 })
        let pathEntries = (processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)

        return wrapperDirectories.filter { wrapperDirectory in
            let toolName = URL(fileURLWithPath: wrapperDirectory, isDirectory: true).lastPathComponent
            return pathEntries.contains { entry in
                guard !excludedDirectories.contains(entry) else {
                    return false
                }

                let candidatePath = URL(fileURLWithPath: entry, isDirectory: true)
                    .appendingPathComponent(toolName, isDirectory: false)
                    .path
                return FileManager.default.isExecutableFile(atPath: candidatePath)
            }
        }
    }

    static func shellIntegrationDirectoryPath(in bundle: Bundle = .main) -> String? {
        validatedDirectoryPath(
            bundle.resourceURL?.appendingPathComponent("shell-integration", isDirectory: true),
            requiredRelativePaths: [
                ".zshenv",
                "zentty-zsh-integration.zsh",
                "zentty-bash-integration.bash",
            ],
            executableRelativePaths: []
        )
    }

    static func post(_ payload: AgentStatusPayload) {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            AgentStatusTransport.notificationName,
            object: nil,
            userInfo: payload.notificationUserInfo,
            deliverImmediately: true
        )
    }

    static func writeError(_ error: Error) {
        let errorDescription: String
        if let payloadError = error as? AgentStatusPayloadError {
            errorDescription = String(describing: payloadError)
        } else {
            errorDescription = error.localizedDescription
        }
        FileHandle.standardError.write(Data((errorDescription + "\n").utf8))
    }

    private static func validatedDirectoryPath(
        _ directoryURL: URL?,
        requiredRelativePaths: [String],
        executableRelativePaths: [String]
    ) -> String? {
        guard let directoryURL else {
            return nil
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        for relativePath in requiredRelativePaths {
            let requiredURL = directoryURL.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.isReadableFile(atPath: requiredURL.path) else {
                return nil
            }
        }

        for relativePath in executableRelativePaths {
            let requiredURL = directoryURL.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.isExecutableFile(atPath: requiredURL.path) else {
                return nil
            }
        }

        return directoryURL.path
    }
}

struct CodexHookInput {
    let hookEventName: String
    let sessionID: String?
    let cwd: String?
    let lastAssistantMessage: String?
}

struct OpenCodeHookInput {
    let eventType: String
    let sessionID: String?
    let cwd: String?
    let status: String?
    let title: String?
    let questions: [[String: Any]]
}

enum CodexHookBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "codex-hook" else {
            return nil
        }

        let rawSubcommand = arguments.dropFirst(2).first
        let defaultHookEventName = mappedHookEventName(from: rawSubcommand)

        do {
            let input = try parseInput(
                readStandardInput(),
                defaultHookEventName: defaultHookEventName
            )
            guard currentTargetIfAvailable(from: environment) != nil else {
                print("{}")
                return EXIT_SUCCESS
            }

            for payload in try makePayloads(from: input, environment: environment) {
                AgentStatusHelper.post(payload)
            }
            print("{}")
            return EXIT_SUCCESS
        } catch {
            AgentStatusHelper.writeError(error)
            return EXIT_FAILURE
        }
    }

    static func parseInput(
        _ data: Data,
        defaultHookEventName: String? = nil
    ) throws -> CodexHookInput {
        let jsonObject = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
        let hookEventName = firstString(in: jsonObject, keys: ["hook_event_name", "hookEventName"])
            ?? defaultHookEventName

        guard let hookEventName else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return CodexHookInput(
            hookEventName: hookEventName,
            sessionID: firstString(in: jsonObject, keys: ["session_id", "sessionId"]),
            cwd: firstString(in: jsonObject, keys: ["cwd", "current_working_directory", "currentWorkingDirectory"]),
            lastAssistantMessage: firstString(
                in: jsonObject,
                keys: ["last_assistant_message", "lastAssistantMessage", "message", "body", "text"]
            )
        )
    }

    static func makePayloads(
        from input: CodexHookInput,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let target = try currentTarget(from: environment)
        let pid = parseCodexPID(from: environment)

        switch input.hookEventName {
        case "SessionStart":
            var payloads: [AgentStatusPayload] = []
            if let pid {
                payloads.append(
                    pidPayload(
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        pid: pid,
                        sessionID: input.sessionID
                    )
                )
            }
            payloads.append(
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .starting,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                )
            )
            return payloads
        case "UserPromptSubmit":
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .running,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                ),
            ]
        case "Stop":
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .idle,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                ),
            ]
        default:
            return []
        }
    }

    private static func mappedHookEventName(from rawSubcommand: String?) -> String? {
        switch rawSubcommand?.lowercased() {
        case "session-start":
            return "SessionStart"
        case "prompt-submit":
            return "UserPromptSubmit"
        case "stop":
            return "Stop"
        default:
            return nil
        }
    }

    private static func currentTarget(from environment: [String: String]) throws -> (worklaneID: WorklaneID, paneID: PaneID) {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"] else {
            throw AgentStatusPayloadError.missingWorklaneID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }
        return (WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func currentTargetIfAvailable(from environment: [String: String]) -> (worklaneID: WorklaneID, paneID: PaneID)? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return (WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func lifecyclePayload(
        worklaneID: WorklaneID,
        paneID: PaneID,
        state: PaneAgentState,
        sessionID: String?,
        cwd: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.codex.displayName,
            text: nil,
            lifecycleEvent: .update,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }

    private static func pidPayload(
        worklaneID: WorklaneID,
        paneID: PaneID,
        pid: Int32,
        sessionID: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .pid,
            state: nil,
            pid: pid,
            pidEvent: .attach,
            origin: .explicitHook,
            toolName: AgentTool.codex.displayName,
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private static func parseCodexPID(from environment: [String: String]) -> Int32? {
        guard let rawPID = environment["ZENTTY_CODEX_PID"] else {
            return nil
        }
        return Int32(rawPID)
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

enum OpenCodeHookBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "opencode-hook" else {
            return nil
        }

        do {
            let input = try parseInput(readStandardInput())
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

    static func parseInput(_ data: Data) throws -> OpenCodeHookInput {
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = firstString(in: json, keys: ["eventType", "event_type", "type"]) else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return OpenCodeHookInput(
            eventType: eventType,
            sessionID: firstString(in: json, keys: ["sessionID", "sessionId", "session_id"]),
            cwd: firstString(in: json, keys: ["cwd", "workingDirectory", "working_directory"]),
            status: firstString(in: json, keys: ["status"]),
            title: firstString(in: json, keys: ["title", "text", "message"]),
            questions: (json["questions"] as? [[String: Any]]) ?? []
        )
    }

    static func makePayloads(
        from input: OpenCodeHookInput,
        environment: [String: String]
    ) throws -> [AgentStatusPayload] {
        let target = try currentTarget(from: environment)

        switch input.eventType {
        case "session.status":
            switch input.status?.lowercased() {
            case "busy", "retry":
                return [
                    lifecyclePayload(
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        state: .running,
                        text: nil,
                        interactionKind: .none,
                        sessionID: input.sessionID,
                        cwd: input.cwd
                    ),
                ]
            case "idle":
                return [
                    lifecyclePayload(
                        worklaneID: target.worklaneID,
                        paneID: target.paneID,
                        state: .idle,
                        text: nil,
                        interactionKind: .none,
                        sessionID: input.sessionID,
                        cwd: input.cwd
                    ),
                ]
            default:
                return []
            }

        case "session.idle":
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .idle,
                    text: nil,
                    interactionKind: .none,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                ),
            ]

        case "permission.asked", "permission.updated":
            let text = input.title ?? "OpenCode needs your approval"
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: text,
                    interactionKind: .approval,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                ),
            ]

        case "question.asked":
            guard let description = describeQuestion(input.questions) else {
                return []
            }
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .needsInput,
                    text: description.text,
                    interactionKind: description.interactionKind,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                ),
            ]

        case "permission.replied", "question.replied":
            return [
                lifecyclePayload(
                    worklaneID: target.worklaneID,
                    paneID: target.paneID,
                    state: .running,
                    text: nil,
                    interactionKind: .none,
                    sessionID: input.sessionID,
                    cwd: input.cwd
                ),
            ]

        default:
            return []
        }
    }

    private static func lifecyclePayload(
        worklaneID: WorklaneID,
        paneID: PaneID,
        state: PaneAgentState,
        text: String?,
        interactionKind: PaneAgentInteractionKind,
        sessionID: String?,
        cwd: String?
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.openCode.displayName,
            text: text,
            lifecycleEvent: .update,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: cwd
        )
    }

    private static func describeQuestion(_ questions: [[String: Any]]) -> (text: String, interactionKind: PaneAgentInteractionKind)? {
        guard let first = questions.first else {
            return nil
        }

        var lines: [String] = []
        if let question = firstString(in: first, keys: ["question"]), !question.isEmpty {
            lines.append(question)
        } else if let header = firstString(in: first, keys: ["header"]), !header.isEmpty {
            lines.append(header)
        }

        let options = (first["options"] as? [[String: Any]]) ?? []
        let labels = options.compactMap { firstString(in: $0, keys: ["label"]) }
        if !labels.isEmpty {
            lines.append(labels.map { "[\($0)]" }.joined(separator: " "))
        }

        guard !lines.isEmpty else {
            return nil
        }

        return (
            text: lines.joined(separator: "\n"),
            interactionKind: labels.isEmpty ? .question : .decision
        )
    }

    private static func currentTarget(from environment: [String: String]) throws -> (worklaneID: WorklaneID, paneID: PaneID) {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"] else {
            throw AgentStatusPayloadError.missingWorklaneID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }
        return (WorklaneID(worklaneID), PaneID(paneID))
    }

    private static func currentTargetIfAvailable(from environment: [String: String]) -> (worklaneID: WorklaneID, paneID: PaneID)? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"],
              let paneID = environment["ZENTTY_PANE_ID"] else {
            return nil
        }
        return (WorklaneID(worklaneID), PaneID(paneID))
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
