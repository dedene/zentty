import Foundation

struct MenuBarPaneSnapshot: Equatable, Sendable {
    let windowID: WindowID
    let windowTitle: String
    let worklaneID: WorklaneID
    let paneID: PaneID
    let agentTool: AgentTool
    let primaryText: String
    let contextText: String?
    let statusLabel: String
    let attentionState: WorklaneAttentionState?
    let fleetState: MenuBarFleetState
    let updatedAt: Date
    let taskProgress: PaneAgentTaskProgress?
    let sortPriority: Int
}
