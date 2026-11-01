import AppKit

/// The main window side of the palette: where it shows, the focused pane's project, settings,
/// focus and the toolbar button. `RootViewController` conforms.
@MainActor
protocol AgentHistoryPaletteHost: AnyObject {
    var agentHistoryWindow: NSWindow? { get }
    var agentHistoryBackdropView: CommandPaletteBackdropView { get }
    var agentHistoryTheme: ZenttyTheme { get }
    var agentHistoryWindowID: WindowID { get }
    /// The focused pane's project; nil for a remote pane or one without a directory.
    func agentHistoryCurrentProject() -> AgentHistoryProjectScope?
    func agentHistoryProject(forWorklane id: WorklaneID) -> AgentHistoryProjectScope?
    func agentHistoryShowSettings()
    func agentHistoryRestoreFocus()
    func agentHistorySetToolbarPresented(_ presented: Bool)
    /// Views whose clicks don't dismiss the palette (the toolbar button toggles it).
    func agentHistoryExemptClickViews() -> [NSView]
}

/// Opens, toggles and closes one window's Agent History palette. Each open gets a fresh view
/// model; the services are injected once per window (UI10) and nil until then.
@MainActor
final class AgentHistoryPaletteCoordinator {
    private weak var host: (any AgentHistoryPaletteHost)?
    private let panelController: AgentHistoryPanelController
    private var model: AgentHistoryViewModel?
    private var restoresFocusOnClose = false

    var services: AgentHistoryPaletteServices?

    var isShown: Bool { panelController.isShown }

    init(host: any AgentHistoryPaletteHost, panelController: AgentHistoryPanelController? = nil) {
        self.host = host
        self.panelController = panelController ?? AgentHistoryPanelController()
        self.panelController.onClosed = { [weak self] in
            self?.panelDidClose()
        }
    }

    /// The shortcut, menu and toolbar button: a second press closes the palette.
    func toggle(entryPoint: AgentHistoryEntryPoint) {
        if isShown {
            close(restoreFocus: true)
        } else {
            show(entryPoint: entryPoint)
        }
    }

    /// Opens the palette; reopens it when it shows for another entry point (e.g. a worklane).
    func show(entryPoint: AgentHistoryEntryPoint) {
        if isShown {
            guard model?.context.entryPoint != entryPoint else { return }
            close(restoreFocus: false)
        }
        guard let host, let window = host.agentHistoryWindow else { return }
        guard let services else {
            AgentHistoryLog.indexer.info("Agent History palette requested before its services were wired")
            return
        }

        let worklaneProject: AgentHistoryProjectScope?
        if case .worklaneContextMenu(let worklaneID) = entryPoint {
            worklaneProject = host.agentHistoryProject(forWorklane: worklaneID)
        } else {
            worklaneProject = nil
        }
        let context = Self.openContext(
            entryPoint: entryPoint,
            currentProject: host.agentHistoryCurrentProject(),
            worklaneProject: worklaneProject,
            windowID: host.agentHistoryWindowID
        )
        let theme = host.agentHistoryTheme
        let model = AgentHistoryViewModel(
            context: context,
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: theme)
        )
        model.onRequestClose = { [weak self] restoreFocus in
            self?.close(restoreFocus: restoreFocus)
        }
        model.onRequestSettings = { [weak self] in
            guard let self else { return }
            let host = self.host
            self.close(restoreFocus: false)
            host?.agentHistoryShowSettings()
        }
        model.onRequestFolderPicker = { [weak self, weak model] in
            self?.panelController.presentFolderPicker { urls in
                model?.addExcludedFolders(urls)
            }
        }
        self.model = model

        host.agentHistorySetToolbarPresented(true)
        panelController.show(
            in: window,
            backdropView: host.agentHistoryBackdropView,
            theme: theme,
            model: model,
            exemptClickViews: { [weak host] in host?.agentHistoryExemptClickViews() ?? [] }
        )
    }

    /// `restoreFocus` is false after a launch: the launcher already moved focus.
    func close(restoreFocus: Bool) {
        guard isShown else { return }
        restoresFocusOnClose = restoreFocus
        panelController.close(animated: true)
    }

    func updateTheme(_ theme: ZenttyTheme) {
        panelController.updateTheme(theme)
    }

    /// The worklane menu opens on that worklane's project (all projects when it has none);
    /// every other entry opens on all projects with the focused pane's project one ⇥ away.
    static func openContext(
        entryPoint: AgentHistoryEntryPoint,
        currentProject: AgentHistoryProjectScope?,
        worklaneProject: AgentHistoryProjectScope?,
        windowID: WindowID
    ) -> AgentHistoryOpenContext {
        let initialScope: AgentHistoryScope
        if case .worklaneContextMenu = entryPoint, let worklaneProject {
            initialScope = .project(worklaneProject)
        } else {
            initialScope = .all
        }
        return AgentHistoryOpenContext(
            entryPoint: entryPoint,
            currentProject: currentProject,
            initialScope: initialScope,
            hostWindowID: windowID
        )
    }

    private func panelDidClose() {
        let restoreFocus = restoresFocusOnClose
        restoresFocusOnClose = false
        model = nil
        host?.agentHistorySetToolbarPresented(false)
        if restoreFocus {
            host?.agentHistoryRestoreFocus()
        }
    }
}

#if DEBUG
extension AgentHistoryPaletteCoordinator {
    var modelForTesting: AgentHistoryViewModel? { model }
    var panelControllerForTesting: AgentHistoryPanelController { panelController }
}
#endif
