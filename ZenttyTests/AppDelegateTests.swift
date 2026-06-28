import AppKit
import XCTest
@testable import Zentty

@MainActor
final class AppDelegateTests: XCTestCase {
    private var originalMainMenu: NSMenu?
    private weak var originalWindowsMenu: NSMenu?
    private var originalServicesMenu: NSMenu?
    private var originalWindows: [NSWindow] = []
    private var testDefaultsSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        originalMainMenu = NSApp.mainMenu
        originalWindowsMenu = NSApp.windowsMenu
        originalServicesMenu = NSApp.servicesMenu
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
        NSApp.windowsMenu = originalWindowsMenu
        NSApp.servicesMenu = originalServicesMenu
        testDefaultsSuiteNames.forEach {
            UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0)
        }
        testDefaultsSuiteNames.removeAll()
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
        let requiredItems = Array(editMenu?.items.prefix(7) ?? [])
        let findMenu = editMenu?.items.first(where: { $0.title == "Find" })?.submenu

        XCTAssertEqual(editMenu?.title, "Edit")
        XCTAssertEqual(requiredItems.map(\.title), [
            "Copy", "Clean Copy", "Copy Raw", "Copy Path", "Paste", "Select All", "Find",
        ])
        XCTAssertEqual(requiredItems.map(\.action), [
            #selector(NSText.copy(_:)),
            #selector(MainWindowController.cleanCopy(_:)),
            #selector(MainWindowController.copyRaw(_:)),
            #selector(MainWindowController.copyFocusedPanePath(_:)),
            #selector(NSText.paste(_:)),
            #selector(NSResponder.selectAll(_:)),
            Selector(("submenuAction:")),
        ])
        XCTAssertEqual(requiredItems.map(\.keyEquivalent), ["c", "c", "", "c", "v", "a", ""])
        XCTAssertEqual(requiredItems.map(\.keyEquivalentModifierMask), [
            [.command],
            [.command, .control],
            [],
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

    func test_application_launch_registers_services_menu_with_appkit() throws {
        NSApp.mainMenu = nil
        NSApp.servicesMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let servicesMenu = try XCTUnwrap(NSApp.servicesMenu)
        XCTAssertEqual(servicesMenu.title, "Services")
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

    func test_application_launch_installs_window_menu_and_registers_it_with_appkit() throws {
        NSApp.mainMenu = nil
        NSApp.windowsMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let windowMenu = try XCTUnwrap(menu(named: "Window"))
        let closeWindowItem = try XCTUnwrap(windowMenu.items.first(where: { $0.action == #selector(NSWindow.performClose(_:)) }))
        let minimizeItem = try XCTUnwrap(windowMenu.items.first(where: { $0.action == #selector(NSWindow.performMiniaturize(_:)) }))

        XCTAssertEqual(windowMenu.title, "Window")
        XCTAssertEqual(closeWindowItem.keyEquivalent, "")
        XCTAssertEqual(closeWindowItem.keyEquivalentModifierMask, [])
        XCTAssertEqual(minimizeItem.keyEquivalent, "m")
        XCTAssertEqual(minimizeItem.keyEquivalentModifierMask, [.command])
        XCTAssertNotNil(windowMenu.items.first(where: { $0.action == #selector(NSWindow.performZoom(_:)) }))
        XCTAssertNotNil(windowMenu.items.first(where: { $0.action == #selector(NSApplication.arrangeInFront(_:)) }))
        XCTAssertTrue(NSApp.windowsMenu === windowMenu)

        let fileMenu = try XCTUnwrap(menu(named: "File"))
        let closePaneItem = try XCTUnwrap(fileMenu.items.first(where: { $0.action == #selector(MainWindowController.closeFocusedPane(_:)) }))
        XCTAssertEqual(closePaneItem.keyEquivalent, "w")
        XCTAssertEqual(closePaneItem.keyEquivalentModifierMask, [.command])
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
                "Show Bookmarks & Presets",
                "Toggle Sidebar",
                "Add Pane Right",
                "New Pane Below",
                "Move Pane to New Window",
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

        let separatorCount = viewMenu.items.filter({ $0.isSeparatorItem }).count
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

    func test_application_launch_places_task_manager_in_window_menu() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let windowMenu = try XCTUnwrap(menu(named: "Window"))
        let viewMenu = try XCTUnwrap(menu(named: "View"))
        let taskManagerItem = windowMenu.items.first(where: { $0.title == "Task Manager" })

        XCTAssertEqual(taskManagerItem?.action, #selector(AppDelegate.showTaskManager(_:)))
        XCTAssertNotNil(taskManagerItem?.image)
        XCTAssertNil(recursiveMenuItem(matchingTitle: "Task Manager", action: nil, in: viewMenu))
    }

    #if DEBUG
    func test_application_launch_places_performance_overlay_in_window_menu() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let windowMenu = try XCTUnwrap(menu(named: "Window"))
        let frameMeterItem = try XCTUnwrap(windowMenu.items.first(where: { $0.title == "Performance Overlay" }))

        XCTAssertEqual(frameMeterItem.action, #selector(AppDelegate.toggleTerminalFrameMeter(_:)))
        XCTAssertEqual(frameMeterItem.state, .off)
    }
    #endif

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

    func test_licenses_window_opens_from_about_window_and_reuses_existing_window() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showAboutWindow(nil)
        let aboutWindow = try XCTUnwrap(delegate.aboutWindow)

        let originalWindowNumbers = Set(NSApp.windows.map(\.windowNumber))
        try clickButton(titled: "Licenses", in: aboutWindow)
        waitForAppWindows()

        let firstLicensesWindow = try XCTUnwrap(delegate.licensesWindow)
        XCTAssertTrue(originalWindowNumbers.contains(firstLicensesWindow.windowNumber) == false)
        XCTAssertEqual(firstLicensesWindow.title, "Third-Party Licenses")

        try clickButton(titled: "Licenses", in: aboutWindow)
        waitForAppWindows()

        let reusedWindow = try XCTUnwrap(delegate.licensesWindow)
        XCTAssertTrue(reusedWindow === firstLicensesWindow)
        XCTAssertTrue(firstLicensesWindow.isVisible)
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
        let visibleManagedWindows = delegate.windowControllersForTesting.map(\.window).filter(\.isVisible)
        XCTAssertEqual(visibleManagedWindows.count, 1)
    }

    func test_application_quit_prompt_attaches_to_key_window_when_background_window_has_active_terminal_progress() throws {
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
                title: nil,
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

        keyController.window.makeKeyAndOrderFrontForHostedTesting(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: keyController.window)
        let focused = expectation(description: "key window focused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused.fulfill() }
        wait(for: [focused], timeout: 2.0)

        let reply = delegate.applicationShouldTerminate(NSApp)

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertNil(blockingController.window.attachedSheet)
        XCTAssertNotNil(keyController.window.attachedSheet)
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
        XCTAssertNotEqual(firstEnvironment["ZENTTY_WINDOW_ID"], secondEnvironment["ZENTTY_WINDOW_ID"])
    }

    func test_windows_share_notification_store() throws {
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
        XCTAssertTrue(
            controllers[0].rootViewControllerForTesting.notificationStoreForTesting
                === controllers[1].rootViewControllerForTesting.notificationStoreForTesting
        )
    }

    func test_move_last_pane_to_existing_worklane_closes_source_window_without_closing_moved_pane() throws {
        NSApp.mainMenu = nil

        let adapterStore = CloseEmittingAdapterStore()
        let delegate = AppDelegate(
            runtimeRegistryFactory: {
                PaneRuntimeRegistry(adapterFactory: { paneID in
                    adapterStore.makeAdapter(for: paneID)
                })
            }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.newWindow(nil)
        waitForAppWindows("windows opened")

        let controllers = delegate.windowControllersForTesting
        XCTAssertEqual(controllers.count, 2)

        let destination = controllers[0]
        let source = controllers[1]
        let targetWorklaneID = WorklaneID("target")
        let otherWorklaneID = WorklaneID("other")
        let sourceWorklaneID = WorklaneID("source")
        let existingPaneID = PaneID("existing-pane")
        let movedPaneID = PaneID("moved-pane")
        let otherPaneID = PaneID("other-pane")
        let sharedCWD = "/tmp/shared-project"
        let sharedRequest = TerminalSessionRequest(
            workingDirectory: sharedCWD,
            command: "codex",
            surfaceContext: .window
        )

        destination.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: targetWorklaneID,
                title: "TARGET",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: existingPaneID, title: "codex", sessionRequest: sharedRequest)],
                    focusedPaneID: existingPaneID
                )
            ),
            WorklaneState(
                id: otherWorklaneID,
                title: "OTHER",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: otherPaneID, title: "shell")],
                    focusedPaneID: otherPaneID
                )
            ),
        ], activeWorklaneID: targetWorklaneID)
        source.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: sourceWorklaneID,
                title: "SOURCE",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: movedPaneID, title: "codex", sessionRequest: sharedRequest)],
                    focusedPaneID: movedPaneID
                )
            )
        ], activeWorklaneID: sourceWorklaneID)
        waitForAppWindows("worklanes replaced", delay: 0.05)

        XCTAssertTrue(adapterStore.createdPaneIDs.contains(movedPaneID))
        adapterStore.paneIDThatEmitsSurfaceClosedOnClose = movedPaneID

        let item = NSMenuItem()
        item.representedObject = MovePaneToWorklaneRequest(
            sourcePaneID: movedPaneID,
            destinationWindowID: destination.windowIDForTesting,
            destinationWorklaneID: targetWorklaneID
        )
        source.movePaneToWorklane(item)
        waitForAppWindows("pane transfer settled")

        XCTAssertEqual(delegate.windowControllerCount, 1)
        let remainingDestination = try XCTUnwrap(
            delegate.windowControllersForTesting.first { $0.windowIDForTesting == destination.windowIDForTesting }
        )
        XCTAssertEqual(remainingDestination.rootViewControllerForTesting.activeWorklaneIDForTesting, targetWorklaneID)

        let targetWorklane = try XCTUnwrap(
            remainingDestination.rootViewControllerForTesting.worklaneStore.worklanes
                .first { $0.id == targetWorklaneID }
        )
        XCTAssertEqual(targetWorklane.paneStripState.panes.map(\.id), [existingPaneID, movedPaneID])
        XCTAssertEqual(targetWorklane.paneStripState.focusedPaneID, movedPaneID)

        let exportedTarget = try XCTUnwrap(
            remainingDestination.workspaceRecipeWindow.worklanes.first { $0.id == targetWorklaneID.rawValue }
        )
        XCTAssertEqual(
            exportedTarget.columns.flatMap(\.panes).map(\.id),
            [existingPaneID.rawValue, movedPaneID.rawValue]
        )
    }

    func test_notification_navigation_targets_exact_origin_window_when_worklane_is_duplicated() throws {
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

        let worklaneID = WorklaneID("main")
        let paneID = PaneID("main-shell")
        let duplicatedWorklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )

        controllers[0].rootViewControllerForTesting.replaceWorklanes([duplicatedWorklane], activeWorklaneID: worklaneID)
        controllers[1].rootViewControllerForTesting.replaceWorklanes([duplicatedWorklane], activeWorklaneID: worklaneID)

        let replaced = expectation(description: "worklanes replaced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { replaced.fulfill() }
        wait(for: [replaced], timeout: 2.0)

        delegate.navigateToNotification(
            windowID: controllers[1].windowIDForTesting,
            worklaneID: worklaneID,
            paneID: paneID
        )

        let routed = expectation(description: "notification routed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { routed.fulfill() }
        wait(for: [routed], timeout: 2.0)

        XCTAssertEqual(controllers[1].rootViewControllerForTesting.activeWorklaneIDForTesting, worklaneID)
        XCTAssertEqual(controllers[1].rootViewControllerForTesting.focusedPaneIDForTesting, paneID)
        // Cannot assert window.isKeyWindow under the hosted test host's .prohibited
        // activation policy. Instead verify that navigateToPane was invoked on the
        // expected controller and not on the other, proving that the windowID-based
        // routing targeted the correct window.
        XCTAssertEqual(controllers[1].lastNavigateRequestWorklaneIDForTesting, worklaneID)
        XCTAssertEqual(controllers[1].lastNavigateRequestPaneIDForTesting, paneID)
        XCTAssertNil(controllers[0].lastNavigateRequestWorklaneIDForTesting)
        XCTAssertNil(controllers[0].lastNavigateRequestPaneIDForTesting)
    }

    func test_restore_launch_uses_legacy_autosaved_frame_as_layout_seed_when_recipe_has_no_frame() throws {
        NSApp.mainMenu = nil
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.AppDelegate.LegacyRestore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sidebarDefaultsName = "ZenttyTests.AppDelegate.LegacyRestore.Sidebar.\(UUID().uuidString)"
        let visibilityDefaultsName = "ZenttyTests.AppDelegate.LegacyRestore.Visibility.\(UUID().uuidString)"
        let frameDefaultsName = "ZenttyTests.AppDelegate.LegacyRestore.Frame.\(UUID().uuidString)"
        let sidebarDefaults = try XCTUnwrap(UserDefaults(suiteName: sidebarDefaultsName))
        let visibilityDefaults = try XCTUnwrap(UserDefaults(suiteName: visibilityDefaultsName))
        let frameDefaults = try XCTUnwrap(UserDefaults(suiteName: frameDefaultsName))
        testDefaultsSuiteNames.append(contentsOf: [sidebarDefaultsName, visibilityDefaultsName, frameDefaultsName])
        SidebarWidthPreference.persist(280, in: sidebarDefaults)
        SidebarVisibilityPreference.persist(.pinnedOpen, in: visibilityDefaults)

        let configStore = AppConfigStore(
            fileURL: directoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: sidebarDefaults,
            sidebarVisibilityDefaults: visibilityDefaults
        )
        let legacyFrame = NSRect(x: 20, y: 30, width: 1720, height: 900)
        frameDefaults.set(
            "20 30 1720 900 0 0 3440 1410 ",
            forKey: "NSWindow Frame MainWindow"
        )
        let layoutContext = MainWindowController.initialPaneLayoutContextForRestore(
            initialFrame: legacyFrame,
            config: configStore.current
        )
        let restoredColumnWidth = Double(layoutContext.singlePaneWidth)
        let sessionRestoreStore = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )
        try sessionRestoreStore.saveSnapshot(
            SessionRestoreEnvelope(
                workspace: WorkspaceRecipe(
                    windows: [
                        WorkspaceRecipe.Window(
                            id: "window-main",
                            worklanes: [
                                WorkspaceRecipe.Worklane(
                                    id: "worklane-main",
                                    title: "Main",
                                    nextPaneNumber: 3,
                                    focusedColumnID: "column-main",
                                    columns: [
                                        WorkspaceRecipe.Column(
                                            id: "column-main",
                                            width: restoredColumnWidth,
                                            focusedPaneID: "pane-main",
                                            lastFocusedPaneID: "pane-main",
                                            paneHeights: [1],
                                            panes: [
                                                WorkspaceRecipe.Pane(
                                                    id: "pane-main",
                                                    titleSeed: "main",
                                                    workingDirectory: nil
                                                )
                                            ]
                                        ),
                                        WorkspaceRecipe.Column(
                                            id: "column-second",
                                            width: restoredColumnWidth,
                                            focusedPaneID: "pane-second",
                                            lastFocusedPaneID: "pane-second",
                                            paneHeights: [1],
                                            panes: [
                                                WorkspaceRecipe.Pane(
                                                    id: "pane-second",
                                                    titleSeed: "second",
                                                    workingDirectory: nil
                                                )
                                            ]
                                        ),
                                    ],
                                    color: nil,
                                    bookmarkOriginID: nil
                                )
                            ],
                            activeWorklaneID: "worklane-main"
                        )
                    ],
                    activeWindowID: "window-main"
                )
            )
        )

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) },
            configStore: configStore,
            appUpdateController: StubAppUpdateController(canCheckForUpdates: true),
            sessionRestoreStore: sessionRestoreStore,
            sessionRestoreEnabled: true,
            windowFrameDefaults: frameDefaults
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        waitForAppWindows("restore launched")

        let controller = try XCTUnwrap(delegate.windowControllersForTesting.first)
        addTeardownBlock { @MainActor [weak controller] in
            controller?.onWindowDidClose = nil
            controller?.closeWindowBypassingConfirmation()
        }
        let appCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let paneViews = appCanvasView
            .descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
        let visibleLayoutContext = MainWindowController.initialPaneLayoutContextForRestore(
            initialFrame: controller.window.frame,
            config: configStore.current
        )

        XCTAssertGreaterThan(abs(controller.window.frame.width - legacyFrame.width), 1.0)
        XCTAssertEqual(paneViews.first?.frame.width ?? 0, visibleLayoutContext.singlePaneWidth, accuracy: 1.0)
    }

    func test_restore_launch_prefers_autosaved_layout_seed_over_stale_recipe_frame() throws {
        if HostedTestDisplay.screenNameFromEnvironment != nil {
            throw XCTSkip("AppDelegate launch tests create hosted app windows that are not virtual-display safe.")
        }

        NSApp.mainMenu = nil
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.AppDelegate.CurrentFrameRestore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let frameDefaultsName = "ZenttyTests.AppDelegate.CurrentFrameRestore.Frame.\(UUID().uuidString)"
        let frameDefaults = try XCTUnwrap(UserDefaults(suiteName: frameDefaultsName))
        testDefaultsSuiteNames.append(frameDefaultsName)

        let testScreen = HostedTestDisplay.screen(named: HostedTestDisplay.screenNameFromEnvironment)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = try XCTUnwrap(testScreen?.visibleFrame)
        let staleRecipeFrame = NSRect(
            x: visibleFrame.minX + 20,
            y: visibleFrame.minY + 20,
            width: min(960, visibleFrame.width - 40),
            height: min(600, visibleFrame.height - 40)
        ).integral
        let autosavedFrame = NSRect(
            x: visibleFrame.minX + 80,
            y: visibleFrame.minY + 90,
            width: min(1120, visibleFrame.width - 120),
            height: min(720, visibleFrame.height - 140)
        ).integral
        frameDefaults.set(
            "\(autosavedFrame.minX) \(autosavedFrame.minY) \(autosavedFrame.width) \(autosavedFrame.height) \(visibleFrame.minX) \(visibleFrame.minY) \(visibleFrame.width) \(visibleFrame.height) ",
            forKey: "NSWindow Frame MainWindow"
        )

        let configStore = AppConfigStore(fileURL: directoryURL.appendingPathComponent("config.toml"))
        let layoutContext = MainWindowController.initialPaneLayoutContextForRestore(
            initialFrame: autosavedFrame,
            config: configStore.current
        )
        let sessionRestoreStore = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )
        try sessionRestoreStore.saveSnapshot(
            SessionRestoreEnvelope(
                workspace: WorkspaceRecipe(
                    windows: [
                        WorkspaceRecipe.Window(
                            id: "window-main",
                            frame: WorkspaceRecipe.WindowFrame(rect: staleRecipeFrame),
                            worklanes: [
                                WorkspaceRecipe.Worklane(
                                    id: "worklane-main",
                                    title: "Main",
                                    nextPaneNumber: 2,
                                    focusedColumnID: "column-main",
                                    columns: [
                                        WorkspaceRecipe.Column(
                                            id: "column-main",
                                            width: Double(layoutContext.singlePaneWidth),
                                            focusedPaneID: "pane-main",
                                            lastFocusedPaneID: "pane-main",
                                            paneHeights: [1],
                                            panes: [
                                                WorkspaceRecipe.Pane(
                                                    id: "pane-main",
                                                    titleSeed: "main",
                                                    workingDirectory: nil
                                                )
                                            ]
                                        ),
                                    ],
                                    color: nil,
                                    bookmarkOriginID: nil
                                )
                            ],
                            activeWorklaneID: "worklane-main"
                        )
                    ],
                    activeWindowID: "window-main"
                )
            )
        )

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) },
            configStore: configStore,
            appUpdateController: StubAppUpdateController(canCheckForUpdates: true),
            sessionRestoreStore: sessionRestoreStore,
            sessionRestoreEnabled: true,
            windowFrameDefaults: frameDefaults
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        waitForAppWindows("restore launched")

        let controller = try XCTUnwrap(delegate.windowControllersForTesting.first)
        addTeardownBlock { @MainActor [weak controller] in
            controller?.onWindowDidClose = nil
            controller?.closeWindowBypassingConfirmation()
        }

        XCTAssertNotEqual(controller.window.frame.integral, staleRecipeFrame)
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

        let launchedWindow = try XCTUnwrap(delegate.windowControllersForTesting.first?.window)
        XCTAssertTrue(launchedWindow.isVisible)
        let contentView = try XCTUnwrap(launchedWindow.contentView)
        let leadingControlsBar = try XCTUnwrap(
            contentView.firstDescendant(ofType: LeadingChromeControlsBar.self)
        )
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
            leadingControlsBar.frame.minX,
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

@MainActor
private extension AppDelegateTests {
    func clickButton(titled title: String, in window: NSWindow?) throws {
        let button = try XCTUnwrap(window?.contentView?.firstDescendantButton(titled: title))
        button.performClick(button)
    }

    func waitForAppWindows(
        _ description: String = "windows settled",
        delay: TimeInterval = 0.1
    ) {
        let expectation = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}

@MainActor
private final class CloseEmittingAdapterStore {
    var paneIDThatEmitsSurfaceClosedOnClose: PaneID?
    private(set) var createdPaneIDs: [PaneID] = []

    func makeAdapter(for paneID: PaneID) -> any TerminalAdapter {
        createdPaneIDs.append(paneID)
        return CloseEmittingTerminalAdapter(
            emitsSurfaceClosedOnClose: paneID == paneIDThatEmitsSurfaceClosedOnClose
        )
    }
}

@MainActor
private final class CloseEmittingTerminalAdapter: TerminalAdapter {
    private let terminalView = TerminalSurfaceMockView()
    private let emitsSurfaceClosedOnClose: Bool

    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    init(emitsSurfaceClosedOnClose: Bool) {
        self.emitsSurfaceClosedOnClose = emitsSurfaceClosedOnClose
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        metadataDidChange?(TerminalMetadata(currentWorkingDirectory: request.workingDirectory))
    }

    func close() {
        if emitsSurfaceClosedOnClose {
            eventDidOccur?(.surfaceClosed)
        }
    }

    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}

private extension NSView {
    func firstDescendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }

        for subview in subviews {
            if let match = subview.firstDescendantButton(titled: title) {
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

    func descendantPaneViews() -> [PaneContainerView] {
        var paneViews: [PaneContainerView] = []

        func walk(_ view: NSView) {
            if let paneView = view as? PaneContainerView {
                paneViews.append(paneView)
            }

            view.subviews.forEach(walk)
        }

        walk(self)
        return paneViews
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
