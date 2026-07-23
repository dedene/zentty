import AppKit
import Foundation

// MARK: - Dashboard state source

extension AppDelegate: CompanionDashboardStateProviding {
    /// Enumerates every window → worklane → pane with an agent status and maps
    /// it to a wire `CompanionDashboardWorklane`. Uses the same discovery walk as
    /// `DiscoveryIPCHandler` (`orderedWindowControllersForDiscovery` →
    /// `discoveryWorkspaceState.worklanes` → `paneStripState.panes`).
    ///
    /// `windowId` carries the window's 1-based display order (like
    /// `DiscoveredWindow.order`), not the opaque `WindowID` string — the wire
    /// type is `Int` and pane/worklane routing already travels by string id.
    func companionDashboardWorklanes() -> [CompanionDashboardWorklane] {
        orderedWindowControllersForDiscovery().flatMap { controller -> [CompanionDashboardWorklane] in
            let windowOrder = controller.windowOrder + 1
            return controller.discoveryWorkspaceState.worklanes.map { worklane in
                let panes: [CompanionPaneSummary] = worklane.paneStripState.panes.compactMap { pane in
                    guard let status = worklane.auxiliaryStateByPaneID[pane.id]?.agentStatus else {
                        return nil
                    }
                    let title = WorklaneContextFormatter.trimmed(pane.customTitle) ?? pane.title
                    return CompanionDashboardMapping.summary(
                        paneID: pane.id.rawValue,
                        worklaneID: worklane.id.rawValue,
                        title: title,
                        status: status
                    )
                }
                return CompanionDashboardWorklane(
                    id: worklane.id.rawValue,
                    title: worklane.title ?? "",
                    windowId: windowOrder,
                    attention: panes.contains { $0.requiresHumanAttention },
                    panes: panes
                )
            }
        }
    }
}

// MARK: - Transcript source

extension AppDelegate: CompanionTranscriptSourceProviding {
    /// Resolves the transcript-locating context for a pane by finding its
    /// `PaneAgentStatus` in the discovery graph. For Claude it also consults the
    /// hook session store for the live transcript path the agent reported (correct
    /// even when the working directory is a symlink); the feed falls back to the
    /// canonical `sessionID` + `workingDirectory` path when no live path is known.
    func companionTranscriptTarget(forPaneId paneId: String) -> CompanionTranscriptTarget? {
        guard let status = companionPaneAgentStatus(forPaneId: paneId) else { return nil }
        return CompanionTranscriptTarget(
            tool: status.tool,
            sessionID: status.sessionID,
            workingDirectory: status.workingDirectory,
            liveTranscriptPath: companionLiveTranscriptPath(for: status)
        )
    }

    private func companionPaneAgentStatus(forPaneId paneId: String) -> PaneAgentStatus? {
        let paneID = PaneID(paneId)
        for controller in orderedWindowControllersForDiscovery() {
            for worklane in controller.discoveryWorkspaceState.worklanes {
                if let status = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus {
                    return status
                }
            }
        }
        return nil
    }

    private func companionLiveTranscriptPath(for status: PaneAgentStatus) -> String? {
        guard status.tool == .claudeCode, let sessionID = status.sessionID else { return nil }
        return try? ClaudeHookSessionStore().lookup(sessionID: sessionID)?.transcriptPath
    }
}

// MARK: - Input sink

extension AppDelegate: CompanionInputSink {
    /// Resolves the pane by id and writes `text` to its live terminal, mirroring
    /// the `TmuxCompatIPCHandler` send path. Returns `false` when the pane is
    /// unknown or has no live runtime.
    func companionSendText(_ text: String, toPaneId paneId: String) -> Bool {
        let paneID = PaneID(paneId)
        guard let controller = windowController(containingPane: paneID) else { return false }
        return controller.sendText(text, to: paneID)
    }
}

// MARK: - Lease takeover applier

extension AppDelegate: CompanionLeaseTakeoverApplying {
    /// Resolves the pane and applies the control-lease takeover to its live
    /// terminal host (fixed grid + occlusion + placeholder). Returns `false` when
    /// the pane is unknown or has no live runtime.
    @discardableResult
    func companionApplyLeaseTakeover(
        paneId: String,
        cols: Int,
        rows: Int,
        deviceName: String,
        onTakeBack: @escaping () -> Void
    ) -> Bool {
        let paneID = PaneID(paneId)
        guard let controller = windowController(containingPane: paneID) else { return false }
        return controller.applyControlLease(
            to: paneID,
            cols: cols,
            rows: rows,
            deviceName: deviceName,
            onTakeBack: onTakeBack
        )
    }

    func companionRestoreLeasedPane(paneId: String) {
        let paneID = PaneID(paneId)
        windowController(containingPane: paneID)?.restoreControlLease(from: paneID)
    }
}

// MARK: - Pane text source

extension AppDelegate: CompanionPaneTextProviding {
    /// Resolves the pane and reads its viewport (or scrollback) text plus live
    /// grid size, mirroring the `TmuxCompatIPCHandler` capture path. Returns `nil`
    /// when the pane is unknown or has no live runtime.
    func companionReadPaneText(
        paneId: String,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> CompanionPaneTextReadout? {
        let paneID = PaneID(paneId)
        guard let controller = windowController(containingPane: paneID),
              let text = controller.readText(
                  from: paneID,
                  includeScrollback: includeScrollback,
                  lineLimit: lineLimit
              )
        else {
            return nil
        }
        let grid = controller.paneGridSize(from: paneID)
        return CompanionPaneTextReadout(
            text: text,
            gridCols: grid?.cols ?? 0,
            gridRows: grid?.rows ?? 0,
            cursorRow: nil
        )
    }
}
