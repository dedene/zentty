import AppKit
import SwiftUI

@MainActor
final class CommandPaletteController {
    private var panel: CommandPalettePanel?
    private var hostingView: NSHostingView<CommandPaletteView>?
    private var glassSurface: GlassSurfaceView?
    private weak var backdropView: CommandPaletteBackdropView?
    private weak var parentWindow: NSWindow?
    private var clickMonitor: Any?
    private var recentCommands = RecentCommandsTracker()
    private var lastFocusedPanePath: String?
    private var taskRunnerActionsByID: [String: TaskRunnerAction] = [:]
    var onExecute: ((AppAction) -> Void)?
    var onOpenWith: ((_ stableID: String, _ workingDirectory: String) -> Void)?
    var onOpenServer: ((_ serverID: String) -> Void)?
    var onRunTaskRunner: ((TaskRunnerAction) -> Void)?
    var onOpenTaskRunnerSource: ((_ sourcePath: String) -> Void)?
    var onSetWorklaneColor: ((WorklaneColor?) -> Void)?
    var onShowSettingsSection: ((SettingsSection) -> Void)?
    var onNavigateToPane: ((WorklaneID, PaneID) -> Void)?
    var onRunRestoredCommand: ((PaneID) -> Void)?

    var isShown: Bool { panel != nil }

    // Availability depends on focused-pane state for pane-local search commands.
    func show(
        in window: NSWindow,
        backdropView: CommandPaletteBackdropView,
        theme: ZenttyTheme,
        shortcutManager: ShortcutManager,
        availabilityContext: CommandAvailabilityContext,
        focusedPanePath: String?,
        focusedBranchName: String?,
        focusedRestoredCommand: String? = nil,
        worklanes: [WorklaneState] = [],
        currentPaneReference: WorklaneStore.PaneReference? = nil,
        recentPaneReferences: [WorklaneStore.PaneReference] = [],
        openWithTargets: [OpenWithResolvedTarget] = [],
        openWithIconProvider: ((OpenWithResolvedTarget) -> NSImage?)? = nil,
        rightPaneCommandPresentation: PaneRightCommandPresentation = .addsToWorklane,
        servers: [DetectedServer] = [],
        taskRunnerActions: [TaskRunnerAction] = []
    ) {
        if isShown {
            close()
            return
        }

        lastFocusedPanePath = focusedPanePath
        taskRunnerActionsByID = Dictionary(taskRunnerActions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let availableIDs = CommandAvailabilityResolver.availableCommandIDs(for: availabilityContext)
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: availableIDs,
            shortcutManager: shortcutManager,
            focusedPanePath: focusedPanePath,
            focusedBranchName: focusedBranchName,
            rightPaneCommandPresentation: rightPaneCommandPresentation
        )
        let openWithItems = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: openWithTargets,
            focusedPanePath: focusedPanePath,
            iconProvider: openWithIconProvider
        )
        let serverItems = CommandPaletteItemBuilder.buildServerItems(servers: servers)
        let taskRunnerItems = CommandPaletteItemBuilder.buildTaskRunnerItems(actions: taskRunnerActions)
        let worklaneColorItems = CommandPaletteItemBuilder.buildWorklaneColorItems()
        let settingsItems = CommandPaletteItemBuilder.buildSettingsItems()
        let paneItems = CommandPaletteItemBuilder.buildPaneItems(
            worklanes: worklanes,
            currentPaneReference: currentPaneReference
        )
        let restoredCommandItem = currentPaneReference.flatMap { reference in
            focusedRestoredCommand.map {
                CommandPaletteItemBuilder.buildRestoredCommandItem(
                    paneID: reference.paneID,
                    command: $0
                )
            }
        }
        let restoredCommandItems = restoredCommandItem.map { [$0] } ?? []
        let allItems = restoredCommandItems
            + commandItems
            + taskRunnerItems
            + paneItems
            + settingsItems
            + openWithItems
            + serverItems
            + worklaneColorItems
        let emptyActionIDs = restoredCommandItems.map(\.id) + Self.emptyActionIDs
        let recentPaneIDs = recentPaneReferences.map {
            CommandPaletteItemID.pane(worklaneID: $0.worklaneID, paneID: $0.paneID)
        }
        let currentPaneID = currentPaneReference.map {
            CommandPaletteItemID.pane(worklaneID: $0.worklaneID, paneID: $0.paneID)
        }

        let recentItems = recentCommands.recentItemIDs.compactMap { itemID in
            allItems.first { $0.id == itemID }
        }
        let initialResults = CommandPaletteResultsResolver.resolve(
            searchText: "",
            items: allItems,
            recentItems: recentItems,
            recentPaneIDs: recentPaneIDs,
            currentPaneID: currentPaneID,
            emptyActionIDs: emptyActionIDs
        )
        let initialPanelHeight = CommandPaletteLayoutMetrics.preferredPanelHeight(results: initialResults)
        let paletteTheme = CommandPaletteTheme(zenttyTheme: theme)

        let view = CommandPaletteView(
            items: allItems,
            recentItems: recentItems,
            recentPaneIDs: recentPaneIDs,
            currentPaneID: currentPaneID,
            emptyActionIDs: emptyActionIDs,
            theme: paletteTheme,
            onExecute: { [weak self] itemID in
                self?.executeItem(itemID)
            },
            onDismiss: { [weak self] in
                self?.close()
            },
            onHeightChange: { [weak self] height in
                self?.resizePanel(to: height)
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = GlassSurfaceView(style: .commandPalette)
        glass.apply(theme: theme, animated: false)

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        containerView.addSubview(glass)
        containerView.addSubview(hosting)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            glass.topAnchor.constraint(equalTo: containerView.topAnchor),
            glass.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: containerView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        let windowFrame = window.frame
        let panelX = windowFrame.midX - CommandPaletteLayoutMetrics.panelWidth / 2
        let panelY = windowFrame.maxY - (windowFrame.height * 0.25) - initialPanelHeight

        let panelFrame = NSRect(
            x: panelX,
            y: panelY,
            width: CommandPaletteLayoutMetrics.panelWidth,
            height: initialPanelHeight
        ).integral

        let newPanel = CommandPalettePanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = containerView

        containerView.frame = NSRect(origin: .zero, size: panelFrame.size)
        glass.frame = containerView.bounds
        hosting.frame = containerView.bounds

        backdropView.apply(theme: theme, animated: false)
        backdropView.setVisible(true, animated: true)

        newPanel.alphaValue = 0
        window.addChildWindow(newPanel, ordered: .above)
        newPanel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        self.panel = newPanel
        self.hostingView = hosting
        self.glassSurface = glass
        self.backdropView = backdropView
        self.parentWindow = window
        installDismissMonitor()
    }

    func close() {
        guard let panel else { return }

        let backdrop = backdropView
        let parentWindow = parentWindow

        self.panel = nil
        self.hostingView = nil
        self.glassSurface = nil
        self.backdropView = nil
        self.parentWindow = nil

        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        backdrop?.setVisible(false, animated: true)

        guard let parentWindow else {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                parentWindow.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        })
    }

    func updateTheme(_ theme: ZenttyTheme) {
        glassSurface?.apply(theme: theme, animated: true)
        backdropView?.apply(theme: theme, animated: true)
    }

    private func executeItem(_ itemID: CommandPaletteItemID) {
        if itemID.shouldRecordAsRecentCommand {
            recentCommands.record(itemID)
        }
        close()

        switch itemID {
        case .command(let commandID):
            let action = AppCommandRegistry.definition(for: commandID).action
            onExecute?(action)
        case .openWith(let stableID):
            guard let path = lastFocusedPanePath else { return }
            onOpenWith?(stableID, path)
        case .server(let serverID):
            onOpenServer?(serverID)
        case .taskRunner(let id):
            guard let action = taskRunnerActionsByID[id] else { return }
            if action.isEnabled {
                onRunTaskRunner?(action)
            } else {
                onOpenTaskRunnerSource?(action.sourcePath)
            }
        case .worklaneColor(let color):
            onSetWorklaneColor?(color)
        case .settings(let section):
            onShowSettingsSection?(section)
        case .pane(let worklaneID, let paneID):
            onNavigateToPane?(worklaneID, paneID)
        case .restoredCommand(let paneID):
            onRunRestoredCommand?(paneID)
        }
    }

    private static let emptyActionIDs: [CommandPaletteItemID] = [
        .command(.newWorklane),
        .command(.splitHorizontally),
        .command(.splitVertically),
        .command(.openSettings),
    ]

    private func installDismissMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            guard event.window !== panel else { return event }
            self.close()
            return event
        }
    }

    private func resizePanel(to targetHeight: CGFloat) {
        guard let panel else { return }

        let clampedHeight = min(CommandPaletteLayoutMetrics.maximumPanelHeight, ceil(targetHeight))
        let currentFrame = panel.frame
        guard abs(currentFrame.height - clampedHeight) > 0.5 else { return }

        let newFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - clampedHeight,
            width: currentFrame.width,
            height: clampedHeight
        ).integral

        guard CommandPaletteLayoutMetrics.dynamicHeightChangeAnimationDuration > 0 else {
            panel.setFrame(newFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = CommandPaletteLayoutMetrics.dynamicHeightChangeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }
}

private extension CommandPaletteItemID {
    var shouldRecordAsRecentCommand: Bool {
        switch self {
        case .pane, .restoredCommand:
            false
        case .command, .openWith, .server, .worklaneColor, .settings:
            true
        case .taskRunner:
            false
        }
    }
}
