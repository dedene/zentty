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

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertNotNil(NSApp.mainMenu)
    }

    func test_application_launch_installs_quit_menu_item() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
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
        let requiredItems = Array(editMenu?.items.prefix(4) ?? [])

        XCTAssertEqual(editMenu?.title, "Edit")
        XCTAssertEqual(requiredItems.map(\.title), ["Copy", "Copy Path", "Paste", "Select All"])
        XCTAssertEqual(requiredItems.map(\.action), [
            #selector(NSText.copy(_:)),
            #selector(MainWindowController.copyFocusedPanePath(_:)),
            #selector(NSText.paste(_:)),
            #selector(NSResponder.selectAll(_:)),
        ])
        XCTAssertEqual(requiredItems.map(\.keyEquivalent), ["c", "c", "v", "a"])
        XCTAssertEqual(requiredItems.map(\.keyEquivalentModifierMask), [
            [.command],
            [.command, .shift],
            [.command],
            [.command],
        ])
    }

    func test_application_launch_installs_view_menu_with_pane_actions() {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let viewMenu = menu(named: "View")
        let items = viewMenu?.items ?? []
        let actionItems = items.filter { !$0.isSeparatorItem }

        XCTAssertGreaterThanOrEqual(items.count, 15, "View menu should contain pane navigation and manipulation items")
        XCTAssertTrue(actionItems.allSatisfy { $0.action != nil }, "all non-separator items should have an action")

        let actions = Set(actionItems.compactMap { $0.action })
        let requiredActions: [Selector] = [
            #selector(MainWindowController.toggleSidebar(_:)),
            #selector(MainWindowController.splitHorizontally(_:)),
            #selector(MainWindowController.splitVertically(_:)),
            #selector(MainWindowController.focusLeftPane(_:)),
            #selector(MainWindowController.focusRightPane(_:)),
            #selector(MainWindowController.resetPaneLayout(_:)),
        ]
        for action in requiredActions {
            XCTAssertTrue(actions.contains(action), "View menu should contain action \(action)")
        }

        let separatorCount = items.count(where: { $0.isSeparatorItem })
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
                    commandID: .toggleSidebar,
                    shortcut: .init(key: .character("b"), modifiers: [.command])
                )
            ]
        }

        let delegate = AppDelegate(
            shouldOpenMainWindow: false,
            configStore: configStore
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let viewMenu = menu(named: "View")
        let toggleSidebarItem = viewMenu?.items.first(where: { $0.action == #selector(MainWindowController.toggleSidebar(_:)) })

        XCTAssertEqual(toggleSidebarItem?.keyEquivalent, "b")
        XCTAssertEqual(toggleSidebarItem?.keyEquivalentModifierMask, [.command])
    }

    @objc func test_application_launch_preserves_main_menu_when_required_items_already_exist() {
        let existingMenu = AppMenuBuilder.makeMainMenu(appName: "Zentty")
        NSApp.mainMenu = existingMenu

        let delegate = AppDelegate(shouldOpenMainWindow: false)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertTrue(NSApp.mainMenu === existingMenu)
    }

    func test_show_settings_window_creates_visible_settings_window() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showSettingsWindow(nil)

        let settingsWindow = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(settingsWindow.title, "General")
    }

    func test_application_launch_places_sidebar_toggle_beside_traffic_lights_without_resize() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
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

    private func menu(named title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu
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
