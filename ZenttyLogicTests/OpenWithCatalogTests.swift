import XCTest
@testable import Zentty

final class OpenWithCatalogTests: XCTestCase {
    func test_macos_catalog_matches_curated_editor_and_finder_order_without_terminals() {
        XCTAssertEqual(
            OpenWithCatalog.macOSBuiltInTargets.map(\.id.rawValue),
            [
                "vscode",
                "vscode-insiders",
                "cursor",
                "zed",
                "windsurf",
                "antigravity",
                "finder",
                "xcode",
                "android-studio",
                "intellij-idea",
                "rider",
                "goland",
                "rustrover",
                "pycharm",
                "webstorm",
                "phpstorm",
                "sublime-text",
                "bbedit",
                "textmate",
            ]
        )
        XCTAssertFalse(OpenWithCatalog.macOSBuiltInTargets.contains { $0.kind == .terminal })
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
