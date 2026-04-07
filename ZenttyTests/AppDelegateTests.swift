import AppKit
import XCTest
@testable import Zentty

@MainActor
final class AppDelegateTests: XCTestCase {
    private var originalMainMenu: NSMenu?
    private var originalWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        originalMainMenu = NSApp.mainMenu
        originalWindows = NSApp.windows
    }

    override func tearDown() {
        for window in NSApp.windows where originalWindows.contains(where: { $0 === window }) == false {
            if let controller = window.delegate as? MainWindowController {
                controller.closeWindowBypassingConfirmation()
            } else {
                window.close()
            }
        }

        NSApp.mainMenu = originalMainMenu
        super.tearDown()
    }

    func test_application_launch_installs_main_menu_when_missing() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertNotNil(NSApp.mainMenu)
    }

    func test_application_launch_installs_quit_menu_item() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            shouldOpenMainWindow: false,
            appUpdateController: StubAppUpdateController(canCheckForUpdates: true)
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let appMenuItem = NSApp.mainMenu?.items.first
        let aboutItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(AppDelegate.showAboutWindow(_:)) })
        let updatesItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(AppDelegate.checkForUpdates(_:)) })
        let settingsItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(AppDelegate.showSettingsWindow(_:)) })
        let quitItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) })

        XCTAssertEqual(appMenuItem?.submenu?.title, "Zentty")
        XCTAssertEqual(aboutItem?.title, "About Zentty")
        XCTAssertEqual(updatesItem?.title, "Check for Updates…")
        XCTAssertEqual(settingsItem?.title, "Settings…")
        XCTAssertEqual(settingsItem?.keyEquivalent, ",")
        XCTAssertEqual(quitItem?.title, "Quit Zentty")
        XCTAssertEqual(quitItem?.keyEquivalent, "q")
    }

    func test_application_launch_places_about_item_above_settings() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            shouldOpenMainWindow: false,
            appUpdateController: StubAppUpdateController(canCheckForUpdates: true)
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let appMenuItems = NSApp.mainMenu?.items.first?.submenu?.items ?? []
        let aboutIndex = appMenuItems.firstIndex(where: { $0.action == #selector(AppDelegate.showAboutWindow(_:)) })
        let updatesIndex = appMenuItems.firstIndex(where: { $0.action == #selector(AppDelegate.checkForUpdates(_:)) })
        let settingsIndex = appMenuItems.firstIndex(where: { $0.action == #selector(AppDelegate.showSettingsWindow(_:)) })

        XCTAssertEqual(aboutIndex, 0)
        XCTAssertEqual(updatesIndex, 1)
        XCTAssertEqual(settingsIndex, 3)
    }

    func test_check_for_updates_forwards_to_app_update_controller() {
        NSApp.mainMenu = nil

        let appUpdateController = StubAppUpdateController(canCheckForUpdates: true)
        let delegate = AppDelegate(
            shouldOpenMainWindow: false,
            appUpdateController: appUpdateController
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.checkForUpdates(nil)

        XCTAssertEqual(appUpdateController.checkForUpdatesCallCount, 1)
    }

    func test_application_launch_installs_file_menu_with_new_worklane_action() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let fileMenu = menu(named: "File")
        let newWorklaneItem = fileMenu?.items.first(where: { $0.action == #selector(MainWindowController.newWorklane(_:)) })

        XCTAssertEqual(fileMenu?.title, "File")
        XCTAssertEqual(newWorklaneItem?.title, "New Worklane")
        XCTAssertEqual(newWorklaneItem?.keyEquivalent, "t")
        XCTAssertEqual(newWorklaneItem?.keyEquivalentModifierMask, [.command])
    }

    @objc func test_application_launch_installs_edit_menu_with_standard_actions() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let editMenu = menu(named: "Edit")
        let requiredItems = Array(editMenu?.items.prefix(5) ?? [])
        let findMenu = editMenu?.items.first(where: { $0.title == "Find" })?.submenu

        XCTAssertEqual(editMenu?.title, "Edit")
        XCTAssertEqual(requiredItems.map(\.title), ["Copy", "Copy Path", "Paste", "Select All", "Find"])
        XCTAssertEqual(requiredItems.map(\.action), [
            #selector(NSText.copy(_:)),
            #selector(MainWindowController.copyFocusedPanePath(_:)),
            #selector(NSText.paste(_:)),
            #selector(NSResponder.selectAll(_:)),
            Selector(("submenuAction:")),
        ])
        XCTAssertEqual(requiredItems.map(\.keyEquivalent), ["c", "c", "v", "a", ""])
        XCTAssertEqual(requiredItems.map(\.keyEquivalentModifierMask), [
            [.command],
            [.command, .shift],
            [.command],
            [.command],
            [],
        ])
        XCTAssertEqual(findMenu?.items.map(\.title), [
            "Find…",
            "Global Find…",
            "Find Next",
            "Find Previous",
            "Use Selection for Find",
        ])
        XCTAssertEqual(findMenu?.items.map(\.action), [
            #selector(MainWindowController.find(_:)),
            #selector(MainWindowController.globalFind(_:)),
            #selector(MainWindowController.findNext(_:)),
            #selector(MainWindowController.findPrevious(_:)),
            #selector(MainWindowController.useSelectionForFind(_:)),
        ])
        XCTAssertEqual(findMenu?.items.map(\.keyEquivalent), ["f", "f", "g", "g", "e"])
        XCTAssertEqual(findMenu?.items.map(\.keyEquivalentModifierMask), [
            [.command],
            [.command, .shift],
            [.command],
            [.command, .shift],
            [.command],
        ])
    }

    func test_application_launch_installs_navigation_menu_with_history_and_focus_actions() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let navigationMenu = menu(named: "Navigation")
        let actionItems = navigationMenu?.items.filter { !$0.isSeparatorItem } ?? []

        XCTAssertEqual(
            actionItems.map(\.title),
            [
                "Navigate Back",
                "Navigate Forward",
                "Focus Previous Pane",
                "Focus Next Pane",
                "Focus Left Pane",
                "Focus Right Pane",
                "Focus Up In Column",
                "Focus Down In Column",
            ]
        )

        let actions = actionItems.compactMap(\.action)
        let requiredActions: [Selector] = [
            #selector(MainWindowController.navigateBack(_:)),
            #selector(MainWindowController.navigateForward(_:)),
            #selector(MainWindowController.focusPreviousPane(_:)),
            #selector(MainWindowController.focusNextPane(_:)),
            #selector(MainWindowController.focusLeftPane(_:)),
            #selector(MainWindowController.focusRightPane(_:)),
            #selector(MainWindowController.focusUpInColumn(_:)),
            #selector(MainWindowController.focusDownInColumn(_:)),
        ]
        for action in requiredActions {
            XCTAssertTrue(actions.contains(action), "Navigation menu should contain action \(action)")
        }
    }

    func test_application_launch_installs_view_menu_with_arrange_submenus_and_layout_actions() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let viewMenu = try XCTUnwrap(menu(named: "View"))
        let actionItems = viewMenu.items.filter { !$0.isSeparatorItem }

        XCTAssertEqual(
            actionItems.map(\.title),
            [
                "Command Palette…",
                "Toggle Sidebar",
                "Split Horizontally",
                "Split Vertically",
                "Arrange Width",
                "Arrange Height",
                "Resize Pane Left",
                "Resize Pane Right",
                "Resize Pane Up",
                "Resize Pane Down",
                "Reset Pane Layout",
            ]
        )

        let arrangeWidthMenu = try XCTUnwrap(submenu(named: "Arrange Width", in: viewMenu))
        XCTAssertEqual(
            arrangeWidthMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Arrange Width: Full Width",
                "Arrange Width: Half Width",
                "Arrange Width: Thirds",
                "Arrange Width: Quarters",
                "Arrange Width: Golden — Focus Wide",
                "Arrange Width: Golden — Focus Narrow",
            ]
        )

        let arrangeHeightMenu = try XCTUnwrap(submenu(named: "Arrange Height", in: viewMenu))
        XCTAssertEqual(
            arrangeHeightMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Arrange Height: Full Height",
                "Arrange Height: 2 Per Column",
                "Arrange Height: 3 Per Column",
                "Arrange Height: 4 Per Column",
                "Arrange Height: Golden — Focus Tall",
                "Arrange Height: Golden — Focus Short",
            ]
        )

        let separatorCount = viewMenu.items.count(where: { $0.isSeparatorItem })
        XCTAssertGreaterThanOrEqual(separatorCount, 3, "View menu should have separator groups for visual structure")
    }

    func test_application_launch_applies_configured_shortcuts_to_menu_items() throws {
        NSApp.mainMenu = nil

        let configStore = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.AppDelegate.Shortcuts")
        )
        try configStore.update { config in
            config.shortcuts.bindings = [
                ShortcutBindingOverride(
                    commandID: .arrangeWidthGoldenFocusWide,
                    shortcut: .init(key: .character("w"), modifiers: [.command, .option])
                )
            ]
        }

        let delegate = AppDelegate(
            shouldOpenMainWindow: false,
            configStore: configStore
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let viewMenu = try XCTUnwrap(menu(named: "View"))
        let arrangeWidthMenu = try XCTUnwrap(submenu(named: "Arrange Width", in: viewMenu))
        let wideItem = arrangeWidthMenu.items.first(where: { $0.action == #selector(MainWindowController.arrangeWidthGoldenFocusWide(_:)) })

        XCTAssertEqual(wideItem?.keyEquivalent, "w")
        XCTAssertEqual(wideItem?.keyEquivalentModifierMask, [.command, .option])
    }

    @objc func test_application_launch_keeps_existing_main_menu_semantically_valid() {
        let existingMenu = AppMenuBuilder.makeMainMenu(appName: "Zentty")
        NSApp.mainMenu = existingMenu

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let fileMenu = menu(named: "File")
        let navigationMenu = menu(named: "Navigation")
        let viewMenu = menu(named: "View")

        XCTAssertEqual(appMenu?.title, "Zentty")
        XCTAssertNotNil(fileMenu?.items.first(where: { $0.action == #selector(AppDelegate.newWindow(_:)) }))
        XCTAssertNotNil(navigationMenu)
        XCTAssertNotNil(viewMenu?.items.first(where: { $0.title == "Toggle Sidebar" }))
    }

    func test_show_settings_window_creates_visible_settings_window() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showSettingsWindow(nil)

        let settingsWindow = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(settingsWindow.title, "General")
    }

    func test_show_about_window_creates_visible_about_window() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showAboutWindow(nil)

        let aboutWindow = try XCTUnwrap(delegate.aboutWindow)
        XCTAssertTrue(aboutWindow.isVisible)
        XCTAssertEqual(aboutWindow.title, "About Zentty")
    }

    func test_show_about_window_reuses_existing_window() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showAboutWindow(nil)
        let firstWindow = try XCTUnwrap(delegate.aboutWindow)

        delegate.showAboutWindow(nil)
        let reusedWindow = try XCTUnwrap(delegate.aboutWindow)

        XCTAssertTrue(firstWindow === reusedWindow)
    }

    func test_show_about_window_uses_active_window_appearance() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let expectedAppearance = try XCTUnwrap(delegate.firstWindowController?.terminalAppearance)

        delegate.showAboutWindow(nil)

        let aboutWindow = try XCTUnwrap(delegate.aboutWindow)
        XCTAssertEqual(
            aboutWindow.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            expectedAppearance.bestMatch(from: [.darkAqua, .aqua])
        )
    }

    func test_closing_one_window_keeps_app_running_when_another_window_is_open() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.newWindow(nil)

        let opened = expectation(description: "windows opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { opened.fulfill() }
        wait(for: [opened], timeout: 2.0)

        XCTAssertEqual(delegate.windowControllerCount, 2)
        let controllerToClose = try XCTUnwrap(delegate.firstWindowController)

        controllerToClose.closeWindowBypassingConfirmation()

        let closed = expectation(description: "window closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { closed.fulfill() }
        wait(for: [closed], timeout: 2.0)

        XCTAssertEqual(delegate.windowControllerCount, 1)
        let visibleLaunchedWindows = NSApp.windows.filter { window in
            originalWindows.contains(where: { $0 === window }) == false && window.isVisible
        }
        XCTAssertEqual(visibleLaunchedWindows.count, 1)
    }

    func test_application_quit_prompts_when_background_window_has_active_terminal_progress() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.newWindow(nil)

        let opened = expectation(description: "windows opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { opened.fulfill() }
        wait(for: [opened], timeout: 2.0)

        let controllers = delegate.windowControllersForTesting
        XCTAssertEqual(controllers.count, 2)

        let blockingController = controllers[0]
        let keyController = controllers[1]
        let paneID = PaneID("main-shell")
        blockingController.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                terminalProgressByPaneID: [
                    paneID: TerminalProgressReport(state: .indeterminate, progress: nil)
                ]
            )
        ], activeWorklaneID: WorklaneID("main"))

        let replaced = expectation(description: "worklane replaced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { replaced.fulfill() }
        wait(for: [replaced], timeout: 2.0)

        keyController.window.makeKeyAndOrderFront(nil)
        let focused = expectation(description: "key window focused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused.fulfill() }
        wait(for: [focused], timeout: 2.0)

        let reply = delegate.applicationShouldTerminate(NSApp)

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertNotNil(blockingController.window.attachedSheet)
        XCTAssertNil(keyController.window.attachedSheet)
    }

    func test_new_windows_export_distinct_runtime_identity_environment() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.newWindow(nil)

        let opened = expectation(description: "windows opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { opened.fulfill() }
        wait(for: [opened], timeout: 2.0)

        let controllers = delegate.windowControllersForTesting
        XCTAssertEqual(controllers.count, 2)

        let firstEnvironment = try XCTUnwrap(controllers[0].focusedPaneEnvironmentForTesting)
        let secondEnvironment = try XCTUnwrap(controllers[1].focusedPaneEnvironmentForTesting)

        XCTAssertNotEqual(firstEnvironment["ZENTTY_WORKLANE_ID"], secondEnvironment["ZENTTY_WORKLANE_ID"])
        XCTAssertNotEqual(firstEnvironment["ZENTTY_PANE_ID"], secondEnvironment["ZENTTY_PANE_ID"])
    }

    func test_application_launch_places_sidebar_toggle_beside_traffic_lights_without_resize() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let settled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)

        let launchedWindow = try XCTUnwrap(
            NSApp.windows.first(where: { window in
                !originalWindows.contains(where: { $0 === window }) && window.isVisible
            })
        )
        let contentView = try XCTUnwrap(launchedWindow.contentView)
        let toggleButton = try XCTUnwrap(contentView.firstDescendant(ofType: SidebarToggleButton.self))
        let sidebarView = try XCTUnwrap(contentView.firstDescendant(ofType: SidebarView.self))
        let zoomButton = try XCTUnwrap(launchedWindow.standardWindowButton(.zoomButton))
        let buttonSuperview = try XCTUnwrap(zoomButton.superview)
        let zoomAnchorInWindow = buttonSuperview.convert(
            NSPoint(x: zoomButton.frame.maxX, y: zoomButton.frame.midY),
            to: nil
        )
        let zoomAnchorInContent = contentView.convert(zoomAnchorInWindow, from: nil)
        let expectedLeading = max(
            zoomAnchorInContent.x + SidebarToggleButton.spacingFromTrafficLights,
            sidebarView.frame.maxX + ShellMetrics.shellGap
        )

        XCTAssertEqual(
            toggleButton.frame.minX,
            expectedLeading,
            accuracy: 1.0
        )
    }

    func test_application_launch_routes_toggle_sidebar_menu_item_to_main_window_controller() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let settled = expectation(description: "window shown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)

        let viewMenu = try XCTUnwrap(menu(named: "View"))
        let toggleSidebarItem = try XCTUnwrap(
            recursiveMenuItem(
                matchingTitle: "Toggle Sidebar",
                action: nil,
                in: viewMenu
            )
        )
        guard let action = toggleSidebarItem.action else {
            return XCTFail("Toggle Sidebar menu item should have an action")
        }
        let target = NSApp.target(forAction: action, to: nil, from: toggleSidebarItem)

        XCTAssertTrue(target is AppDelegate)
    }

    private func menu(named title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu
    }

    private func submenu(named title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first(where: { $0.submenu?.title == title })?.submenu
    }

    private func recursiveMenuItem(
        matchingTitle title: String,
        action: Selector?,
        in menu: NSMenu
    ) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title, action == nil || item.action == action {
                return item
            }
            if let submenu = item.submenu,
               let match = recursiveMenuItem(matchingTitle: title, action: action, in: submenu) {
                return match
            }
        }

        return nil
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }
}

@MainActor
private final class StubAppUpdateController: AppUpdateControlling {
    let canCheckForUpdates: Bool
    let updateStateStore = AppUpdateStateStore()
    private(set) var checkForUpdatesCallCount = 0
    private(set) var startCallCount = 0

    init(canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func start() {
        startCallCount += 1
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}
