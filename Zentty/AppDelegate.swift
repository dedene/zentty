import AppKit
import OSLog
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RestoreSnapshot {
        static let debounceNanoseconds: UInt64 = 350_000_000
    }

    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "SessionRestore")
    private static var isHostedTestMode: Bool {
        CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private let shouldOpenMainWindow: Bool
    private let configStore: AppConfigStore
    private let runtimeRegistryFactory: () -> PaneRuntimeRegistry
    private let appUpdateController: AppUpdateControlling
    private let sessionRestoreStore: SessionRestoreStore
    private let notificationStore = NotificationStore()
    private lazy var paneNotificationCoordinator = PaneNotificationCoordinator(
        notificationStore: notificationStore,
        configStore: configStore
    )
    private var windowControllers: [ObjectIdentifier: MainWindowController] = [:]
    private var aboutWindowController: AboutWindowController?
    private var licensesWindowController: LicensesWindowController?
    private var taskManagerWindowController: TaskManagerWindowController?
    private var menuBarStatusController: MenuBarStatusController?
    private var lastKeyWindowControllerID: ObjectIdentifier?
    private var configObserverID: UUID?
    private var nextWindowIndex = 0
    private var pendingSnapshotSaveTask: Task<Void, Never>?
    private var isLaunchingWorkspace = false
    private let isSessionRestoreEnabled: Bool
    private let restoreErrorReporter: ((String) -> Void)?

    init(
        shouldOpenMainWindow: Bool = true,
        runtimeRegistryFactory: @escaping () -> PaneRuntimeRegistry = { PaneRuntimeRegistry() },
        configStore: AppConfigStore = AppConfigStore(),
        appUpdateController: AppUpdateControlling? = nil,
        sessionRestoreStore: SessionRestoreStore? = nil,
        sessionRestoreEnabled: Bool? = nil,
        restoreErrorReporter: ((String) -> Void)? = nil
    ) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistryFactory = runtimeRegistryFactory
        self.configStore = configStore
        self.appUpdateController = appUpdateController
            ?? makeDefaultAppUpdateController(configStore: configStore)
        self.sessionRestoreStore = sessionRestoreStore
            ?? SessionRestoreStore(configDirectoryURL: configStore.fileURL.deletingLastPathComponent())
        self.isSessionRestoreEnabled = sessionRestoreEnabled
            ?? !Self.isHostedTestMode
        self.restoreErrorReporter = restoreErrorReporter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.delegate !== self {
            NSApp.delegate = self
        }
        appUpdateController.start()
        AppMenuBuilder.installIfNeeded(on: NSApp, config: configStore.current)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        CleanCopyPipeline.isAutoCleanEnabled = configStore.current.clipboard.alwaysCleanCopies
        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor in
                guard let self else { return }
                CleanCopyPipeline.isAutoCleanEnabled = config.clipboard.alwaysCleanCopies
                AppMenuBuilder.installIfNeeded(on: NSApp, config: config)
                self.applyAuxiliaryWindowTheme()
                self.applyMenuBarStatusConfig(config)
                if self.isSessionRestoreEnabled {
                    self.handleRestorePreferenceChange(config.restore)
                }
            }
        }
        UNUserNotificationCenter.current().delegate = self
        applyMenuBarStatusConfig(configStore.current)

        guard shouldOpenMainWindow else { return }

        if isSessionRestoreEnabled {
            let launchDecision: SessionRestoreStore.LaunchDecision?
            do {
                launchDecision = try sessionRestoreStore.prepareForLaunch(
                    restorePreferenceEnabled: configStore.current.restore.restoreWorkspaceOnLaunch
                )
            } catch {
                reportRestoreError("Failed to prepare restore launch", error: error)
                launchDecision = nil
            }

            do {
                try sessionRestoreStore.markLaunchStarted()
            } catch {
                reportRestoreError("Failed to mark restore launch as started", error: error)
            }

            if let launchDecision, launchWorkspace(launchDecision.envelope) {
                do {
                    try sessionRestoreStore.consumeSnapshot()
                } catch {
                    reportRestoreError("Failed to consume restore snapshot after successful launch", error: error)
                }
            } else {
                if launchDecision != nil {
                    reportRestoreError("Prepared restore snapshot could not be launched; deleting snapshot")
                    do {
                        try sessionRestoreStore.deleteSnapshot()
                    } catch {
                        reportRestoreError("Failed to delete unusable restore snapshot", error: error)
                    }
                }

                let windowController = makeWindowController()
                windowController.showWindow(nil)
            }
        } else {
            let windowController = makeWindowController()
            windowController.showWindow(nil)
        }

        if !Self.isHostedTestMode {
            NSApp.activate(ignoringOtherApps: true)
        }
        if isSessionRestoreEnabled {
            scheduleWorkspaceSnapshotSave()
        }
    }

    @objc
    func newWindow(_ sender: Any?) {
        let windowController = makeWindowController()
        windowController.showWindow(nil)
    }

    @objc
    func showSettingsWindow(_ sender: Any?) {
        keyWindowController?.showSettingsWindow(sender)
    }

    @objc
    func showTaskManager(_ sender: Any?) {
        let appearance = resolvedAboutAppearance
        let theme = resolvedAboutTheme
        let controller = taskManagerWindowController ?? TaskManagerWindowController(
            paneSourcesProvider: { [weak self] in
                self?.orderedWindowControllersForDiscovery().flatMap { $0.taskManagerPaneSources() } ?? []
            },
            focusPaneHandler: { [weak self] windowID, worklaneID, paneID in
                self?.windowController(with: windowID)?.navigateToPane(worklaneID: worklaneID, paneID: paneID)
            },
            closePaneHandler: { [weak self] windowID, paneID in
                self?.windowController(with: windowID)?.closePane(id: paneID)
            },
            appearance: appearance,
            theme: theme
        )
        taskManagerWindowController = controller
        controller.applyAppearance(appearance)
        controller.applyTheme(theme)
        controller.show(sender: sender)
    }

    @objc
    func toggleSidebarMenuItem(_ sender: Any?) {
        keyWindowController?.toggleSidebar(sender)
    }

    @objc
    func showAboutWindow(_ sender: Any?) {
        let appearance = resolvedAboutAppearance
        let theme = resolvedAboutTheme
        let controller = aboutWindowController ?? AboutWindowController(
            onLicensesRequested: { [weak self] in
                self?.showLicensesWindow(nil)
            },
            appearance: appearance,
            theme: theme
        )
        aboutWindowController = controller
        controller.applyAppearance(appearance)
        controller.applyTheme(theme)
        controller.show(sender: sender)
    }

    @objc
    func checkForUpdates(_ sender: Any?) {
        appUpdateController.checkForUpdates()
    }

    @objc
    private func showLicensesWindow(_ sender: Any?) {
        let appearance = resolvedAboutAppearance
        let controller = licensesWindowController ?? LicensesWindowController(appearance: appearance)
        licensesWindowController = controller
        controller.applyAppearance(appearance)
        controller.show(sender: sender)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard configStore.current.confirmations.confirmBeforeQuitting,
              let blockingController = windowControllers.values.first(where: { $0.anyPaneRequiresQuitConfirmation }) else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Zentty?"
        alert.informativeText = "All windows, panes, and running processes will be terminated."
        alert.alertStyle = .warning
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.keyEquivalent = "\r"
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        let presentationController = quitConfirmationPresentationController(blockingController: blockingController)
        alert.window.appearance = presentationController.terminalAppearance
        let restoreToggle = makeRestoreToggleButton()
        alert.accessoryView = restoreToggle

        let window = presentationController.window
        if window.isVisible {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.persistRestorePreferenceIfNeeded(from: restoreToggle)
                }
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            persistRestorePreferenceIfNeeded(from: restoreToggle)
            return .terminateNow
        }

        return .terminateCancel
    }

    private func quitConfirmationPresentationController(
        blockingController: MainWindowController
    ) -> MainWindowController {
        if let keyController = windowControllers.values.first(where: { controller in
            controller.window.isKeyWindow && controller.window.isVisible && !controller.window.isMiniaturized
        }) {
            return keyController
        }

        if let lastKeyWindowControllerID,
           let lastKeyController = windowControllers[lastKeyWindowControllerID],
           lastKeyController.window.isVisible,
           !lastKeyController.window.isMiniaturized {
            return lastKeyController
        }

        return blockingController
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if isSessionRestoreEnabled {
            pendingSnapshotSaveTask?.cancel()
            saveWorkspaceSnapshot(reason: .cleanExit)
            try? sessionRestoreStore.markCleanExit()
        }
        AgentIPCServer.shared.stop()
        for controller in windowControllers.values {
            controller.tearDownRuntime()
        }
        windowControllers.removeAll()
        if let configObserverID {
            configStore.removeObserver(configObserverID)
        }
        menuBarStatusController?.stop()
        menuBarStatusController = nil
        NSApp.dockTile.badgeLabel = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindow(nil)
        }
        return true
    }

    private func makeWindowController() -> MainWindowController {
        let controller = makeWindowController(
            windowID: makeWindowID(),
            initialWorkspaceState: nil
        )
        scheduleWorkspaceSnapshotSave()
        return controller
    }

    private func makeWindowController(
        windowID: WindowID,
        initialWorkspaceState: WindowWorkspaceState?,
        runtimeRegistry: PaneRuntimeRegistry? = nil
    ) -> MainWindowController {
        let index = nextWindowIndex
        nextWindowIndex += 1
        let controller = MainWindowController(
            windowID: windowID,
            runtimeRegistry: runtimeRegistry ?? runtimeRegistryFactory(),
            configStore: configStore,
            appUpdateStateStore: appUpdateController.updateStateStore,
            notificationStore: notificationStore,
            windowIndex: index,
            initialWorkspaceState: initialWorkspaceState
        )
        let id = ObjectIdentifier(controller)
        windowControllers[id] = controller
        if lastKeyWindowControllerID == nil {
            lastKeyWindowControllerID = id
        }
        controller.onWindowDidClose = { [weak self] closedController in
            self?.handleWindowDidClose(closedController)
        }
        controller.onWindowAppearanceDidChange = { [weak self] _, _ in
            guard let self else { return }
            self.applyAuxiliaryWindowTheme()
        }
        controller.onCheckForUpdatesRequested = { [weak self] in
            self?.checkForUpdates(nil)
        }
        controller.onNavigateToNotificationRequested = { [weak self] windowID, worklaneID, paneID in
            self?.navigateToNotification(windowID: windowID, worklaneID: worklaneID, paneID: paneID)
        }
        controller.onMovePaneToNewWindowRequested = { [weak self] sourceController, paneID in
            self?.movePaneToNewWindow(from: sourceController, paneID: paneID)
        }
        controller.moveToWorklaneCatalogProvider = { [weak self] sourceController, paneID in
            self?.buildMoveToWorklaneCatalog(sourceController: sourceController, paneID: paneID)
        }
        controller.onMovePaneToWorklaneRequested = { [weak self] sourceController, request in
            self?.movePaneToWorklane(from: sourceController, request: request)
        }
        controller.onMovePaneToNewWorklaneInThisWindowRequested = { [weak self] sourceController, paneID in
            self?.movePaneToNewWorklaneInThisWindow(from: sourceController, paneID: paneID)
        }
        controller.onWorkspaceStateDidChange = { [weak self] in
            self?.scheduleWorkspaceSnapshotSave()
        }
        syncMenuBarStatusSources()
        return controller
    }

    private func movePaneToNewWindow(from sourceController: MainWindowController, paneID requestedPaneID: PaneID?) {
        guard let paneID = requestedPaneID,
              sourceController.canMovePaneToNewWindow(paneID: paneID)
        else {
            return
        }

        let sourceFrame = sourceController.window.frame
        let destinationWindowID = makeWindowID()
        guard let extracted = sourceController.splitOutPaneForNewWindow(
            paneID: paneID,
            destinationWindowID: destinationWindowID
        ) else {
            return
        }

        let destinationRegistry = runtimeRegistryFactory()
        if let runtime = extracted.runtime {
            destinationRegistry.adoptRuntime(runtime, for: extracted.result.movedPaneID)
        }

        let destinationController = makeWindowController(
            windowID: destinationWindowID,
            initialWorkspaceState: extracted.result.destinationWorkspaceState,
            runtimeRegistry: destinationRegistry
        )
        destinationController.showSplitOutWindow(cascadingFrom: sourceFrame)
        if let destinationWorklaneID = extracted.result.destinationWorkspaceState.activeWorklaneID {
            destinationController.focusPane(id: extracted.result.movedPaneID, in: destinationWorklaneID)
        }

        if extracted.result.sourceWindowShouldClose {
            sourceController.closeWindowBypassingConfirmation()
        }
        scheduleWorkspaceSnapshotSave()
    }

    private func buildMoveToWorklaneCatalog(
        sourceController: MainWindowController,
        paneID: PaneID
    ) -> WorklaneDestinationCatalog? {
        guard let sourceWorklaneID = sourceController.worklaneID(containing: paneID) else {
            return nil
        }
        let ordered = orderedControllers(sourceFirst: sourceController)

        var groups: [WorklaneDestinationGroup] = []
        for controller in ordered {
            let exclude: WorklaneID? = (controller === sourceController) ? sourceWorklaneID : nil
            let summaries = controller.availableWorklaneSummaries(excluding: exclude)
            if !summaries.isEmpty {
                groups.append(WorklaneDestinationGroup(windowID: controller.windowID, summaries: summaries))
            }
        }

        let canCreateNewWorklane = sourceController.paneCount(in: sourceWorklaneID) > 1
        return WorklaneDestinationCatalog(groups: groups, canCreateNewWorklane: canCreateNewWorklane)
    }

    private func orderedControllers(sourceFirst: MainWindowController) -> [MainWindowController] {
        let sortedAll = windowControllers.values.sorted { $0.windowOrder < $1.windowOrder }
        return [sourceFirst] + sortedAll.filter { $0 !== sourceFirst }
    }

    private func movePaneToWorklane(
        from source: MainWindowController,
        request: MovePaneToWorklaneRequest
    ) {
        if source.windowID == request.destinationWindowID {
            source.transferPaneToWorklaneInThisWindow(
                paneID: request.sourcePaneID,
                targetWorklaneID: request.destinationWorklaneID
            )
            scheduleWorkspaceSnapshotSave()
            return
        }

        guard let destination = windowControllers.values.first(where: { $0.windowID == request.destinationWindowID }),
              destination.containsWorklane(request.destinationWorklaneID) else {
            return
        }

        guard let extracted = source.extractPaneForCrossWindowTransfer(paneID: request.sourcePaneID) else {
            return
        }

        destination.acceptCrossWindowPane(
            payload: extracted.payload,
            runtime: extracted.runtime,
            targetWorklaneID: request.destinationWorklaneID
        )

        if extracted.payload.sourceWindowShouldClose {
            source.closeWindowBypassingConfirmation()
        }
        scheduleWorkspaceSnapshotSave()
    }

    private func movePaneToNewWorklaneInThisWindow(
        from source: MainWindowController,
        paneID: PaneID
    ) {
        source.transferPaneToNewWorklaneInThisWindow(paneID: paneID)
        scheduleWorkspaceSnapshotSave()
    }

    private func makeWindowID() -> WindowID {
        WindowID("wd_\(UUID().uuidString.lowercased())")
    }

    private func handleWindowDidClose(_ controller: MainWindowController) {
        let controllerID = ObjectIdentifier(controller)
        windowControllers.removeValue(forKey: controllerID)
        if lastKeyWindowControllerID == controllerID {
            lastKeyWindowControllerID = nil
        }
        applyAuxiliaryWindowTheme()
        if windowControllers.isEmpty {
            NSApp.terminate(nil)
        } else {
            syncMenuBarStatusSources()
            scheduleWorkspaceSnapshotSave()
        }
    }

    private var keyWindowController: MainWindowController? {
        windowControllers.values.first { $0.window.isKeyWindow }
            ?? windowControllers.values.first
    }

    private var aboutThemeSourceController: MainWindowController? {
        if let keyController = windowControllers.values.first(where: { $0.window.isKeyWindow }) {
            return keyController
        }

        if let lastKeyWindowControllerID, let lastKeyController = windowControllers[lastKeyWindowControllerID] {
            return lastKeyController
        }

        return windowControllers.values.first
    }

    private var resolvedAboutAppearance: NSAppearance? {
        aboutThemeSourceController?.terminalAppearance ?? NSApp.effectiveAppearance
    }

    private var resolvedAboutTheme: ZenttyTheme {
        aboutThemeSourceController?.currentWindowTheme
            ?? ZenttyTheme.fallback(for: resolvedAboutAppearance)
    }

    private func applyAuxiliaryWindowTheme() {
        let appearance = resolvedAboutAppearance
        let theme = resolvedAboutTheme
        aboutWindowController?.applyAppearance(appearance)
        aboutWindowController?.applyTheme(theme)
        licensesWindowController?.applyAppearance(appearance)
        taskManagerWindowController?.applyAppearance(appearance)
        taskManagerWindowController?.applyTheme(theme)
    }

    private func makeRestoreToggleButton() -> NSButton {
        let button = NSButton(checkboxWithTitle: "Restore worklanes on next launch", target: nil, action: nil)
        button.state = configStore.current.restore.restoreWorkspaceOnLaunch ? .on : .off
        return button
    }

    private func persistRestorePreferenceIfNeeded(from button: NSButton) {
        let shouldRestore = button.state == .on
        guard shouldRestore != configStore.current.restore.restoreWorkspaceOnLaunch else {
            return
        }

        try? configStore.update { config in
            config.restore.restoreWorkspaceOnLaunch = shouldRestore
        }
    }

    private func handleRestorePreferenceChange(_ restore: AppConfig.Restore) {
        guard isSessionRestoreEnabled else {
            return
        }

        if restore.restoreWorkspaceOnLaunch {
            scheduleWorkspaceSnapshotSave()
        } else {
            pendingSnapshotSaveTask?.cancel()
            try? sessionRestoreStore.deleteSnapshot()
        }
    }

    private func scheduleWorkspaceSnapshotSave() {
        guard isSessionRestoreEnabled else {
            return
        }

        guard !isLaunchingWorkspace else {
            return
        }

        pendingSnapshotSaveTask?.cancel()
        pendingSnapshotSaveTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: RestoreSnapshot.debounceNanoseconds)
            guard !Task.isCancelled else {
                return
            }

            self.saveWorkspaceSnapshot(reason: .liveSnapshot)
        }
    }

    private func saveWorkspaceSnapshot(reason: SessionRestoreEnvelope.SaveReason) {
        if !configStore.current.restore.restoreWorkspaceOnLaunch {
            try? sessionRestoreStore.deleteSnapshot()
            return
        }

        let envelope = currentSessionRestoreEnvelope(reason: reason)
        guard let envelope else {
            return
        }

        let defaultWorkingDirectory = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard WorkspaceRecipeMeaningfulness.isMeaningful(envelope.workspace, defaultWorkingDirectory: defaultWorkingDirectory) else {
            try? sessionRestoreStore.deleteSnapshot()
            return
        }

        try? sessionRestoreStore.saveSnapshot(envelope)
    }

    private func currentSessionRestoreEnvelope(reason: SessionRestoreEnvelope.SaveReason) -> SessionRestoreEnvelope? {
        let controllers = orderedWindowControllers
        guard !controllers.isEmpty else {
            return nil
        }

        let activeWindowID = keyWindowController?.windowID.rawValue
            ?? lastKeyWindowControllerID.flatMap { windowControllers[$0]?.windowID.rawValue }

        return SessionRestoreEnvelope(
            reason: reason,
            workspace: WorkspaceRecipe(
                windows: controllers.map(\.workspaceRecipeWindow),
                activeWindowID: activeWindowID
            ),
            restoreDraftWindows: controllers.compactMap(\.sessionRestoreDraftWindow)
        )
    }

    private var orderedWindowControllers: [MainWindowController] {
        windowControllers.values.sorted { lhs, rhs in
            lhs.window.windowNumber < rhs.window.windowNumber
        }
    }

    private func applyMenuBarStatusConfig(_ config: AppConfig) {
        if config.menuBar.showStatusItem {
            let controller = menuBarStatusController ?? MenuBarStatusController(
                configStore: configStore,
                focusWorklaneHandler: { [weak self] windowID, worklaneID in
                    self?.focusWorklaneFromMenuBar(windowID: windowID, worklaneID: worklaneID)
                }
            )
            menuBarStatusController = controller
            controller.start()
            syncMenuBarStatusSources()
        } else {
            menuBarStatusController?.stop()
            menuBarStatusController = nil
        }
    }

    private func syncMenuBarStatusSources() {
        guard let menuBarStatusController else { return }
        menuBarStatusController.syncSources(orderedWindowControllers.map { controller in
            MenuBarWorklaneSource(
                windowID: controller.windowID,
                windowTitle: controller.menuBarDisplayTitle,
                worklaneStore: controller.worklaneStore
            )
        })
    }

    private func focusWorklaneFromMenuBar(windowID: WindowID, worklaneID: WorklaneID) {
        guard let controller = windowControllers.values.first(where: { $0.windowID == windowID }) else {
            return
        }
        controller.focusWorklane(id: worklaneID)
    }

    private func launchWorkspace(_ envelope: SessionRestoreEnvelope) -> Bool {
        let workspace = envelope.workspace
        let windows = workspace.windows
        guard !windows.isEmpty else {
            return false
        }

        isLaunchingWorkspace = true
        defer { isLaunchingWorkspace = false }

        let config = configStore.current
        var launchedControllers: [MainWindowController] = []

        for recipeWindow in windows {
            let initialFrame = MainWindowController.defaultFrameForRestore()
            let layoutContext = MainWindowController.initialPaneLayoutContextForRestore(
                initialFrame: initialFrame,
                config: config
            )
            let importedState = WorkspaceRecipeImporter.makeWorklanes(
                from: recipeWindow,
                restoreDraftWindow: envelope.restoreDraftWindow(forWindowID: recipeWindow.id),
                windowID: WindowID(recipeWindow.id),
                layoutContext: layoutContext,
                processEnvironment: ProcessInfo.processInfo.environment,
                agentTeamsEnabled: config.agentTeams.enabled
            )
            let controller = makeWindowController(
                windowID: WindowID(recipeWindow.id),
                initialWorkspaceState: importedState
            )
            launchedControllers.append(controller)
        }

        guard !launchedControllers.isEmpty else {
            return false
        }

        let activeControllerID = workspace.activeWindowID
        let activeController = activeControllerID.flatMap { activeID in
            launchedControllers.first { $0.windowID.rawValue == activeID }
        } ?? launchedControllers.first

        for controller in launchedControllers {
            controller.showWindow(nil)
        }

        activeController?.window.makeKeyAndOrderFront(nil)
        return true
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        guard let controller = windowControllers.values.first(where: { $0.window === window }) else {
            return
        }

        lastKeyWindowControllerID = ObjectIdentifier(controller)
        applyAuxiliaryWindowTheme()
    }

    func windowController(containingWorklane worklaneID: WorklaneID) -> MainWindowController? {
        windowControllers.values.first { $0.containsWorklane(worklaneID) }
    }

    func windowController(containingPane paneID: PaneID) -> MainWindowController? {
        windowControllers.values.first { $0.containsPane(paneID) }
    }

    func orderedWindowControllersForDiscovery() -> [MainWindowController] {
        windowControllers.values.sorted { lhs, rhs in
            lhs.windowOrder < rhs.windowOrder
        }
    }

    func navigateToNotification(windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        let target = windowID.flatMap(windowController(with:))
            .flatMap { controller in
                controller.containsPane(worklaneID: worklaneID, paneID: paneID) ? controller : nil
            }
            ?? windowController(containingPane: paneID)
            ?? windowControllers.values.first {
                $0.containsPane(worklaneID: worklaneID, paneID: paneID)
            }

        guard let target else { return }
        let resolvedWorklaneID = target.worklaneID(containing: paneID) ?? worklaneID
        target.navigateToPane(worklaneID: resolvedWorklaneID, paneID: paneID)
    }

    func deliverPaneNotification(_ request: PaneNotificationRequest) {
        paneNotificationCoordinator.deliver(request)
    }

    @discardableResult
    func createGridWindow(
        inheritingFrom sourceController: MainWindowController,
        sourcePaneID: PaneID,
        rows: Int,
        columns: Int,
        command: String?,
        includeSource: Bool,
        focus: GridFocus
    ) throws -> GridApplicationResult? {
        let destinationWindowID = makeWindowID()
        guard let workspaceState = sourceController.gridWindowWorkspaceState(
            inheritingFrom: sourcePaneID,
            destinationWindowID: destinationWindowID
        ),
              let destinationWorklaneID = workspaceState.activeWorklaneID,
              let destinationPaneID = workspaceState.worklanes
                .first(where: { $0.id == destinationWorklaneID })?
                .paneStripState
                .focusedPaneID else {
            return nil
        }

        let destinationController = makeWindowController(
            windowID: destinationWindowID,
            initialWorkspaceState: workspaceState
        )
        destinationController.showSplitOutWindow(cascadingFrom: sourceController.window.frame)
        destinationController.focusPane(id: destinationPaneID, in: destinationWorklaneID)
        let result = try destinationController.applyGrid(
            sourcePaneID: destinationPaneID,
            rows: rows,
            columns: columns,
            command: command,
            includeSource: includeSource,
            focus: focus
        )
        if includeSource, let command {
            _ = destinationController.submitCommand(command, to: result.sourcePaneID)
        }
        scheduleWorkspaceSnapshotSave()
        return result
    }

    func windowController(with windowID: WindowID) -> MainWindowController? {
        windowControllers.values.first { $0.windowID == windowID }
    }

    private func reportRestoreError(_ message: String, error: Error? = nil) {
        if let error {
            let errorDescription = String(describing: error)
            Self.logger.error("\(message, privacy: .public): \(errorDescription, privacy: .public)")
            restoreErrorReporter?("\(message): \(errorDescription)")
        } else {
            Self.logger.error("\(message, privacy: .public)")
            restoreErrorReporter?(message)
        }
    }

    var windowControllerCount: Int {
        windowControllers.count
    }

    #if DEBUG
    var aboutWindow: NSWindow? {
        aboutWindowController?.window
    }

    var licensesWindow: NSWindow? {
        licensesWindowController?.window
    }

    var windowControllersForTesting: [MainWindowController] {
        windowControllers.values.sorted { lhs, rhs in
            lhs.window.windowNumber < rhs.window.windowNumber
        }
    }

    var settingsWindow: NSWindow? {
        keyWindowController?.settingsWindow
    }

    var firstWindowController: MainWindowController? {
        windowControllers.values.first
    }
    #endif
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return appUpdateController.canCheckForUpdates
        }

        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        guard let worklaneRaw = userInfo["worklaneID"] as? String,
              let paneRaw = userInfo["paneID"] as? String else {
            return
        }
        let windowIDRaw = userInfo["windowID"] as? String
        let shouldJump = actionIdentifier == UNNotificationDefaultActionIdentifier
            || actionIdentifier == "JUMP"

        await MainActor.run {
            if shouldJump {
                let worklaneID = WorklaneID(worklaneRaw)
                self.navigateToNotification(
                    windowID: windowIDRaw.map(WindowID.init),
                    worklaneID: worklaneID,
                    paneID: PaneID(paneRaw)
                )
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
