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
            window.close()
        }

        NSApp.mainMenu = originalMainMenu
        super.tearDown()
    }

    func test_application_launch_installs_main_menu_when_missing() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertNotNil(NSApp.mainMenu)
    }

    func test_application_launch_installs_quit_menu_item() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let appMenuItem = NSApp.mainMenu?.items.first
        let settingsItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(AppDelegate.showSettingsWindow(_:)) })
        let quitItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) })

        XCTAssertEqual(appMenuItem?.submenu?.title, "Zentty")
        XCTAssertEqual(settingsItem?.title, "Settings…")
        XCTAssertEqual(settingsItem?.keyEquivalent, ",")
        XCTAssertEqual(quitItem?.title, "Quit Zentty")
        XCTAssertEqual(quitItem?.keyEquivalent, "q")
    }

    func test_application_launch_installs_file_menu_with_new_workspace_action() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let fileMenu = menu(named: "File")
        let newWorkspaceItem = fileMenu?.items.first(where: { $0.action == #selector(AppDelegate.newWorkspace(_:)) })

        XCTAssertEqual(fileMenu?.title, "File")
        XCTAssertEqual(newWorkspaceItem?.title, "New Workspace")
        XCTAssertEqual(newWorkspaceItem?.keyEquivalent, "t")
        XCTAssertEqual(newWorkspaceItem?.keyEquivalentModifierMask, [.command])
    }

    @objc func test_application_launch_installs_edit_menu_with_standard_actions() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let editMenu = menu(named: "Edit")
        let requiredItems = Array(editMenu?.items.prefix(3) ?? [])

        XCTAssertEqual(editMenu?.title, "Edit")
        XCTAssertEqual(requiredItems.map(\.title), ["Copy", "Paste", "Select All"])
        XCTAssertEqual(requiredItems.map(\.action), [
            #selector(NSText.copy(_:)),
            #selector(NSText.paste(_:)),
            #selector(NSResponder.selectAll(_:)),
        ])
        XCTAssertEqual(requiredItems.map(\.keyEquivalent), ["c", "v", "a"])
        XCTAssertEqual(requiredItems.map(\.keyEquivalentModifierMask), [
            [.command],
            [.command],
            [.command],
        ])
    }

    func test_application_launch_installs_view_menu_with_pane_actions() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let viewMenu = menu(named: "View")

        XCTAssertEqual(
            viewMenu?.items.map(\.title),
            [
                "Split Right",
                "Split Left",
                "",
                "Focus Left Pane",
                "Focus Right Pane",
                "Focus First Pane",
                "Focus Last Pane",
            ]
        )
        XCTAssertEqual(
            viewMenu?.items.map(\.action),
            [
                #selector(AppDelegate.splitRight(_:)),
                #selector(AppDelegate.splitLeft(_:)),
                nil,
                #selector(AppDelegate.focusLeftPane(_:)),
                #selector(AppDelegate.focusRightPane(_:)),
                #selector(AppDelegate.focusFirstPane(_:)),
                #selector(AppDelegate.focusLastPane(_:)),
            ]
        )
        XCTAssertEqual(
            viewMenu?.items.map(\.keyEquivalent),
            ["d", "d", "", String(UnicodeScalar(NSLeftArrowFunctionKey)!), String(UnicodeScalar(NSRightArrowFunctionKey)!), String(UnicodeScalar(NSLeftArrowFunctionKey)!), String(UnicodeScalar(NSRightArrowFunctionKey)!)]
        )
        XCTAssertEqual(
            viewMenu?.items.map(\.keyEquivalentModifierMask),
            [
                [.command],
                [.command, .shift],
                [],
                [.command, .option],
                [.command, .option],
                [.command, .option, .shift],
                [.command, .option, .shift],
            ]
        )
    }

    @objc func test_application_launch_preserves_main_menu_when_required_items_already_exist() {
        let existingMenu = AppMenuBuilder.makeMainMenu(appName: "Zentty")
        NSApp.mainMenu = existingMenu

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertTrue(NSApp.mainMenu === existingMenu)
    }

    func test_show_settings_window_creates_visible_settings_window() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showSettingsWindow(nil)

        let settingsWindow = try XCTUnwrap(delegate.settingsWindowForTesting)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(settingsWindow.title, "Settings")
    }

    private func menu(named title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu
    }
}
