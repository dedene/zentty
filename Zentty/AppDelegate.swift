import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let configStore: AppConfigStore
    private let runtimeRegistryFactory: () -> PaneRuntimeRegistry
    private let appUpdateController: AppUpdateControlling
    private var windowControllers: [ObjectIdentifier: MainWindowController] = [:]
    private var aboutWindowController: AboutWindowController?
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
        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor in
                guard let self else { return }
                AppMenuBuilder.installIfNeeded(on: NSApp, config: config)
                self.aboutWindowController?.applyAppearance(self.resolvedAboutAppearance)
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
        let controller = aboutWindowController ?? AboutWindowController(appearance: appearance)
        aboutWindowController = controller
        controller.applyAppearance(appearance)
        controller.show(sender: sender)
    }

    @objc
    func checkForUpdates(_ sender: Any?) {
        appUpdateController.checkForUpdates()
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
            runtimeRegistry: runtimeRegistryFactory(),
            configStore: configStore,
            appUpdateStateStore: appUpdateController.updateStateStore,
            windowIndex: index
        )
        let id = ObjectIdentifier(controller)
        windowControllers[id] = controller
        controller.onWindowDidClose = { [weak self] closedController in
            self?.handleWindowDidClose(closedController)
        }
        controller.onWindowAppearanceDidChange = { [weak self] _ in
            guard let self else { return }
            self.aboutWindowController?.applyAppearance(self.resolvedAboutAppearance)
        }
        controller.onCheckForUpdatesRequested = { [weak self] in
            self?.checkForUpdates(nil)
        }
        return controller
    }

    private func handleWindowDidClose(_ controller: MainWindowController) {
        windowControllers.removeValue(forKey: ObjectIdentifier(controller))
        if windowControllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    private var keyWindowController: MainWindowController? {
        windowControllers.values.first { $0.window.isKeyWindow }
            ?? windowControllers.values.first
    }

    private var resolvedAboutAppearance: NSAppearance? {
        keyWindowController?.terminalAppearance ?? NSApp.effectiveAppearance
    }

    func windowController(containingWorklane worklaneID: WorklaneID) -> MainWindowController? {
        windowControllers.values.first { $0.containsWorklane(worklaneID) }
    }

    var windowControllerCount: Int {
        windowControllers.count
    }

    #if DEBUG
    var aboutWindow: NSWindow? {
        aboutWindowController?.window
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
        let shouldJump = actionIdentifier == UNNotificationDefaultActionIdentifier
            || actionIdentifier == "JUMP"

        await MainActor.run {
            if shouldJump {
                let worklaneID = WorklaneID(worklaneRaw)
                let target = self.windowController(containingWorklane: worklaneID)
                target?.navigateToPane(
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
