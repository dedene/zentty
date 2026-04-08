import AppKit

@MainActor
final class PaneLayoutMenuCoordinator {
    let menuButton: PaneLayoutMenuButton
    private var shortcutManager: ShortcutManager
    private weak var menuItemTarget: AnyObject?
    private var menuItemAction: Selector?

    var onAction: ((AppAction) -> Void)?

    init(menuButton: PaneLayoutMenuButton = PaneLayoutMenuButton(), shortcutManager: ShortcutManager) {
        self.menuButton = menuButton
        self.shortcutManager = shortcutManager
    }

    func setup(target: AnyObject, buttonAction: Selector, menuItemAction: Selector, theme: ZenttyTheme) {
        self.menuItemTarget = target
        self.menuItemAction = menuItemAction
        menuButton.target = target
        menuButton.action = buttonAction
        menuButton.configure(theme: theme, animated: false)
    }

    func updateShortcutManager(_ manager: ShortcutManager) {
        shortcutManager = manager
    }

    func applyTheme(_ theme: ZenttyTheme, animated: Bool) {
        menuButton.configure(theme: theme, animated: animated)
    }

    func showMenu(worklaneStore: WorklaneStore) {
        let menu = makeMenu(worklaneStore: worklaneStore)
        let menuLocation = NSPoint(x: 0, y: menuButton.bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: menuButton)
    }

    func handleMenuItem(_ sender: NSMenuItem) {
        guard let commandID = sender.representedObject as? AppCommandID else {
            return
        }
        onAction?(AppCommandRegistry.definition(for: commandID).action)
    }

    // MARK: - Menu Building

    func makeMenu(worklaneStore: WorklaneStore) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        addMenuItems([.splitHorizontally, .splitVertically], to: menu, worklaneStore: worklaneStore)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            makeSubmenuItem(
                title: "Width Presets",
                commandIDs: [
                    .arrangeWidthFull,
                    .arrangeWidthHalves,
                    .arrangeWidthThirds,
                    .arrangeWidthQuarters,
                ],
                trailingCommandIDs: [
                    .arrangeWidthGoldenFocusWide,
                    .arrangeWidthGoldenFocusNarrow,
                ],
                worklaneStore: worklaneStore
            )
        )
        menu.addItem(
            makeSubmenuItem(
                title: "Height Presets",
                commandIDs: [
                    .arrangeHeightFull,
                    .arrangeHeightTwoPerColumn,
                    .arrangeHeightThreePerColumn,
                    .arrangeHeightFourPerColumn,
                ],
                trailingCommandIDs: [
                    .arrangeHeightGoldenFocusTall,
                    .arrangeHeightGoldenFocusShort,
                ],
                worklaneStore: worklaneStore
            )
        )
        return menu
    }

    private func makeSubmenuItem(
        title: String,
        commandIDs: [AppCommandID],
        trailingCommandIDs: [AppCommandID] = [],
        worklaneStore: WorklaneStore
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        addMenuItems(commandIDs, to: submenu, worklaneStore: worklaneStore)
        if !trailingCommandIDs.isEmpty {
            submenu.addItem(NSMenuItem.separator())
            addMenuItems(trailingCommandIDs, to: submenu, worklaneStore: worklaneStore)
        }
        let allCommandIDs = commandIDs + trailingCommandIDs
        item.submenu = submenu
        item.isEnabled = allCommandIDs.contains(where: { isCommandEnabled($0, worklaneStore: worklaneStore) })
        return item
    }

    private func addMenuItems(_ commandIDs: [AppCommandID], to menu: NSMenu, worklaneStore: WorklaneStore) {
        commandIDs.forEach { commandID in
            menu.addItem(makeMenuItem(commandID: commandID, worklaneStore: worklaneStore))
        }
    }

    private func makeMenuItem(commandID: AppCommandID, worklaneStore: WorklaneStore) -> NSMenuItem {
        let definition = AppCommandRegistry.definition(for: commandID)
        let title = definition.menuItem?.title ?? definition.title
        let item = NSMenuItem(title: title, action: menuItemAction, keyEquivalent: "")
        item.target = menuItemTarget
        item.representedObject = commandID
        item.isEnabled = isCommandEnabled(commandID, worklaneStore: worklaneStore)
        apply(shortcutManager.shortcut(for: commandID), to: item)
        return item
    }

    private func isCommandEnabled(_ commandID: AppCommandID, worklaneStore: WorklaneStore) -> Bool {
        CommandAvailabilityResolver.isCommandAvailable(
            commandID,
            for: commandAvailabilityContext(worklaneStore: worklaneStore)
        )
    }

    private func commandAvailabilityContext(worklaneStore: WorklaneStore) -> CommandAvailabilityContext {
        let paneStripState = worklaneStore.activeWorklane?.paneStripState
        return CommandAvailabilityContext(
            worklaneCount: worklaneStore.worklanes.count,
            activePaneCount: paneStripState?.panes.count ?? 0,
            totalPaneCount: worklaneStore.worklanes.reduce(0) { $0 + $1.paneStripState.panes.count },
            activeColumnCount: paneStripState?.columns.count ?? 0,
            focusedColumnPaneCount: paneStripState?.focusedColumn?.panes.count ?? 0,
            focusedPaneHasRememberedSearch: false,
            globalSearchHasRememberedSearch: false
        )
    }

    private func apply(_ shortcut: KeyboardShortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.menuModifierFlags ?? []
    }
}
