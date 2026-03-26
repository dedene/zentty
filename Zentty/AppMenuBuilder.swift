import AppKit

@MainActor
enum AppMenuBuilder {
    static func installIfNeeded(
        on application: NSApplication,
        appName: String = resolvedAppName()
    ) {
        guard hasRequiredMenuItems(in: application.mainMenu, appName: appName) == false else {
            return
        }

        application.mainMenu = makeMainMenu(appName: appName)
    }

    static func makeMainMenu(appName: String) -> NSMenu {
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
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())

        return mainMenu
    }

    static func resolvedAppName(bundle: Bundle = .main) -> String {
        if let bundleName = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
           bundleName.isEmpty == false {
            return bundleName
        }

        return ProcessInfo.processInfo.processName
    }

    private static func makeEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(makeEditMenuActionItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(makeMenuActionItem(
            title: "Copy Path",
            action: #selector(MainWindowController.copyFocusedPanePath(_:)),
            keyEquivalent: "c",
            modifiers: [.command, .shift]
        ))
        editMenu.addItem(makeEditMenuActionItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(makeEditMenuActionItem(
            title: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        ))

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    private static func makeFileMenuItem() -> NSMenuItem {
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(makeMenuActionItem(
            title: "New Workspace",
            action: #selector(MainWindowController.newWorkspace(_:)),
            keyEquivalent: "t"
        ))

        fileMenuItem.submenu = fileMenu
        return fileMenuItem
    }

    private static func makeViewMenuItem() -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        viewMenu.addItem(makeMenuActionItem(
            title: "Split Horizontally",
            action: #selector(MainWindowController.splitHorizontally(_:)),
            keyEquivalent: "d"
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Split Vertically",
            action: #selector(MainWindowController.splitVertically(_:)),
            keyEquivalent: "d",
            modifiers: [.command, .shift]
        ))
        viewMenu.addItem(makeSeparatorItem())
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Left Pane",
            action: #selector(MainWindowController.focusLeftPane(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Right Pane",
            action: #selector(MainWindowController.focusRightPane(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Up In Column",
            action: #selector(MainWindowController.focusUpInColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Down In Column",
            action: #selector(MainWindowController.focusDownInColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus First Column",
            action: #selector(MainWindowController.focusFirstColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option, .shift]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Last Column",
            action: #selector(MainWindowController.focusLastColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .option, .shift]
        ))
        viewMenu.addItem(makeSeparatorItem())
        viewMenu.addItem(makeMenuActionItem(
            title: "Resize Pane Left",
            action: #selector(MainWindowController.resizePaneLeft(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .control, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Resize Pane Right",
            action: #selector(MainWindowController.resizePaneRight(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .control, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Resize Pane Up",
            action: #selector(MainWindowController.resizePaneUp(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.command, .control, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Resize Pane Down",
            action: #selector(MainWindowController.resizePaneDown(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.command, .control, .option]
        ))
        viewMenu.addItem(makeSeparatorItem())
        viewMenu.addItem(makeMenuActionItem(
            title: "Reset Pane Layout",
            action: #selector(MainWindowController.resetPaneLayout(_:)),
            keyEquivalent: "0",
            modifiers: [.command, .control, .option]
        ))

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    private static func makeEditMenuActionItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        makeMenuActionItem(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    private static func makeMenuActionItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
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
            $0.keyEquivalent == "q" &&
            $0.title == "Quit \(appName)"
        })
        let hasSettingsItem = appMenu.items.contains(where: {
            $0.action == #selector(AppDelegate.showSettingsWindow(_:)) &&
            $0.keyEquivalent == "," &&
            $0.title == "Settings…"
        })
        let fileMenu = menu(named: "File", in: mainMenu)
        let editMenu = menu(named: "Edit", in: mainMenu)
        let viewMenu = menu(named: "View", in: mainMenu)
        let requiredFileItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("New Workspace", #selector(MainWindowController.newWorkspace(_:)), "t", [.command]),
        ]
        let requiredEditItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Copy Path", #selector(MainWindowController.copyFocusedPanePath(_:)), "c", [.command, .shift]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSResponder.selectAll(_:)), "a", [.command]),
        ]
        let requiredViewItems: [(String?, Selector?, String, NSEvent.ModifierFlags)] = [
            ("Split Horizontally", #selector(MainWindowController.splitHorizontally(_:)), "d", [.command]),
            ("Split Vertically", #selector(MainWindowController.splitVertically(_:)), "d", [.command, .shift]),
            (nil, nil, "", []),
            ("Focus Left Pane", #selector(MainWindowController.focusLeftPane(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            ("Focus Right Pane", #selector(MainWindowController.focusRightPane(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            ("Focus Up In Column", #selector(MainWindowController.focusUpInColumn(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            ("Focus Down In Column", #selector(MainWindowController.focusDownInColumn(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            ("Focus First Column", #selector(MainWindowController.focusFirstColumn(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option, .shift]),
            ("Focus Last Column", #selector(MainWindowController.focusLastColumn(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option, .shift]),
            (nil, nil, "", []),
            ("Resize Pane Left", #selector(MainWindowController.resizePaneLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .control, .option]),
            ("Resize Pane Right", #selector(MainWindowController.resizePaneRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .control, .option]),
            ("Resize Pane Up", #selector(MainWindowController.resizePaneUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .control, .option]),
            ("Resize Pane Down", #selector(MainWindowController.resizePaneDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .control, .option]),
            (nil, nil, "", []),
            ("Reset Pane Layout", #selector(MainWindowController.resetPaneLayout(_:)), "0", [.command, .control, .option]),
        ]
        let hasFileItems = hasRequiredItems(requiredFileItems, in: fileMenu)
        let hasEditItems =
            editMenu?.title == "Edit" &&
            hasRequiredItems(requiredEditItems, in: editMenu)
        let hasViewItems =
            viewMenu?.title == "View" &&
            hasRequiredItems(requiredViewItems, in: viewMenu)

        return hasSettingsItem && hasQuitItem && hasFileItems && hasEditItems && hasViewItems
    }

    private static func menu(named title: String, in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu
    }

    private static func hasRequiredItems(
        _ requiredItems: [(String, Selector, String, NSEvent.ModifierFlags)],
        in menu: NSMenu?
    ) -> Bool {
        guard let menu, menu.items.count >= requiredItems.count else {
            return false
        }

        return zip(menu.items.prefix(requiredItems.count), requiredItems).allSatisfy { item, expected in
            item.title == expected.0 &&
            item.action == expected.1 &&
            item.keyEquivalent == expected.2 &&
            item.keyEquivalentModifierMask == expected.3
        }
    }

    private static func hasRequiredItems(
        _ requiredItems: [(String?, Selector?, String, NSEvent.ModifierFlags)],
        in menu: NSMenu?
    ) -> Bool {
        guard let menu, menu.items.count >= requiredItems.count else {
            return false
        }

        return zip(menu.items.prefix(requiredItems.count), requiredItems).allSatisfy { item, expected in
            if let expectedTitle = expected.0 {
                return item.title == expectedTitle &&
                item.action == expected.1 &&
                item.keyEquivalent == expected.2 &&
                item.keyEquivalentModifierMask == expected.3
            }

            return item.isSeparatorItem &&
            item.action == expected.1 &&
            item.keyEquivalent == expected.2 &&
            item.keyEquivalentModifierMask == expected.3
        }
    }
}
