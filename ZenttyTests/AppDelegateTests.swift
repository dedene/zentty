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
        let quitItem = appMenuItem?.submenu?.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) })

        XCTAssertEqual(appMenuItem?.submenu?.title, "Zentty")
        XCTAssertEqual(quitItem?.title, "Quit Zentty")
        XCTAssertEqual(quitItem?.keyEquivalent, "q")
    }

    @objc func test_application_launch_installs_edit_menu_with_standard_actions() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let editMenu = NSApp.mainMenu?.items.dropFirst().first?.submenu
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

    @objc func test_application_launch_preserves_main_menu_when_required_items_already_exist() {
        let existingMenu = AppMenuBuilder.makeMainMenu(appName: "Zentty")
        NSApp.mainMenu = existingMenu

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertTrue(NSApp.mainMenu === existingMenu)
    }
}
