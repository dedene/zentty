import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    let id: AppCommandID
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
                id: definition.id,
                title: definition.title,
                subtitle: subtitle,
                shortcutDisplay: shortcut?.displayString,
                category: definition.category.title,
                searchText: definition.searchText
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
