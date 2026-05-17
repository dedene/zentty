import XCTest
@testable import Zentty

final class ServerBrowserCatalogTests: XCTestCase {
    func test_default_server_browser_is_system_default() throws {
        let browser = ServerBrowserCatalog.preferredTarget(
            preferences: AppConfig.ServerDetection.default.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "firefox",
                    path: "/Applications/Firefox.app",
                    name: "Firefox",
                    bundleIdentifier: "org.mozilla.firefox"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(browser.stableID, ServerBrowserTarget.systemDefaultID)
        XCTAssertTrue(browser.isSystemDefault)
    }

    func test_missing_preferred_browser_falls_back_to_system_default() throws {
        var preferences = AppConfig.ServerDetection.default
        preferences.preferredBrowserID = "bundle:com.google.Chrome"

        let browser = ServerBrowserCatalog.preferredTarget(
            preferences: preferences.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "firefox",
                    path: "/Applications/Firefox.app",
                    name: "Firefox",
                    bundleIdentifier: "org.mozilla.firefox"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(browser.stableID, ServerBrowserTarget.systemDefaultID)
    }

    func test_missing_saved_bundle_browser_remains_visible_as_unavailable_target() throws {
        var preferences = AppConfig.ServerDetection.default
        preferences.preferredBrowserID = "bundle:com.google.Chrome"

        let targets = ServerBrowserCatalog.targets(
            preferences: preferences.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "firefox",
                    path: "/Applications/Firefox.app",
                    name: "Firefox",
                    bundleIdentifier: "org.mozilla.firefox"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(targets.last?.stableID, "bundle:com.google.Chrome")
        XCTAssertEqual(targets.last?.bundleIdentifier, "com.google.Chrome")
        XCTAssertFalse(targets.last?.isAvailable ?? true)
    }

    func test_resolved_built_ins_deduped_by_bundle_id() throws {
        let targets = ServerBrowserCatalog.targets(
            preferences: AppConfig.ServerDetection.default.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "chrome",
                    path: "/Applications/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome"
                ),
                browser(
                    stableID: "chrome",
                    path: "/Volumes/Chrome/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome"
                ),
                browser(
                    stableID: "firefox",
                    path: "/Applications/Firefox.app",
                    name: "Firefox",
                    bundleIdentifier: "org.mozilla.firefox"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(
            targets.map(\.stableID),
            [
                ServerBrowserTarget.systemDefaultID,
                "chrome",
                "firefox",
            ]
        )
    }

    func test_zentty_itself_is_filtered_from_browser_handlers() throws {
        let targets = ServerBrowserCatalog.targets(
            preferences: AppConfig.ServerDetection.default.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "zentty",
                    path: "/Applications/Zentty.app",
                    name: "Zentty",
                    bundleIdentifier: "be.zenjoy.zentty"
                ),
                browser(
                    stableID: "dia",
                    path: "/Applications/Dia.app",
                    name: "Dia",
                    bundleIdentifier: "company.thebrowser.dia"
                ),
            ],
            currentBundleIdentifier: "be.zenjoy.zentty",
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(targets.map(\.stableID), [
            ServerBrowserTarget.systemDefaultID,
            "dia",
        ])
    }

    func test_custom_browser_skipped_when_same_bundle_as_resolved_built_in() throws {
        let targets = ServerBrowserCatalog.targets(
            preferences: AppConfig.ServerDetection(
                passiveDetectionEnabled: true,
                preferredBrowserID: ServerBrowserTarget.systemDefaultID,
                enabledBrowserTargetIDs: [],
                customBrowsers: [
                    ServerBrowserCustomApp(
                        id: "custom:extra-chrome",
                        name: "Chrome copy",
                        appPath: "/Applications/Other Chrome.app",
                        bundleIdentifier: "com.google.Chrome"
                    ),
                ]
            ).normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "chrome",
                    path: "/Applications/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(targets.map(\.stableID), [
            ServerBrowserTarget.systemDefaultID,
            "chrome",
        ])
    }

    func test_helper_bundles_outside_normal_app_locations_are_filtered() throws {
        let targets = ServerBrowserCatalog.targets(
            preferences: AppConfig.ServerDetection.default.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "helper",
                    path: "/Applications/Chrome.app/Contents/Frameworks/Chrome Helper.app",
                    name: "Chrome Helper",
                    bundleIdentifier: "com.google.Chrome.helper"
                ),
                browser(
                    stableID: "tmp",
                    path: "/tmp/Firefox.app",
                    name: "Firefox",
                    bundleIdentifier: "org.mozilla.firefox"
                ),
                browser(
                    stableID: "sizzy",
                    path: "/Applications/Sizzy.app",
                    name: "Sizzy",
                    bundleIdentifier: "com.sizzy.Sizzy"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(targets.map(\.stableID), [
            ServerBrowserTarget.systemDefaultID,
            "sizzy",
        ])
    }

    func test_preferred_matching_accepts_legacy_bundle_id_for_built_in_row() throws {
        var preferences = AppConfig.ServerDetection.default
        preferences.preferredBrowserID = "bundle:com.google.Chrome"

        let preferred = ServerBrowserCatalog.preferredTarget(
            preferences: preferences.normalized(),
            resolvedBuiltIns: [
                browser(
                    stableID: "chrome",
                    path: "/Applications/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(preferred.stableID, "chrome")
    }

    func test_targets_excludes_built_ins_not_in_enabled_list() throws {
        var preferences = AppConfig.ServerDetection.default
        preferences.enabledBrowserTargetIDs = ["firefox"]
        preferences = preferences.normalized()

        let targets = ServerBrowserCatalog.targets(
            preferences: preferences,
            resolvedBuiltIns: [
                browser(
                    stableID: "chrome",
                    path: "/Applications/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome"
                ),
                browser(
                    stableID: "firefox",
                    path: "/Applications/Firefox.app",
                    name: "Firefox",
                    bundleIdentifier: "org.mozilla.firefox"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(
            targets.map(\.stableID),
            [ServerBrowserTarget.systemDefaultID, "firefox"]
        )
    }

    func test_targets_excludes_custom_browser_when_disabled() throws {
        var preferences = AppConfig.ServerDetection.default
        preferences.customBrowsers = [
            ServerBrowserCustomApp(
                id: "custom:mybrowser",
                name: "My Browser",
                appPath: "/Applications/My Browser.app",
                bundleIdentifier: "com.example.browser"
            ),
        ]
        preferences.enabledBrowserTargetIDs = ["chrome"]
        preferences = preferences.normalized()

        let targets = ServerBrowserCatalog.targets(
            preferences: preferences,
            resolvedBuiltIns: [
                browser(
                    stableID: "chrome",
                    path: "/Applications/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome"
                ),
            ],
            isApplicationAvailable: { _ in true }
        )

        XCTAssertEqual(targets.map(\.stableID), [ServerBrowserTarget.systemDefaultID, "chrome"])
    }

    private func browser(
        stableID: String,
        path: String,
        name: String,
        bundleIdentifier: String?
    ) -> ServerBrowserTarget {
        ServerBrowserTarget(
            stableID: stableID,
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            appURL: URL(fileURLWithPath: path),
            isSystemDefault: false,
            isAvailable: true
        )
    }
}
