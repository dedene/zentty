import Foundation
import UserNotifications

enum AgentStatusPayloadError: Error {
    case missingPaneID
    case missingWorkspaceID
    case missingState
    case invalidArguments(String)
    case invalidArtifactURL(String)
    case invalidNotificationPayload
    case invalidHookPayload
}

struct AgentStatusPayload: Equatable, Sendable {
    let workspaceID: WorkspaceID
    let paneID: PaneID
    let state: PaneAgentState?
    let toolName: String?
    let text: String?
    let artifactKind: WorkspaceArtifactKind?
    let artifactLabel: String?
    let artifactURL: URL?

    var clearsStatus: Bool {
        state == nil
    }

    var notificationUserInfo: [AnyHashable: Any]? {
        var userInfo: [AnyHashable: Any] = [
            "workspaceID": workspaceID.rawValue,
            "paneID": paneID.rawValue,
        ]
        if let state {
            userInfo["state"] = state.rawValue
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
        state: PaneAgentState?,
        toolName: String?,
        text: String?,
        artifactKind: WorkspaceArtifactKind?,
        artifactLabel: String?,
        artifactURL: URL?
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.state = state
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

        let state = (userInfo["state"] as? String).flatMap(PaneAgentState.init(rawValue:))
        let artifactURL = (userInfo["artifactURL"] as? String).flatMap(URL.init(string:))
        self.init(
            workspaceID: WorkspaceID(workspaceID),
            paneID: PaneID(paneID),
            state: state,
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

        let artifactURL: URL?
        if let rawArtifactURL = options["artifact-url"] {
            guard let url = URL(string: rawArtifactURL) else {
                throw AgentStatusPayloadError.invalidArtifactURL(rawArtifactURL)
            }
            artifactURL = url
        } else {
            artifactURL = nil
        }

        return AgentStatusCommand(
            payload: AgentStatusPayload(
                workspaceID: WorkspaceID(workspaceID),
                paneID: PaneID(paneID),
                state: state,
                toolName: options["tool"],
                text: options["text"],
                artifactKind: options["artifact-kind"].flatMap(WorkspaceArtifactKind.init(rawValue:)),
                artifactLabel: options["artifact-label"],
                artifactURL: artifactURL
            )
        )
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
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
}

enum AgentStatusTransport {
    static let notificationName = Notification.Name("com.peterdedene.zentty.agent-status")
}

enum AgentStatusHelper {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "agent-status" else {
            return nil
        }

        do {
            let command = try AgentStatusCommand.parse(arguments: arguments, environment: environment)
            post(command.payload)
            return EXIT_SUCCESS
        } catch {
            writeError(error)
            return EXIT_FAILURE
        }
    }

    static func binaryPath(in bundle: Bundle = .main) -> String? {
        bundle.executableURL?.path
    }

    static func claudeHookCommand(in bundle: Bundle = .main) -> String? {
        guard let binaryPath = binaryPath(in: bundle) else {
            return nil
        }

        return "\(binaryPath) claude-hook"
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
}

struct ClaudeHookInput: Decodable, Equatable {
    let hookEventName: String
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case message
    }
}

enum ClaudeHookBridge {
    static func runIfNeeded(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == "claude-hook" else {
            return nil
        }

        do {
            let input = try parseInput(readStandardInput())
            if let payload = try makePayload(from: input, environment: environment) {
                AgentStatusHelper.post(payload)
            }
            return EXIT_SUCCESS
        } catch {
            AgentStatusHelper.writeError(error)
            return EXIT_FAILURE
        }
    }

    static func parseInput(_ data: Data) throws -> ClaudeHookInput {
        guard !data.isEmpty else {
            throw AgentStatusPayloadError.invalidHookPayload
        }

        return try JSONDecoder().decode(ClaudeHookInput.self, from: data)
    }

    static func makePayload(
        from input: ClaudeHookInput,
        environment: [String: String]
    ) throws -> AgentStatusPayload? {
        guard let workspaceID = environment["ZENTTY_WORKSPACE_ID"] else {
            throw AgentStatusPayloadError.missingWorkspaceID
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }

        let trimmedMessage = input.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch input.hookEventName {
        case "Notification":
            return AgentStatusPayload(
                workspaceID: WorkspaceID(workspaceID),
                paneID: PaneID(paneID),
                state: .needsInput,
                toolName: AgentTool.claudeCode.displayName,
                text: trimmedMessage?.isEmpty == false ? trimmedMessage : "Claude is waiting for your input",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        case "UserPromptSubmit", "SessionStart", "SubagentStart", "PreToolUse":
            return AgentStatusPayload(
                workspaceID: WorkspaceID(workspaceID),
                paneID: PaneID(paneID),
                state: .running,
                toolName: AgentTool.claudeCode.displayName,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        case "Stop", "SubagentStop":
            return AgentStatusPayload(
                workspaceID: WorkspaceID(workspaceID),
                paneID: PaneID(paneID),
                state: .completed,
                toolName: AgentTool.claudeCode.displayName,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        default:
            return nil
        }
    }

    private static func readStandardInput() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
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

        onPayload?(payload)
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
            let isNotifyable = attention.state == .needsInput || attention.state == .unresolvedStop
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
