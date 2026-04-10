@testable import Zentty
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
            shortcutManager: shortcutManager
        )
        XCTAssertEqual(items.first?.title, "Split Horizontally")
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

    func testEmptyAvailableIDsProducesNoItems() {
        let items = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [],
            shortcutManager: shortcutManager
        )
        XCTAssertTrue(items.isEmpty)
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

    func testPreferredHeightCapsAtMaximumForScopedNineSingleLineResults() {
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

        XCTAssertEqual(height, CommandPaletteLayoutMetrics.maximumPanelHeight)
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

        XCTAssertEqual(height, heightWithoutAllowance + CommandPaletteLayoutMetrics.visualOverflowAllowance)
    }
}
