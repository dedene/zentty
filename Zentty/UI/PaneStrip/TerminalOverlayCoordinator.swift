import AppKit
import os

private let quickActionOverlayLogger = Logger(subsystem: "be.zenjoy.zentty", category: "QuickActionOverlay")

/// Owns a window's quick-action overlays: opening them on a pane or worklane,
/// keeping them anchored and visible as panes and worklanes change, and
/// answering the focus and close-confirmation questions the rest of the window
/// asks about them. Overlays live outside the worklane store, so nothing else
/// can see them.
@MainActor
final class TerminalOverlayCoordinator {
    private let rootViewController: RootViewController
    private let adapterFactory: (PaneID) -> any TerminalAdapter
    private var sessions: [String: TerminalOverlaySession] = [:]
    private var lastActiveWorklaneID: WorklaneID?

    init(
        rootViewController: RootViewController,
        adapterFactory: @escaping (PaneID) -> any TerminalAdapter
    ) {
        self.rootViewController = rootViewController
        self.adapterFactory = adapterFactory
    }

    private var worklaneStore: WorklaneStore { rootViewController.worklaneStore }

    // MARK: - Commands

    @discardableResult
    func open(on paneID: PaneID, options: PaneOverlayIPCOptions) throws -> String {
        guard let worklaneID = rootViewController.worklaneID(containing: paneID),
              let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }),
              let pane = worklane.paneStripState.panes.first(where: { $0.id == paneID }) else {
            throw TerminalOverlayError.paneNotFound
        }
        guard !sessions.values.contains(where: {
            $0.placement == options.placement &&
                (options.placement == .worklane ? $0.worklaneID == worklaneID : $0.paneID == paneID)
        }) else { throw TerminalOverlayError.alreadyOpen }
        let directory = options.workingDirectory
            ?? worklane.auxiliaryStateByPaneID[paneID]?.shellContext?.path
            ?? pane.sessionRequest.workingDirectory
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw TerminalOverlayError.invalidWorkingDirectory(directory)
            }
        }
        let overlay = TerminalOverlaySession(
            paneID: paneID,
            worklaneID: worklaneID,
            command: options.command,
            workingDirectory: directory,
            wait: options.wait,
            sizePercent: options.sizePercent,
            placement: options.placement,
            environment: { [windowID = worklaneStore.windowID] overlayID in
                WorklaneSessionEnvironment.overlay(
                    windowID: windowID,
                    worklaneID: worklaneID,
                    overlayID: overlayID,
                    processEnvironment: ProcessInfo.processInfo.environment
                )
            },
            adapterFactory: adapterFactory
        )
        overlay.apply(theme: rootViewController.currentWindowTheme)
        overlay.isPresented = options.follow || worklaneID == worklaneStore.activeWorklaneID
        overlay.revealsOnNextNavigation = options.notify && !overlay.isPresented
        let overlayID = overlay.id
        overlay.onClose = { [weak self] in
            self?.sessions.removeValue(forKey: overlayID)
            self?.syncSidebarOverlays()
        }
        overlay.onRestoreFocus = { [weak self] in
            self?.rootViewController.restoreTerminalFocusAfterOverlay()
        }
        overlay.onInfoChanged = { [weak self] in self?.syncSidebarOverlays() }
        sessions[overlay.id] = overlay
        if options.follow {
            focusPane(id: paneID, in: worklaneID)
        }
        syncVisibility()
        try overlay.start()
        // Ghostty's view becomes focusable after its surface starts.
        if options.follow || worklaneID == worklaneStore.activeWorklaneID {
            syncVisibility(focusing: overlay.id)
        }
        return overlay.id
    }

    func toggleQuickAction() {
        guard !rootViewController.isWorklanePeekActive else { return }
        guard let paneID = rootViewController.focusedPaneID() else { return }
        if let overlay = overlay(on: paneID) {
            if overlay.isPresented {
                overlay.hide()
            } else {
                overlay.isPresented = true
                syncVisibility(focusing: overlay.id)
            }
            return
        }
        let options = PaneOverlayIPCOptions(
            command: "", workingDirectory: nil, wait: false,
            follow: false, notify: false, sizePercent: 100
        )
        do {
            try open(on: paneID, options: options)
        } catch {
            quickActionOverlayLogger.error("Could not open quick action overlay: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    func show(on paneID: PaneID) throws {
        guard let overlay = overlay(on: paneID) else { throw TerminalOverlayError.notOpen }
        focusPane(id: paneID, in: overlay.worklaneID)
        overlay.isPresented = true
        syncVisibility(focusing: overlay.id)
    }

    func close(on paneID: PaneID) throws {
        guard let overlay = overlay(on: paneID) else { throw TerminalOverlayError.notOpen }
        overlay.close()
    }

    func closeAll() {
        for overlay in Array(sessions.values) {
            overlay.close(restoringFocus: false)
        }
    }

    func listJSON(on paneID: PaneID? = nil) throws -> String {
        struct Entry: Encodable {
            let id: String
            let paneID: String
            let worklaneID: String
            let placement: String
            let exitCode: Int?
        }
        let owner = paneID.flatMap { rootViewController.worklaneID(containing: $0) }
        let entries = sessions.values.filter {
            guard let paneID else { return true }
            return $0.placement == .pane ? $0.paneID == paneID : $0.worklaneID == owner
        }.map {
            Entry(id: $0.id, paneID: $0.paneID.rawValue,
                  worklaneID: $0.worklaneID.rawValue,
                  placement: $0.placement.rawValue, exitCode: $0.exitCode)
        }.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(entries), as: UTF8.self) + "\n"
    }

    /// The overlay a pane-targeted command acts on: the pane's own overlay,
    /// else its worklane's.
    func overlay(on paneID: PaneID) -> TerminalOverlaySession? {
        let owner = rootViewController.worklaneID(containing: paneID)
        return sessions.values.first { $0.placement == .pane && $0.paneID == paneID }
            ?? sessions.values.first { $0.placement == .worklane && $0.worklaneID == owner }
    }

    /// Closes the overlay holding `responder`, so ⌘W closes the overlay rather than the pane under it.
    func closeFocusedOverlay(responder: NSResponder?) -> Bool {
        guard let focusedView = responder as? NSView else { return false }
        for overlay in Array(sessions.values) where !overlay.view.isHiddenOrHasHiddenAncestor {
            if focusedView.isDescendant(of: overlay.view) {
                overlay.close()
                return true
            }
        }
        return false
    }

    /// Shows a `--notify` overlay that was opened out of sight once the user
    /// follows its notification to the pane.
    func revealOverlayAwaitingNavigation(on paneID: PaneID) {
        let owner = rootViewController.worklaneID(containing: paneID)
        guard let overlay = sessions.values.first(where: {
            $0.revealsOnNextNavigation && ($0.placement == .pane ? $0.paneID == paneID : $0.worklaneID == owner)
        }) else { return }
        overlay.isPresented = true
        syncVisibility(focusing: overlay.id)
    }

    func apply(theme: ZenttyTheme) {
        for overlay in sessions.values {
            overlay.apply(theme: theme)
        }
    }

    /// Hands a shell-integration payload sent under an overlay's ID to that
    /// overlay; false when it belongs to a pane.
    func apply(_ payload: AgentStatusPayload) -> Bool {
        guard let overlay = sessions[payload.paneID.rawValue] else { return false }
        overlay.apply(payload)
        return true
    }

    // MARK: - Sidebar

    func selectSidebarOverlay(id: String) -> Bool {
        guard let overlay = sessions[id] else { return false }
        focusPane(id: overlay.paneID, in: overlay.worklaneID)
        overlay.isPresented = true
        syncVisibility(focusing: id)
        return true
    }

    func closeSidebarOverlay(id: String) -> Bool {
        guard let overlay = sessions[id] else { return false }
        overlay.close()
        return true
    }

    private func syncSidebarOverlays() {
        var overlays: [WorklaneID: [WorklaneSidebarOverlay]] = [:]
        for overlay in sessions.values.sorted(by: { $0.id < $1.id }) {
            overlays[overlay.worklaneID, default: []].append(overlay.sidebarOverlay)
        }
        rootViewController.updateSidebarOverlays(overlays)
    }

    // MARK: - Focus

    /// Keeps keyboard focus out of terminals hidden under an overlay: a worklane
    /// overlay that holds focus keeps it, and a pane overlay takes its pane's focus.
    func interceptTerminalFocus(paneID: PaneID) -> Bool {
        let activeWorklaneID = worklaneStore.activeWorklaneID
        let showing = sessions.values.filter { $0.isShowing && $0.worklaneID == activeWorklaneID }
        if showing.contains(where: { $0.placement == .worklane && $0.holdsKeyboardFocus }) {
            return true
        }
        guard let paneOverlay = showing.first(where: { $0.placement == .pane && $0.paneID == paneID }) else {
            return false
        }
        paneOverlay.focusTerminal()
        return true
    }

    // MARK: - Close confirmation

    var anyNeedsCloseConfirmation: Bool {
        sessions.values.contains(where: \.needsCloseConfirmation)
    }

    /// Live overlays that closing `paneID` terminates: its own overlay, plus its
    /// worklane's when it is the worklane's last pane.
    func runningQuickActions(closingWithPane paneID: PaneID) -> [RunningQuickAction] {
        guard let worklaneID = rootViewController.worklaneID(containing: paneID),
              let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }) else {
            return []
        }
        let closesWorklane = worklane.paneStripState.panes.count == 1
        return runningQuickActions {
            $0.placement == .pane ? $0.paneID == paneID : closesWorklane && $0.worklaneID == worklaneID
        }
    }

    /// Live overlays that closing `worklaneID` terminates.
    func runningQuickActions(closingWithWorklane worklaneID: WorklaneID) -> [RunningQuickAction] {
        runningQuickActions { $0.worklaneID == worklaneID }
    }

    private func runningQuickActions(
        where closesWith: (TerminalOverlaySession) -> Bool
    ) -> [RunningQuickAction] {
        sessions.values
            .filter { $0.needsCloseConfirmation && closesWith($0) }
            .sorted { $0.id < $1.id }
            .map(\.runningQuickAction)
    }

    // MARK: - Visibility

    /// Re-anchors overlays to their pane or worklane, closes those whose owner
    /// is gone, and shows only the active worklane's presented overlays.
    func syncVisibility(focusing overlayID: String? = nil) {
        defer { syncSidebarOverlays() }
        let activeWorklaneID = worklaneStore.activeWorklaneID
        let switchedWorklanes = lastActiveWorklaneID != activeWorklaneID
        lastActiveWorklaneID = activeWorklaneID
        guard !sessions.isEmpty else { return }
        for overlay in Array(sessions.values) {
            if overlay.placement == .worklane {
                guard let worklane = worklaneStore.worklanes.first(where: { $0.id == overlay.worklaneID }) else {
                    overlay.close()
                    continue
                }
                if !worklane.paneStripState.panes.contains(where: { $0.id == overlay.paneID }),
                   let replacement = worklane.paneStripState.focusedPaneID {
                    overlay.paneID = replacement
                }
            } else {
                guard let owner = rootViewController.worklaneID(containing: overlay.paneID) else {
                    overlay.close()
                    continue
                }
                overlay.worklaneID = owner
            }
            if switchedWorklanes && overlay.worklaneID != activeWorklaneID {
                overlay.hide(restoringFocus: false)
            }
            let visible = overlay.isPresented && overlay.worklaneID == activeWorklaneID
            let anchor = (visible
                ? rootViewController.quickActionOverlayAnchor(for: overlay.paneID, placement: overlay.placement)
                : nil) ?? rootViewController.quickActionOverlayAnchor(for: overlay.paneID, placement: .worklane)
            overlay.setVisible(visible, anchor: anchor, focus: overlay.id == overlayID)
        }
    }

    private func focusPane(id: PaneID, in worklaneID: WorklaneID) {
        rootViewController.paneCommands.focusPaneByID(id, in: worklaneID)
    }
}
