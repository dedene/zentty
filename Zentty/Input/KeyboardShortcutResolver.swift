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
    case copyFocusedPanePath = "pane.copy_path"
    case jumpToLatestNotification = "notifications.jump_latest"
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
    case closeFocusedPane = "pane.close_focused"
    case focusLeftPane = "pane.focus.left"
    case focusRightPane = "pane.focus.right"
    case focusUpInColumn = "pane.focus.up"
    case focusDownInColumn = "pane.focus.down"
    case focusFirstColumn = "pane.focus.first_column"
    case focusLastColumn = "pane.focus.last_column"
    case resizePaneLeft = "pane.resize.left"
    case resizePaneRight = "pane.resize.right"
    case resizePaneUp = "pane.resize.up"
    case resizePaneDown = "pane.resize.down"
    case resetPaneLayout = "pane.reset_layout"
    case navigateBack = "navigate.back"
    case navigateForward = "navigate.forward"
    case showCommandPalette = "command_palette.show"
    case openSettings = "app.open_settings"
    case closeWindow = "app.close_window"
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
    case copyFocusedPanePath
    case jumpToLatestNotification
    case pane(PaneCommand)
    case navigateBack
    case navigateForward
    case showCommandPalette
    case openSettings
    case closeWindow
    case reloadConfig
}

enum AppMenuSection: String, CaseIterable {
    case file = "File"
    case edit = "Edit"
    case view = "View"
}

enum AppMenuEntry {
    case separator
    case command(AppCommandID)
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
                selector: #selector(MainWindowController.toggleSidebar(_:))
            )
        ),
        AppCommandDefinition(
            id: .navigateBack,
            title: "Navigate Back",
            category: .general,
            defaultShortcut: .init(key: .character("["), modifiers: [.command]),
            action: .navigateBack,
            menuItem: AppCommandMenuItem(
                section: .view,
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
                section: .view,
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
            id: .jumpToLatestNotification,
            title: "Jump To Latest Notification",
            category: .notifications,
            defaultShortcut: .init(key: .character("u"), modifiers: [.command, .shift]),
            action: .jumpToLatestNotification,
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
            id: .closeFocusedPane,
            title: "Close Focused Pane",
            category: .panes,
            defaultShortcut: .init(key: .character("w"), modifiers: [.command]),
            action: .pane(.closeFocusedPane),
            menuItem: nil
        ),
        AppCommandDefinition(
            id: .focusLeftPane,
            title: "Focus Left Pane",
            category: .panes,
            defaultShortcut: .init(key: .leftArrow, modifiers: [.command, .option]),
            action: .pane(.focusLeft),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Focus Left Pane",
                selector: #selector(MainWindowController.focusLeftPane(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusRightPane,
            title: "Focus Right Pane",
            category: .panes,
            defaultShortcut: .init(key: .rightArrow, modifiers: [.command, .option]),
            action: .pane(.focusRight),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Focus Right Pane",
                selector: #selector(MainWindowController.focusRightPane(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusUpInColumn,
            title: "Focus Up In Column",
            category: .panes,
            defaultShortcut: .init(key: .upArrow, modifiers: [.command, .option]),
            action: .pane(.focusUp),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Focus Up In Column",
                selector: #selector(MainWindowController.focusUpInColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusDownInColumn,
            title: "Focus Down In Column",
            category: .panes,
            defaultShortcut: .init(key: .downArrow, modifiers: [.command, .option]),
            action: .pane(.focusDown),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Focus Down In Column",
                selector: #selector(MainWindowController.focusDownInColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusFirstColumn,
            title: "Focus First Column",
            category: .panes,
            defaultShortcut: .init(key: .leftArrow, modifiers: [.command, .option, .shift]),
            action: .pane(.focusFirstColumn),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Focus First Column",
                selector: #selector(MainWindowController.focusFirstColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .focusLastColumn,
            title: "Focus Last Column",
            category: .panes,
            defaultShortcut: .init(key: .rightArrow, modifiers: [.command, .option, .shift]),
            action: .pane(.focusLastColumn),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Focus Last Column",
                selector: #selector(MainWindowController.focusLastColumn(_:))
            )
        ),
        AppCommandDefinition(
            id: .resizePaneLeft,
            title: "Resize Pane Left",
            category: .panes,
            defaultShortcut: .init(key: .leftArrow, modifiers: [.command, .control, .option]),
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
            defaultShortcut: .init(key: .rightArrow, modifiers: [.command, .control, .option]),
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
            defaultShortcut: .init(key: .upArrow, modifiers: [.command, .control, .option]),
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
            defaultShortcut: .init(key: .downArrow, modifiers: [.command, .control, .option]),
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
            id: .openSettings,
            title: "Open Settings",
            category: .general,
            defaultShortcut: nil,
            action: .openSettings,
            menuItem: nil
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
            .command(.newWorklane),
            .command(.nextWorklane),
            .command(.previousWorklane),
        ],
        .edit: [
            .command(.copyFocusedPanePath),
        ],
        .view: [
            .command(.showCommandPalette),
            .separator,
            .command(.toggleSidebar),
            .separator,
            .command(.navigateBack),
            .command(.navigateForward),
            .separator,
            .command(.splitHorizontally),
            .command(.splitVertically),
            .separator,
            .command(.arrangeWidthFull),
            .command(.arrangeWidthHalves),
            .command(.arrangeWidthThirds),
            .command(.arrangeWidthQuarters),
            .separator,
            .command(.arrangeHeightFull),
            .command(.arrangeHeightTwoPerColumn),
            .command(.arrangeHeightThreePerColumn),
            .command(.arrangeHeightFourPerColumn),
            .separator,
            .command(.focusLeftPane),
            .command(.focusRightPane),
            .command(.focusUpInColumn),
            .command(.focusDownInColumn),
            .command(.focusFirstColumn),
            .command(.focusLastColumn),
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

    static func definition(for id: AppCommandID) -> AppCommandDefinition {
        guard let definition = definitionsByID[id] else {
            fatalError("Missing command definition for \(id.rawValue)")
        }

        return definition
    }

    static func commands(in category: ShortcutCategory) -> [AppCommandDefinition] {
        definitions.filter { $0.category == category }
    }
}

extension AppCommandDefinition {
    var detailDescription: String {
        switch id {
        case .toggleSidebar:
            "Show or hide the sidebar so you can focus on the canvas or quickly jump between worklanes."
        case .navigateBack:
            "Jump back to the previously focused pane, retracing your navigation history."
        case .navigateForward:
            "Jump forward to the pane you navigated away from after going back."
        case .newWorklane:
            "Create a new worklane immediately, keeping your current context intact while opening a fresh lane for new work."
        case .nextWorklane:
            "Move focus to the next worklane in sequence without leaving the keyboard."
        case .previousWorklane:
            "Move focus to the previous worklane so you can cycle backward through your active lanes."
        case .copyFocusedPanePath:
            "Copy the working path from the focused pane so you can paste it into another app or command."
        case .jumpToLatestNotification:
            "Jump directly to the latest in-app notification so you can review recent activity without scanning manually."
        case .splitHorizontally:
            "Split the focused pane horizontally to create another pane in the same column."
        case .splitVertically:
            "Split the focused pane vertically to create a new adjacent column."
        case .arrangeWidthFull:
            "Make every existing column span the full readable window width, preserving each column's current vertical stack."
        case .arrangeWidthHalves:
            "Normalize every existing column to half the readable window width while preserving vertical stacks."
        case .arrangeWidthThirds:
            "Normalize every existing column to one third of the readable window width while preserving vertical stacks."
        case .arrangeWidthQuarters:
            "Normalize every existing column to one quarter of the readable window width while preserving vertical stacks."
        case .arrangeHeightFull:
            "Repack panes into one pane per column so each pane takes the full height of its column."
        case .arrangeHeightTwoPerColumn:
            "Repack panes into columns of two panes each, distributed top-to-bottom then left-to-right."
        case .arrangeHeightThreePerColumn:
            "Repack panes into columns of three panes each, distributing any partial final column evenly."
        case .arrangeHeightFourPerColumn:
            "Repack panes into columns of four panes each, distributing any partial final column evenly."
        case .closeFocusedPane:
            "Close the currently focused pane while keeping the rest of the layout intact."
        case .focusLeftPane:
            "Move focus to the pane immediately to the left of the current pane."
        case .focusRightPane:
            "Move focus to the pane immediately to the right of the current pane."
        case .focusUpInColumn:
            "Move focus up within the column, or to the previous worklane at the top."
        case .focusDownInColumn:
            "Move focus down within the column, or to the next worklane at the bottom."
        case .focusFirstColumn:
            "Jump focus to the first column in the current pane layout."
        case .focusLastColumn:
            "Jump focus to the last column in the current pane layout."
        case .resizePaneLeft:
            "Make the focused pane wider by pulling its left boundary outward."
        case .resizePaneRight:
            "Make the focused pane wider by pushing its right boundary outward."
        case .resizePaneUp:
            "Increase the height of the focused pane by moving its upper split."
        case .resizePaneDown:
            "Increase the height of the focused pane by moving its lower split."
        case .resetPaneLayout:
            "Restore the current pane layout to its default proportions."
        case .showCommandPalette:
            "Open the command palette to quickly find and run any command."
        case .openSettings:
            "Open the settings window to customize shortcuts, appearance, and behavior."
        case .closeWindow:
            "Close the current window."
        case .reloadConfig:
            "Reload the configuration file from disk and apply any changes."
        }
    }

    var searchText: String {
        [title, detailDescription].joined(separator: " ").lowercased()
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
