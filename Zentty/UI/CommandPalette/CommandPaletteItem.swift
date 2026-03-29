import Foundation

enum CommandPaletteItemID: Hashable {
    case command(AppCommandID)
    case openWith(stableID: String)
}

struct CommandPaletteItem: Identifiable, Equatable {
    let id: CommandPaletteItemID
    let title: String
    let subtitle: String
    let shortcutDisplay: String?
    let category: String
    let searchText: String
}

enum CommandPaletteItemBuilder {
    static func buildItems(
        availableCommandIDs: Set<AppCommandID>,
        shortcutManager: ShortcutManager,
        focusedPanePath: String? = nil
    ) -> [CommandPaletteItem] {
        AppCommandRegistry.definitions.compactMap { definition in
            guard availableCommandIDs.contains(definition.id) else {
                return nil
            }

            let subtitle = enrichedSubtitle(for: definition, focusedPanePath: focusedPanePath)
            let shortcut = shortcutManager.shortcut(for: definition.id)

            return CommandPaletteItem(
                id: .command(definition.id),
                title: definition.title,
                subtitle: subtitle,
                shortcutDisplay: shortcut?.displayString,
                category: definition.category.title,
                searchText: definition.searchText
            )
        }
    }

    static func buildOpenWithItems(
        targets: [OpenWithResolvedTarget],
        focusedPanePath: String?
    ) -> [CommandPaletteItem] {
        guard let path = focusedPanePath else { return [] }

        return targets.map { target in
            CommandPaletteItem(
                id: .openWith(stableID: target.stableID),
                title: "Open in \(target.displayName)",
                subtitle: path,
                shortcutDisplay: nil,
                category: "Open With",
                searchText: "open with \(target.displayName) editor \(target.kind.searchHint)".lowercased()
            )
        }
    }

    private static func enrichedSubtitle(
        for definition: AppCommandDefinition,
        focusedPanePath: String?
    ) -> String {
        guard let path = focusedPanePath else {
            return definition.detailDescription
        }

        switch definition.id {
        case .copyFocusedPanePath:
            return "Copy Path — \(path)"
        default:
            return definition.detailDescription
        }
    }
}

private extension OpenWithTargetKind {
    var searchHint: String {
        switch self {
        case .editor: "code"
        case .fileManager: "finder files"
        case .terminal: "terminal"
        }
    }
}
