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
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(makeEditMenuItem())

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

    private static func makeEditMenuActionItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.command]
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
        let editMenu = mainMenu?.items.dropFirst().first?.submenu
        let requiredEditItems: [(String, Selector, String)] = [
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ]
        let hasEditItems =
            editMenu?.title == "Edit" &&
            editMenu.map { menu in
                guard menu.items.count >= requiredEditItems.count else {
                    return false
                }

                return zip(menu.items.prefix(requiredEditItems.count), requiredEditItems).allSatisfy { item, expected in
                    item.title == expected.0 &&
                    item.action == expected.1 &&
                    item.keyEquivalent == expected.2 &&
                    item.keyEquivalentModifierMask == [.command]
                }
            } == true

        return hasQuitItem && hasEditItems
    }
}
