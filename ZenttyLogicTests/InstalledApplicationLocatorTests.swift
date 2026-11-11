import XCTest
@testable import Zentty

/// Chrome refreshes and menu validation ask for editor and browser targets on
/// every focus change. These tests pin that the answers come from memory, not
/// from LaunchServices and `/Applications` listings on the main thread.
@MainActor
final class InstalledApplicationLocatorTests: XCTestCase {
    func test_repeated_lookup_queries_launch_services_once() {
        let probe = ApplicationLookupProbe(bundles: ["com.microsoft.VSCode": "/Applications/Visual Studio Code.app"])
        let locator = probe.makeLocator()

        for _ in 0..<5 {
            XCTAssertEqual(
                locator.applicationURL(bundleIdentifiers: ["com.microsoft.VSCode"], exactNames: ["Visual Studio Code.app"])?.path,
                "/Applications/Visual Studio Code.app"
            )
        }

        XCTAssertEqual(probe.bundleLookups, 1)
    }

    func test_missing_app_is_remembered_and_never_lists_folders_without_prefix_names() {
        let probe = ApplicationLookupProbe()
        let locator = probe.makeLocator()

        for _ in 0..<5 {
            XCTAssertNil(locator.applicationURL(bundleIdentifiers: ["dev.zed.Zed"], exactNames: ["Zed.app"]))
        }

        XCTAssertEqual(probe.bundleLookups, 1)
        XCTAssertEqual(probe.fileExistsChecks, 2, "one exact-name check per search directory")
        XCTAssertEqual(probe.directoryListings, 0)
    }

    func test_prefix_lookups_share_one_listing_per_folder() {
        let probe = ApplicationLookupProbe(listings: [
            "/Applications": ["/Applications/IntelliJ IDEA 2026.1.app", "/Applications/RustRover 2026.1.app"],
        ])
        let locator = probe.makeLocator()

        XCTAssertEqual(
            locator.applicationURL(bundleIdentifiers: [], exactNames: [], prefixNames: ["IntelliJ IDEA"])?.lastPathComponent,
            "IntelliJ IDEA 2026.1.app"
        )
        XCTAssertEqual(
            locator.applicationURL(bundleIdentifiers: [], exactNames: [], prefixNames: ["RustRover"])?.lastPathComponent,
            "RustRover 2026.1.app"
        )
        XCTAssertNil(locator.applicationURL(bundleIdentifiers: [], exactNames: [], prefixNames: ["GoLand"]))

        XCTAssertEqual(probe.directoryListings, 2, "each search directory is listed once")
    }

    func test_invalidate_forgets_answers_and_bumps_generation() {
        let probe = ApplicationLookupProbe()
        let locator = probe.makeLocator()
        XCTAssertNil(locator.applicationURL(bundleIdentifiers: ["dev.zed.Zed"], exactNames: ["Zed.app"]))
        let generation = locator.generation

        probe.bundles["dev.zed.Zed"] = "/Applications/Zed.app"
        locator.invalidate()

        XCTAssertEqual(locator.generation, generation + 1)
        XCTAssertEqual(
            locator.applicationURL(bundleIdentifiers: ["dev.zed.Zed"], exactNames: ["Zed.app"])?.path,
            "/Applications/Zed.app"
        )
        XCTAssertEqual(probe.bundleLookups, 2)
    }

    func test_open_with_chrome_refreshes_do_not_requery_installed_apps() {
        let probe = ApplicationLookupProbe(bundles: ["com.microsoft.VSCode": "/Applications/Visual Studio Code.app"])
        let service = OpenWithService(applicationLocator: probe.makeLocator())
        let preferences = AppConfig.OpenWith.default

        _ = service.primaryTarget(preferences: preferences)
        let lookupsAfterFirstRefresh = probe.totalLookups

        for _ in 0..<10 {
            _ = service.primaryTarget(preferences: preferences)
            _ = service.availableTargets(preferences: preferences)
            _ = service.detectedTargets(preferences: preferences)
        }

        XCTAssertEqual(probe.totalLookups, lookupsAfterFirstRefresh)
        XCTAssertEqual(probe.directoryListings, 2, "prefix-named editors share one listing per folder")
    }

    func test_open_with_picks_up_newly_installed_editor_after_invalidation() {
        let probe = ApplicationLookupProbe()
        let locator = probe.makeLocator()
        let service = OpenWithService(applicationLocator: locator)
        var preferences = AppConfig.OpenWith.default
        preferences.enabledTargetIDs = [OpenWithBuiltInTargetID.zed.rawValue]

        XCTAssertTrue(service.availableTargets(preferences: preferences).isEmpty)

        probe.bundles["dev.zed.Zed"] = "/Applications/Zed.app"
        XCTAssertTrue(service.availableTargets(preferences: preferences).isEmpty, "cached until invalidated")

        locator.invalidate()
        XCTAssertEqual(service.availableTargets(preferences: preferences).map(\.stableID), ["zed"])
    }

    func test_server_chrome_refreshes_do_not_requery_installed_browsers() {
        let probe = ApplicationLookupProbe(
            bundles: ["org.mozilla.firefox": "/Applications/Firefox.app"],
            readablePaths: ["/Applications/Firefox.app"]
        )
        let service = ServerOpenService(applicationLocator: probe.makeLocator())
        let config = AppConfig.ServerDetection.default.normalized()

        _ = service.preferredBrowser(config: config)
        let lookupsAfterFirstRefresh = probe.totalLookups

        for _ in 0..<10 {
            _ = service.preferredBrowser(config: config)
            _ = service.availableBrowsers(config: config)
        }

        XCTAssertEqual(probe.totalLookups, lookupsAfterFirstRefresh)
    }
}

@MainActor
private final class ApplicationLookupProbe {
    var bundles: [String: String]
    var listings: [String: [String]]
    var readablePaths: Set<String>
    private(set) var bundleLookups = 0
    private(set) var fileExistsChecks = 0
    private(set) var readabilityChecks = 0
    private(set) var directoryListings = 0

    var totalLookups: Int {
        bundleLookups + fileExistsChecks + readabilityChecks + directoryListings
    }

    init(
        bundles: [String: String] = [:],
        listings: [String: [String]] = [:],
        readablePaths: Set<String> = []
    ) {
        self.bundles = bundles
        self.listings = listings
        self.readablePaths = readablePaths
    }

    func makeLocator() -> InstalledApplicationLocator {
        InstalledApplicationLocator(
            environment: InstalledApplicationLocator.Environment(
                searchDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true),
                ],
                urlForBundleIdentifier: { [unowned self] bundleIdentifier in
                    bundleLookups += 1
                    return bundles[bundleIdentifier].map { URL(fileURLWithPath: $0, isDirectory: true) }
                },
                fileExists: { [unowned self] _ in
                    fileExistsChecks += 1
                    return false
                },
                isReadableFile: { [unowned self] path in
                    readabilityChecks += 1
                    return readablePaths.contains(path)
                },
                contentsOfDirectory: { [unowned self] directoryURL in
                    directoryListings += 1
                    return (listings[directoryURL.path] ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
                }
            )
        )
    }
}
