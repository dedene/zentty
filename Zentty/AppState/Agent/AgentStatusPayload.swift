import Foundation

enum AgentStatusPayloadError: Error {
    case missingPaneID
    case missingPID
    case missingWorklaneID
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

struct AgentStatusPayload: Equatable, Sendable {
    let worklaneID: WorklaneID
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
    let lifecycleEvent: AgentLifecycleEvent?
    let interactionKind: PaneAgentInteractionKind?
    let confidence: AgentSignalConfidence?
    let sessionID: String?
    let parentSessionID: String?
    let artifactKind: WorklaneArtifactKind?
    let artifactLabel: String?
    let artifactURL: URL?
    let agentWorkingDirectory: String?

    var clearsStatus: Bool {
        signalKind == .lifecycle && state == nil
    }

    var clearsPaneContext: Bool {
        signalKind == .paneContext && paneContext == nil
    }

    var notificationUserInfo: [AnyHashable: Any]? {
        var userInfo: [AnyHashable: Any] = [
            "worklaneID": worklaneID.rawValue,
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
            if let gitBranch = paneContext.gitBranch {
                userInfo["paneContextGitBranch"] = gitBranch
            }
        }
        if let toolName {
            userInfo["toolName"] = toolName
        }
        if let text {
            userInfo["text"] = text
        }
        if let lifecycleEvent {
            userInfo["lifecycleEvent"] = lifecycleEvent.rawValue
        }
        if let interactionKind {
            userInfo["interactionKind"] = interactionKind.rawValue
        }
        if let confidence {
            userInfo["confidence"] = confidence.rawValue
        }
        if let sessionID {
            userInfo["sessionID"] = sessionID
        }
        if let parentSessionID {
            userInfo["parentSessionID"] = parentSessionID
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
        if let agentWorkingDirectory {
            userInfo["agentWorkingDirectory"] = agentWorkingDirectory
        }
        return userInfo
    }

    init(
        worklaneID: WorklaneID,
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
        lifecycleEvent: AgentLifecycleEvent? = nil,
        interactionKind: PaneAgentInteractionKind? = nil,
        confidence: AgentSignalConfidence? = nil,
        sessionID: String? = nil,
        parentSessionID: String? = nil,
        artifactKind: WorklaneArtifactKind?,
        artifactLabel: String?,
        artifactURL: URL?,
        agentWorkingDirectory: String? = nil
    ) {
        self.worklaneID = worklaneID
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
        self.lifecycleEvent = lifecycleEvent
        self.interactionKind = interactionKind
        self.confidence = confidence
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.artifactKind = artifactKind
        self.artifactLabel = artifactLabel
        self.artifactURL = artifactURL
        self.agentWorkingDirectory = agentWorkingDirectory
    }

    init(userInfo: [AnyHashable: Any]) throws {
        guard
            let worklaneID = userInfo["worklaneID"] as? String,
            let paneID = userInfo["paneID"] as? String
        else {
            throw AgentStatusPayloadError.invalidNotificationPayload
        }

        let signalKind = (userInfo["kind"] as? String).flatMap(AgentSignalKind.init(rawValue:)) ?? .lifecycle
        let state = (userInfo["state"] as? String).flatMap(PaneAgentState.transportValue(_:))
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
                    host: userInfo["paneContextHost"] as? String,
                    gitBranch: userInfo["paneContextGitBranch"] as? String
                )
            }
        let artifactURL = (userInfo["artifactURL"] as? String).flatMap(URL.init(string:))

        self.init(
            worklaneID: WorklaneID(worklaneID),
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
            lifecycleEvent: (userInfo["lifecycleEvent"] as? String).flatMap(AgentLifecycleEvent.init(rawValue:)),
            interactionKind: (userInfo["interactionKind"] as? String).flatMap(PaneAgentInteractionKind.init(rawValue:)),
            confidence: (userInfo["confidence"] as? String).flatMap(AgentSignalConfidence.init(rawValue:)),
            sessionID: userInfo["sessionID"] as? String,
            parentSessionID: userInfo["parentSessionID"] as? String,
            artifactKind: (userInfo["artifactKind"] as? String).flatMap(WorklaneArtifactKind.init(rawValue:)),
            artifactLabel: userInfo["artifactLabel"] as? String,
            artifactURL: artifactURL,
            agentWorkingDirectory: userInfo["agentWorkingDirectory"] as? String
        )
    }
}

enum AgentStatusTransport {
    static let notificationName = Notification.Name("be.zenjoy.zentty.agent-status")
}

private extension PaneAgentState {
    static func transportValue(_ rawValue: String) -> PaneAgentState? {
        switch rawValue {
        case "completed", "idle":
            return .idle
        default:
            return PaneAgentState(rawValue: rawValue)
        }
    }
}
