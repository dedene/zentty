import XCTest
@testable import Zentty

final class OpenWithCatalogTests: XCTestCase {
    func test_macos_catalog_contains_curated_editors_and_finder_without_terminals() {
        let targets = OpenWithCatalog.macOSBuiltInTargets

        XCTAssertFalse(targets.isEmpty)
        XCTAssertFalse(targets.contains { $0.kind == .terminal }, "built-in catalog should exclude terminal apps")
        XCTAssertTrue(
            targets.contains { $0.displayName == "Codex" && $0.kind == .editor },
            "Codex should be in the catalog"
        )
        XCTAssertTrue(
            targets.contains { $0.displayName == "Claude" && $0.kind == .editor },
            "Claude should be in the catalog"
        )

        let ids = Set(targets.map(\.id))
        XCTAssertTrue(ids.contains(.codex), "Codex should be in the catalog")
        XCTAssertTrue(ids.contains(.claude), "Claude should be in the catalog")
        XCTAssertTrue(ids.contains(.vscode), "VS Code should be in the catalog")
        XCTAssertTrue(ids.contains(.cursor), "Cursor should be in the catalog")
        XCTAssertTrue(ids.contains(.finder), "Finder should be in the catalog")
        XCTAssertTrue(ids.contains(.xcode), "Xcode should be in the catalog")

        XCTAssertEqual(targets.count, ids.count, "catalog should not contain duplicate entries")
    }

    func test_primary_target_prefers_requested_enabled_available_target() {
        let preferences = AppConfig.OpenWith(
            primaryTargetID: "finder",
            enabledTargetIDs: ["finder", "cursor", "xcode"],
            customApps: []
        )

        let resolvedPrimaryTarget = OpenWithPreferencesResolver.primaryTarget(
            preferences: preferences,
            availableTargetIDs: ["finder", "cursor"]
        )

        XCTAssertEqual(resolvedPrimaryTarget?.id, .finder)
    }

    func test_primary_target_falls_back_to_first_enabled_available_catalog_target() {
        let preferences = AppConfig.OpenWith(
            primaryTargetID: "xcode",
            enabledTargetIDs: ["finder", "cursor", "xcode"],
            customApps: []
        )

        let resolvedPrimaryTarget = OpenWithPreferencesResolver.primaryTarget(
            preferences: preferences,
            availableTargetIDs: ["finder", "cursor"]
        )

        XCTAssertEqual(resolvedPrimaryTarget?.id, .cursor)
    }

    func test_enabled_targets_preserve_catalog_order_and_append_enabled_custom_apps() {
        let preferences = AppConfig.OpenWith(
            primaryTargetID: "custom:bbedit-preview",
            enabledTargetIDs: ["finder", "custom:bbedit-preview", "cursor"],
            customApps: [
                OpenWithCustomApp(
                    id: "custom:bbedit-preview",
                    name: "BBEdit Preview",
                    appPath: "/Applications/BBEdit Preview.app"
                )
            ]
        )

        let resolvedTargets = OpenWithPreferencesResolver.enabledTargets(
            preferences: preferences,
            availableTargetIDs: ["finder", "cursor", "custom:bbedit-preview"]
        )

        XCTAssertEqual(
            resolvedTargets.map(\.stableID),
            ["cursor", "finder", "custom:bbedit-preview"]
        )
    }
}
