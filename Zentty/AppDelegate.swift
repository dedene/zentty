import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let configStore: AppConfigStore
    private let runtimeRegistryFactory: () -> PaneRuntimeRegistry
    private let appUpdateController: AppUpdateControlling
    private let notificationStore = NotificationStore()
    private var windowControllers: [ObjectIdentifier: MainWindowController] = [:]
    private var aboutWindowController: AboutWindowController?
    private var licensesWindowController: LicensesWindowController?
    private var lastKeyWindowControllerID: ObjectIdentifier?
    private var configObserverID: UUID?
    private var nextWindowIndex = 0

    init(
        shouldOpenMainWindow: Bool = true,
        runtimeRegistryFactory: @escaping () -> PaneRuntimeRegistry = { PaneRuntimeRegistry() },
        configStore: AppConfigStore = AppConfigStore(),
        appUpdateController: AppUpdateControlling? = nil
    ) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistryFactory = runtimeRegistryFactory
        self.configStore = configStore
        self.appUpdateController = appUpdateController
            ?? makeDefaultAppUpdateController(configStore: configStore)
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
        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor in
                guard let self else { return }
                AppMenuBuilder.installIfNeeded(on: NSApp, config: config)
                self.aboutWindowController?.applyAppearance(self.resolvedAboutAppearance)
                self.aboutWindowController?.applyTheme(self.resolvedAboutTheme)
                self.licensesWindowController?.applyAppearance(self.resolvedAboutAppearance)
            }
        }
        UNUserNotificationCenter.current().delegate = self

        guard shouldOpenMainWindow else { return }

        let windowController = makeWindowController()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let window = blockingController.window
        if window.isVisible {
            alert.beginSheetModal(for: window) { response in
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
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
        let index = nextWindowIndex
        nextWindowIndex += 1
        let controller = MainWindowController(
            windowID: makeWindowID(),
            runtimeRegistry: runtimeRegistryFactory(),
            configStore: configStore,
            appUpdateStateStore: appUpdateController.updateStateStore,
            notificationStore: notificationStore,
            windowIndex: index
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
