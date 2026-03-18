import Darwin
import Foundation
import UserNotifications

enum AgentStatusPayloadError: Error {
    case missingPaneID
    case missingPID
    case missingWorkspaceID
    case missingState
    case invalidArguments(String)
    case invalidArtifactURL(String)
    case invalidNotificationPayload
    case invalidHookPayload
}

enum AgentSignalKind: String, Equatable, Sendable {
    case lifecycle
    case shellState = "shell-state"
    case pid
    case paneContext = "pane-context"
}

enum AgentPIDSignalEvent: String, Equatable, Sendable {
    case attach
    case clear
}

enum PaneShellContextScope: String, Equatable, Sendable {
    case local
    case remote
}

struct PaneShellContext: Equatable, Sendable {
    let scope: PaneShellContextScope
    let path: String?
    let home: String?
    let user: String?
    let host: String?

    init(
        scope: PaneShellContextScope,
        path: String?,
        home: String?,
        user: String?,
        host: String?
    ) {
        self.scope = scope
        self.path = Self.trimmed(path)
        self.home = Self.trimmed(home)
        self.user = Self.trimmed(user)
        self.host = Self.trimmed(host)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}

struct AgentStatusPayload: Equatable, Sendable {
    let workspaceID: WorkspaceID
    let paneID: PaneID
    let signalKind: AgentSignalKind
    let state: PaneAgentState?
    let shellActivityState: PaneShellActivityState?
    let pid: Int32?
    let pidEvent: AgentPIDSignalEvent?
    let paneContext: PaneShellContext?
    let origin: AgentSignalOrigin
    let toolName: String?
    let text: String?
    let artifactKind: WorkspaceArtifactKind?
    let artifactLabel: String?
    let artifactURL: URL?

    var clearsStatus: Bool {
        signalKind == .lifecycle && state == nil
    }

    var clearsPaneContext: Bool {
        signalKind == .paneContext && paneContext == nil
    }

    var notificationUserInfo: [AnyHashable: Any]? {
        var userInfo: [AnyHashable: Any] = [
            "workspaceID": workspaceID.rawValue,
            "paneID": paneID.rawValue,
            "kind": signalKind.rawValue,
            "origin": origin.rawValue,
        ]
        if let state {
            userInfo["state"] = state.rawValue
        }
        if let shellActivityState {
            userInfo["shellActivityState"] = shellActivityState.rawValue
        }
        if let pid {
            userInfo["pid"] = NSNumber(value: pid)
        }
        if let pidEvent {
            userInfo["pidEvent"] = pidEvent.rawValue
        }
        if let paneContext {
            userInfo["paneContextScope"] = paneContext.scope.rawValue
            if let path = paneContext.path {
                userInfo["paneContextPath"] = path
            }
            if let home = paneContext.home {
                userInfo["paneContextHome"] = home
            }
            if let user = paneContext.user {
                userInfo["paneContextUser"] = user
            }
            if let host = paneContext.host {
                userInfo["paneContextHost"] = host
            }
        }
        if let toolName {
            userInfo["toolName"] = toolName
        }
        if let text {
            userInfo["text"] = text
        }
        if let artifactKind {
            userInfo["artifactKind"] = artifactKind.rawValue
        }
        if let artifactLabel {
            userInfo["artifactLabel"] = artifactLabel
        }
        if let artifactURL {
            userInfo["artifactURL"] = artifactURL.absoluteString
        }
        return userInfo
    }

    init(
        workspaceID: WorkspaceID,
        paneID: PaneID,
        signalKind: AgentSignalKind = .lifecycle,
        state: PaneAgentState?,
        shellActivityState: PaneShellActivityState? = nil,
        pid: Int32? = nil,
        pidEvent: AgentPIDSignalEvent? = nil,
        paneContext: PaneShellContext? = nil,
        origin: AgentSignalOrigin = .compatibility,
        toolName: String?,
        text: String?,
        artifactKind: WorkspaceArtifactKind?,
        artifactLabel: String?,
        artifactURL: URL?
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.signalKind = signalKind
        self.state = state
        self.shellActivityState = shellActivityState
        self.pid = pid
        self.pidEvent = pidEvent
        self.paneContext = paneContext
        self.origin = origin
        self.toolName = toolName
        self.text = text
        self.artifactKind = artifactKind
        self.artifactLabel = artifactLabel
        self.artifactURL = artifactURL
    }

    init(userInfo: [AnyHashable: Any]) throws {
        guard
            let workspaceID = userInfo["workspaceID"] as? String,
            let paneID = userInfo["paneID"] as? String
        else {
            throw AgentStatusPayloadError.invalidNotificationPayload
        }

        let signalKind = (userInfo["kind"] as? String).flatMap(AgentSignalKind.init(rawValue:)) ?? .lifecycle
        let state = (userInfo["state"] as? String).flatMap(PaneAgentState.init(rawValue:))
        let shellActivityState = (userInfo["shellActivityState"] as? String)
            .flatMap(PaneShellActivityState.init(rawValue:))
        let pid = (userInfo["pid"] as? NSNumber)?.int32Value
        let pidEvent = (userInfo["pidEvent"] as? String).flatMap(AgentPIDSignalEvent.init(rawValue:))
        let paneContext = (userInfo["paneContextScope"] as? String)
            .flatMap(PaneShellContextScope.init(rawValue:))
            .map {
                PaneShellContext(
                    scope: $0,
                    path: userInfo["paneContextPath"] as? String,
                    home: userInfo["paneContextHome"] as? String,
                    user: userInfo["paneContextUser"] as? String,
                    host: userInfo["paneContextHost"] as? String
                )
            }
        let artifactURL = (userInfo["artifactURL"] as? String).flatMap(URL.init(string:))

        self.init(
            workspaceID: WorkspaceID(workspaceID),
            paneID: PaneID(paneID),
            signalKind: signalKind,
            state: state,
            shellActivityState: shellActivityState,
            pid: pid,
            pidEvent: pidEvent,
            paneContext: paneContext,
            origin: (userInfo["origin"] as? String).flatMap(AgentSignalOrigin.init(rawValue:)) ?? .compatibility,
            toolName: userInfo["toolName"] as? String,
            text: userInfo["text"] as? String,
            artifactKind: (userInfo["artifactKind"] as? String).flatMap(WorkspaceArtifactKind.init(rawValue:)),
            artifactLabel: userInfo["artifactLabel"] as? String,
            artifactURL: artifactURL
        )
    }
}

struct AgentStatusCommand {
    let payload: AgentStatusPayload

    static func parse(arguments: [String], environment: [String: String]) throws -> AgentStatusCommand {
        let trimmedArguments: ArraySlice<String>
        if arguments.dropFirst().first == "agent-status" {
            trimmedArguments = arguments.dropFirst(2)
        } else {
            trimmedArguments = arguments.dropFirst()
        }

        guard let verb = trimmedArguments.first else {
            throw AgentStatusPayloadError.invalidArguments("Missing status verb.")
        }

        let state: PaneAgentState?
        switch verb {
        case PaneAgentState.running.rawValue:
            state = .running
        case PaneAgentState.needsInput.rawValue:
            state = .needsInput
        case PaneAgentState.completed.rawValue:
            state = .completed
        case "clear":
            state = nil
        default:
            throw AgentStatusPayloadError.invalidArguments("Unsupported status verb: \(verb)")
        }

        let options = try parseOptions(Array(trimmedArguments.dropFirst()))
        guard let workspaceID = options["workspace-id"] ?? environment["ZENTTY_WORKSPACE_ID"] else {
            throw AgentStatusPayloadError.missingWorkspaceID
        }
        guard let paneID = options["pane-id"] ?? environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }

        return AgentStatusCommand(
            payload: AgentStatusPayload(
                workspaceID: WorkspaceID(workspaceID),
                paneID: PaneID(paneID),
                signalKind: .lifecycle,
                state: state,
                origin: .compatibility,
                toolName: options["tool"],
                text: options["text"],
                artifactKind: options["artifact-kind"].flatMap(WorkspaceArtifactKind.init(rawValue:)),
                artifactLabel: options["artifact-label"],
                artifactURL: try parseArtifactURL(from: options["artifact-url"])
            )
        )
    }

    fileprivate static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var index = 0
        var options: [String: String] = [:]

        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw AgentStatusPayloadError.invalidArguments("Unexpected argument: \(key)")
            }
            let optionName = String(key.dropFirst(2))
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else {
                throw AgentStatusPayloadError.invalidArguments("Missing value for \(key)")
            }
            options[optionName] = arguments[valueIndex]
            index += 2
        }

        return options
    }

    fileprivate static func parseArtifactURL(from rawValue: String?) throws -> URL? {
        guard let rawValue else {
            return nil
        }
        guard let url = URL(string: rawValue) else {
            throw AgentStatusPayloadError.invalidArtifactURL(rawValue)
        }
        return url
    }
}

struct AgentSignalCommand {
    let payload: AgentStatusPayload

    static func parse(arguments: [String], environment: [String: String]) throws -> AgentSignalCommand {
        let trimmedArguments: ArraySlice<String>
        if arguments.dropFirst().first == "agent-signal" {
            trimmedArguments = arguments.dropFirst(2)
        } else {
            trimmedArguments = arguments.dropFirst()
        }

        guard let rawKind = trimmedArguments.first,
              let kind = AgentSignalKind(rawValue: rawKind) else {
            throw AgentStatusPayloadError.invalidArguments("Missing or invalid signal kind.")
        }

        let (positionals, options) = try parsePositionalsAndOptions(Array(trimmedArguments.dropFirst()))
        guard let workspaceID = options["workspace-id"] ?? environment["ZENTTY_WORKSPACE_ID"] else {
            throw AgentStatusPayloadError.missingWorkspaceID
        }
        guard let paneID = options["pane-id"] ?? environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }

        let origin = options["origin"].flatMap(AgentSignalOrigin.init(rawValue:)) ?? defaultOrigin(for: kind)

        switch kind {
        case .lifecycle:
            guard let verb = positionals.first else {
                throw AgentStatusPayloadError.missingState
            }

            let state: PaneAgentState?
            switch verb {
            case PaneAgentState.running.rawValue:
                state = .running
            case PaneAgentState.needsInput.rawValue:
                state = .needsInput
            case PaneAgentState.completed.rawValue:
                state = .completed
            case "clear":
                state = nil
            default:
                throw AgentStatusPayloadError.invalidArguments("Unsupported lifecycle state: \(verb)")
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .lifecycle,
                    state: state,
                    origin: origin,
                    toolName: options["tool"],
                    text: options["text"],
                    artifactKind: options["artifact-kind"].flatMap(WorkspaceArtifactKind.init(rawValue:)),
                    artifactLabel: options["artifact-label"],
                    artifactURL: try AgentStatusCommand.parseArtifactURL(from: options["artifact-url"])
                )
            )
        case .shellState:
            guard let rawState = positionals.first else {
                throw AgentStatusPayloadError.invalidArguments("Missing shell state.")
            }

            let shellActivityState: PaneShellActivityState
            switch rawState {
            case "prompt", "idle":
                shellActivityState = .promptIdle
            case "running", "busy", "command":
                shellActivityState = .commandRunning
            case "clear", "unknown":
                shellActivityState = .unknown
            default:
                throw AgentStatusPayloadError.invalidArguments("Unsupported shell state: \(rawState)")
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .shellState,
                    state: nil,
                    shellActivityState: shellActivityState,
                    origin: origin,
                    toolName: options["tool"],
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                )
            )
        case .pid:
            guard let rawEvent = positionals.first,
                  let pidEvent = AgentPIDSignalEvent(rawValue: rawEvent) else {
                throw AgentStatusPayloadError.invalidArguments("Missing or invalid pid event.")
            }

            let pid: Int32?
            switch pidEvent {
            case .attach:
                guard positionals.count >= 2,
                      let parsedPID = Int32(positionals[1]),
                      parsedPID > 0 else {
                    throw AgentStatusPayloadError.missingPID
                }
                pid = parsedPID
            case .clear:
                pid = nil
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .pid,
                    state: nil,
                    pid: pid,
                    pidEvent: pidEvent,
                    origin: origin,
                    toolName: options["tool"],
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                )
            )
        case .paneContext:
            guard let rawScope = positionals.first else {
                throw AgentStatusPayloadError.invalidArguments("Missing pane context scope.")
            }

            if rawScope == "clear" {
                return AgentSignalCommand(
                    payload: AgentStatusPayload(
                        workspaceID: WorkspaceID(workspaceID),
                        paneID: PaneID(paneID),
                        signalKind: .paneContext,
                        state: nil,
                        paneContext: nil,
                        origin: origin,
                        toolName: nil,
                        text: nil,
                        artifactKind: nil,
                        artifactLabel: nil,
                        artifactURL: nil
                    )
                )
            }

            guard let scope = PaneShellContextScope(rawValue: rawScope) else {
                throw AgentStatusPayloadError.invalidArguments("Unsupported pane context scope: \(rawScope)")
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .paneContext,
                    state: nil,
                    paneContext: PaneShellContext(
                        scope: scope,
                        path: options["path"],
                        home: options["home"],
                        user: options["user"],
                        host: options["host"]
                    ),
                    origin: origin,
                    toolName: nil,
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                )
            )
        }
    }

    private static func parsePositionalsAndOptions(_ arguments: [String]) throws -> ([String], [String: String]) {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let optionName = String(argument.dropFirst(2))
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw AgentStatusPayloadError.invalidArguments("Missing value for \(argument)")
                }
                options[optionName] = arguments[valueIndex]
                index += 2
            } else {
                positionals.append(argument)
                index += 1
            }
        }

        return (positionals, options)
    }

    private static func defaultOrigin(for kind: AgentSignalKind) -> AgentSignalOrigin {
        switch kind {
        case .lifecycle:
            return .compatibility
        case .shellState:
            return .shell
        case .pid:
            return .explicitAPI
        case .paneContext:
            return .shell
        }
    }
}

enum AgentStatusTransport {
    static let notificationName = Notification.Name("com.peterdedene.zentty.agent-status")
}

enum AgentStatusHelper {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        let subcommand = arguments.dropFirst().first
        guard subcommand == "agent-status" || subcommand == "agent-signal" else {
            return nil
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
                "zentty-agent-wrapper",
                "claude",
                "codex",
                "opencode",
            ],
            executableRelativePaths: [
                "zentty-agent-wrapper",
                "claude",
                "codex",
                "opencode",
            ]
        )
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

    fileprivate static func post(_ payload: AgentStatusPayload) {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            AgentStatusTransport.notificationName,
            object: nil,
            userInfo: payload.notificationUserInfo,
            deliverImmediately: true
        )
    }

    fileprivate static func writeError(_ error: Error) {
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

enum AgentInteractionClassifier {
    enum WaitingMessageSpecificity: Int, Comparable {
        case generic = 0
        case approval = 1
        case specific = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    static func requiresHumanInput(message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        let markers = [
            "waiting for your input",
            "needs your input",
            "needs your attention",
            "permission",
            "approve",
            "approval",
            "allow ",
            "confirm",
            "select ",
            "choose ",
            "grant access",
            "press enter",
            "log in",
            "login",
        ]

        return markers.contains { message.contains($0) }
    }

    static func isGenericNeedsInputMessage(_ message: String?) -> Bool {
        guard let message = normalized(message) else {
            return false
        }

        return [
            "claude needs your input",
            "claude is waiting for your input",
            "claude needs your attention",
        ].contains(message)
    }

    static func specificity(forWaitingMessage message: String?) -> WaitingMessageSpecificity? {
        guard let normalized = normalized(message) else {
            return nil
        }

        if isGenericNeedsInputMessage(normalized) {
            return .generic
        }

        let approvalMarkers = [
            "permission",
            "approve",
            "approval",
            "allow ",
            "grant access",
        ]
        if approvalMarkers.contains(where: normalized.contains) {
            return .approval
        }

        if requiresHumanInput(message: normalized) {
            return .specific
        }

        return nil
    }

    static func preferredWaitingMessage(existing: String?, candidate: String?) -> String? {
        let existingTrimmed = trimmed(existing)
        let candidateTrimmed = trimmed(candidate)

        guard let candidateTrimmed else {
            return existingTrimmed
        }
        guard let existingTrimmed else {
            return candidateTrimmed
        }

        let existingSpecificity = specificity(forWaitingMessage: existingTrimmed) ?? .generic
        let candidateSpecificity = specificity(forWaitingMessage: candidateTrimmed) ?? .generic

        if candidateSpecificity > existingSpecificity {
            return candidateTrimmed
        }

        return existingTrimmed
    }

    static func trimmed(_ message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return nil
        }
        return message
    }

    private static func normalized(_ message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return nil
        }
        return message.lowercased()
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

@MainActor
final class AgentStatusCenter: NSObject {
    var onPayload: ((AgentStatusPayload) -> Void)?

    private let center: DistributedNotificationCenter
    private var hasStarted = false

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
        super.init()
    }

    func start() {
        guard !hasStarted else {
            return
        }

        center.addObserver(
            self,
            selector: #selector(handleDistributedNotification(_:)),
            name: AgentStatusTransport.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        hasStarted = true
    }

    deinit {
        if hasStarted {
            center.removeObserver(
                self,
                name: AgentStatusTransport.notificationName,
                object: nil
            )
        }
    }

    @objc
    private func handleDistributedNotification(_ notification: Notification) {
        handle(notification: notification)
    }

    private func handle(notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }

        guard let payload = try? AgentStatusPayload(userInfo: userInfo) else {
            return
        }

        Task { @MainActor [weak self] in
            self?.onPayload?(payload)
        }
    }
}

@MainActor
protocol WorkspaceAttentionUserNotificationCenter: AnyObject {
    func requestAuthorizationIfNeeded()
    func add(identifier: String, title: String, body: String)
}

@MainActor
final class WorkspaceAttentionNotificationCoordinator {
    private let center: any WorkspaceAttentionUserNotificationCenter
    private var lastSeenStates: [WorkspaceID: WorkspaceAttentionState] = [:]

    init(center: any WorkspaceAttentionUserNotificationCenter = WorkspaceAttentionUNCenter()) {
        self.center = center
        center.requestAuthorizationIfNeeded()
    }

    func update(
        workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID,
        windowIsKey: Bool
    ) {
        var nextSeenStates: [WorkspaceID: WorkspaceAttentionState] = [:]

        for workspace in workspaces {
            guard let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace) else {
                continue
            }

            nextSeenStates[workspace.id] = attention.state
            let didChange = lastSeenStates[workspace.id] != attention.state
            let shouldNotify = (workspace.id != activeWorkspaceID) || !windowIsKey
            let isNotifyable = attention.requiresHumanAttention
            guard didChange, shouldNotify, isNotifyable else {
                continue
            }

            center.add(
                identifier: "\(workspace.id.rawValue)-\(attention.state.rawValue)-\(attention.updatedAt.timeIntervalSince1970)",
                title: attention.statusText,
                body: attention.primaryText
            )
        }

        lastSeenStates = nextSeenStates
    }
}

@MainActor
final class WorkspaceAttentionUNCenter: NSObject, WorkspaceAttentionUserNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else {
            return
        }

        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func add(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
