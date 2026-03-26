import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shouldOpenMainWindow: Bool
    private let runtimeRegistry: PaneRuntimeRegistry
    private let configStore: AppConfigStore
    private var windowController: MainWindowController?

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
        AppMenuBuilder.installIfNeeded(on: NSApp)
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

    func applicationWillTerminate(_ notification: Notification) {
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
