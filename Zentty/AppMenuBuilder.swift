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
        appMenu.addItem(.separator())
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
            action: #selector(AppDelegate.newWorkspace(_:)),
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
            action: #selector(AppDelegate.splitHorizontally(_:)),
            keyEquivalent: "d"
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Split Vertically",
            action: #selector(AppDelegate.splitVertically(_:)),
            keyEquivalent: "d",
            modifiers: [.command, .shift]
        ))
        let separatorItem = NSMenuItem.separator()
        separatorItem.keyEquivalentModifierMask = []
        viewMenu.addItem(separatorItem)
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Left Pane",
            action: #selector(AppDelegate.focusLeftPane(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Right Pane",
            action: #selector(AppDelegate.focusRightPane(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Up In Column",
            action: #selector(AppDelegate.focusUpInColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Down In Column",
            action: #selector(AppDelegate.focusDownInColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.command, .option]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus First Column",
            action: #selector(AppDelegate.focusFirstColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option, .shift]
        ))
        viewMenu.addItem(makeMenuActionItem(
            title: "Focus Last Column",
            action: #selector(AppDelegate.focusLastColumn(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .option, .shift]
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
            ("New Workspace", #selector(AppDelegate.newWorkspace(_:)), "t", [.command]),
        ]
        let requiredEditItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ].map { ($0.0, $0.1, $0.2, [.command]) }
        let requiredViewItems: [(String?, Selector?, String, NSEvent.ModifierFlags)] = [
            ("Split Horizontally", #selector(AppDelegate.splitHorizontally(_:)), "d", [.command]),
            ("Split Vertically", #selector(AppDelegate.splitVertically(_:)), "d", [.command, .shift]),
            (nil, nil, "", []),
            ("Focus Left Pane", #selector(AppDelegate.focusLeftPane(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
            ("Focus Right Pane", #selector(AppDelegate.focusRightPane(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            ("Focus Up In Column", #selector(AppDelegate.focusUpInColumn(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            ("Focus Down In Column", #selector(AppDelegate.focusDownInColumn(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            ("Focus First Column", #selector(AppDelegate.focusFirstColumn(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option, .shift]),
            ("Focus Last Column", #selector(AppDelegate.focusLastColumn(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option, .shift]),
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
