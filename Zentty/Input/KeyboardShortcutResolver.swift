import AppKit

enum ShortcutCategory: String, CaseIterable, Equatable, Sendable {
    case general
    case worklanes
    case panes
    case notifications

    var title: String {
        switch self {
        case .general:
            "General"
        case .worklanes:
            "Worklanes"
        case .panes:
            "Panes"
        case .notifications:
            "Notifications"
        }
    }
}

enum AppCommandID: String, CaseIterable, Equatable, Hashable, Sendable {
    case toggleSidebar = "sidebar.toggle"
    case newWorklane = "worklane.new"
    case nextWorklane = "worklane.next"
    case previousWorklane = "worklane.previous"
    case find = "pane.search.find"
    case globalFind = "window.search.find"
    case useSelectionForFind = "pane.search.selection"
    case findNext = "pane.search.next"
    case findPrevious = "pane.search.previous"
    case copyFocusedPanePath = "pane.copy_path"
    case jumpToLatestNotification = "notifications.jump_latest"
    case duplicateFocusedPane = "pane.duplicate"
    case splitHorizontally = "pane.split.horizontal"
    case splitVertically = "pane.split.vertical"
    case arrangeWidthFull = "pane.arrange.width.full"
    case arrangeWidthHalves = "pane.arrange.width.halves"
    case arrangeWidthThirds = "pane.arrange.width.thirds"
    case arrangeWidthQuarters = "pane.arrange.width.quarters"
    case arrangeHeightFull = "pane.arrange.height.full"
    case arrangeHeightTwoPerColumn = "pane.arrange.height.two_per_column"
    case arrangeHeightThreePerColumn = "pane.arrange.height.three_per_column"
    case arrangeHeightFourPerColumn = "pane.arrange.height.four_per_column"
    case arrangeWidthGoldenFocusWide = "pane.arrange.width.golden_focus_wide"
    case arrangeWidthGoldenFocusNarrow = "pane.arrange.width.golden_focus_narrow"
    case arrangeHeightGoldenFocusTall = "pane.arrange.height.golden_focus_tall"
    case arrangeHeightGoldenFocusShort = "pane.arrange.height.golden_focus_short"
    case closeFocusedPane = "pane.close_focused"
    case focusPreviousPane = "pane.focus.previous"
    case focusNextPane = "pane.focus.next"
    case focusLeftPane = "pane.focus.left"
    case focusRightPane = "pane.focus.right"
    case focusUpInColumn = "pane.focus.up"
    case focusDownInColumn = "pane.focus.down"
    case resizePaneLeft = "pane.resize.left"
    case resizePaneRight = "pane.resize.right"
    case resizePaneUp = "pane.resize.up"
    case resizePaneDown = "pane.resize.down"
    case resetPaneLayout = "pane.reset_layout"
    case toggleZoomOut = "pane.toggle_zoom_out"
    case navigateBack = "navigate.back"
    case navigateForward = "navigate.forward"
    case showCommandPalette = "command_palette.show"
    case openBranchOnRemote = "branch.open_remote"
    case openSettings = "app.open_settings"
    case newWindow = "app.new_window"
    case closeWindow = "app.close_window"
    case cleanCopy = "clipboard.clean_copy"
    case copyRaw = "clipboard.copy_raw"
    case reloadConfig = "app.reload_config"
}

struct ShortcutBindingOverride: Equatable, Sendable {
    let commandID: AppCommandID
    let shortcut: KeyboardShortcut?
}

enum AppAction: Equatable, Sendable {
    case toggleSidebar
    case newWorklane
    case nextWorklane
    case previousWorklane
    case find
    case globalFind
    case useSelectionForFind
    case findNext
    case findPrevious
    case copyFocusedPanePath
    case cleanCopy
    case copyRaw
    case jumpToLatestNotification
    case pane(PaneCommand)
    case navigateBack
    case navigateForward
    case showCommandPalette
    case openBranchOnRemote
    case openSettings
    case newWindow
    case closeWindow
    case reloadConfig
}

enum AppMenuSection: String, CaseIterable {
    case file = "File"
    case edit = "Edit"
    case navigation = "Navigation"
    case view = "View"
}

indirect enum AppMenuEntry {
    case separator
    case command(AppCommandID)
    case submenu(String, [AppMenuEntry])
}

struct AppCommandMenuItem {
    let section: AppMenuSection
    let title: String
    let selector: Selector
}

struct AppCommandDefinition {
    let id: AppCommandID
    let title: String
    let category: ShortcutCategory
    let defaultShortcut: KeyboardShortcut?
    let action: AppAction
    let menuItem: AppCommandMenuItem?
}

enum AppCommandRegistry {
    static let definitions: [AppCommandDefinition] = [
        AppCommandDefinition(
            id: .toggleSidebar,
            title: "Toggle Sidebar",
            category: .general,
            defaultShortcut: .init(key: .character("s"), modifiers: [.command]),
            action: .toggleSidebar,
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Toggle Sidebar",
                selector: #selector(AppDelegate.toggleSidebarMenuItem(_:))
            )
        ),
        AppCommandDefinition(
            id: .navigateBack,
            title: "Navigate Back",
            category: .general,
            defaultShortcut: .init(key: .character("["), modifiers: [.command]),
            action: .navigateBack,
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Navigate Back",
                selector: #selector(MainWindowController.navigateBack(_:))
            )
        ),
        AppCommandDefinition(
            id: .navigateForward,
            title: "Navigate Forward",
            category: .general,
            defaultShortcut: .init(key: .character("]"), modifiers: [.command]),
            action: .navigateForward,
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Navigate Forward",
                selector: #selector(MainWindowController.navigateForward(_:))
            )
        ),
        AppCommandDefinition(
            id: .newWorklane,
            title: "New Worklane",
            category: .worklanes,
            defaultShortcut: .init(key: .character("t"), modifiers: [.command]),
            action: .newWorklane,
            menuItem: AppCommandMenuItem(
                section: .file,
                title: "New Worklane",
                selector: #selector(MainWindowController.newWorklane(_:))
            )
        ),
        AppCommandDefinition(
            id: .nextWorklane,
            title: "Next Worklane",
            category: .worklanes,
            defaultShortcut: .init(key: .tab, modifiers: [.control]),
            action: .nextWorklane,
            menuItem: AppCommandMenuItem(
                section: .file,
                title: "Next Worklane",
                selector: #selector(MainWindowController.nextWorklane(_:))
            )
        ),
        AppCommandDefinition(
            id: .previousWorklane,
            title: "Previous Worklane",
            category: .worklanes,
            defaultShortcut: .init(key: .tab, modifiers: [.control, .shift]),
            action: .previousWorklane,
            menuItem: AppCommandMenuItem(
                section: .file,
                title: "Previous Worklane",
                selector: #selector(MainWindowController.previousWorklane(_:))
            )
        ),
        AppCommandDefinition(
            id: .find,
            title: "Find",
            category: .panes,
            defaultShortcut: .init(key: .character("f"), modifiers: [.command]),
            action: .find,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Find…",
                selector: #selector(MainWindowController.find(_:))
            )
        ),
        AppCommandDefinition(
            id: .globalFind,
            title: "Global Find",
            category: .panes,
            defaultShortcut: .init(key: .character("f"), modifiers: [.command, .shift]),
            action: .globalFind,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Global Find…",
                selector: #selector(MainWindowController.globalFind(_:))
            )
        ),
        AppCommandDefinition(
            id: .useSelectionForFind,
            title: "Use Selection for Find",
            category: .panes,
            defaultShortcut: .init(key: .character("e"), modifiers: [.command]),
            action: .useSelectionForFind,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Use Selection for Find",
                selector: #selector(MainWindowController.useSelectionForFind(_:))
            )
        ),
        AppCommandDefinition(
            id: .findNext,
            title: "Find Next",
            category: .panes,
            defaultShortcut: .init(key: .character("g"), modifiers: [.command]),
            action: .findNext,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Find Next",
                selector: #selector(MainWindowController.findNext(_:))
            )
        ),
        AppCommandDefinition(
            id: .findPrevious,
            title: "Find Previous",
            category: .panes,
            defaultShortcut: .init(key: .character("g"), modifiers: [.command, .shift]),
            action: .findPrevious,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Find Previous",
                selector: #selector(MainWindowController.findPrevious(_:))
            )
        ),
        AppCommandDefinition(
            id: .copyFocusedPanePath,
            title: "Copy Path",
            category: .panes,
            defaultShortcut: .init(key: .character("c"), modifiers: [.command, .shift]),
            action: .copyFocusedPanePath,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Copy Path",
                selector: #selector(MainWindowController.copyFocusedPanePath(_:))
            )
        ),
        AppCommandDefinition(
            id: .cleanCopy,
            title: "Clean Copy",
            category: .general,
            defaultShortcut: .init(key: .character("c"), modifiers: [.command, .control]),
            action: .cleanCopy,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Clean Copy",
                selector: #selector(MainWindowController.cleanCopy(_:))
            )
        ),
        AppCommandDefinition(
            id: .copyRaw,
            title: "Copy Raw",
            category: .general,
            defaultShortcut: nil,
            action: .copyRaw,
            menuItem: AppCommandMenuItem(
                section: .edit,
                title: "Copy Raw",
                selector: #selector(MainWindowController.copyRaw(_:))
            )
        ),
        AppCommandDefinition(
            id: .jumpToLatestNotification,
            title: "Jump To Latest Notification",
            category: .notifications,
            defaultShortcut: .init(key: .character("u"), modifiers: [.command, .shift]),
            action: .jumpToLatestNotification,
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .duplicateFocusedPane,
            title: "Duplicate This Pane",
            category: .panes,
            defaultShortcut: nil,
            action: .pane(.duplicateFocusedPane),
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .splitHorizontally,
            title: "Split Horizontally",
            category: .panes,
            defaultShortcut: .init(key: .character("d"), modifiers: [.command]),
            action: .pane(.splitHorizontally),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Split Horizontally",
                selector: #selector(MainWindowController.splitHorizontally(_:))
            )
        ),
        AppCommandDefinition(
            id: .splitVertically,
            title: "Split Vertically",
            category: .panes,
            defaultShortcut: .init(key: .character("d"), modifiers: [.command, .shift]),
            action: .pane(.splitVertically),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Split Vertically",
                selector: #selector(MainWindowController.splitVertically(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeWidthFull,
            title: "Arrange Width: Full Width",
            category: .panes,
            defaultShortcut: .init(key: .character("1"), modifiers: [.command]),
            action: .pane(.arrangeHorizontally(.fullWidth)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Width: Full Width",
                selector: #selector(MainWindowController.arrangePaneWidthFull(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeWidthHalves,
            title: "Arrange Width: Half Width",
            category: .panes,
            defaultShortcut: .init(key: .character("2"), modifiers: [.command]),
            action: .pane(.arrangeHorizontally(.halfWidth)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Width: Half Width",
                selector: #selector(MainWindowController.arrangePaneWidthHalves(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeWidthThirds,
            title: "Arrange Width: Thirds",
            category: .panes,
            defaultShortcut: .init(key: .character("3"), modifiers: [.command]),
            action: .pane(.arrangeHorizontally(.thirds)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Width: Thirds",
                selector: #selector(MainWindowController.arrangePaneWidthThirds(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeWidthQuarters,
            title: "Arrange Width: Quarters",
            category: .panes,
            defaultShortcut: .init(key: .character("4"), modifiers: [.command]),
            action: .pane(.arrangeHorizontally(.quarters)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Width: Quarters",
                selector: #selector(MainWindowController.arrangePaneWidthQuarters(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeHeightFull,
            title: "Arrange Height: Full Height",
            category: .panes,
            defaultShortcut: .init(key: .character("1"), modifiers: [.command, .shift]),
            action: .pane(.arrangeVertically(.fullHeight)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Height: Full Height",
                selector: #selector(MainWindowController.arrangePaneHeightFull(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeHeightTwoPerColumn,
            title: "Arrange Height: 2 Per Column",
            category: .panes,
            defaultShortcut: .init(key: .character("2"), modifiers: [.command, .shift]),
            action: .pane(.arrangeVertically(.twoPerColumn)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Height: 2 Per Column",
                selector: #selector(MainWindowController.arrangePaneHeightTwoPerColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeHeightThreePerColumn,
            title: "Arrange Height: 3 Per Column",
            category: .panes,
            defaultShortcut: .init(key: .character("3"), modifiers: [.command, .shift]),
            action: .pane(.arrangeVertically(.threePerColumn)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Height: 3 Per Column",
                selector: #selector(MainWindowController.arrangePaneHeightThreePerColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeHeightFourPerColumn,
            title: "Arrange Height: 4 Per Column",
            category: .panes,
            defaultShortcut: .init(key: .character("4"), modifiers: [.command, .shift]),
            action: .pane(.arrangeVertically(.fourPerColumn)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Height: 4 Per Column",
                selector: #selector(MainWindowController.arrangePaneHeightFourPerColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeWidthGoldenFocusWide,
            title: "Arrange Width: Golden — Focus Wide",
            category: .panes,
            defaultShortcut: .init(key: .character("g"), modifiers: [.command, .control]),
            action: .pane(.arrangeGoldenRatio(.focusWide)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Width: Golden — Focus Wide",
                selector: #selector(MainWindowController.arrangeWidthGoldenFocusWide(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeWidthGoldenFocusNarrow,
            title: "Arrange Width: Golden — Focus Narrow",
            category: .panes,
            defaultShortcut: .init(key: .character("g"), modifiers: [.command, .control, .option]),
            action: .pane(.arrangeGoldenRatio(.focusNarrow)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Width: Golden — Focus Narrow",
                selector: #selector(MainWindowController.arrangeWidthGoldenFocusNarrow(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeHeightGoldenFocusTall,
            title: "Arrange Height: Golden — Focus Tall",
            category: .panes,
            defaultShortcut: .init(key: .character("g"), modifiers: [.command, .control, .shift]),
            action: .pane(.arrangeGoldenRatio(.focusTall)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Height: Golden — Focus Tall",
                selector: #selector(MainWindowController.arrangeHeightGoldenFocusTall(_:))
            )
        ),
        AppCommandDefinition(
            id: .arrangeHeightGoldenFocusShort,
            title: "Arrange Height: Golden — Focus Short",
            category: .panes,
            defaultShortcut: .init(key: .character("g"), modifiers: [.command, .control, .shift, .option]),
            action: .pane(.arrangeGoldenRatio(.focusShort)),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Arrange Height: Golden — Focus Short",
                selector: #selector(MainWindowController.arrangeHeightGoldenFocusShort(_:))
            )
        ),
        AppCommandDefinition(
            id: .closeFocusedPane,
            title: "Close Focused Pane",
            category: .panes,
            defaultShortcut: .init(key: .character("w"), modifiers: [.command]),
            action: .pane(.closeFocusedPane),
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .focusPreviousPane,
            title: "Focus Previous Pane",
            category: .panes,
            defaultShortcut: .init(key: .upArrow, modifiers: [.command, .option]),
            action: .pane(.focusPreviousPaneBySidebarOrder),
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Focus Previous Pane",
                selector: #selector(MainWindowController.focusPreviousPane(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusNextPane,
            title: "Focus Next Pane",
            category: .panes,
            defaultShortcut: .init(key: .downArrow, modifiers: [.command, .option]),
            action: .pane(.focusNextPaneBySidebarOrder),
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Focus Next Pane",
                selector: #selector(MainWindowController.focusNextPane(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusLeftPane,
            title: "Focus Left Pane",
            category: .panes,
            defaultShortcut: .init(key: .leftArrow, modifiers: [.command]),
            action: .pane(.focusLeft),
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Focus Left Pane",
                selector: #selector(MainWindowController.focusLeftPane(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusRightPane,
            title: "Focus Right Pane",
            category: .panes,
            defaultShortcut: .init(key: .rightArrow, modifiers: [.command]),
            action: .pane(.focusRight),
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Focus Right Pane",
                selector: #selector(MainWindowController.focusRightPane(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusUpInColumn,
            title: "Focus Up In Column",
            category: .panes,
            defaultShortcut: .init(key: .upArrow, modifiers: [.command]),
            action: .pane(.focusUp),
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Focus Up In Column",
                selector: #selector(MainWindowController.focusUpInColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusDownInColumn,
            title: "Focus Down In Column",
            category: .panes,
            defaultShortcut: .init(key: .downArrow, modifiers: [.command]),
            action: .pane(.focusDown),
            menuItem: AppCommandMenuItem(
                section: .navigation,
                title: "Focus Down In Column",
                selector: #selector(MainWindowController.focusDownInColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .resizePaneLeft,
            title: "Resize Pane Left",
            category: .panes,
            defaultShortcut: .init(key: .leftArrow, modifiers: [.command, .option, .shift]),
            action: .pane(.resizeLeft),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Resize Pane Left",
                selector: #selector(MainWindowController.resizePaneLeft(_:))
            )
        ),
        AppCommandDefinition(
            id: .resizePaneRight,
            title: "Resize Pane Right",
            category: .panes,
            defaultShortcut: .init(key: .rightArrow, modifiers: [.command, .option, .shift]),
            action: .pane(.resizeRight),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Resize Pane Right",
                selector: #selector(MainWindowController.resizePaneRight(_:))
            )
        ),
        AppCommandDefinition(
            id: .resizePaneUp,
            title: "Resize Pane Up",
            category: .panes,
            defaultShortcut: .init(key: .upArrow, modifiers: [.command, .option, .shift]),
            action: .pane(.resizeUp),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Resize Pane Up",
                selector: #selector(MainWindowController.resizePaneUp(_:))
            )
        ),
        AppCommandDefinition(
            id: .resizePaneDown,
            title: "Resize Pane Down",
            category: .panes,
            defaultShortcut: .init(key: .downArrow, modifiers: [.command, .option, .shift]),
            action: .pane(.resizeDown),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Resize Pane Down",
                selector: #selector(MainWindowController.resizePaneDown(_:))
            )
        ),
        AppCommandDefinition(
            id: .resetPaneLayout,
            title: "Reset Pane Layout",
            category: .panes,
            defaultShortcut: .init(key: .character("0"), modifiers: [.command, .control, .option]),
            action: .pane(.resetLayout),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Reset Pane Layout",
                selector: #selector(MainWindowController.resetPaneLayout(_:))
            )
        ),
        // Toggle Zoom Out is currently internal-only (triggered by drag).
        // Hidden from menu and command palette until the UX is finalized.
        AppCommandDefinition(
            id: .toggleZoomOut,
            title: "Toggle Zoom Out",
            category: .panes,
            defaultShortcut: nil,
            action: .pane(.toggleZoomOut),
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .showCommandPalette,
            title: "Command Palette",
            category: .general,
            defaultShortcut: .init(key: .character("p"), modifiers: [.command, .shift]),
            action: .showCommandPalette,
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Command Palette…",
                selector: #selector(MainWindowController.showCommandPalette(_:))
            )
        ),
        AppCommandDefinition(
            id: .openBranchOnRemote,
            title: "Open Branch on Remote",
            category: .general,
            defaultShortcut: nil,
            action: .openBranchOnRemote,
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .openSettings,
            title: "Open Settings",
            category: .general,
            defaultShortcut: .init(key: .character(","), modifiers: [.command]),
            action: .openSettings,
            menuItem: AppCommandMenuItem(
                section: .file,
                title: "Settings…",
                selector: #selector(AppDelegate.showSettingsWindow(_:))
            )
        ),
        AppCommandDefinition(
            id: .newWindow,
            title: "New Window",
            category: .general,
            defaultShortcut: .init(key: .character("n"), modifiers: [.command, .shift]),
            action: .newWindow,
            menuItem: AppCommandMenuItem(
                section: .file,
                title: "New Window",
                selector: #selector(AppDelegate.newWindow(_:))
            )
        ),
        AppCommandDefinition(
            id: .closeWindow,
            title: "Close Window",
            category: .general,
            defaultShortcut: nil,
            action: .closeWindow,
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .reloadConfig,
            title: "Reload Configuration",
            category: .general,
            defaultShortcut: nil,
            action: .reloadConfig,
            menuItem: nil
        ),
    ]

    static let menuEntriesBySection: [AppMenuSection: [AppMenuEntry]] = [
        .file: [
            .command(.newWindow),
            .command(.newWorklane),
            .separator,
            .command(.nextWorklane),
            .command(.previousWorklane),
        ],
        .edit: [
            .submenu("Find", [
                .command(.find),
                .command(.globalFind),
                .command(.findNext),
                .command(.findPrevious),
                .command(.useSelectionForFind),
            ]),
            .command(.copyFocusedPanePath),
            .command(.cleanCopy),
            .command(.copyRaw),
        ],
        .navigation: [
            .command(.navigateBack),
            .command(.navigateForward),
            .separator,
            .command(.focusPreviousPane),
            .command(.focusNextPane),
            .command(.focusLeftPane),
            .command(.focusRightPane),
            .command(.focusUpInColumn),
            .command(.focusDownInColumn),
        ],
        .view: [
            .command(.showCommandPalette),
            .separator,
            .command(.toggleSidebar),
            .separator,
            .command(.splitHorizontally),
            .command(.splitVertically),
            .separator,
            .submenu("Arrange Width", [
                .command(.arrangeWidthFull),
                .command(.arrangeWidthHalves),
                .command(.arrangeWidthThirds),
                .command(.arrangeWidthQuarters),
                .separator,
                .command(.arrangeWidthGoldenFocusWide),
                .command(.arrangeWidthGoldenFocusNarrow),
            ]),
            .submenu("Arrange Height", [
                .command(.arrangeHeightFull),
                .command(.arrangeHeightTwoPerColumn),
                .command(.arrangeHeightThreePerColumn),
                .command(.arrangeHeightFourPerColumn),
                .separator,
                .command(.arrangeHeightGoldenFocusTall),
                .command(.arrangeHeightGoldenFocusShort),
            ]),
            .separator,
            .command(.resizePaneLeft),
            .command(.resizePaneRight),
            .command(.resizePaneUp),
            .command(.resizePaneDown),
            .separator,
            .command(.resetPaneLayout),
        ],
    ]

    private static let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    private static let commandIDByMenuAction = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
        definition.menuItem.map { (NSStringFromSelector($0.selector), definition.id) }
    })

    static func definition(for id: AppCommandID) -> AppCommandDefinition {
        guard let definition = definitionsByID[id] else {
            fatalError("Missing command definition for \(id.rawValue)")
        }

        return definition
    }

    static func commands(in category: ShortcutCategory) -> [AppCommandDefinition] {
        definitions.filter { $0.category == category }
    }

    static func commandID(forMenuAction selector: Selector) -> AppCommandID? {
        commandIDByMenuAction[NSStringFromSelector(selector)]
    }
}

extension AppCommandDefinition {
    var detailDescription: String {
        switch id {
        case .toggleSidebar:
            "Show or hide the sidebar."
        case .navigateBack:
            "Go back to the pane you were in before."
        case .navigateForward:
            "Go forward again after navigating back."
        case .newWorklane:
            "Open a new worklane."
        case .nextWorklane:
            "Switch to the next worklane."
        case .previousWorklane:
            "Switch to the previous worklane."
        case .find:
            "Open find in the focused pane."
        case .globalFind:
            "Search across all panes in this window."
        case .useSelectionForFind:
            "Find the selected text in the focused pane."
        case .findNext:
            "Go to the next search result."
        case .findPrevious:
            "Go to the previous search result."
        case .copyFocusedPanePath:
            "Copy the working directory path from the focused pane."
        case .cleanCopy:
            "Copy the selected text with extra whitespace, color codes, and shell prompts removed."
        case .copyRaw:
            "Copy the selected text exactly as it appears, without any cleanup."
        case .jumpToLatestNotification:
            "Go to the most recent notification."
        case .duplicateFocusedPane:
            "Duplicate the focused pane in a new column, keeping its working directory."
        case .splitHorizontally:
            "Add a pane below in the same column."
        case .splitVertically:
            "Add a pane to the right in a new column."
        case .arrangeWidthFull:
            "Give each column the full window width."
        case .arrangeWidthHalves:
            "Set all columns to equal halves."
        case .arrangeWidthThirds:
            "Set all columns to equal thirds."
        case .arrangeWidthQuarters:
            "Set all columns to equal quarters."
        case .arrangeHeightFull:
            "One pane per column, full height."
        case .arrangeHeightTwoPerColumn:
            "Stack two panes per column."
        case .arrangeHeightThreePerColumn:
            "Stack three panes per column."
        case .arrangeHeightFourPerColumn:
            "Stack four panes per column."
        case .arrangeWidthGoldenFocusWide:
            "Golden ratio: focused column gets the wide side (~62%)."
        case .arrangeWidthGoldenFocusNarrow:
            "Golden ratio: focused column gets the narrow side (~38%)."
        case .arrangeHeightGoldenFocusTall:
            "Golden ratio: focused pane gets the tall side (~62%)."
        case .arrangeHeightGoldenFocusShort:
            "Golden ratio: focused pane gets the short side (~38%)."
        case .closeFocusedPane:
            "Close the focused pane."
        case .focusPreviousPane:
            "Focus the previous pane, wrapping across worklanes."
        case .focusNextPane:
            "Focus the next pane, wrapping across worklanes."
        case .focusLeftPane:
            "Focus the pane to the left."
        case .focusRightPane:
            "Focus the pane to the right."
        case .focusUpInColumn:
            "Focus the pane above, or the previous worklane at the top."
        case .focusDownInColumn:
            "Focus the pane below, or the next worklane at the bottom."
        case .resizePaneLeft:
            "Grow the focused pane to the left."
        case .resizePaneRight:
            "Grow the focused pane to the right."
        case .resizePaneUp:
            "Grow the focused pane upward."
        case .resizePaneDown:
            "Grow the focused pane downward."
        case .resetPaneLayout:
            "Reset pane sizes to their defaults."
        case .toggleZoomOut:
            "Zoom out to see all panes and drag to reorder."
        case .showCommandPalette:
            "Open the command palette."
        case .openBranchOnRemote:
            "Open the current branch on GitHub or your remote host."
        case .openSettings:
            "Open settings."
        case .newWindow:
            "Open a new window."
        case .closeWindow:
            "Close this window."
        case .reloadConfig:
            "Reload the config file from disk."
        }
    }

    var searchText: String {
        switch id {
        case .openBranchOnRemote:
            [title, detailDescription, "remote branch github branch gitlab branch"]
                .joined(separator: " ")
                .lowercased()
        default:
            [title, detailDescription].joined(separator: " ").lowercased()
        }
    }
}

struct ShortcutConflict: Equatable {
    let commandID: AppCommandID
    let shortcut: KeyboardShortcut
}

struct ShortcutManager {
    private let activeShortcutByCommandID: [AppCommandID: KeyboardShortcut]
    private let unboundCommandIDs: Set<AppCommandID>
    private let commandIDByActiveShortcut: [KeyboardShortcut: AppCommandID]
    let bindings: [ShortcutBindingOverride]

    init(shortcuts: AppConfig.Shortcuts) {
        let bindings = Self.sanitizedBindings(shortcuts.bindings)
        self.bindings = bindings

        var activeShortcutByCommandID = [AppCommandID: KeyboardShortcut](
            uniqueKeysWithValues: AppCommandRegistry.definitions.compactMap { definition -> (AppCommandID, KeyboardShortcut)? in
                guard let shortcut = definition.defaultShortcut else {
                    return nil
                }

                return (definition.id, shortcut)
            }
        )
        var unboundCommandIDs: Set<AppCommandID> = []

        for binding in bindings {
            activeShortcutByCommandID.removeValue(forKey: binding.commandID)
            guard let shortcut = binding.shortcut else {
                unboundCommandIDs.insert(binding.commandID)
                continue
            }

            activeShortcutByCommandID[binding.commandID] = shortcut
        }

        self.activeShortcutByCommandID = activeShortcutByCommandID
        self.unboundCommandIDs = unboundCommandIDs
        self.commandIDByActiveShortcut = Dictionary(
            uniqueKeysWithValues: activeShortcutByCommandID.map { ($1, $0) }
        )
    }

    func commandID(for shortcut: KeyboardShortcut) -> AppCommandID? {
        commandIDByActiveShortcut[shortcut]
    }

    func shortcut(for commandID: AppCommandID) -> KeyboardShortcut? {
        if let shortcut = activeShortcutByCommandID[commandID] {
            return shortcut
        }

        if unboundCommandIDs.contains(commandID) {
            return nil
        }

        return AppCommandRegistry.definition(for: commandID).defaultShortcut
    }

    func isUnbound(_ commandID: AppCommandID) -> Bool {
        unboundCommandIDs.contains(commandID)
    }

    func conflict(for shortcut: KeyboardShortcut, assigningTo commandID: AppCommandID) -> ShortcutConflict? {
        guard let conflictingCommandID = commandIDByActiveShortcut[shortcut],
              conflictingCommandID != commandID else {
            return nil
        }

        return ShortcutConflict(commandID: conflictingCommandID, shortcut: shortcut)
    }

    static func updatedBindings(
        from bindings: [ShortcutBindingOverride],
        commandID: AppCommandID,
        shortcut: KeyboardShortcut?
    ) -> [ShortcutBindingOverride] {
        let filtered = bindings.filter { $0.commandID != commandID }
        let definition = AppCommandRegistry.definition(for: commandID)

        if definition.defaultShortcut == shortcut {
            return sanitizedBindings(filtered)
        }

        return sanitizedBindings(
            filtered + [ShortcutBindingOverride(commandID: commandID, shortcut: shortcut)]
        )
    }

    static func sanitizedBindings(_ bindings: [ShortcutBindingOverride]) -> [ShortcutBindingOverride] {
        let deduplicated = deduplicatedBindings(bindings)
        let overriddenCommandIDs = Set(deduplicated.map(\.commandID))
        var activeCommandIDByShortcut = [KeyboardShortcut: AppCommandID](
            uniqueKeysWithValues: AppCommandRegistry.definitions.compactMap { definition -> (KeyboardShortcut, AppCommandID)? in
                guard
                    overriddenCommandIDs.contains(definition.id) == false,
                    let shortcut = definition.defaultShortcut
                else {
                    return nil
                }

                return (shortcut, definition.id)
            }
        )
        var sanitized: [ShortcutBindingOverride] = []

        for binding in deduplicated {
            let definition = AppCommandRegistry.definition(for: binding.commandID)
            if definition.defaultShortcut == binding.shortcut {
                continue
            }

            guard let shortcut = binding.shortcut else {
                sanitized.append(binding)
                continue
            }

            guard shortcut.isEligibleCommandBinding else {
                continue
            }

            guard activeCommandIDByShortcut[shortcut] == nil else {
                continue
            }

            activeCommandIDByShortcut[shortcut] = binding.commandID
            sanitized.append(binding)
        }

        return sanitized
    }

    private static func deduplicatedBindings(_ bindings: [ShortcutBindingOverride]) -> [ShortcutBindingOverride] {
        var seenCommandIDs: Set<AppCommandID> = []
        var deduplicatedReversed: [ShortcutBindingOverride] = []

        for binding in bindings.reversed() where seenCommandIDs.insert(binding.commandID).inserted {
            deduplicatedReversed.append(binding)
        }

        return deduplicatedReversed.reversed()
    }
}

enum KeyboardShortcutResolver {
    static func resolve(
        _ shortcut: KeyboardShortcut,
        shortcuts: AppConfig.Shortcuts = .default
    ) -> AppAction? {
        let manager = ShortcutManager(shortcuts: shortcuts)
        guard let commandID = manager.commandID(for: shortcut) else {
            return nil
        }

        return AppCommandRegistry.definition(for: commandID).action
    }
}
