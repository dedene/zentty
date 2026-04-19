import Foundation

enum AgentIPCProtocol {
    static let version = 1
    static let selfPIDPlaceholder = "__ZENTTY_SELF_PID__"
}

enum AgentIPCRequestKind: String, Codable, Equatable {
    case ipc
    case bootstrap
    case pane
    case discover
}

enum AgentBootstrapTool: String, Codable, Equatable {
    case claude
    case codex
    case copilot
    case gemini
    case opencode
}

struct AgentIPCRequest: Codable, Equatable {
    let version: Int
    let id: String
    let kind: AgentIPCRequestKind
    let arguments: [String]
    let standardInput: String?
    let environment: [String: String]
    let expectsResponse: Bool
    let subcommand: String?
    let tool: AgentBootstrapTool?

    init(
        version: Int = AgentIPCProtocol.version,
        id: String = UUID().uuidString,
        kind: AgentIPCRequestKind,
        arguments: [String],
        standardInput: String?,
        environment: [String: String],
        expectsResponse: Bool,
        subcommand: String? = nil,
        tool: AgentBootstrapTool? = nil
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.expectsResponse = expectsResponse
        self.subcommand = subcommand
        self.tool = tool
    }

}

struct AgentLaunchAction: Codable, Equatable {
    let subcommand: String
    let arguments: [String]
    let standardInput: String?
}

struct AgentLaunchPlan: Codable, Equatable {
    let executablePath: String
    let arguments: [String]
    let setEnvironment: [String: String]
    let unsetEnvironment: [String]
    let preLaunchActions: [AgentLaunchAction]
}

struct PaneListEntry: Codable, Equatable {
    let index: Int
    let id: String
    let column: Int
    let title: String
    let workingDirectory: String?
    let isFocused: Bool
    let agentTool: String?
    let agentStatus: String?
}

struct DiscoveredWindow: Codable, Equatable {
    let id: String
    let order: Int
    let isFocused: Bool
    let worklaneCount: Int
    let paneCount: Int
}

struct DiscoveredWorklane: Codable, Equatable {
    let id: String
    let windowID: String
    let order: Int
    let title: String?
    let isFocused: Bool
    let paneCount: Int
    let columnCount: Int
    let focusedPaneID: String?
}

struct DiscoveredPane: Codable, Equatable {
    let id: String
    let windowID: String
    let worklaneID: String
    let index: Int
    let column: Int
    let title: String
    let workingDirectory: String?
    let isFocused: Bool
    let agentTool: String?
    let agentStatus: String?
    let controlToken: String?
}

struct AgentIPCResponseResult: Codable, Equatable {
    let launchPlan: AgentLaunchPlan?
    let paneList: [PaneListEntry]?
    let discoveredWindows: [DiscoveredWindow]?
    let discoveredWorklanes: [DiscoveredWorklane]?
    let discoveredPanes: [DiscoveredPane]?

    init(
        launchPlan: AgentLaunchPlan? = nil,
        paneList: [PaneListEntry]? = nil,
        discoveredWindows: [DiscoveredWindow]? = nil,
        discoveredWorklanes: [DiscoveredWorklane]? = nil,
        discoveredPanes: [DiscoveredPane]? = nil
    ) {
        self.launchPlan = launchPlan
        self.paneList = paneList
        self.discoveredWindows = discoveredWindows
        self.discoveredWorklanes = discoveredWorklanes
        self.discoveredPanes = discoveredPanes
    }
}

struct AgentIPCResponseError: Codable, Equatable {
    let code: String
    let message: String
}

struct AgentIPCResponse: Codable, Equatable {
    let version: Int
    let id: String
    let ok: Bool
    let result: AgentIPCResponseResult?
    let error: AgentIPCResponseError?

    init(
        version: Int = AgentIPCProtocol.version,
        id: String,
        ok: Bool,
        result: AgentIPCResponseResult? = nil,
        error: AgentIPCResponseError? = nil
    ) {
        self.version = version
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}
