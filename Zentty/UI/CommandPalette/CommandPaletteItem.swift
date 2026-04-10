import Foundation

enum CommandPaletteItemID: Hashable {
    case command(AppCommandID)
    case openWith(stableID: String)
}

enum CommandPaletteItemFamily: Hashable {
    case openWith
}

struct CommandPaletteItem: Identifiable, Equatable {
    let id: CommandPaletteItemID
    let title: String
    let subtitle: String
    let shortcutDisplay: String?
    let category: String
    let searchText: String
    let family: CommandPaletteItemFamily?
    let familySearchText: String?
    let familyOrder: Int?
}

enum CommandPaletteItemBuilder {
    static func buildItems(
        availableCommandIDs: Set<AppCommandID>,
        shortcutManager: ShortcutManager,
        focusedPanePath: String? = nil,
        focusedBranchName: String? = nil
    ) -> [CommandPaletteItem] {
        AppCommandRegistry.definitions.compactMap { definition in
            guard availableCommandIDs.contains(definition.id) else {
                return nil
            }

            let subtitle = enrichedSubtitle(
                for: definition,
                focusedPanePath: focusedPanePath,
                focusedBranchName: focusedBranchName
            )
            let shortcut = shortcutManager.shortcut(for: definition.id)

            return CommandPaletteItem(
                id: .command(definition.id),
                title: definition.title,
                subtitle: subtitle,
                shortcutDisplay: shortcut?.displayString,
                category: definition.category.title,
                searchText: definition.searchText,
                family: nil,
                familySearchText: nil,
                familyOrder: nil
            )
        }
    }

    static func buildOpenWithItems(
        targets: [OpenWithResolvedTarget],
        focusedPanePath: String?
    ) -> [CommandPaletteItem] {
        guard let path = focusedPanePath else { return [] }

        return targets.enumerated().map { index, target in
            let familySearchText = [
                target.displayName,
                target.kind.searchHint,
                target.searchAliases,
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

            return CommandPaletteItem(
                id: .openWith(stableID: target.stableID),
                title: target.displayName,
                subtitle: path,
                shortcutDisplay: nil,
                category: "Open With",
                searchText: "open with open \(familySearchText)".lowercased(),
                family: .openWith,
                familySearchText: familySearchText,
                familyOrder: index
            )
        }
    }

    private static func enrichedSubtitle(
        for definition: AppCommandDefinition,
        focusedPanePath: String?,
        focusedBranchName: String?
    ) -> String {
        switch definition.id {
        case .copyFocusedPanePath:
            guard let path = focusedPanePath else {
                return definition.detailDescription
            }
            return "Copy Path — \(path)"
        case .openBranchOnRemote:
            guard let focusedBranchName, focusedBranchName.isEmpty == false else {
                return definition.detailDescription
            }
            return "Open remote branch — \(focusedBranchName)"
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

private extension OpenWithResolvedTarget {
    var searchAliases: String {
        let aliases: [String] = switch builtInID {
        case .vscode?:
            ["code", "visual studio code", "visual studio"]
        case .vscodeInsiders?:
            ["code insiders", "visual studio code insiders", "visual studio"]
        case .cursor?:
            ["ai editor"]
        case .zed?:
            ["zed editor"]
        case .windsurf?:
            ["codeium", "ai editor"]
        case .antigravity?:
            ["ai editor"]
        case .finder?:
            ["files", "file manager"]
        case .xcode?:
            ["apple ide", "swift"]
        case .androidStudio?:
            ["jetbrains", "android"]
        case .intellijIdea?:
            ["jetbrains", "idea", "intellij"]
        case .rider?:
            ["jetbrains", "dotnet"]
        case .goland?:
            ["jetbrains", "go"]
        case .rustrover?:
            ["jetbrains", "rust"]
        case .pycharm?:
            ["jetbrains", "python"]
        case .webstorm?:
            ["jetbrains", "javascript", "typescript"]
        case .phpstorm?:
            ["jetbrains", "php"]
        case .sublimeText?:
            ["sublime"]
        case .bbedit?:
            ["bare bones"]
        case .textmate?:
            ["text mate"]
        case nil:
            []
        }

        return aliases.joined(separator: " ")
    }
}
