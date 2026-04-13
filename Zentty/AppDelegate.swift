import AppKit
import OSLog
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RestoreSnapshot {
        static let debounceNanoseconds: UInt64 = 350_000_000
    }

    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "SessionRestore")

    private let shouldOpenMainWindow: Bool
    private let configStore: AppConfigStore
    private let runtimeRegistryFactory: () -> PaneRuntimeRegistry
    private let appUpdateController: AppUpdateControlling
    private let sessionRestoreStore: SessionRestoreStore
    private let notificationStore = NotificationStore()
    private var windowControllers: [ObjectIdentifier: MainWindowController] = [:]
    private var aboutWindowController: AboutWindowController?
    private var licensesWindowController: LicensesWindowController?
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
            ?? !CommandLine.arguments.contains("-ApplePersistenceIgnoreState")
        self.restoreErrorReporter = restoreErrorReporter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                self.aboutWindowController?.applyAppearance(self.resolvedAboutAppearance)
                self.aboutWindowController?.applyTheme(self.resolvedAboutTheme)
                self.licensesWindowController?.applyAppearance(self.resolvedAboutAppearance)
                if self.isSessionRestoreEnabled {
                    self.handleRestorePreferenceChange(config.restore)
                }
            }
        }
        UNUserNotificationCenter.current().delegate = self

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

        NSApp.activate(ignoringOtherApps: true)
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
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = blockingController.terminalAppearance
        let restoreToggle = makeRestoreToggleButton()
        alert.accessoryView = restoreToggle

        let window = blockingController.window
        if window.isVisible {
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
        initialWorkspaceState: WindowWorkspaceState?
    ) -> MainWindowController {
        let index = nextWindowIndex
        nextWindowIndex += 1
        let controller = MainWindowController(
            windowID: windowID,
            runtimeRegistry: runtimeRegistryFactory(),
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
            self.aboutWindowController?.applyAppearance(self.resolvedAboutAppearance)
            self.aboutWindowController?.applyTheme(self.resolvedAboutTheme)
            self.licensesWindowController?.applyAppearance(self.resolvedAboutAppearance)
        }
        controller.onCheckForUpdatesRequested = { [weak self] in
            self?.checkForUpdates(nil)
        }
        controller.onNavigateToNotificationRequested = { [weak self] windowID, worklaneID, paneID in
            self?.navigateToNotification(windowID: windowID, worklaneID: worklaneID, paneID: paneID)
        }
        controller.onWorkspaceStateDidChange = { [weak self] in
            self?.scheduleWorkspaceSnapshotSave()
        }
        return controller
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
        aboutWindowController?.applyAppearance(resolvedAboutAppearance)
        aboutWindowController?.applyTheme(resolvedAboutTheme)
        licensesWindowController?.applyAppearance(resolvedAboutAppearance)
        if windowControllers.isEmpty {
            NSApp.terminate(nil)
        } else {
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
                processEnvironment: ProcessInfo.processInfo.environment
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
        aboutWindowController?.applyAppearance(resolvedAboutAppearance)
        aboutWindowController?.applyTheme(resolvedAboutTheme)
        licensesWindowController?.applyAppearance(resolvedAboutAppearance)
    }

    func windowController(containingWorklane worklaneID: WorklaneID) -> MainWindowController? {
        windowControllers.values.first { $0.containsWorklane(worklaneID) }
    }

    func navigateToNotification(windowID: WindowID?, worklaneID: WorklaneID, paneID: PaneID) {
        let target = windowID.flatMap(windowController(with:))
            .flatMap { controller in
                controller.containsPane(worklaneID: worklaneID, paneID: paneID) ? controller : nil
            }
            ?? windowControllers.values.first {
                $0.containsPane(worklaneID: worklaneID, paneID: paneID)
            }

        target?.navigateToPane(worklaneID: worklaneID, paneID: paneID)
    }

    private func windowController(with windowID: WindowID) -> MainWindowController? {
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
