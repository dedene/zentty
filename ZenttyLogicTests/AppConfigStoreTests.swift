import XCTest
@testable import Zentty

final class AppConfigStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var sidebarWidthDefaults: UserDefaults!
    private var sidebarVisibilityDefaults: UserDefaults!
    private var paneLayoutDefaults: UserDefaults!
    private var defaultsSuiteNames: [String] = []

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.AppConfigStore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        sidebarWidthDefaults = makeDefaults(suffix: "sidebarWidth")
        sidebarVisibilityDefaults = makeDefaults(suffix: "sidebarVisibility")
        paneLayoutDefaults = makeDefaults(suffix: "paneLayout")
    }

    override func tearDownWithError() throws {
        defaultsSuiteNames.forEach {
            UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0)
        }
        defaultsSuiteNames.removeAll()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        paneLayoutDefaults = nil
        sidebarVisibilityDefaults = nil
        sidebarWidthDefaults = nil
        temporaryDirectoryURL = nil
    }

    func test_default_file_url_uses_xdg_style_config_location() {
        let homeURL = URL(fileURLWithPath: "/Users/peter", isDirectory: true)

        XCTAssertEqual(
            AppConfigStore.defaultFileURL(homeDirectoryURL: homeURL).path,
            "/Users/peter/.config/zentty/config.toml"
        )
    }

    func test_store_migrates_existing_user_defaults_when_file_is_missing() throws {
        SidebarWidthPreference.persist(312, in: sidebarWidthDefaults)
        SidebarVisibilityPreference.persist(.hidden, in: sidebarVisibilityDefaults)
        PaneLayoutPreferenceStore.persist(.roomy, for: .laptop, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(.compact, for: .largeDisplay, in: paneLayoutDefaults)
        PaneLayoutPreferenceStore.persist(.balanced, for: .ultrawide, in: paneLayoutDefaults)

        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.sidebar.width, 312)
        XCTAssertEqual(store.current.sidebar.visibility, .hidden)
        XCTAssertEqual(store.current.paneLayout.laptopPreset, .roomy)
        XCTAssertEqual(store.current.paneLayout.largeDisplayPreset, .compact)
        XCTAssertEqual(store.current.paneLayout.ultrawidePreset, .balanced)
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["finder", "vscode", "cursor", "xcode"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "finder")

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[sidebar]"))
        XCTAssertTrue(persisted.contains("width = 312"))
        XCTAssertTrue(persisted.contains("visibility = \"hidden\""))
        XCTAssertTrue(persisted.contains("[pane_layout]"))
        XCTAssertTrue(persisted.contains("laptop = \"roomy\""))
        XCTAssertTrue(persisted.contains("[open_with]"))
        XCTAssertTrue(persisted.contains("enabled_target_ids = [\"finder\", \"vscode\", \"cursor\", \"xcode\"]"))
    }

    func test_store_prefers_existing_config_file_over_user_defaults_migration() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "roomy"
        ultrawide = "compact"

        [open_with]
        primary_target_id = "cursor"
        enabled_target_ids = ["cursor", "finder"]
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        SidebarWidthPreference.persist(312, in: sidebarWidthDefaults)
        SidebarVisibilityPreference.persist(.hidden, in: sidebarVisibilityDefaults)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.sidebar.width, 260)
        XCTAssertEqual(store.current.sidebar.visibility, .pinnedOpen)
        XCTAssertEqual(store.current.paneLayout.laptopPreset, .balanced)
        XCTAssertEqual(store.current.paneLayout.largeDisplayPreset, .roomy)
        XCTAssertEqual(store.current.paneLayout.ultrawidePreset, .compact)
        XCTAssertEqual(store.current.openWith.primaryTargetID, "cursor")
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["cursor", "finder"])
    }

    func test_store_preserves_invalid_existing_config_file_without_overwriting_it() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let invalidSource = """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "balanced"
        ultrawide = "balanced"

        [open_with]
        primary_target_id = "finder"
        enabled_target_ids = ["finder", "cursor"
        """
        try invalidSource.write(to: fileURL, atomically: true, encoding: .utf8)

        SidebarWidthPreference.persist(312, in: sidebarWidthDefaults)
        SidebarVisibilityPreference.persist(.hidden, in: sidebarVisibilityDefaults)
        PaneLayoutPreferenceStore.persist(.roomy, for: .laptop, in: paneLayoutDefaults)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current, AppConfig.default.normalized())
        XCTAssertEqual(try String(contentsOf: fileURL), invalidSource)
    }

    func test_store_writes_updates_atomically_as_toml() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.sidebar.width = 344
            config.sidebar.visibility = .pinnedOpen
            config.paneLayout.largeDisplayPreset = .roomy
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor", "finder"]
            config.openWith.customApps = [
                OpenWithCustomApp(
                    id: "custom:bbedit",
                    name: "BBEdit",
                    appPath: "/Applications/BBEdit.app"
                )
            ]
        }

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("width = 344"))
        XCTAssertTrue(persisted.contains("large_display = \"roomy\""))
        XCTAssertTrue(persisted.contains("primary_target_id = \"cursor\""))
        XCTAssertTrue(persisted.contains("[[open_with.custom_apps]]"))
        XCTAssertTrue(persisted.contains("path = \"/Applications/BBEdit.app\""))
        XCTAssertEqual(store.current.openWith.customApps.map(\.id), ["custom:bbedit"])
    }

    func test_store_writes_shortcut_overrides_and_unbound_entries() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.shortcuts.bindings = [
                ShortcutBindingOverride(
                    commandID: .toggleSidebar,
                    shortcut: .init(key: .character("b"), modifiers: [.command])
                ),
                ShortcutBindingOverride(
                    commandID: .copyFocusedPanePath,
                    shortcut: nil
                ),
            ]
        }

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[[shortcuts.bindings]]"))
        XCTAssertTrue(persisted.contains("command_id = \"sidebar.toggle\""))
        XCTAssertTrue(persisted.contains("shortcut = \"command+b\""))
        XCTAssertTrue(persisted.contains("command_id = \"pane.copy_path\""))
        XCTAssertTrue(persisted.contains("shortcut = \"\""))
    }

    func test_store_live_reloads_external_file_edits() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )
        let reloaded = expectation(description: "config reloaded from external edit")
        store.onChange = { config in
            guard config.sidebar.width == 401 else {
                return
            }

            XCTAssertEqual(config.sidebar.visibility, .hidden)
            XCTAssertEqual(config.openWith.primaryTargetID, "xcode")
            XCTAssertEqual(config.openWith.enabledTargetIDs, ["xcode", "finder"])
            reloaded.fulfill()
        }

        try """
        [sidebar]
        width = 401
        visibility = "hidden"

        [pane_layout]
        laptop = "compact"
        large_display = "balanced"
        ultrawide = "balanced"

        [open_with]
        primary_target_id = "xcode"
        enabled_target_ids = ["xcode", "finder"]
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        wait(for: [reloaded], timeout: 5)
        XCTAssertEqual(store.current.sidebar.width, 401)
        XCTAssertEqual(store.current.openWith.primaryTargetID, "xcode")
    }

    func test_store_ignores_invalid_external_reload_and_keeps_last_good_config() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )
        let invalidReload = expectation(description: "invalid reload ignored")
        invalidReload.isInverted = true
        store.onChange = { _ in
            invalidReload.fulfill()
        }

        let originalConfig = store.current
        let invalidSource = """
        [sidebar]
        width = 401
        visibility = "hidden"

        [pane_layout]
        laptop = "compact"
        large_display = "balanced"
        ultrawide = "balanced"

        [open_with]
        primary_target_id = "xcode"
        enabled_target_ids = ["xcode", "finder"
        """
        try invalidSource.write(to: fileURL, atomically: true, encoding: .utf8)

        wait(for: [invalidReload], timeout: 0.5)
        XCTAssertEqual(store.current, originalConfig)
        XCTAssertEqual(try String(contentsOf: fileURL), invalidSource)
    }

    func test_store_preserves_empty_enabled_open_with_list_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "balanced"
        ultrawide = "balanced"

        [open_with]
        primary_target_id = "finder"
        enabled_target_ids = []
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.openWith.enabledTargetIDs, [])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "finder")
    }

    func test_store_normalizes_duplicate_and_invalid_open_with_custom_apps_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "balanced"
        ultrawide = "balanced"

        [open_with]
        primary_target_id = "custom:duplicate"
        enabled_target_ids = ["finder", "custom:duplicate", "custom:valid", "finder", "missing"]

        [[open_with.custom_apps]]
        id = "custom:valid"
        name = "Valid App"
        path = "/Applications/Valid.app"

        [[open_with.custom_apps]]
        id = "custom:duplicate"
        name = "Duplicate Path"
        path = "/Applications/Valid.app"

        [[open_with.custom_apps]]
        id = "finder"
        name = "Bad Override"
        path = "/Applications/Bad.app"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.openWith.customApps, [
            OpenWithCustomApp(
                id: "custom:valid",
                name: "Valid App",
                appPath: "/Applications/Valid.app"
            )
        ])
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["finder", "custom:valid"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "custom:valid")
    }

    func test_store_normalizes_duplicate_and_conflicting_shortcut_overrides_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "balanced"
        ultrawide = "balanced"

        [open_with]
        primary_target_id = "finder"
        enabled_target_ids = ["finder", "cursor"]

        [[shortcuts.bindings]]
        command_id = "sidebar.toggle"
        shortcut = "command+b"

        [[shortcuts.bindings]]
        command_id = "sidebar.toggle"
        shortcut = "command+shift+b"

        [[shortcuts.bindings]]
        command_id = "pane.split.horizontal"
        shortcut = "command+t"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.shortcuts.bindings, [
            ShortcutBindingOverride(
                commandID: .toggleSidebar,
                shortcut: .init(key: .character("b"), modifiers: [.command, .shift])
            )
        ])
    }

    func test_store_drops_shortcut_overrides_without_command_control_or_option() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [[shortcuts.bindings]]
        command_id = "sidebar.toggle"
        shortcut = "a"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.shortcuts.bindings, [])
    }

    func test_store_notifies_multiple_observers_for_updates() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        let legacyObserverCalled = expectation(description: "legacy observer called")
        let additionalObserverCalled = expectation(description: "additional observer called")
        store.onChange = { config in
            XCTAssertEqual(config.sidebar.width, 333)
            legacyObserverCalled.fulfill()
        }
        let observerID = store.addObserver { config in
            XCTAssertEqual(config.sidebar.width, 333)
            additionalObserverCalled.fulfill()
        }

        try store.update { config in
            config.sidebar.width = 333
        }

        wait(for: [legacyObserverCalled, additionalObserverCalled], timeout: 2)

        store.removeObserver(observerID)
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let suiteName = "ZenttyTests.AppConfigStoreTests.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
