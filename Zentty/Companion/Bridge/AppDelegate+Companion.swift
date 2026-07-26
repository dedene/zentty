import AppKit
import Foundation
import OSLog

private let companionLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionBridge")

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
                let panes: [CompanionPaneSummary] = worklane.paneStripState.panes.map { pane in
                    let auxiliary = worklane.auxiliaryStateByPaneID[pane.id]
                    let title = WorklaneContextFormatter.trimmed(pane.customTitle) ?? pane.title
                    guard let status = auxiliary?.agentStatus else {
                        // Plain terminal pane (no agent): still listed so the phone
                        // mirrors the sidebar; it gets terminal-only affordances
                        // (no tool, no transcript) and never demands attention.
                        return CompanionDashboardMapping.plainSummary(
                            paneID: pane.id.rawValue,
                            worklaneID: worklane.id.rawValue,
                            title: title,
                            workingDirectory: auxiliary?.presentation.cwd ?? ""
                        )
                    }
                    return CompanionDashboardMapping.summary(
                        paneID: pane.id.rawValue,
                        worklaneID: worklane.id.rawValue,
                        title: title,
                        status: status
                    )
                }
                // Only the user-set worklane title travels; the phone hides the
                // header label when it is empty rather than showing a derived one.
                let title = WorklaneContextFormatter.trimmed(worklane.title) ?? ""
                return CompanionDashboardWorklane(
                    id: worklane.id.rawValue,
                    title: title,
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

    /// Injects a named key as a real key event (not pasted text) so cursor-key
    /// CSI keeps its `ESC` and Return submits. See `CompanionInputSink`.
    func companionSendKey(_ key: TerminalSpecialKey, toPaneId paneId: String) -> Bool {
        let paneID = PaneID(paneId)
        guard let controller = windowController(containingPane: paneID) else { return false }
        return controller.sendSpecialKey(key, to: paneID)
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

    /// Resolves the pane and pins/unpins its render keepalive so a mirrored pane
    /// keeps repainting even when occluded (backgrounded, or under a control-lease
    /// placeholder). A no-op when the pane is unknown or has no live runtime.
    func companionSetPaneRenderKeepAlive(paneId: String, active: Bool) {
        let paneID = PaneID(paneId)
        windowController(containingPane: paneID)?.setCompanionRenderKeepAlive(active, for: paneID)
    }
}

// MARK: - Pane raw-PTY byte source

extension AppDelegate: CompanionPaneBytesProviding {
    /// Resolves the pane and installs (or removes) its libghostty PTY tee, so the
    /// byte lane streams the exact bytes the child process wrote.
    ///
    /// Returns whether the install actually landed. The feed only records a pane
    /// as streaming on `true`, so a pane that could not be resolved yet (one in a
    /// window still being restored, say) is retried on the next attach instead of
    /// being remembered as installed — which would leave the phone with a valid
    /// attach reply and then silence forever, since the phone's recovery is only
    /// ever triggered by an arriving chunk.
    @discardableResult
    func companionSetPaneByteStream(paneId: String, onBytes: CompanionPaneBytesStreamSink?) -> Bool {
        let paneID = PaneID(paneId)
        guard let controller = windowController(containingPane: paneID) else {
            // Only worth reporting for an install; a removal for a pane that is
            // already gone is the normal teardown ordering.
            if onBytes != nil {
                companionLogger.error(
                    "No window controller for pane \(paneId, privacy: .public); byte stream not installed"
                )
            }
            return false
        }
        guard let onBytes else {
            controller.setCompanionByteStream(nil, for: paneID)
            return true
        }
        return controller.setCompanionByteStream({ epoch, seq, bytes in
            onBytes(epoch, seq, bytes)
        }, for: paneID)
    }

    /// Resolves the pane and captures its screen as replayable VT bytes, so a
    /// phone attaching mid-session repaints from a real screen instead of a byte
    /// tail that starts mid-escape-sequence.
    func companionCapturePaneSnapshot(paneId: String) -> CompanionPaneSnapshot? {
        let paneID = PaneID(paneId)
        guard let controller = windowController(containingPane: paneID),
              let snapshot = controller.captureCompanionScreenSnapshot(from: paneID)
        else {
            return nil
        }
        return CompanionPaneSnapshot(
            data: snapshot.data,
            seq: snapshot.seq,
            cols: snapshot.cols,
            rows: snapshot.rows,
            epoch: snapshot.epoch
        )
    }
}
