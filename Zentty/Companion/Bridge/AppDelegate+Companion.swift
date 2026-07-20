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
