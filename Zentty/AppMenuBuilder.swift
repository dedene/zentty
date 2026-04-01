import AppKit

@MainActor
enum AppMenuBuilder {
    static func installIfNeeded(
        on application: NSApplication,
        config: AppConfig = .default,
        appName: String = resolvedAppName()
    ) {
        guard hasRequiredMenuItems(in: application.mainMenu, appName: appName) == false else {
            applyConfiguredShortcuts(to: application.mainMenu, config: config)
            return
        }

        application.mainMenu = makeMainMenu(appName: appName, config: config)
    }

    static func makeMainMenu(appName: String, config: AppConfig = .default) -> NSMenu {
        let shortcutManager = ShortcutManager(shortcuts: config.shortcuts)
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.showSettingsWindow(_:)),
            keyEquivalent: ","
        )
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        settingsItem.keyEquivalentModifierMask = [.command]
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(settingsItem)
        appMenu.addItem(makeSeparatorItem())
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(makeFileMenuItem(shortcutManager: shortcutManager))
        mainMenu.addItem(makeEditMenuItem(shortcutManager: shortcutManager))
        mainMenu.addItem(makeViewMenuItem(shortcutManager: shortcutManager))

        return mainMenu
    }

    static func resolvedAppName(bundle: Bundle = .main) -> String {
        if let bundleName = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
           bundleName.isEmpty == false {
            return bundleName
        }

        return ProcessInfo.processInfo.processName
    }

    static func applyConfiguredShortcuts(to mainMenu: NSMenu?, config: AppConfig) {
        let shortcutManager = ShortcutManager(shortcuts: config.shortcuts)

        for definition in AppCommandRegistry.definitions {
            guard let menuDefinition = definition.menuItem,
                  let item = menuItem(for: menuDefinition.selector, in: mainMenu) else {
                continue
            }

            item.title = menuDefinition.title
            apply(shortcutManager.shortcut(for: definition.id), to: item)
        }
    }

    private static func makeEditMenuItem(shortcutManager: ShortcutManager) -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(makeStandardMenuActionItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(makeCommandMenuItem(commandID: .copyFocusedPanePath, shortcutManager: shortcutManager))
        editMenu.addItem(makeStandardMenuActionItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(makeStandardMenuActionItem(
            title: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        ))

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    private static func makeFileMenuItem(shortcutManager: ShortcutManager) -> NSMenuItem {
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        for entry in AppCommandRegistry.menuEntriesBySection[.file] ?? [] {
            switch entry {
            case .separator:
                fileMenu.addItem(makeSeparatorItem())
            case .command(let commandID):
                fileMenu.addItem(makeCommandMenuItem(commandID: commandID, shortcutManager: shortcutManager))
            }
        }

        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    private static func makeViewMenuItem(shortcutManager: ShortcutManager) -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        for entry in AppCommandRegistry.menuEntriesBySection[.view] ?? [] {
            switch entry {
            case .separator:
                viewMenu.addItem(makeSeparatorItem())
            case .command(let commandID):
                viewMenu.addItem(makeCommandMenuItem(commandID: commandID, shortcutManager: shortcutManager))
            }
        }

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    private static func makeStandardMenuActionItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.command]
        return item
    }

    private static func makeCommandMenuItem(
        commandID: AppCommandID,
        shortcutManager: ShortcutManager
    ) -> NSMenuItem {
        let definition = AppCommandRegistry.definition(for: commandID)
        guard let menuDefinition = definition.menuItem else {
            fatalError("Missing menu definition for command \(commandID.rawValue)")
        }

        let item = NSMenuItem(title: menuDefinition.title, action: menuDefinition.selector, keyEquivalent: "")
        apply(shortcutManager.shortcut(for: commandID), to: item)
        return item
    }

    private static func apply(_ shortcut: KeyboardShortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.menuModifierFlags ?? []
    }

    private static func makeSeparatorItem() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.keyEquivalentModifierMask = []
        return item
    }

    private static func hasRequiredMenuItems(in mainMenu: NSMenu?, appName: String) -> Bool {
        guard let appMenu = mainMenu?.items.first?.submenu else {
            return false
        }

        let hasQuitItem = appMenu.items.contains(where: {
            $0.action == #selector(NSApplication.terminate(_:)) &&
            $0.title == "Quit \(appName)"
        })
        let hasSettingsItem = appMenu.items.contains(where: {
            $0.action == #selector(AppDelegate.showSettingsWindow(_:)) &&
            $0.title == "Settings…"
        })
        let fileMenu = menu(named: AppMenuSection.file.rawValue, in: mainMenu)
        let editMenu = menu(named: AppMenuSection.edit.rawValue, in: mainMenu)
        let viewMenu = menu(named: AppMenuSection.view.rawValue, in: mainMenu)
        let requiredFileItems: [(String, Selector)] = [
            ("New Worklane", #selector(MainWindowController.newWorklane(_:))),
            ("Next Worklane", #selector(MainWindowController.nextWorklane(_:))),
            ("Previous Worklane", #selector(MainWindowController.previousWorklane(_:))),
        ]
        let requiredEditItems: [(String, Selector)] = [
            ("Copy", #selector(NSText.copy(_:))),
            ("Copy Path", #selector(MainWindowController.copyFocusedPanePath(_:))),
            ("Paste", #selector(NSText.paste(_:))),
            ("Select All", #selector(NSResponder.selectAll(_:))),
        ]
        let requiredViewItems: [(String?, Selector?)] = [
            ("Command Palette\u{2026}", #selector(MainWindowController.showCommandPalette(_:))),
            (nil, nil),
            ("Toggle Sidebar", #selector(MainWindowController.toggleSidebar(_:))),
            (nil, nil),
            ("Navigate Back", #selector(MainWindowController.navigateBack(_:))),
            ("Navigate Forward", #selector(MainWindowController.navigateForward(_:))),
            (nil, nil),
            ("Split Horizontally", #selector(MainWindowController.splitHorizontally(_:))),
            ("Split Vertically", #selector(MainWindowController.splitVertically(_:))),
            (nil, nil),
            ("Arrange Width: Full Width", #selector(MainWindowController.arrangePaneWidthFull(_:))),
            ("Arrange Width: Half Width", #selector(MainWindowController.arrangePaneWidthHalves(_:))),
            ("Arrange Width: Thirds", #selector(MainWindowController.arrangePaneWidthThirds(_:))),
            ("Arrange Width: Quarters", #selector(MainWindowController.arrangePaneWidthQuarters(_:))),
            (nil, nil),
            ("Arrange Height: Full Height", #selector(MainWindowController.arrangePaneHeightFull(_:))),
            ("Arrange Height: 2 Per Column", #selector(MainWindowController.arrangePaneHeightTwoPerColumn(_:))),
            ("Arrange Height: 3 Per Column", #selector(MainWindowController.arrangePaneHeightThreePerColumn(_:))),
            ("Arrange Height: 4 Per Column", #selector(MainWindowController.arrangePaneHeightFourPerColumn(_:))),
            (nil, nil),
            ("Focus Previous Pane", #selector(MainWindowController.focusPreviousPane(_:))),
            ("Focus Next Pane", #selector(MainWindowController.focusNextPane(_:))),
            ("Focus Left Pane", #selector(MainWindowController.focusLeftPane(_:))),
            ("Focus Right Pane", #selector(MainWindowController.focusRightPane(_:))),
            ("Focus Up In Column", #selector(MainWindowController.focusUpInColumn(_:))),
            ("Focus Down In Column", #selector(MainWindowController.focusDownInColumn(_:))),
            (nil, nil),
            ("Resize Pane Left", #selector(MainWindowController.resizePaneLeft(_:))),
            ("Resize Pane Right", #selector(MainWindowController.resizePaneRight(_:))),
            ("Resize Pane Up", #selector(MainWindowController.resizePaneUp(_:))),
            ("Resize Pane Down", #selector(MainWindowController.resizePaneDown(_:))),
            (nil, nil),
            ("Reset Pane Layout", #selector(MainWindowController.resetPaneLayout(_:))),
        ]
        let hasFileItems = hasRequiredItems(requiredFileItems, in: fileMenu)
        let hasEditItems =
            editMenu?.title == AppMenuSection.edit.rawValue &&
            hasRequiredItems(requiredEditItems, in: editMenu)
        let hasViewItems =
            viewMenu?.title == AppMenuSection.view.rawValue &&
            hasRequiredItems(requiredViewItems, in: viewMenu)

        return hasSettingsItem && hasQuitItem && hasFileItems && hasEditItems && hasViewItems
    }

    private static func menu(named title: String, in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu
    }

    private static func menuItem(for action: Selector, in mainMenu: NSMenu?) -> NSMenuItem? {
        for rootItem in mainMenu?.items ?? [] {
            if let found = rootItem.submenu?.items.first(where: { $0.action == action }) {
                return found
            }
        }

        return nil
    }

    private static func hasRequiredItems(
        _ requiredItems: [(String, Selector)],
        in menu: NSMenu?
    ) -> Bool {
        guard let menu, menu.items.count >= requiredItems.count else {
            return false
        }

        return zip(menu.items.prefix(requiredItems.count), requiredItems).allSatisfy { item, expected in
            item.title == expected.0 &&
            item.action == expected.1
        }
    }

    private static func hasRequiredItems(
        _ requiredItems: [(String?, Selector?)],
        in menu: NSMenu?
    ) -> Bool {
        guard let menu, menu.items.count >= requiredItems.count else {
            return false
        }

        return zip(menu.items.prefix(requiredItems.count), requiredItems).allSatisfy { item, expected in
            if let expectedTitle = expected.0 {
                return item.title == expectedTitle && item.action == expected.1
            }

            return item.isSeparatorItem && item.action == expected.1
        }
    }
}
