import XCTest
@testable import Zentty

final class CommandPaletteWorklaneColorTests: XCTestCase {
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
