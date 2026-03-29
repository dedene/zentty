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
    case toggleZoomOut = "pane.toggle_zoom_out"
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
            id: .toggleZoomOut,
            title: "Toggle Zoom Out",
            category: .panes,
            defaultShortcut: .init(key: .character("-"), modifiers: [.command, .shift]),
            action: .pane(.toggleZoomOut),
            menuItem: AppCommandMenuItem(
                section: .view,
                title: "Toggle Zoom Out",
                selector: #selector(MainWindowController.toggleZoomOut(_:))
            )
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
            .command(.toggleSidebar),
            .separator,
            .command(.splitHorizontally),
            .command(.splitVertically),
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
            .separator,
            .command(.toggleZoomOut),
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
        case .closeFocusedPane:
            "Close the currently focused pane while keeping the rest of the layout intact."
        case .focusLeftPane:
            "Move focus to the pane immediately to the left of the current pane."
        case .focusRightPane:
            "Move focus to the pane immediately to the right of the current pane."
        case .focusUpInColumn:
            "Move focus to the pane above the current one within the same column."
        case .focusDownInColumn:
            "Move focus to the pane below the current one within the same column."
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
        case .toggleZoomOut:
            "Toggle zoomed-out view of all panes for drag reordering."
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
