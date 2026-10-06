import XCTest
@testable import Zentty

final class ZenttyBuildFlavorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyBuildFlavorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Resolution

    func test_missing_or_unknown_flavor_resolves_to_production() {
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: nil), .production)
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: [:]), .production)
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: ["ZenttyBuildFlavor": "staging"]), .production)
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: ["ZenttyBuildFlavor": ""]), .production)
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: ["ZenttyBuildFlavor": 1]), .production)
    }

    func test_dev_and_production_flavors_resolve_from_info_dictionary() {
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: ["ZenttyBuildFlavor": "dev"]), .dev)
        XCTAssertEqual(ZenttyBuildFlavor(infoDictionary: ["ZenttyBuildFlavor": "production"]), .production)
    }

    func test_test_runner_resolves_to_production() {
        XCTAssertEqual(ZenttyBuildFlavor.current, .production)
    }

    func test_display_name_reads_bundle_display_name_only_from_zentty_bundles() {
        XCTAssertEqual(
            ZenttyBuildFlavor.displayName(infoDictionary: [
                "ZenttyBuildFlavor": "dev",
                "CFBundleDisplayName": "Zentty Dev",
            ]),
            "Zentty Dev"
        )
        XCTAssertEqual(ZenttyBuildFlavor.displayName(infoDictionary: ["CFBundleDisplayName": "xctest"]), "Zentty")
        XCTAssertEqual(ZenttyBuildFlavor.displayName(infoDictionary: ["ZenttyBuildFlavor": "production"]), "Zentty")
        XCTAssertEqual(
            ZenttyBuildFlavor.displayName(infoDictionary: ["ZenttyBuildFlavor": "dev", "CFBundleDisplayName": ""]),
            "Zentty"
        )
        XCTAssertEqual(ZenttyBuildFlavor.displayName(infoDictionary: nil), "Zentty")
    }

    // MARK: - Derived names

    /// Regression guard: production names must stay byte-for-byte what they
    /// were before the flavor seam, or existing installs lose their state.
    @MainActor
    func test_production_names_match_pre_flavor_literals() {
        let flavor = ZenttyBuildFlavor.production
        XCTAssertEqual(flavor.configDirectoryName, "zentty")
        XCTAssertEqual(flavor.libraryFolderName, "Zentty")
        XCTAssertEqual(flavor.ghosttyTempFilePrefix + "local-overrides.conf", "zentty-ghostty-local-overrides.conf")
        XCTAssertEqual(flavor.agentWrappersDirectoryName, "agent-wrappers")
        XCTAssertEqual(flavor.selectionPasteboardName, "be.zenjoy.zentty.selection")
        XCTAssertEqual(flavor.customSoundFilePrefix, "zentty-custom-")

        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            AppConfigStore.defaultFileURL(homeDirectoryURL: home, flavor: flavor).path,
            "/Users/tester/.config/zentty/config.toml"
        )
        XCTAssertEqual(
            AppConfigStore.bookmarksFileURL(homeDirectoryURL: home, flavor: flavor).path,
            "/Users/tester/.config/zentty/bookmarks.json"
        )
        XCTAssertEqual(ClosedPaneScrollbackArchive.directoryName, "Zentty/restore-output")
    }

    func test_dev_names_are_distinct() {
        let flavor = ZenttyBuildFlavor.dev
        XCTAssertEqual(flavor.configDirectoryName, "zentty-dev")
        XCTAssertEqual(flavor.libraryFolderName, "Zentty Dev")
        XCTAssertEqual(flavor.ghosttyTempFilePrefix, "zentty-dev-ghostty-")
        XCTAssertEqual(flavor.agentWrappersDirectoryName, "agent-wrappers-dev")
        XCTAssertEqual(flavor.selectionPasteboardName, "be.zenjoy.zentty.dev.selection")
        XCTAssertEqual(flavor.customSoundFilePrefix, "zentty-dev-custom-")

        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            AppConfigStore.defaultFileURL(homeDirectoryURL: home, flavor: flavor).path,
            "/Users/tester/.config/zentty-dev/config.toml"
        )
    }

    // MARK: - Dev config seeding

    func test_seed_copies_config_and_bookmarks_but_not_restore_or_tmux_state() throws {
        let production = try makeProductionDirectory(files: [
            "config.toml": "[appearance]\n",
            "bookmarks.json": "[]",
            "restore-snapshot.json": "{}",
            "restore-lifecycle.json": "{}",
            "tmux-compat-store.json": "{}",
        ])
        let dev = temporaryDirectoryURL.appendingPathComponent("zentty-dev", isDirectory: true)

        let copied = AppConfigStore.seedDevConfigIfNeeded(productionDirectoryURL: production, devDirectoryURL: dev)

        XCTAssertEqual(copied, ["config.toml", "bookmarks.json"])
        XCTAssertEqual(try contents(of: dev), ["bookmarks.json", "config.toml"])
        XCTAssertEqual(
            try String(contentsOf: dev.appendingPathComponent("config.toml"), encoding: .utf8),
            "[appearance]\n"
        )
    }

    func test_seed_copies_symlinked_production_files_as_regular_files() throws {
        // Dotfile setups symlink config.toml; Dev must get its own copy, never the link,
        // because persist/BookmarkStore write through symlinks.
        let dotfiles = temporaryDirectoryURL.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realConfig = dotfiles.appendingPathComponent("config.toml")
        try "[appearance]\n".write(to: realConfig, atomically: true, encoding: .utf8)
        let production = try makeProductionDirectory(files: [:])
        try FileManager.default.createSymbolicLink(
            at: production.appendingPathComponent("config.toml"),
            withDestinationURL: realConfig
        )
        let dev = temporaryDirectoryURL.appendingPathComponent("zentty-dev", isDirectory: true)

        let copied = AppConfigStore.seedDevConfigIfNeeded(productionDirectoryURL: production, devDirectoryURL: dev)

        XCTAssertEqual(copied, ["config.toml"])
        let devConfig = dev.appendingPathComponent("config.toml")
        let attributes = try FileManager.default.attributesOfItem(atPath: devConfig.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOf: devConfig, encoding: .utf8), "[appearance]\n")

        // Write the way persist does (through any symlink) and confirm prod is untouched.
        let writeTarget = FileManager.default.resolvingSymlinkTarget(at: devConfig)
        try "dev-only".write(to: writeTarget, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: realConfig, encoding: .utf8), "[appearance]\n")
        XCTAssertEqual(try String(contentsOf: devConfig, encoding: .utf8), "dev-only")
    }

    func test_seed_is_noop_when_dev_config_already_exists() throws {
        let production = try makeProductionDirectory(files: [
            "config.toml": "production",
            "bookmarks.json": "[]",
        ])
        let dev = temporaryDirectoryURL.appendingPathComponent("zentty-dev", isDirectory: true)
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try "dev".write(to: dev.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let copied = AppConfigStore.seedDevConfigIfNeeded(productionDirectoryURL: production, devDirectoryURL: dev)

        XCTAssertEqual(copied, [])
        XCTAssertEqual(try contents(of: dev), ["config.toml"])
        XCTAssertEqual(try String(contentsOf: dev.appendingPathComponent("config.toml"), encoding: .utf8), "dev")
    }

    func test_seed_is_noop_when_production_directory_is_missing() throws {
        let production = temporaryDirectoryURL.appendingPathComponent("zentty", isDirectory: true)
        let dev = temporaryDirectoryURL.appendingPathComponent("zentty-dev", isDirectory: true)

        let copied = AppConfigStore.seedDevConfigIfNeeded(productionDirectoryURL: production, devDirectoryURL: dev)

        XCTAssertEqual(copied, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dev.path))
    }

    // MARK: - Helpers

    private func makeProductionDirectory(files: [String: String]) throws -> URL {
        let directory = temporaryDirectoryURL.appendingPathComponent("zentty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
