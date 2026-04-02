import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let configStore: AppConfigStore
    private let runtimeRegistryFactory: () -> PaneRuntimeRegistry
    private var windowControllers: [ObjectIdentifier: MainWindowController] = [:]
    private var configObserverID: UUID?
    private var nextWindowIndex = 0

    init(
        shouldOpenMainWindow: Bool = true,
        runtimeRegistryFactory: @escaping () -> PaneRuntimeRegistry = { PaneRuntimeRegistry() },
        configStore: AppConfigStore = AppConfigStore()
    ) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistryFactory = runtimeRegistryFactory
        self.configStore = configStore
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenuBuilder.installIfNeeded(on: NSApp, config: configStore.current)
        configObserverID = configStore.addObserver { config in
            Task { @MainActor in
                AppMenuBuilder.installIfNeeded(on: NSApp, config: config)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard configStore.current.confirmations.confirmBeforeQuitting,
              windowControllers.values.contains(where: { $0.anyPaneRequiresQuitConfirmation }) else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Zentty?"
        alert.informativeText = "All windows, panes, and running processes will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = keyWindowController?.terminalAppearance

        if let window = keyWindowController?.window, window.isVisible {
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

    // MARK: - Window Lifecycle

    private func makeWindowController() -> MainWindowController {
        let index = nextWindowIndex
        nextWindowIndex += 1
        let controller = MainWindowController(
            runtimeRegistry: runtimeRegistryFactory(),
            configStore: configStore,
            windowIndex: index
        )
        let id = ObjectIdentifier(controller)
        windowControllers[id] = controller
        controller.onWindowDidClose = { [weak self] closedController in
            self?.handleWindowDidClose(closedController)
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

    func windowController(containingWorklane worklaneID: WorklaneID) -> MainWindowController? {
        windowControllers.values.first { $0.containsWorklane(worklaneID) }
    }

    var windowControllerCount: Int {
        windowControllers.count
    }

    #if DEBUG
    var settingsWindow: NSWindow? {
        keyWindowController?.settingsWindow
    }

    var firstWindowController: MainWindowController? {
        windowControllers.values.first
    }
    #endif
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
