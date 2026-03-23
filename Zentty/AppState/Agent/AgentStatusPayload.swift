import Foundation

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
                    host: userInfo["paneContextHost"] as? String,
                    gitBranch: userInfo["paneContextGitBranch"] as? String
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

enum AgentStatusTransport {
    static let notificationName = Notification.Name("com.peterdedene.zentty.agent-status")
}
