import XCTest
@testable import Zentty

/// Table-driven coverage for `WorkspaceRecipeMigration.migrate`, exercising
/// every historical `WorkspaceRecipe` shape: unversioned (pre-v2) JSON, v2
/// JSON, v3 JSON, and a hypothetical future schema version. Each fixture
/// pins the exact behavior the scattered `schemaVersion == nil` checks used
/// to produce, so the migration pipeline can be refactored freely as long
/// as these keep passing.
final class WorkspaceRecipeMigrationTests: XCTestCase {
    // MARK: - Fixtures (decode)

    func test_decodes_unversioned_json_as_nil_schema_version() throws {
        let recipe = try decodeFixture(unversionedFixtureJSON)
        XCTAssertNil(recipe.schemaVersion)
        XCTAssertEqual(recipe.windows[0].worklanes.map(\.title), ["MAIN", "WS 3", "Nimbu support"])
    }

    func test_decodes_v2_json_with_schema_version_two() throws {
        let recipe = try decodeFixture(versionedFixtureJSON(schemaVersion: 2))
        XCTAssertEqual(recipe.schemaVersion, 2)
        XCTAssertEqual(recipe.windows[0].worklanes.map(\.title), ["MAIN", "WS 3", "Nimbu support"])
    }

    func test_decodes_v3_json_with_custom_title_field() throws {
        let recipe = try decodeFixture(v3FixtureJSONWithCustomTitle)
        XCTAssertEqual(recipe.schemaVersion, 3)
        XCTAssertEqual(recipe.windows[0].worklanes[0].columns[0].panes[0].customTitle, "Nimbu API")
    }

    // MARK: - Migration hop: unversioned -> current

    func test_migrate_sanitizes_legacy_junk_titles_from_unversioned_recipe() throws {
        let decoded = try decodeFixture(unversionedFixtureJSON)
        let migrated = WorkspaceRecipeMigration.migrate(decoded)

        XCTAssertEqual(migrated.schemaVersion, WorkspaceRecipe.currentSchemaVersion)
        XCTAssertEqual(migrated.windows[0].worklanes.map(\.title), [nil, nil, "Nimbu support"])
    }

    func test_migrate_strips_whitespace_only_legacy_title_to_nil() {
        let window = makeTitleFixtureWindow(titles: ["   "])
        let recipe = WorkspaceRecipe(schemaVersion: nil, windows: [window])

        let migrated = WorkspaceRecipeMigration.migrate(recipe)

        XCTAssertEqual(migrated.schemaVersion, WorkspaceRecipe.currentSchemaVersion)
        XCTAssertNil(migrated.windows[0].worklanes[0].title)
    }

    // MARK: - Migration hop: v2 -> current (verbatim titles, no-op)

    func test_migrate_keeps_v2_titles_verbatim() {
        let window = makeTitleFixtureWindow(titles: ["MAIN", "WS 3", "Nimbu support"])
        let recipe = WorkspaceRecipe(schemaVersion: 2, windows: [window])

        let migrated = WorkspaceRecipeMigration.migrate(recipe)

        XCTAssertEqual(migrated.schemaVersion, WorkspaceRecipe.currentSchemaVersion)
        XCTAssertEqual(migrated.windows[0].worklanes.map(\.title), ["MAIN", "WS 3", "Nimbu support"])
    }

    // MARK: - Migration hop: v3 -> current (already current, no-op)

    func test_migrate_is_a_no_op_for_current_schema_recipes() {
        let window = makeTitleFixtureWindow(titles: ["MAIN", "Nimbu support", nil])
        let recipe = WorkspaceRecipe(schemaVersion: WorkspaceRecipe.currentSchemaVersion, windows: [window])

        let migrated = WorkspaceRecipeMigration.migrate(recipe)

        XCTAssertEqual(migrated, recipe)
    }

    // MARK: - Forward-compat: newer-than-current schema versions

    func test_migrate_treats_future_schema_version_like_current_verbatim() {
        let window = makeTitleFixtureWindow(titles: ["MAIN", "WS 3", "Nimbu support"])
        let recipe = WorkspaceRecipe(schemaVersion: 99, windows: [window])

        let migrated = WorkspaceRecipeMigration.migrate(recipe)

        // Matches today's behavior: only `schemaVersion == nil` triggers
        // sanitization, so anything non-nil — including an unrecognized
        // future version — is treated as verbatim, same as v2/v3.
        XCTAssertEqual(migrated.schemaVersion, WorkspaceRecipe.currentSchemaVersion)
        XCTAssertEqual(migrated.windows[0].worklanes.map(\.title), ["MAIN", "WS 3", "Nimbu support"])
    }

    // MARK: - migrateWindowFromUnversioned hop in isolation

    func test_migrate_window_from_unversioned_sanitizes_only_that_window() {
        let window = makeTitleFixtureWindow(titles: ["MAIN", "WS 1", "Nimbu support"])

        let migrated = WorkspaceRecipeMigration.migrateWindowFromUnversioned(window)

        XCTAssertEqual(migrated.worklanes.map(\.title), [nil, nil, "Nimbu support"])
    }

    // MARK: - Fixture helpers

    private func decodeFixture(_ json: String) throws -> WorkspaceRecipe {
        try JSONDecoder().decode(WorkspaceRecipe.self, from: try XCTUnwrap(json.data(using: .utf8)))
    }

    private func makeTitleFixtureWindow(titles: [String?]) -> WorkspaceRecipe.Window {
        WorkspaceRecipe.Window(
            id: "window-main",
            worklanes: titles.enumerated().map { index, title in
                WorkspaceRecipe.Worklane(
                    id: "worklane-\(index)",
                    title: title,
                    nextPaneNumber: 1,
                    focusedColumnID: nil,
                    columns: []
                )
            },
            activeWorklaneID: "worklane-0"
        )
    }

    private var unversionedFixtureJSON: String {
        """
        {
          "windows": [
            {
              "id": "window-main",
              "worklanes": [
                { "id": "worklane-0", "title": "MAIN", "nextPaneNumber": 1, "columns": [] },
                { "id": "worklane-1", "title": "WS 3", "nextPaneNumber": 1, "columns": [] },
                { "id": "worklane-2", "title": "Nimbu support", "nextPaneNumber": 1, "columns": [] }
              ],
              "activeWorklaneID": "worklane-0"
            }
          ],
          "activeWindowID": "window-main"
        }
        """
    }

    private func versionedFixtureJSON(schemaVersion: Int) -> String {
        """
        {
          "schemaVersion": \(schemaVersion),
          "windows": [
            {
              "id": "window-main",
              "worklanes": [
                { "id": "worklane-0", "title": "MAIN", "nextPaneNumber": 1, "columns": [] },
                { "id": "worklane-1", "title": "WS 3", "nextPaneNumber": 1, "columns": [] },
                { "id": "worklane-2", "title": "Nimbu support", "nextPaneNumber": 1, "columns": [] }
              ],
              "activeWorklaneID": "worklane-0"
            }
          ],
          "activeWindowID": "window-main"
        }
        """
    }

    private var v3FixtureJSONWithCustomTitle: String {
        """
        {
          "schemaVersion": 3,
          "windows": [
            {
              "id": "window-main",
              "worklanes": [
                {
                  "id": "worklane-0",
                  "title": null,
                  "nextPaneNumber": 1,
                  "columns": [
                    {
                      "id": "column-main",
                      "width": 640,
                      "paneHeights": [480],
                      "panes": [
                        { "id": "pane-main", "customTitle": "Nimbu API" }
                      ]
                    }
                  ]
                }
              ],
              "activeWorklaneID": "worklane-0"
            }
          ],
          "activeWindowID": "window-main"
        }
        """
    }
}
