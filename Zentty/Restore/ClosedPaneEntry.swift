import CoreGraphics
import Foundation

enum PaneCloseSource: Sendable, Equatable {
    case userCommand
    case shellExit
    case cascade
}

struct ClosedPaneAgentSnapshot: Equatable, Sendable {
    let tool: AgentTool
    let toolDisplayName: String
    let sessionID: String?
    let workingDirectory: String?
}

struct ClosedPaneEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let closedAt: Date
    let originalPaneID: PaneID
    let originalWorklaneID: WorklaneID
    let originalColumnID: PaneColumnID
    let originalColumnIndex: Int
    let originalPaneIndex: Int
    /// Width of the column the pane lived in at close time. Restored when
    /// the pane needs a brand-new column (its original column was removed).
    let originalColumnWidth: CGFloat
    /// Height *weight* (not pixels) the pane had within its column at close
    /// time. `paneHeights` in PaneStripState is a proportional weight array;
    /// equal weights mean equal pixel heights. Nil when the pane was the
    /// only one in its column at close (no meaningful intra-column weight).
    let originalHeightInColumn: CGFloat?
    let title: String
    let workingDirectory: String?
    let originalNativeCommand: String?
    let originalCommand: String?
    let agentSnapshot: ClosedPaneAgentSnapshot?
    let scrollbackText: String?

    init(
        id: UUID = UUID(),
        closedAt: Date,
        originalPaneID: PaneID,
        originalWorklaneID: WorklaneID,
        originalColumnID: PaneColumnID,
        originalColumnIndex: Int,
        originalPaneIndex: Int,
        originalColumnWidth: CGFloat,
        originalHeightInColumn: CGFloat?,
        title: String,
        workingDirectory: String?,
        originalNativeCommand: String?,
        originalCommand: String?,
        agentSnapshot: ClosedPaneAgentSnapshot?,
        scrollbackText: String?
    ) {
        self.id = id
        self.closedAt = closedAt
        self.originalPaneID = originalPaneID
        self.originalWorklaneID = originalWorklaneID
        self.originalColumnID = originalColumnID
        self.originalColumnIndex = originalColumnIndex
        self.originalPaneIndex = originalPaneIndex
        self.originalColumnWidth = originalColumnWidth
        self.originalHeightInColumn = originalHeightInColumn
        self.title = title
        self.workingDirectory = workingDirectory
        self.originalNativeCommand = originalNativeCommand
        self.originalCommand = originalCommand
        self.agentSnapshot = agentSnapshot
        self.scrollbackText = scrollbackText
    }
}
