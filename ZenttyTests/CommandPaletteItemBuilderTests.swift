@testable import Zentty
import AppKit
import XCTest

final class CommandPaletteItemBuilderTests: XCTestCase {
    private let shortcutManager = ShortcutManager(shortcuts: .default)

    func testBuildsItemsOnlyForAvailableIDs() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.toggleSidebar, .newWorklane],
            shortcutManager: shortcutManager
        )
        let ids = Set(items.map(\.id))
        XCTAssertEqual(ids, [.command(.toggleSidebar), .command(.newWorklane)])
    }

    func testItemTitlesMatchDefinitions() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.splitHorizontally],
            shortcutManager: shortcutManager,
            rightPaneCommandPresentation: .addsToWorklane
        )
        XCTAssertEqual(items.first?.title, "Add Pane Right")
    }

    func testRightPaneCommandTitleCanReflectVisibleSplitBehavior() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.splitHorizontally],
            shortcutManager: shortcutManager,
            rightPaneCommandPresentation: .splitsVisibly
        )

        XCTAssertEqual(items.first?.title, "Split Right")
        XCTAssertEqual(items.first?.subtitle, "Split the current pane area into two visible panes.")
    }

    func testDuplicatePaneItemIsBuiltWithoutShortcutDisplayWhenUnboundByDefault() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.duplicateFocusedPane],
            shortcutManager: shortcutManager
        )

        XCTAssertEqual(items.first?.title, "Duplicate This Pane")
        XCTAssertNil(items.first?.shortcutDisplay)
    }

    func testItemsHaveShortcutDisplayForBoundCommands() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.toggleSidebar],
            shortcutManager: shortcutManager
        )
        XCTAssertNotNil(items.first?.shortcutDisplay)
    }

    func testCopyPathSubtitleIncludesPathWhenProvided() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.copyFocusedPanePath],
            shortcutManager: shortcutManager,
            focusedPanePath: "/Users/peter/projects"
        )
        XCTAssertEqual(items.first?.subtitle, "Copy Path — /Users/peter/projects")
    }

    func testOtherItemsUseDetailDescription() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.toggleSidebar],
            shortcutManager: shortcutManager
        )
        let expected = AppCommandRegistry.definition(for: .toggleSidebar).detailDescription
        XCTAssertEqual(items.first?.subtitle, expected)
    }

    func testOpenBranchOnRemoteUsesBranchSubtitleAndSearchAliases() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.openBranchOnRemote],
            shortcutManager: shortcutManager,
            focusedBranchName: "feature/remote-link"
        )

        XCTAssertEqual(items.first?.title, "Open Branch on Remote")
        XCTAssertEqual(items.first?.subtitle, "Open remote branch — feature/remote-link")
        XCTAssertTrue(items.first?.searchText.contains("remote branch") == true)
        XCTAssertTrue(items.first?.searchText.contains("github branch") == true)
    }

    func testEmptyAvailableIDsProducesNoItems() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [],
            shortcutManager: shortcutManager
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testSettingsItemsGeneratedForEverySection() {
        let items = CommandPaletteItemBuilder.buildSettingsItems()

        XCTAssertEqual(items.map(\.id), SettingsSection.allCases.map { .settings($0) })
        XCTAssertEqual(items.map(\.title), SettingsSection.allCases.map { "\($0.title) Settings" })
        XCTAssertEqual(items.map(\.iconSystemName), SettingsSection.allCases.map(\.symbolName))
        XCTAssertTrue(items.allSatisfy { $0.group == .settings })
    }

    func testPaneItemsUsePresentationTitleAndSearchableContext() {
        let worklaneID = WorklaneID("worklane-1")
        let paneID = PaneID("pane-1")
        let pane = PaneState(id: paneID, title: "zsh")
        let presentation = PanePresentationState(
            cwd: "/Users/peter/Development/Personal/zentty",
            repoRoot: "/Users/peter/Development/Personal/zentty",
            branch: "feature/palette",
            branchDisplayText: "feature/palette",
            rememberedTitle: "Improve command palette",
            runtimePhase: .running,
            statusText: "Running"
        )
        let worklane = WorklaneState(
            id: worklaneID,
            title: "Zentty",
            paneStripState: PaneStripState(panes: [pane], focusedPaneID: paneID),
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(presentation: presentation),
            ]
        )

        let items = CommandPaletteItemBuilder.buildPaneItems(
            worklanes: [worklane],
            currentPaneReference: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, .pane(worklaneID: worklaneID, paneID: paneID))
        XCTAssertEqual(items[0].title, "Improve command palette")
        XCTAssertTrue(items[0].subtitle.contains("Zentty"))
        XCTAssertTrue(items[0].subtitle.contains("feature/palette"))
        XCTAssertTrue(items[0].subtitle.contains("zentty"))
        XCTAssertEqual(items[0].category, "Pane")
        XCTAssertEqual(items[0].group, .pane)
        XCTAssertEqual(items[0].iconSystemName, "arrow.right.square")
        XCTAssertTrue(items[0].searchText.contains("improve command palette"))
        XCTAssertTrue(items[0].searchText.contains("feature/palette"))
        XCTAssertTrue(items[0].searchText.contains("/users/peter/development/personal/zentty"))
    }

    func testEmptyQueryPrunesDefaultResultsToAvoidOpeningWithScroll() {
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.newWorklane, .splitHorizontally, .splitVertically, .openSettings],
            shortcutManager: shortcutManager
        )
        let paneItems = (0..<20).map { index in
            CommandPaletteItem(
                id: .pane(worklaneID: WorklaneID("worklane-\(index)"), paneID: PaneID("pane-\(index)")),
                title: "Recent Pane \(index)",
                subtitle: "Main • feature/palette-\(index)",
                shortcutDisplay: nil,
                category: "Pane",
                searchText: "recent pane \(index) palette",
                group: .pane,
                iconSystemName: "arrow.right.square"
            )
        }
        let recentActionItems = (0..<20).map { index in
            CommandPaletteItem(
                id: .openWith(stableID: "recent-action-\(index)"),
                title: "Recent Action \(index)",
                subtitle: "/tmp/project-\(index)",
                shortcutDisplay: nil,
                category: "Open With",
                searchText: "recent action \(index)",
                iconSystemName: "terminal"
            )
        }

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "",
            items: commandItems + paneItems + recentActionItems,
            recentItems: recentActionItems,
            recentPaneIDs: paneItems.map(\.id),
            emptyActionIDs: [
                .command(.newWorklane),
                .command(.splitHorizontally),
                .command(.splitVertically),
                .command(.openSettings),
            ]
        )

        XCTAssertFalse(resolved.requiresScrolling)
        XCTAssertLessThanOrEqual(
            CommandPaletteLayoutMetrics.preferredPanelHeight(results: resolved),
            CommandPaletteLayoutMetrics.maximumPanelHeight
        )
        XCTAssertEqual(resolved.sections.first?.title, "Actions")
        XCTAssertEqual(resolved.sections.first?.items.count, 4)
        XCTAssertLessThan(resolved.items.count, commandItems.count + paneItems.count + recentActionItems.count)
    }

    func testEmptyQueryGroupsCuratedActionsAndRecentPanesBeforePrunedRecentActions() {
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.newWorklane, .splitHorizontally, .splitVertically, .openSettings, .toggleSidebar],
            shortcutManager: shortcutManager
        )
        let paneItem = CommandPaletteItem(
            id: .pane(worklaneID: WorklaneID("worklane-1"), paneID: PaneID("pane-1")),
            title: "Fix palette",
            subtitle: "Main • feature/palette",
            shortcutDisplay: nil,
            category: "Pane",
            searchText: "fix palette main feature/palette",
            group: .pane,
            iconSystemName: "rectangle"
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "",
            items: commandItems + [paneItem],
            recentItems: [commandItems.first { $0.id == .command(.toggleSidebar) }!],
            recentPaneIDs: [paneItem.id],
            emptyActionIDs: [
                .command(.newWorklane),
                .command(.splitHorizontally),
                .command(.splitVertically),
                .command(.openSettings),
            ]
        )

        XCTAssertEqual(resolved.sections.map(\.title), ["Actions", "Recent Panes"])
        XCTAssertEqual(resolved.items.map(\.item.id), [
            .command(.newWorklane),
            .command(.splitHorizontally),
            .command(.splitVertically),
            .command(.openSettings),
            paneItem.id,
        ])
        XCTAssertFalse(resolved.requiresScrolling)
    }

    func testEmptyQueryExcludesCurrentPaneFromRecentPanes() {
        let currentPaneID = CommandPaletteItemID.pane(worklaneID: WorklaneID("worklane-1"), paneID: PaneID("pane-current"))
        let otherPaneID = CommandPaletteItemID.pane(worklaneID: WorklaneID("worklane-1"), paneID: PaneID("pane-other"))
        let items = [
            CommandPaletteItem(
                id: currentPaneID,
                title: "Current",
                subtitle: "Main",
                shortcutDisplay: nil,
                category: "Pane",
                searchText: "current main",
                group: .pane,
                iconSystemName: "rectangle"
            ),
            CommandPaletteItem(
                id: otherPaneID,
                title: "Other",
                subtitle: "Main",
                shortcutDisplay: nil,
                category: "Pane",
                searchText: "other main",
                group: .pane,
                iconSystemName: "rectangle"
            ),
        ]

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "",
            items: items,
            recentItems: [],
            recentPaneIDs: [currentPaneID, otherPaneID],
            currentPaneID: currentPaneID
        )

        XCTAssertEqual(resolved.sections.map(\.title), ["Recent Panes"])
        XCTAssertEqual(resolved.items.map(\.item.id), [otherPaneID])
    }

    func testTypedSearchGroupsResultsByDestinationType() {
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.openSettings],
            shortcutManager: shortcutManager
        )
        let settingsItems = CommandPaletteItemBuilder.buildSettingsItems()
        let paneItem = CommandPaletteItem(
            id: .pane(worklaneID: WorklaneID("worklane-1"), paneID: PaneID("pane-1")),
            title: "Palette test pane",
            subtitle: "Main • feature/palette",
            shortcutDisplay: nil,
            category: "Pane",
            searchText: "palette test pane main feature/palette",
            group: .pane,
            iconSystemName: "rectangle"
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "palette",
            items: [paneItem] + settingsItems + commandItems,
            recentItems: []
        )

        XCTAssertEqual(resolved.sections.first?.title, "Panes")
        XCTAssertEqual(resolved.sections.first?.items.map(\.item.id), [paneItem.id])
    }

    func testTypedSearchCapsResultsPerGroup() {
        let paneItems = (0..<20).map { index in
            CommandPaletteItem(
                id: .pane(worklaneID: WorklaneID("worklane-\(index)"), paneID: PaneID("pane-\(index)")),
                title: "Palette Pane \(index)",
                subtitle: "Main",
                shortcutDisplay: nil,
                category: "Pane",
                searchText: "palette pane \(index)",
                group: .pane,
                iconSystemName: "arrow.right.square"
            )
        }
        let settingsItems = (0..<12).map { index in
            CommandPaletteItem(
                id: .openWith(stableID: "settings-\(index)"),
                title: "Palette Setting \(index)",
                subtitle: "Settings",
                shortcutDisplay: nil,
                category: "Settings",
                searchText: "palette setting \(index)",
                group: .settings,
                iconSystemName: "gearshape"
            )
        }
        let actionItems = (0..<20).map { index in
            CommandPaletteItem(
                id: .openWith(stableID: "action-\(index)"),
                title: "Palette Action \(index)",
                subtitle: "Action",
                shortcutDisplay: nil,
                category: "Actions",
                searchText: "palette action \(index)",
                group: .action,
                iconSystemName: "command"
            )
        }

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "palette",
            items: paneItems + settingsItems + actionItems,
            recentItems: []
        )

        XCTAssertEqual(resolved.sections.map(\.title), ["Panes", "Settings", "Actions"])
        XCTAssertEqual(resolved.sections.map { $0.items.count }, [12, 8, 12])
        XCTAssertTrue(resolved.requiresScrolling)
    }

    func testPaneTitleAliasMatchRanksBeforePaneContextMatch() {
        let matchingTitleID = CommandPaletteItemID.pane(worklaneID: WorklaneID("worklane-title"), paneID: PaneID("pane-title"))
        let contextOnlyID = CommandPaletteItemID.pane(worklaneID: WorklaneID("worklane-context"), paneID: PaneID("pane-context"))
        let matchingTitle = CommandPaletteItem(
            id: matchingTitleID,
            title: "restore-closed-pane",
            subtitle: "Main • feature/restore-pane • .../restore-pane",
            shortcutDisplay: nil,
            category: "Pane",
            searchText: "restore-closed-pane main feature/restore-pane .../restore-pane",
            group: .pane,
            iconSystemName: "arrow.right.square"
        )
        let contextOnly = CommandPaletteItem(
            id: contextOnlyID,
            title: "fix-horizontal-split-drop-overlay",
            subtitle: "Main • restore closed pane • .../zentty",
            shortcutDisplay: nil,
            category: "Pane",
            searchText: "fix-horizontal-split-drop-overlay main restore closed pane .../zentty",
            group: .pane,
            iconSystemName: "arrow.right.square"
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "restore closed pane",
            items: [contextOnly, matchingTitle],
            recentItems: []
        )

        XCTAssertEqual(resolved.items.first?.item.id, matchingTitleID)
    }

    func testPaneTitleMatchingTreatsCommonSeparatorsAsEquivalent() {
        let separators = [
            "restore-closed-pane",
            "restore_closed_pane",
            "restore.closed.pane",
            "restore/closed/pane",
            "restore closed pane",
        ]

        for title in separators {
            let matchingTitleID = CommandPaletteItemID.pane(worklaneID: WorklaneID("worklane-\(title)"), paneID: PaneID("pane-\(title)"))
            let matchingTitle = CommandPaletteItem(
                id: matchingTitleID,
                title: title,
                subtitle: "Main",
                shortcutDisplay: nil,
                category: "Pane",
                searchText: "\(title) main",
                group: .pane,
                iconSystemName: "arrow.right.square"
            )
            let contextOnly = CommandPaletteItem(
                id: .pane(worklaneID: WorklaneID("context-\(title)"), paneID: PaneID("context-pane-\(title)")),
                title: "unrelated-pane",
                subtitle: "restore closed pane",
                shortcutDisplay: nil,
                category: "Pane",
                searchText: "unrelated-pane restore closed pane",
                group: .pane,
                iconSystemName: "arrow.right.square"
            )

            let resolved = CommandPaletteResultsResolver.resolve(
                searchText: "restore closed pane",
                items: [contextOnly, matchingTitle],
                recentItems: []
            )

            XCTAssertEqual(resolved.items.first?.item.id, matchingTitleID, "Expected \(title) to rank first")
        }
    }

    func testPaneContextStillMatchesWhenTitleDoesNotMatch() {
        let paneID = CommandPaletteItemID.pane(worklaneID: WorklaneID("worklane-1"), paneID: PaneID("pane-1"))
        let pane = CommandPaletteItem(
            id: paneID,
            title: "unrelated-pane",
            subtitle: "Main • feature/restore-pane • .../restore-pane",
            shortcutDisplay: nil,
            category: "Pane",
            searchText: "unrelated-pane main feature/restore-pane .../restore-pane",
            group: .pane,
            iconSystemName: "arrow.right.square"
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "restore pane",
            items: [pane],
            recentItems: []
        )

        XCTAssertEqual(resolved.items.map(\.item.id), [paneID])
    }

    @MainActor
    func testViewModelDoesNotResolveAgainWhenSelectionMoves() {
        let item = CommandPaletteItem(
            id: .command(.openSettings),
            title: "Open Settings",
            subtitle: "Open settings.",
            shortcutDisplay: nil,
            category: "General",
            searchText: "open settings",
            iconSystemName: "gearshape"
        )
        let index = CommandPaletteSearchIndex(
            items: [item],
            recentItems: [],
            recentPaneIDs: [],
            currentPaneID: nil,
            emptyActionIDs: []
        )
        var resolveCount = 0
        let viewModel = CommandPaletteViewModel(
            searchIndex: index,
            resolver: { searchText, searchIndex in
                resolveCount += 1
                return CommandPaletteResultsResolver.resolve(searchText: searchText, index: searchIndex)
            }
        )

        XCTAssertEqual(resolveCount, 1)
        viewModel.moveSelection(by: 1)
        viewModel.moveSelection(by: -1)
        XCTAssertEqual(resolveCount, 1)

        viewModel.updateSearchText("settings")
        XCTAssertEqual(resolveCount, 2)
    }

    // MARK: - Open With Items

    func testOpenWithItemsGeneratedWithPath() {
        let targets = [
            OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
            OpenWithResolvedTarget(stableID: "finder", kind: .fileManager, displayName: "Finder", builtInID: .finder, appPath: nil),
        ]
        let items = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: targets,
            focusedPanePath: "/Users/peter/projects"
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "VS Code")
        XCTAssertEqual(items[1].title, "Finder")
        XCTAssertEqual(items[0].id, .openWith(stableID: "vscode"))
        XCTAssertEqual(items[0].subtitle, "/Users/peter/projects")
        XCTAssertEqual(items[0].category, "Open With")
        XCTAssertNil(items[0].shortcutDisplay)
    }

    func testOpenWithItemsUseProvidedAppIcons() {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        let target = OpenWithResolvedTarget(
            stableID: "cursor",
            kind: .editor,
            displayName: "Cursor",
            builtInID: .cursor,
            appPath: nil
        )

        let items = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: [target],
            focusedPanePath: "/Users/peter/projects",
            iconProvider: { providedTarget in
                providedTarget.stableID == target.stableID ? icon : nil
            }
        )

        XCTAssertTrue(items[0].iconImage === icon)
        XCTAssertEqual(items[0].iconSystemName, "pencil.and.outline")
    }

    func testOpenWithItemsEmptyWithoutPath() {
        let targets = [
            OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
        ]
        let items = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: targets,
            focusedPanePath: nil
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testOpenWithItemsSearchable() {
        let targets = [
            OpenWithResolvedTarget(stableID: "cursor", kind: .editor, displayName: "Cursor", builtInID: .cursor, appPath: nil),
        ]
        let items = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: targets,
            focusedPanePath: "/tmp"
        )
        XCTAssertTrue(items[0].searchText.contains("cursor"))
        XCTAssertTrue(items[0].searchText.contains("open with"))
    }

    func testOpenWithItemsIncludeCuratedAliases() {
        let targets = [
            OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
            OpenWithResolvedTarget(stableID: "finder", kind: .fileManager, displayName: "Finder", builtInID: .finder, appPath: nil),
        ]
        let items = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: targets,
            focusedPanePath: "/tmp/project"
        )

        XCTAssertTrue(items[0].searchText.contains("visual studio code"))
        XCTAssertEqual(items[0].family, .openWith)
        XCTAssertTrue(items[0].familySearchText?.contains("visual studio code") == true)
        XCTAssertTrue(items[1].familySearchText?.contains("file manager") == true)
    }

    func testScopedOpenWithQueryShowsAllTargetsAndUsesRecentOpenWithFirst() {
        let openWithItems = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: [
                OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
                OpenWithResolvedTarget(stableID: "finder", kind: .fileManager, displayName: "Finder", builtInID: .finder, appPath: nil),
                OpenWithResolvedTarget(stableID: "xcode", kind: .editor, displayName: "Xcode", builtInID: .xcode, appPath: nil),
            ],
            focusedPanePath: "/tmp/project"
        )
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.openSettings],
            shortcutManager: shortcutManager
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "open with",
            items: commandItems + openWithItems,
            recentItems: [
                openWithItems[2],
                commandItems[0],
            ]
        )

        XCTAssertEqual(resolved.scope?.family, .openWith)
        XCTAssertEqual(resolved.scope?.title, "Open With")
        XCTAssertEqual(resolved.scope?.subtitle, "/tmp/project")
        XCTAssertEqual(resolved.items.map(\.item.id), [
            .openWith(stableID: "xcode"),
            .openWith(stableID: "vscode"),
            .openWith(stableID: "finder"),
        ])
        XCTAssertEqual(resolved.items.map(\.showsSubtitle), [false, false, false])
        XCTAssertEqual(resolved.items.map(\.showsCategory), [false, false, false])
    }

    func testLeadingOpenAliasScopesWhenRemainderMatchesOpenWithTarget() {
        let openWithItems = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: [
                OpenWithResolvedTarget(stableID: "finder", kind: .fileManager, displayName: "Finder", builtInID: .finder, appPath: nil),
                OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
            ],
            focusedPanePath: "/tmp/project"
        )
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.openSettings],
            shortcutManager: shortcutManager
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "open fi",
            items: commandItems + openWithItems,
            recentItems: []
        )

        XCTAssertEqual(resolved.scope?.family, .openWith)
        XCTAssertEqual(resolved.items.map(\.item.id), [
            .openWith(stableID: "finder"),
            .openWith(stableID: "vscode"),
        ])
    }

    func testLeadingOpenAliasDoesNotScopeWhenRemainderMatchesRegularCommandInstead() {
        let openWithItems = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: [
                OpenWithResolvedTarget(stableID: "finder", kind: .fileManager, displayName: "Finder", builtInID: .finder, appPath: nil),
            ],
            focusedPanePath: "/tmp/project"
        )
        let commandItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.openSettings],
            shortcutManager: shortcutManager
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "open settings",
            items: commandItems + openWithItems,
            recentItems: []
        )

        XCTAssertNil(resolved.scope)
        XCTAssertEqual(resolved.items.first?.item.id, .command(.openSettings))
        XCTAssertEqual(resolved.items.first?.showsSubtitle, true)
    }

    func testScopedOpenWithQueryKeepsContextWhilePrioritizingMatches() {
        let openWithItems = CommandPaletteItemBuilder.buildOpenWithItems(
            targets: [
                OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
                OpenWithResolvedTarget(stableID: "finder", kind: .fileManager, displayName: "Finder", builtInID: .finder, appPath: nil),
                OpenWithResolvedTarget(stableID: "xcode", kind: .editor, displayName: "Xcode", builtInID: .xcode, appPath: nil),
            ],
            focusedPanePath: "/tmp/project"
        )

        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "open with fi",
            items: openWithItems,
            recentItems: []
        )

        XCTAssertEqual(resolved.scope?.family, .openWith)
        XCTAssertEqual(resolved.items.map(\.item.id), [
            .openWith(stableID: "finder"),
            .openWith(stableID: "vscode"),
            .openWith(stableID: "xcode"),
        ])
        XCTAssertEqual(resolved.items.map(\.showsCategory), [false, false, false])
    }

    func testUnscopedOpenWithResultsKeepCategoryVisible() {
        let resolved = CommandPaletteResultsResolver.resolve(
            searchText: "vs code",
            items: CommandPaletteItemBuilder.buildOpenWithItems(
                targets: [
                    OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
                ],
                focusedPanePath: "/tmp/project"
            ),
            recentItems: []
        )

        XCTAssertNil(resolved.scope)
        XCTAssertEqual(resolved.items.map(\.showsCategory), [true])
    }

    func testScopedOpenWithPreferredHeightShrinksForSmallResultSets() {
        let results = CommandPaletteResultsResolver.resolve(
            searchText: "open xcode",
            items: CommandPaletteItemBuilder.buildOpenWithItems(
                targets: [
                    OpenWithResolvedTarget(stableID: "vscode", kind: .editor, displayName: "VS Code", builtInID: .vscode, appPath: nil),
                    OpenWithResolvedTarget(stableID: "xcode", kind: .editor, displayName: "Xcode", builtInID: .xcode, appPath: nil),
                ],
                focusedPanePath: "/tmp/project"
            ),
            recentItems: []
        )

        let height = CommandPaletteLayoutMetrics.preferredPanelHeight(results: results)

        XCTAssertLessThan(height, CommandPaletteLayoutMetrics.maximumPanelHeight)
        XCTAssertGreaterThan(height, CommandPaletteLayoutMetrics.searchFieldHeight)
    }

    func testPreferredHeightCapsAtMaximumForLargeResultSets() {
        let results = CommandPaletteResolvedResults(
            items: (0..<20).map { index in
                CommandPaletteResolvedItem(
                    item: CommandPaletteItem(
                        id: .openWith(stableID: "app-\(index)"),
                        title: "App \(index)",
                        subtitle: "/tmp/project",
                        shortcutDisplay: nil,
                        category: "Open With",
                        searchText: "app \(index)",
                        family: .openWith,
                        familySearchText: nil,
                        familyOrder: index
                    ),
                    showsSubtitle: false,
                    showsCategory: false
                )
            },
            scope: CommandPaletteResolvedScope(
                family: .openWith,
                title: "Open With",
                subtitle: "/tmp/project"
            )
        )

        let height = CommandPaletteLayoutMetrics.preferredPanelHeight(results: results)

        XCTAssertEqual(height, CommandPaletteLayoutMetrics.maximumPanelHeight)
    }

    func testPreferredHeightAllowsScopedNineSingleLineResultsBelowTallerMaximum() {
        let results = CommandPaletteResolvedResults(
            items: (0..<9).map { index in
                CommandPaletteResolvedItem(
                    item: CommandPaletteItem(
                        id: .openWith(stableID: "app-\(index)"),
                        title: "App \(index)",
                        subtitle: "/tmp/project",
                        shortcutDisplay: nil,
                        category: "Open With",
                        searchText: "app \(index)",
                        family: .openWith,
                        familySearchText: nil,
                        familyOrder: index
                    ),
                    showsSubtitle: false,
                    showsCategory: false
                )
            },
            scope: CommandPaletteResolvedScope(
                family: .openWith,
                title: "Open With",
                subtitle: "/tmp/project"
            )
        )

        let height = CommandPaletteLayoutMetrics.preferredPanelHeight(results: results)

        XCTAssertLessThan(height, CommandPaletteLayoutMetrics.maximumPanelHeight)
        XCTAssertGreaterThan(height, CommandPaletteLayoutMetrics.searchFieldHeight)
    }

    func testScopedPreferredHeightAddsVisualOverflowAllowance() {
        let results = CommandPaletteResolvedResults(
            items: (0..<2).map { index in
                CommandPaletteResolvedItem(
                    item: CommandPaletteItem(
                        id: .openWith(stableID: "app-\(index)"),
                        title: "App \(index)",
                        subtitle: "/tmp/project",
                        shortcutDisplay: nil,
                        category: "Open With",
                        searchText: "app \(index)",
                        family: .openWith,
                        familySearchText: nil,
                        familyOrder: index
                    ),
                    showsSubtitle: false,
                    showsCategory: false
                )
            },
            scope: CommandPaletteResolvedScope(
                family: .openWith,
                title: "Open With",
                subtitle: "/tmp/project"
            )
        )

        let height = CommandPaletteLayoutMetrics.preferredPanelHeight(results: results)
        let heightWithoutAllowance =
            CommandPaletteLayoutMetrics.searchFieldHeight
            + CommandPaletteLayoutMetrics.dividerHeight
            + CommandPaletteLayoutMetrics.scopedHeaderHeightWithSubtitle
            + (CommandPaletteLayoutMetrics.singleLineRowHeight * 2)
            + CommandPaletteLayoutMetrics.resultsVerticalPadding
            + CommandPaletteLayoutMetrics.rowSpacing
            + CommandPaletteLayoutMetrics.footerHeight

        XCTAssertEqual(height, heightWithoutAllowance + CommandPaletteLayoutMetrics.visualOverflowAllowance)
    }
}
