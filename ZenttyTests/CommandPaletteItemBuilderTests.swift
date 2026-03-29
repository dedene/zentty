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
        XCTAssertEqual(items[0].title, "Open in VS Code")
        XCTAssertEqual(items[1].title, "Open in Finder")
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
}
