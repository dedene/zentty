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
        XCTAssertEqual(ids, [.toggleSidebar, .newWorklane])
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
}
