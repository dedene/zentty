import AppKit
import Foundation

enum CommandPaletteItemID: Hashable {
    case command(AppCommandID)
    case openWith(stableID: String)
    case worklaneColor(WorklaneColor?)
    case settings(SettingsSection)
    case pane(worklaneID: WorklaneID, paneID: PaneID)
    case restoredCommand(paneID: PaneID)
}

enum CommandPaletteItemFamily: Hashable {
    case openWith
    case worklaneColor
}

enum CommandPaletteItemGroup: Int, Hashable {
    case pane
    case settings
    case action

    var title: String {
        switch self {
        case .pane:
            "Panes"
        case .settings:
            "Settings"
        case .action:
            "Actions"
        }
    }
}

struct CommandPaletteItem: Identifiable, Equatable {
    let id: CommandPaletteItemID
    let title: String
    let subtitle: String
    let shortcutDisplay: String?
    let category: String
    let searchText: String
    let primarySearchText: String
    let secondarySearchText: String
    let primaryAliasSearchText: String
    let secondaryAliasSearchText: String
    let group: CommandPaletteItemGroup
    let iconSystemName: String
    let iconImage: NSImage?
    let rankingBoost: Double
    let family: CommandPaletteItemFamily?
    let familySearchText: String?
    let familyOrder: Int?

    init(
        id: CommandPaletteItemID,
        title: String,
        subtitle: String,
        shortcutDisplay: String?,
        category: String,
        searchText: String,
        primarySearchText: String? = nil,
        secondarySearchText: String? = nil,
        group: CommandPaletteItemGroup = .action,
        iconSystemName: String = "command",
        iconImage: NSImage? = nil,
        rankingBoost: Double = 0,
        family: CommandPaletteItemFamily? = nil,
        familySearchText: String? = nil,
        familyOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcutDisplay = shortcutDisplay
        self.category = category
        self.searchText = CommandPaletteSearchTextNormalizer.normalized(searchText)
        self.primarySearchText = CommandPaletteSearchTextNormalizer.normalized(primarySearchText ?? title)
        self.secondarySearchText = CommandPaletteSearchTextNormalizer.normalized(secondarySearchText ?? searchText)
        self.primaryAliasSearchText = CommandPaletteSearchTextNormalizer.separatorInsensitive(primarySearchText ?? title)
        self.secondaryAliasSearchText = CommandPaletteSearchTextNormalizer.separatorInsensitive(secondarySearchText ?? searchText)
        self.group = group
        self.iconSystemName = iconSystemName
        self.iconImage = iconImage
        self.rankingBoost = rankingBoost
        self.family = family
        self.familySearchText = familySearchText
        self.familyOrder = familyOrder
    }

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.shortcutDisplay == rhs.shortcutDisplay
            && lhs.category == rhs.category
            && lhs.searchText == rhs.searchText
            && lhs.primarySearchText == rhs.primarySearchText
            && lhs.secondarySearchText == rhs.secondarySearchText
            && lhs.primaryAliasSearchText == rhs.primaryAliasSearchText
            && lhs.secondaryAliasSearchText == rhs.secondaryAliasSearchText
            && lhs.group == rhs.group
            && lhs.iconSystemName == rhs.iconSystemName
            && lhs.iconImage === rhs.iconImage
            && lhs.rankingBoost == rhs.rankingBoost
            && lhs.family == rhs.family
            && lhs.familySearchText == rhs.familySearchText
            && lhs.familyOrder == rhs.familyOrder
    }
}

enum CommandPaletteItemBuilder {
    static func buildItems(
        availableCommandIDs: Set<AppCommandID>,
        shortcutManager: ShortcutManager,
        focusedPanePath: String? = nil,
        focusedBranchName: String? = nil,
        rightPaneCommandPresentation: PaneRightCommandPresentation = .addsToWorklane
    ) -> [CommandPaletteItem] {
        AppCommandRegistry.definitions.compactMap { definition in
            guard availableCommandIDs.contains(definition.id) else {
                return nil
            }

            let title = title(
                for: definition,
                rightPaneCommandPresentation: rightPaneCommandPresentation
            )
            let subtitle = enrichedSubtitle(
                for: definition,
                focusedPanePath: focusedPanePath,
                focusedBranchName: focusedBranchName,
                rightPaneCommandPresentation: rightPaneCommandPresentation
            )
            let shortcut = shortcutManager.shortcut(for: definition.id)

            return CommandPaletteItem(
                id: .command(definition.id),
                title: title,
                subtitle: subtitle,
                shortcutDisplay: shortcut?.displayString,
                category: definition.category.title,
                searchText: searchText(for: definition, title: title, subtitle: subtitle),
                iconSystemName: iconSystemName(for: definition.id),
                family: nil,
                familySearchText: nil,
                familyOrder: nil
            )
        }
    }

    static func buildSettingsItems() -> [CommandPaletteItem] {
        SettingsSection.allCases.map { section in
            let title = "\(section.title) Settings"
            return CommandPaletteItem(
                id: .settings(section),
                title: title,
                subtitle: "Jump to the \(section.title) settings pane.",
                shortcutDisplay: nil,
                category: "Settings",
                searchText: [
                    title,
                    section.title,
                    section.rawValue,
                    "settings preferences configuration",
                ].joined(separator: " ").lowercased(),
                group: .settings,
                iconSystemName: section.symbolName,
                rankingBoost: 0.05
            )
        }
    }

    static func buildRestoredCommandItem(
        paneID: PaneID,
        command: String
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: .restoredCommand(paneID: paneID),
            title: "Run Last Command Again",
            subtitle: command,
            shortcutDisplay: nil,
            category: "Pane",
            searchText: [
                "run last command again rerun repeat restored previous",
                command,
            ].joined(separator: " "),
            iconSystemName: "arrow.clockwise",
            rankingBoost: 0.2
        )
    }

    static func buildPaneItems(
        worklanes: [WorklaneState],
        currentPaneReference: WorklaneStore.PaneReference?
    ) -> [CommandPaletteItem] {
        worklanes.flatMap { worklane in
            worklane.paneStripState.panes.compactMap { pane -> CommandPaletteItem? in
                let context = worklane.paneContext(for: pane.id)
                let presentation = context?.presentation ?? PanePresentationState()
                let title = paneTitle(pane: pane, presentation: presentation)
                let worklaneTitle = WorklaneState.meaningfulTitle(from: worklane.title) ?? "Main"
                let branch = WorklaneContextFormatter.trimmed(presentation.branchDisplayText ?? presentation.branch)
                let location = paneLocation(presentation: presentation, auxiliaryState: context?.auxiliaryState)
                let status = WorklaneContextFormatter.trimmed(presentation.statusText)
                let subtitle = [worklaneTitle, branch, location, status]
                    .compactMap { $0 }
                    .joined(separator: " • ")
                let isCurrent = currentPaneReference?.worklaneID == worklane.id
                    && currentPaneReference?.paneID == pane.id
                let searchText = [
                    title,
                    subtitle,
                    worklane.title,
                    worklaneTitle,
                    pane.title,
                    presentation.cwd,
                    presentation.repoRoot,
                    presentation.branch,
                    presentation.branchDisplayText,
                    presentation.identityText,
                    presentation.contextText,
                    presentation.rememberedTitle,
                    presentation.statusText,
                    context?.auxiliaryState?.shellContext?.path,
                    context?.auxiliaryState?.metadata?.currentWorkingDirectory,
                    context?.auxiliaryState?.metadata?.gitBranch,
                    context?.auxiliaryState?.metadata?.processName,
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                let secondarySearchText = [
                    subtitle,
                    worklane.title,
                    worklaneTitle,
                    pane.title,
                    presentation.cwd,
                    presentation.repoRoot,
                    presentation.branch,
                    presentation.branchDisplayText,
                    presentation.identityText,
                    presentation.contextText,
                    presentation.rememberedTitle,
                    presentation.statusText,
                    context?.auxiliaryState?.shellContext?.path,
                    context?.auxiliaryState?.metadata?.currentWorkingDirectory,
                    context?.auxiliaryState?.metadata?.gitBranch,
                    context?.auxiliaryState?.metadata?.processName,
                ]
                .compactMap { $0 }
                .joined(separator: " ")

                return CommandPaletteItem(
                    id: .pane(worklaneID: worklane.id, paneID: pane.id),
                    title: title,
                    subtitle: subtitle,
                    shortcutDisplay: nil,
                    category: isCurrent ? "Current Pane" : "Pane",
                    searchText: searchText,
                    primarySearchText: title,
                    secondarySearchText: secondarySearchText,
                    group: .pane,
                    iconSystemName: "arrow.right.square",
                    rankingBoost: isCurrent ? 0.02 : 0.08
                )
            }
        }
    }

    static func buildWorklaneColorItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        for (index, color) in WorklaneColor.allCases.enumerated() {
            let name = color.localizedName
            items.append(
                CommandPaletteItem(
                    id: .worklaneColor(color),
                    title: name,
                    subtitle: NSLocalizedString("Set the focused worklane's sidebar color.", comment: "Palette subtitle"),
                    shortcutDisplay: nil,
                    category: "Worklane color",
                    searchText: "worklane color \(name)".lowercased(),
                    iconSystemName: "paintpalette",
                    family: .worklaneColor,
                    familySearchText: name.lowercased(),
                    familyOrder: index
                )
            )
        }
        let resetTitle = NSLocalizedString("Reset to Default", comment: "Palette reset entry")
        items.append(
            CommandPaletteItem(
                id: .worklaneColor(nil),
                title: resetTitle,
                subtitle: NSLocalizedString("Clear the focused worklane's sidebar color.", comment: "Palette reset subtitle"),
                shortcutDisplay: nil,
                category: "Worklane color",
                searchText: "worklane color reset default clear".lowercased(),
                iconSystemName: "paintpalette",
                family: .worklaneColor,
                familySearchText: "reset default clear",
                familyOrder: WorklaneColor.allCases.count
            )
        )
        return items
    }

    static func buildOpenWithItems(
        targets: [OpenWithResolvedTarget],
        focusedPanePath: String?,
        iconProvider: ((OpenWithResolvedTarget) -> NSImage?)? = nil
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
                iconSystemName: target.iconSystemName,
                iconImage: iconProvider?(target),
                family: .openWith,
                familySearchText: familySearchText,
                familyOrder: index
            )
        }
    }

    private static func enrichedSubtitle(
        for definition: AppCommandDefinition,
        focusedPanePath: String?,
        focusedBranchName: String?,
        rightPaneCommandPresentation: PaneRightCommandPresentation
    ) -> String {
        if definition.id == .splitHorizontally {
            return rightPaneCommandPresentation.primaryDetailDescription
        }

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

    private static func title(
        for definition: AppCommandDefinition,
        rightPaneCommandPresentation: PaneRightCommandPresentation
    ) -> String {
        definition.id == .splitHorizontally
            ? rightPaneCommandPresentation.primaryTitle
            : definition.title
    }

    private static func searchText(
        for definition: AppCommandDefinition,
        title: String,
        subtitle: String
    ) -> String {
        if definition.id == .splitHorizontally {
            return [title, subtitle, "new pane right split horizontal add pane right"]
                .joined(separator: " ")
                .lowercased()
        }

        return definition.searchText
    }

    private static func paneTitle(pane: PaneState, presentation: PanePresentationState) -> String {
        WorklaneContextFormatter.trimmed(presentation.rememberedTitle)
            ?? WorklaneContextFormatter.trimmed(presentation.visibleIdentityText)
            ?? WorklaneContextFormatter.trimmed(presentation.contextText)
            ?? WorklaneContextFormatter.trimmed(pane.title)
            ?? "Pane"
    }

    private static func paneLocation(
        presentation: PanePresentationState,
        auxiliaryState: PaneAuxiliaryState?
    ) -> String? {
        WorklaneContextFormatter.trimmed(presentation.remoteLocationLabel)
            ?? WorklaneContextFormatter.formattedWorkingDirectory(presentation.cwd)
            ?? auxiliaryState?.shellContext?.borderContextDisplayText
            ?? WorklaneContextFormatter.formattedWorkingDirectory(
                auxiliaryState?.metadata?.currentWorkingDirectory,
                branch: auxiliaryState?.metadata?.gitBranch
            )
    }

    private static func iconSystemName(for commandID: AppCommandID) -> String {
        switch commandID {
        case .newWorklane:
            "plus.square.on.square"
        case .splitHorizontally:
            "rectangle.split.2x1"
        case .splitVertically:
            "rectangle.split.1x2"
        case .openSettings:
            "gearshape"
        case .toggleSidebar:
            "sidebar.left"
        case .copyFocusedPanePath:
            "doc.on.doc"
        case .openBranchOnRemote:
            "arrow.up.forward.app"
        default:
            "command"
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
    var iconSystemName: String {
        switch kind {
        case .editor:
            "pencil.and.outline"
        case .fileManager:
            "folder"
        case .terminal:
            "terminal"
        }
    }

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
        case .codex?:
            ["openai", "ai editor", "coding agent"]
        case .claude?:
            ["anthropic", "ai editor", "coding agent"]
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
