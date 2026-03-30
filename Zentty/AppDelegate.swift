import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let runtimeRegistry: PaneRuntimeRegistry
    private let configStore: AppConfigStore
    private var windowController: MainWindowController?
    private var configObserverID: UUID?

    init(
        shouldOpenMainWindow: Bool = true,
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        configStore: AppConfigStore = AppConfigStore()
    ) {
        self.shouldOpenMainWindow = shouldOpenMainWindow
        self.runtimeRegistry = runtimeRegistry
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

        let windowController = MainWindowController(
            runtimeRegistry: runtimeRegistry,
            configStore: configStore
        )
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.windowController = windowController
    }

    @objc
    func showSettingsWindow(_ sender: Any?) {
        windowController?.showSettingsWindow(sender)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard configStore.current.confirmations.confirmBeforeQuitting,
              windowController?.anyPaneRequiresQuitConfirmation == true else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Zentty?"
        alert.informativeText = "All panes and running processes will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = windowController?.terminalAppearance

        if let window = windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeRegistry.destroyAll()
        if let configObserverID {
            configStore.removeObserver(configObserverID)
        }
        NSApp.dockTile.badgeLabel = nil
    }

    #if DEBUG
    var settingsWindow: NSWindow? {
        windowController?.settingsWindow
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
                self.windowController?.navigateToPane(
                    worklaneID: WorklaneID(worklaneRaw),
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
