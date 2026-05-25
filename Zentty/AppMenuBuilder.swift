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
            application.windowsMenu = menu(named: "Window", in: application.mainMenu)
            application.servicesMenu = servicesMenu(in: application.mainMenu)
            return
        }

        application.mainMenu = makeMainMenu(appName: appName, config: config)
        application.windowsMenu = menu(named: "Window", in: application.mainMenu)
        application.servicesMenu = servicesMenu(in: application.mainMenu)
    }

    static func makeMainMenu(appName: String, config: AppConfig = .default) -> NSMenu {
        let shortcutManager = ShortcutManager(shortcuts: config.shortcuts)
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        let aboutItem = NSMenuItem(
            title: "About \(appName)",
            action: #selector(AppDelegate.showAboutWindow(_:)),
            keyEquivalent: ""
        )
        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(AppDelegate.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.showSettingsWindow(_:)),
            keyEquivalent: ""
        )
        let hideItem = NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        apply(shortcutManager.shortcut(for: .openSettings), to: settingsItem)
        applySystemImage("gearshape", title: "Settings…", to: settingsItem)
        hideItem.keyEquivalentModifierMask = [.command]
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        showAllItem.keyEquivalentModifierMask = []
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(aboutItem)
        appMenu.addItem(updatesItem)
        appMenu.addItem(makeSeparatorItem())
        appMenu.addItem(settingsItem)
        appMenu.addItem(makeSeparatorItem())
        appMenu.addItem(hideItem)
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(showAllItem)
        appMenu.addItem(makeSeparatorItem())
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(makeFileMenuItem(shortcutManager: shortcutManager))
        mainMenu.addItem(makeEditMenuItem(shortcutManager: shortcutManager))
        mainMenu.addItem(makeSectionMenuItem(section: .navigation, shortcutManager: shortcutManager))
        mainMenu.addItem(makeViewMenuItem(shortcutManager: shortcutManager))
        mainMenu.addItem(makeWindowMenuItem(shortcutManager: shortcutManager))
#if DEBUG
        mainMenu.addItem(makeDebugMenuItem())
#endif

        return mainMenu
    }

#if DEBUG
    private static func makeDebugMenuItem() -> NSMenuItem {
        let debugMenuItem = NSMenuItem()
        let debugMenu = NSMenu(title: "Debug")
        let inspectIconsItem = NSMenuItem(
            title: "Inspect Agent Icons",
            action: #selector(AppDelegate.toggleAgentIconInspector(_:)),
            keyEquivalent: ""
        )
        debugMenu.addItem(inspectIconsItem)
        debugMenuItem.submenu = debugMenu
        return debugMenuItem
    }
#endif

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
                  let item = menuItem(for: menuDefinition.selector, inMainMenu: mainMenu) else {
                continue
            }

            item.title = menuDefinition.title
            applySystemImage(menuDefinition.systemImageName, title: menuDefinition.title, to: item)
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
        editMenu.addItem(makeCommandMenuItem(commandID: .cleanCopy, shortcutManager: shortcutManager))
        editMenu.addItem(makeCommandMenuItem(commandID: .copyRaw, shortcutManager: shortcutManager))
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
        editMenu.addItem(makeMenuItem(
            for: .submenu("Find", [
                .command(.find),
                .command(.globalFind),
                .command(.findNext),
                .command(.findPrevious),
                .command(.useSelectionForFind),
            ]),
            shortcutManager: shortcutManager
        ))
        editMenu.addItem(makeServicesMenuItem())

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    private static func makeFileMenuItem(shortcutManager: ShortcutManager) -> NSMenuItem {
        makeSectionMenuItem(section: .file, shortcutManager: shortcutManager)
    }

    private static func makeViewMenuItem(shortcutManager: ShortcutManager) -> NSMenuItem {
        makeSectionMenuItem(section: .view, shortcutManager: shortcutManager)
    }

    private static func makeWindowMenuItem(shortcutManager: ShortcutManager) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(makeStandardMenuActionItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(makeStandardMenuActionItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(makeSeparatorItem())
        addMenuEntries(AppCommandRegistry.menuEntriesBySection[.window] ?? [], to: menu, shortcutManager: shortcutManager)
        menu.addItem(makePerformanceOverlayMenuItem())
        menu.addItem(makeSeparatorItem())
        menu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        menuItem.submenu = menu
        return menuItem
    }

    private static func makeSectionMenuItem(
        section: AppMenuSection,
        shortcutManager: ShortcutManager
    ) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: section.rawValue)
        addMenuEntries(AppCommandRegistry.menuEntriesBySection[section] ?? [], to: menu, shortcutManager: shortcutManager)
        menuItem.submenu = menu
        return menuItem
    }

    private static func addMenuEntries(
        _ entries: [AppMenuEntry],
        to menu: NSMenu,
        shortcutManager: ShortcutManager
    ) {
        for entry in entries {
            menu.addItem(makeMenuItem(for: entry, shortcutManager: shortcutManager))
        }
    }

    private static func makeMenuItem(
        for entry: AppMenuEntry,
        shortcutManager: ShortcutManager
    ) -> NSMenuItem {
        switch entry {
        case .separator:
            return makeSeparatorItem()
        case .command(let commandID):
            return makeCommandMenuItem(commandID: commandID, shortcutManager: shortcutManager)
        case .submenu(let title, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            addMenuEntries(entries, to: submenu, shortcutManager: shortcutManager)
            item.submenu = submenu
            item.keyEquivalentModifierMask = []
            return item
        }
    }

    private static func makeStandardMenuActionItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : [.command]
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
        applySystemImage(menuDefinition.systemImageName, title: menuDefinition.title, to: item)
        apply(shortcutManager.shortcut(for: commandID), to: item)
        return item
    }

    private static func makePerformanceOverlayMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Performance Overlay",
            action: #selector(AppDelegate.toggleTerminalFrameMeter(_:)),
            keyEquivalent: ""
        )
        item.state = TerminalFrameMeter.shared.isEnabled ? .on : .off
        applySystemImage("waveform.path.ecg", title: "Performance Overlay", to: item)
        return item
    }

    private static func applySystemImage(_ systemImageName: String?, title: String, to item: NSMenuItem) {
        item.image = systemImageName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)
        }
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
        let hasAboutItem = appMenu.items.contains(where: {
            $0.action == #selector(AppDelegate.showAboutWindow(_:)) &&
            $0.title == "About \(appName)"
        })
        let hasSettingsItem = appMenu.items.contains(where: {
            $0.action == #selector(AppDelegate.showSettingsWindow(_:)) &&
            $0.title == "Settings…"
        })
        let hasUpdatesItem = appMenu.items.contains(where: {
            $0.action == #selector(AppDelegate.checkForUpdates(_:)) &&
            $0.title == "Check for Updates…"
        })
        let hasHideItem = appMenu.items.contains(where: {
            $0.action == #selector(NSApplication.hide(_:)) &&
            $0.title == "Hide \(appName)"
        })
        let hasHideOthersItem = appMenu.items.contains(where: {
            $0.action == #selector(NSApplication.hideOtherApplications(_:)) &&
            $0.title == "Hide Others"
        })
        let hasShowAllItem = appMenu.items.contains(where: {
            $0.action == #selector(NSApplication.unhideAllApplications(_:)) &&
            $0.title == "Show All"
        })
        let fileMenu = menu(named: AppMenuSection.file.rawValue, in: mainMenu)
        let editMenu = menu(named: AppMenuSection.edit.rawValue, in: mainMenu)
        let navigationMenu = menu(named: AppMenuSection.navigation.rawValue, in: mainMenu)
        let viewMenu = menu(named: AppMenuSection.view.rawValue, in: mainMenu)
        let windowMenu = menu(named: "Window", in: mainMenu)
        let requiredEditItems: [(String, Selector)] = [
            ("Copy", #selector(NSText.copy(_:))),
            ("Clean Copy", #selector(MainWindowController.cleanCopy(_:))),
            ("Copy Raw", #selector(MainWindowController.copyRaw(_:))),
            ("Copy Path", #selector(MainWindowController.copyFocusedPanePath(_:))),
            ("Paste", #selector(NSText.paste(_:))),
            ("Select All", #selector(NSResponder.selectAll(_:))),
        ]
        let requiredFindEntries: [AppMenuEntry] = [
            .command(.find),
            .command(.globalFind),
            .command(.findNext),
            .command(.findPrevious),
            .command(.useSelectionForFind),
        ]
        let hasFileItems = hasRequiredStructure(expectedEntries(for: .file), in: fileMenu)
        let hasEditItems =
            editMenu?.title == AppMenuSection.edit.rawValue &&
            hasRequiredItems(requiredEditItems, in: editMenu) &&
            editMenu?.items.count ?? 0 >= requiredEditItems.count + 1 &&
            matches(
                item: editMenu?.items[requiredEditItems.count] ?? NSMenuItem(),
                expected: .submenu("Find", requiredFindEntries)
            ) &&
            editMenu?.items.contains(where: { $0.title == "Services" && $0.submenu != nil }) == true
        let hasNavigationItems =
            navigationMenu?.title == AppMenuSection.navigation.rawValue &&
            hasRequiredStructure(expectedEntries(for: .navigation), in: navigationMenu)
        let hasViewItems =
            viewMenu?.title == AppMenuSection.view.rawValue &&
            hasRequiredStructure(expectedEntries(for: .view), in: viewMenu)
        let hasWindowItems =
            windowMenu?.title == "Window" &&
            hasRequiredItems([
                ("Close Window", #selector(NSWindow.performClose(_:))),
                ("Minimize", #selector(NSWindow.performMiniaturize(_:))),
                ("Zoom", #selector(NSWindow.performZoom(_:))),
                (nil, nil),
                ("Task Manager", #selector(AppDelegate.showTaskManager(_:))),
                ("Performance Overlay", #selector(AppDelegate.toggleTerminalFrameMeter(_:))),
                (nil, nil),
                ("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
            ], in: windowMenu)

        return hasAboutItem &&
            hasUpdatesItem &&
            hasSettingsItem &&
            hasHideItem &&
            hasHideOthersItem &&
            hasShowAllItem &&
            hasQuitItem &&
            hasFileItems &&
            hasEditItems &&
            hasNavigationItems &&
            hasViewItems &&
            hasWindowItems
    }

    private static func menu(named title: String, in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu
    }

    private static func servicesMenu(in mainMenu: NSMenu?) -> NSMenu? {
        menuItem(titled: "Services", inMainMenu: mainMenu)?.submenu
    }

    private static func menuItem(for action: Selector, inMainMenu mainMenu: NSMenu?) -> NSMenuItem? {
        for rootItem in mainMenu?.items ?? [] {
            if let found = menuItem(for: action, in: rootItem.submenu) {
                return found
            }
        }

        return nil
    }

    private static func menuItem(titled title: String, inMainMenu mainMenu: NSMenu?) -> NSMenuItem? {
        for rootItem in mainMenu?.items ?? [] {
            if let found = menuItem(titled: title, in: rootItem.submenu) {
                return found
            }
        }

        return nil
    }

    private static func menuItem(for action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action {
                return item
            }
            if let found = menuItem(for: action, in: item.submenu) {
                return found
            }
        }

        return nil
    }

    private static func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title {
                return item
            }
            if let found = menuItem(titled: title, in: item.submenu) {
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

    private static func makeServicesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "Services")
        item.keyEquivalentModifierMask = []
        return item
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

    private static func expectedEntries(for section: AppMenuSection) -> [AppMenuEntry] {
        AppCommandRegistry.menuEntriesBySection[section] ?? []
    }

    private static func hasRequiredStructure(_ requiredEntries: [AppMenuEntry], in menu: NSMenu?) -> Bool {
        guard let menu, menu.items.count >= requiredEntries.count else {
            return false
        }

        return zip(menu.items.prefix(requiredEntries.count), requiredEntries).allSatisfy { item, entry in
            matches(item: item, expected: entry)
        }
    }

    private static func matches(item: NSMenuItem, expected entry: AppMenuEntry) -> Bool {
        switch entry {
        case .separator:
            return item.isSeparatorItem
        case .command(let commandID):
            let definition = AppCommandRegistry.definition(for: commandID)
            guard let menuDefinition = definition.menuItem else {
                return false
            }
            return item.title == menuDefinition.title && item.action == menuDefinition.selector
        case .submenu(let title, let entries):
            return item.title == title && hasRequiredStructure(entries, in: item.submenu)
        }
    }
}
