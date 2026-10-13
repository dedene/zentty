import XCTest
@testable import Zentty

/// config.toml is often shared between Macs (Syncthing, dotfiles repos) and
/// between Zentty versions. These tests pin the two guarantees that make that
/// safe: a file the app cannot read is never overwritten, and sections or keys
/// this build does not know survive a save.
final class AppConfigStoreSyncSafetyTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var defaultsSuiteNames: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.AppConfigSyncSafety.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaultsSuiteNames.forEach {
            UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0)
        }
        defaultsSuiteNames.removeAll()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    // MARK: - Write protection

    func test_update_after_invalid_load_keeps_change_in_memory_without_overwriting_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let invalidSource = """
        [sidebar]
        width = 260

        [open_with]
        enabled_target_ids = ["finder", "cursor"
        """
        try invalidSource.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = makeStore(fileURL: fileURL)

        try store.update { $0.sidebar.width = 333 }

        XCTAssertEqual(store.current.sidebar.width, 333)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), invalidSource)
        XCTAssertTrue(store.isWriteProtected)
    }

    func test_update_after_invalid_external_reload_does_not_overwrite_the_users_edit() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = makeStore(fileURL: fileURL)
        XCTAssertFalse(store.isWriteProtected)

        let invalidEdit = """
        [sidebar]
        width = 401
        visibility = "hidden
        """
        try invalidEdit.write(to: fileURL, atomically: true, encoding: .utf8)
        store.reloadFromDisk()

        try store.update { $0.sidebar.width = 280 }

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), invalidEdit)
        XCTAssertTrue(store.isWriteProtected)
    }

    func test_writes_resume_once_the_file_is_valid_again() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try "[sidebar]\nwidth = oops\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = makeStore(fileURL: fileURL)
        XCTAssertTrue(store.isWriteProtected)

        try "[sidebar]\nwidth = 300\n".write(to: fileURL, atomically: true, encoding: .utf8)
        store.reloadFromDisk()
        XCTAssertFalse(store.isWriteProtected)
        XCTAssertEqual(store.current.sidebar.width, 300)

        try store.update { $0.sidebar.width = 310 }

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("width = 310"), persisted)
    }

    func test_update_is_based_on_the_file_on_disk_not_the_last_watcher_reload() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = makeStore(fileURL: fileURL)
        // A synced edit lands; save before the debounced watcher has run.
        try "[panes]\nshow_labels = false\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try store.update { $0.sidebar.width = 333 }

        let decoded = try XCTUnwrap(AppConfigTOML.decode(try String(contentsOf: fileURL, encoding: .utf8)))
        XCTAssertFalse(decoded.panes.showLabels, "the synced change must survive the save")
        XCTAssertEqual(decoded.sidebar.width, 333)
    }

    func test_update_right_after_a_broken_edit_does_not_overwrite_it() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = makeStore(fileURL: fileURL)
        let brokenEdit = "[sidebar]\nwidth = \n"
        try brokenEdit.write(to: fileURL, atomically: true, encoding: .utf8)

        try store.update { $0.sidebar.width = 333 }

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), brokenEdit)
        XCTAssertTrue(store.isWriteProtected)
    }

    func test_own_save_is_not_mistaken_for_an_external_edit() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = makeStore(fileURL: fileURL)
        let origins = OriginRecorder()
        _ = store.addObserver(withOrigin: { _, origin in origins.append(origin) })

        // localThemeName is kept in memory but never written back to the file.
        try store.update { $0.appearance.localThemeName = "TokyoNight" }
        try store.update { $0.sidebar.width = 333 }

        let settled = expectation(description: "watcher debounce elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(store.current.appearance.localThemeName, "TokyoNight")
        XCTAssertEqual(origins.values, [.inProcess, .inProcess])
    }

    // MARK: - Forward compatibility

    func test_unknown_section_loads_and_survives_a_save() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 300

        [future_feature]
        enabled = true
        mode = "fancy"
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = makeStore(fileURL: fileURL)
        XCTAssertFalse(store.isWriteProtected)
        XCTAssertEqual(store.current.sidebar.width, 300)

        try store.update { $0.sidebar.width = 320 }

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("width = 320"), persisted)
        XCTAssertTrue(persisted.contains("[future_feature]\nenabled = true\nmode = \"fancy\""), persisted)
    }

    func test_unknown_key_in_known_section_survives_a_save_in_its_section() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 300
        future_key = "kept"

        [panes]
        show_labels = false
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = makeStore(fileURL: fileURL)

        try store.update { $0.sidebar.width = 320 }

        let decoded = try XCTUnwrap(AppConfigTOML.decode(try String(contentsOf: fileURL, encoding: .utf8)))
        XCTAssertEqual(decoded.sidebar.width, 320)
        XCTAssertFalse(decoded.panes.showLabels)
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        let sidebarBlock = try XCTUnwrap(persisted.components(separatedBy: "\n\n").first { $0.hasPrefix("[sidebar]") })
        XCTAssertTrue(sidebarBlock.contains("future_key = \"kept\""), persisted)
        XCTAssertEqual(persisted.components(separatedBy: "future_key").count, 2, "the key must be written exactly once")
    }

    func test_unknown_root_keys_and_repeated_array_tables_round_trip_in_order() throws {
        let source = """
        schema_version = 2

        [[future.items]]
        name = "a"

        [[future.items]]
        name = "b"
        """
        let config = try XCTUnwrap(AppConfigTOML.decode(source))

        let encoded = AppConfigTOML.encode(config)

        XCTAssertTrue(encoded.hasPrefix("schema_version = 2\n"), encoded)
        XCTAssertTrue(
            encoded.contains("[[future.items]]\nname = \"a\"\n\n[[future.items]]\nname = \"b\""),
            encoded
        )
        XCTAssertEqual(AppConfigTOML.decode(encoded), config, "re-decoding must be stable")
    }

    func test_unknown_agent_state_value_survives_and_a_later_known_value_replaces_it() throws {
        let config = try XCTUnwrap(AppConfigTOML.decode("""
        [agent_integrations.states]
        claude = "future_state"
        """))

        XCTAssertTrue(AppConfigTOML.encode(config).contains("claude = \"future_state\""))

        var updated = config
        updated.agentIntegrations.states["claude"] = .on
        let encoded = AppConfigTOML.encode(updated)
        XCTAssertEqual(encoded.components(separatedBy: "claude = ").count, 2, encoded)
        XCTAssertTrue(encoded.contains("claude = \"on\""), encoded)
    }

    func test_retired_keys_are_read_but_not_preserved() throws {
        let source = """
        [appearance]
        local_theme_name = "Dracula"
        """
        let config = try XCTUnwrap(AppConfigTOML.decode(source))

        XCTAssertFalse(AppConfigTOML.encode(config).contains("local_theme_name"))
    }

    func test_bad_value_for_a_known_key_still_makes_the_file_invalid() {
        XCTAssertNil(AppConfigTOML.decode("[sidebar]\nwidth = wide\n"))
    }

    // MARK: - Portability

    func test_custom_app_paths_under_home_are_written_with_tilde_and_read_back_absolute() throws {
        let homeApp = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Foo.app")
        var config = AppConfig.default
        config.openWith.customApps = [OpenWithCustomApp(id: "custom:foo", name: "Foo", appPath: homeApp)]
        config.serverDetection.customBrowsers = [
            ServerBrowserCustomApp(id: "custom:bar", name: "Bar", appPath: "/Applications/Bar.app", bundleIdentifier: nil),
        ]

        let encoded = AppConfigTOML.encode(config)

        XCTAssertTrue(encoded.contains("path = \"~/Applications/Foo.app\""), encoded)
        XCTAssertTrue(encoded.contains("path = \"/Applications/Bar.app\""), encoded)
        let decoded = try XCTUnwrap(AppConfigTOML.decode(encoded))
        XCTAssertEqual(decoded.openWith.customApps.first?.appPath, homeApp)
        XCTAssertEqual(decoded.serverDetection.customBrowsers.first?.appPath, "/Applications/Bar.app")
    }

    // MARK: - Helpers

    private func makeStore(fileURL: URL) -> AppConfigStore {
        AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: makeDefaults(suffix: "sidebarWidth"),
            sidebarVisibilityDefaults: makeDefaults(suffix: "sidebarVisibility"),
            paneLayoutDefaults: makeDefaults(suffix: "paneLayout")
        )
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let suiteName = "ZenttyTests.AppConfigSyncSafety.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }
}

private final class OriginRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppConfigChangeOrigin] = []

    var values: [AppConfigChangeOrigin] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ origin: AppConfigChangeOrigin) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(origin)
    }
}
