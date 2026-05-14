import XCTest
@testable import Zentty

final class CommandPaletteWorklaneColorTests: XCTestCase {
    func test_restoredCommandItem_uses_command_as_subtitle_and_search_text() {
        let paneID = PaneID("shell")
        let command = "pnpm start:staging\nnpm run smoke"

        let item = CommandPaletteItemBuilder.buildRestoredCommandItem(
            paneID: paneID,
            command: command
        )

        XCTAssertEqual(item.id, .restoredCommand(paneID: paneID))
        XCTAssertEqual(item.title, "Run Last Command Again")
        XCTAssertEqual(item.subtitle, command)
        XCTAssertTrue(item.searchText.contains("npm run smoke"))
        XCTAssertEqual(item.group, .action)
    }

    func test_restoredCommandItem_is_first_empty_query_action_when_available() {
        let paneID = PaneID("shell")
        let item = CommandPaletteItemBuilder.buildRestoredCommandItem(
            paneID: paneID,
            command: "pnpm start:staging"
        )
        let newWorklane = CommandPaletteItem(
            id: .command(.newWorklane),
            title: "New Worklane",
            subtitle: "",
            shortcutDisplay: nil,
            category: "Window",
            searchText: "new worklane"
        )

        let results = CommandPaletteResultsResolver.resolve(
            searchText: "",
            items: [newWorklane, item],
            recentItems: [],
            emptyActionIDs: [.restoredCommand(paneID: paneID), .command(.newWorklane)]
        )

        XCTAssertEqual(results.items.first?.item.id, .restoredCommand(paneID: paneID))
    }

    func test_builder_emits_13_worklane_color_items() {
        let items = CommandPaletteItemBuilder.buildWorklaneColorItems()
        XCTAssertEqual(items.count, WorklaneColor.allCases.count + 1)
        XCTAssertTrue(items.allSatisfy { $0.family == .worklaneColor })
    }

    func test_each_color_case_has_an_item_and_reset_is_last() {
        let items = CommandPaletteItemBuilder.buildWorklaneColorItems()
        for color in WorklaneColor.allCases {
            XCTAssertTrue(items.contains(where: {
                if case .worklaneColor(let stored) = $0.id { return stored == color } else { return false }
            }), "Missing item for \(color.rawValue)")
        }
        let lastID = items.last?.id
        XCTAssertEqual(lastID, .worklaneColor(nil), "Reset must be the last (highest familyOrder) item")
    }

    func test_typing_worklane_color_query_scopes_to_family() {
        let items = CommandPaletteItemBuilder.buildWorklaneColorItems()
        let results = CommandPaletteResultsResolver.resolve(
            searchText: "worklane color",
            items: items,
            recentItems: []
        )
        XCTAssertEqual(results.scope?.family, .worklaneColor)
        XCTAssertEqual(results.items.count, items.count)
    }

    func test_typing_worklane_color_red_surfaces_red_first() {
        let items = CommandPaletteItemBuilder.buildWorklaneColorItems()
        let results = CommandPaletteResultsResolver.resolve(
            searchText: "worklane color red",
            items: items,
            recentItems: []
        )
        XCTAssertEqual(results.scope?.family, .worklaneColor)
        let first = results.items.first?.item
        if case .worklaneColor(let color) = first?.id {
            XCTAssertEqual(color, .red)
        } else {
            XCTFail("Expected worklaneColor id")
        }
    }

    func test_typing_worklane_color_reset_surfaces_reset() {
        let items = CommandPaletteItemBuilder.buildWorklaneColorItems()
        let results = CommandPaletteResultsResolver.resolve(
            searchText: "worklane color reset",
            items: items,
            recentItems: []
        )
        XCTAssertEqual(results.scope?.family, .worklaneColor)
        let first = results.items.first?.item
        if case .worklaneColor(let color) = first?.id {
            XCTAssertNil(color)
        } else {
            XCTFail("Expected worklaneColor id")
        }
    }
}
