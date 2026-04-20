import XCTest
@testable import Zentty

final class WorkspaceRecipeColorTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    func test_missing_color_decodes_to_nil() throws {
        let json = """
        {
            "id": "wl_abc",
            "nextPaneNumber": 2,
            "columns": []
        }
        """.data(using: .utf8)!

        let worklane = try decoder.decode(WorkspaceRecipe.Worklane.self, from: json)
        XCTAssertNil(worklane.color)
    }

    func test_known_color_round_trips() throws {
        for value in WorklaneColor.allCases {
            let input = WorkspaceRecipe.Worklane(
                id: "wl_rt",
                title: nil,
                nextPaneNumber: 1,
                focusedColumnID: nil,
                columns: [],
                color: value.rawValue
            )
            let data = try encoder.encode(input)
            let decoded = try decoder.decode(WorkspaceRecipe.Worklane.self, from: data)
            XCTAssertEqual(decoded.color, value.rawValue)
            XCTAssertEqual(
                decoded.color.flatMap(WorklaneColor.init(rawValue:)),
                value
            )
        }
    }

    func test_unknown_color_string_decodes_but_resolves_to_nil_enum() throws {
        let json = """
        {
            "id": "wl_x",
            "nextPaneNumber": 1,
            "columns": [],
            "color": "chartreuse"
        }
        """.data(using: .utf8)!

        let worklane = try decoder.decode(WorkspaceRecipe.Worklane.self, from: json)
        XCTAssertEqual(worklane.color, "chartreuse")
        XCTAssertNil(worklane.color.flatMap(WorklaneColor.init(rawValue:)))
    }
}
