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
    /// Mobile companion bridge (nil in hosted test mode, and until launch).
    var companionBridge: CompanionBridgeServer?
    private let sessionRestorePersistence: SessionRestoreSnapshotPersistence
    private let windowFrameDefaults: UserDefaults
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
    private var snapshotSaveGeneration: UInt64 = 0
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
        restoreErrorReporter: ((String) -> Void)? = nil,
        windowFrameDefaults: UserDefaults
    ) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistryFactory = runtimeRegistryFactory
        self.configStore = configStore
        self.appUpdateController = appUpdateController
            ?? makeDefaultAppUpdateController(configStore: configStore)
        let resolvedSessionRestoreStore = sessionRestoreStore
            ?? SessionRestoreStore(configDirectoryURL: configStore.fileURL.deletingLastPathComponent())
        self.sessionRestoreStore = resolvedSessionRestoreStore
        self.sessionRestorePersistence = SessionRestoreSnapshotPersistence(store: resolvedSessionRestoreStore)
        self.windowFrameDefaults = windowFrameDefaults
        self.isSessionRestoreEnabled = sessionRestoreEnabled
            ?? !Self.isHostedTestMode
        self.restoreErrorReporter = restoreErrorReporter
        super.init()
    }

    convenience init(
        shouldOpenMainWindow: Bool = true,
        runtimeRegistryFactory: @escaping () -> PaneRuntimeRegistry = { PaneRuntimeRegistry() },
        configStore: AppConfigStore = AppConfigStore(),
        appUpdateController: AppUpdateControlling? = nil,
        sessionRestoreStore: SessionRestoreStore? = nil,
        sessionRestoreEnabled: Bool? = nil,
        restoreErrorReporter: ((String) -> Void)? = nil
    ) {
        self.init(
            shouldOpenMainWindow: shouldOpenMainWindow,
            runtimeRegistryFactory: runtimeRegistryFactory,
            configStore: configStore,
            appUpdateController: appUpdateController,
            sessionRestoreStore: sessionRestoreStore,
            sessionRestoreEnabled: sessionRestoreEnabled,
            restoreErrorReporter: restoreErrorReporter,
            windowFrameDefaults: .standard
        )
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
        CleanCopyPipeline.options = CleanCopyOptions.from(configStore.current.clipboard)
        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor in
                guard let self else { return }
                CleanCopyPipeline.isAutoCleanEnabled = config.clipboard.alwaysCleanCopies
                CleanCopyPipeline.options = CleanCopyOptions.from(config.clipboard)
                AppMenuBuilder.installIfNeeded(on: NSApp, config: config)
                self.applyAuxiliaryWindowTheme()
                self.applyMenuBarStatusConfig(config)
                self.companionBridge?.refreshAdvertisingState()
                if self.isSessionRestoreEnabled {
                    self.handleRestorePreferenceChange(config.restore)
                }
            }
        }
        UNUserNotificationCenter.current().delegate = self
        applyMenuBarStatusConfig(configStore.current)
        setUpCompanionBridge()

        // Grandfather existing on-disk hook installs into the consent model
        // before any restore spawns agents, so upgrading users are not prompted
        // for hooks they already have. Skip when the config file couldn't be
        // parsed: the migration persists, and we must not overwrite a config we
        // couldn't read (it self-heals once the file is valid again).
        if configStore.didLoadFromValidFile {
            AgentIntegrationGrandfather.migrateIfNeeded(configStore: configStore)
        }

        // Wire the consent coordinator so the IPC handshake can prompt before a
        // persistent agent's hooks are written to the user's config.
        AgentConsentCoordinator.shared.configure(configStore: configStore) { tool, completion in
            AgentIntegrationConsentPanel.present(tool: tool, completion: completion)
        }

        guard shouldOpenMainWindow else { return }

        if isSessionRestoreEnabled {
            let launchDecision: SessionRestoreStore.LaunchDecision?
            do {
                launchDecision = try sessionRestoreStore.prepareForLaunch(
                    restorePreferenceEnabled: configStore.current.restore.restoreWorkspaceOnLaunch
                )
                if let launchDecision {
                    ZenttyBreadcrumbs.record(
                        category: "zentty.launch.restore",
                        message: "prepared",
                        data: [
                            "windowCount": launchDecision.envelope.workspace.windows.count,
                        ]
                    )
                }
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
                ZenttyBreadcrumbs.record(
                    category: "zentty.launch.restore",
                    message: "launched",
                    data: [
                        "windowCount": launchDecision.envelope.workspace.windows.count,
                        "success": true,
                    ]
                )
                do {
                    try sessionRestoreStore.consumeSnapshot()
                } catch {
                    reportRestoreError("Failed to consume restore snapshot after successful launch", error: error)
                }
            } else {
                if launchDecision != nil {
                    ZenttyBreadcrumbs.record(
                        category: "zentty.launch.restore",
                        message: "failed",
                        data: ["success": false]
                    )
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

    /// Builds and installs the mobile companion bridge. Skipped in hosted test
    /// mode so tests never touch the Keychain or open ports. The bridge only
    /// listens/advertises once a device is paired and the toggle is on, so this
    /// is inert on a Mac that has never paired.
    private func setUpCompanionBridge() {
        guard !Self.isHostedTestMode else { return }
        let identity = CompanionDeviceIdentity.loadOrCreate(keychain: CompanionKeychainStore())
        let configDirectoryURL = configStore.fileURL.deletingLastPathComponent()
        let pairingStore = CompanionPairingStore(configDirectoryURL: configDirectoryURL)
        let dashboardFeed = CompanionDashboardFeed(provider: self)
        let paneTextFeed = CompanionPaneTextFeed(
            provider: self,
            setObservationEnabled: { enabled in
                if enabled {
                    LibghosttyContentChangeObservation.retain()
                } else {
                    LibghosttyContentChangeObservation.release()
                }
            }
        )
        let inputRouter = CompanionInputRouter(sink: self)
        let bridge = CompanionBridgeServer(
            identity: identity,
            pairingStore: pairingStore,
            dashboardFeed: dashboardFeed,
            paneTextFeed: paneTextFeed,
            inputRouter: inputRouter,
            isFeatureEnabled: { [weak self] in self?.configStore.current.companion.enabled ?? false },
            relayUrlProvider: { [weak self] in self?.configStore.current.companion.relayUrl ?? "" }
        )
        bridge.installAsShared()
        companionBridge = bridge
        bridge.refreshAdvertisingState()
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
    func focusNextWaitingAgentPane(_ sender: Any?) {
        _ = menuBarStatusController?.focusNextWaitingPane()
    }

#if DEBUG
    @objc
    func toggleAgentIconInspector(_ sender: Any?) {
        guard let controller = menuBarStatusController else {
            // The menu bar status item is disabled in Settings, so there is no
            // dropdown to inspect. Enable "Show menu bar status item" first.
            NSSound.beep()
            return
        }
        controller.toggleIconInspector()
        if let item = sender as? NSMenuItem {
            item.state = controller.isIconInspectorEnabled ? .on : .off
        }
    }
#endif

    @objc
    func toggleTerminalFrameMeter(_ sender: Any?) {
        TerminalFrameMeter.shared.isEnabled.toggle()
        if let item = sender as? NSMenuItem {
            item.state = TerminalFrameMeter.shared.isEnabled ? .on : .off
        }
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
            snapshotSaveGeneration &+= 1
            let generation = snapshotSaveGeneration
            pendingSnapshotSaveTask?.cancel()
            persistWorkspaceSnapshot(reason: .cleanExit, generation: generation, synchronously: true)
            try? sessionRestoreStore.markCleanExit()
        }
        AgentIPCServer.shared.stop()
        companionBridge?.stop()
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
        runtimeRegistry: PaneRuntimeRegistry? = nil,
        initialPaneLayoutFrame: NSRect? = nil
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
            initialPaneLayoutFrame: initialPaneLayoutFrame,
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

        guard destination.acceptCrossWindowPane(
            payload: extracted.payload,
            runtime: extracted.runtime,
            targetWorklaneID: request.destinationWorklaneID
        ) else {
            return
        }

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
        notificationStore.resolveAll(windowID: controller.windowID)
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
            snapshotSaveGeneration &+= 1
            pendingSnapshotSaveTask?.cancel()
            sessionRestorePersistence.persistAsync(.deleteSnapshot, generation: snapshotSaveGeneration)
        }
    }

    private func scheduleWorkspaceSnapshotSave() {
        guard isSessionRestoreEnabled else {
            return
        }

        guard !isLaunchingWorkspace else {
            return
        }

        snapshotSaveGeneration &+= 1
        let generation = snapshotSaveGeneration
        pendingSnapshotSaveTask?.cancel()
        pendingSnapshotSaveTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: RestoreSnapshot.debounceNanoseconds)
            guard !Task.isCancelled else {
                return
            }

            guard generation == self.snapshotSaveGeneration else {
                return
            }

            self.persistWorkspaceSnapshot(reason: .liveSnapshot, generation: generation, synchronously: false)
        }
    }

    private func persistWorkspaceSnapshot(
        reason: SessionRestoreEnvelope.SaveReason,
        generation: UInt64,
        synchronously: Bool
    ) {
        let request = workspaceSnapshotPersistenceRequest(reason: reason)
        if synchronously {
            sessionRestorePersistence.persistSynchronously(request, generation: generation)
        } else {
            sessionRestorePersistence.persistAsync(request, generation: generation)
        }
    }

    private func workspaceSnapshotPersistenceRequest(reason: SessionRestoreEnvelope.SaveReason) -> SessionRestorePersistenceRequest {
        if !configStore.current.restore.restoreWorkspaceOnLaunch {
            return .deleteSnapshot
        }

        let envelope = currentSessionRestoreEnvelope(reason: reason)
        guard let envelope else {
            return .none
        }

        let defaultWorkingDirectory = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard WorkspaceRecipeMeaningfulness.isMeaningful(envelope.workspace, defaultWorkingDirectory: defaultWorkingDirectory) else {
            return .deleteSnapshot
        }

        return .saveSnapshot(envelope)
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
                schemaVersion: WorkspaceRecipe.currentSchemaVersion,
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
                focusPaneHandler: { [weak self] windowID, worklaneID, paneID in
                    self?.focusPaneFromMenuBar(windowID: windowID, worklaneID: worklaneID, paneID: paneID)
                },
                openSettingsHandler: { [weak self] in
                    self?.showAgentsSettingsFromMenuBar()
                }
            )
            menuBarStatusController = controller
            controller.start()
            syncMenuBarStatusSources()
        } else {
            menuBarStatusController?.stop()
            menuBarStatusController = nil
        }
        menuBarStatusController?.refreshPresentation()
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

    private func focusPaneFromMenuBar(windowID: WindowID, worklaneID: WorklaneID, paneID: PaneID) {
        guard let controller = windowControllers.values.first(where: { $0.windowID == windowID }) else {
            return
        }
        controller.navigateToPane(worklaneID: worklaneID, paneID: paneID)
    }

    private func showAgentsSettingsFromMenuBar() {
        let controller = keyWindowController ?? orderedWindowControllers.first
        controller?.showSettingsWindow(section: .agents, sender: nil)
    }

    private func launchWorkspace(_ envelope: SessionRestoreEnvelope) -> Bool {
        // Migrate once, up front, so every downstream consumer (the
        // importer below) only ever sees a current-schema recipe and never
        // needs its own schemaVersion branch.
        let workspace = WorkspaceRecipeMigration.migrate(envelope.workspace)
        let windows = workspace.windows
        guard !windows.isEmpty else {
            return false
        }

        isLaunchingWorkspace = true
        defer { isLaunchingWorkspace = false }

        let config = configStore.current
        var launchedControllers: [MainWindowController] = []

        for (windowIndex, recipeWindow) in windows.enumerated() {
            let paneLayoutSeedFrame = MainWindowController.legacyAutosavedFrameForRestore(
                windowIndex: windowIndex,
                defaults: windowFrameDefaults
            )
                ?? MainWindowController.validatedPaneLayoutSeedFrameForRestore(recipeWindow.frame)
                ?? MainWindowController.defaultFrameForRestore()
            let layoutContext = MainWindowController.initialPaneLayoutContextForRestore(
                initialFrame: paneLayoutSeedFrame,
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
                initialWorkspaceState: importedState,
                initialPaneLayoutFrame: paneLayoutSeedFrame
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

        if menuItem.action == #selector(toggleTerminalFrameMeter(_:)) {
            menuItem.state = TerminalFrameMeter.shared.isEnabled ? .on : .off
            return true
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
