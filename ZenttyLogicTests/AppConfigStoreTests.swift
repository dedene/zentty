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
        XCTAssertTrue(store.current.errorReporting.enabled)
        XCTAssertEqual(store.current.updates.channel, .stable)

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[sidebar]"))
        XCTAssertTrue(persisted.contains("width = 312"))
        XCTAssertTrue(persisted.contains("visibility = \"hidden\""))
        XCTAssertTrue(persisted.contains("[pane_layout]"))
        XCTAssertTrue(persisted.contains("laptop = \"roomy\""))
        XCTAssertTrue(persisted.contains("[panes]"))
        XCTAssertTrue(persisted.contains("show_labels = true"))
        XCTAssertTrue(persisted.contains("inactive_opacity = 0.7"))
        XCTAssertTrue(persisted.contains("show_project_icons = true"))
        XCTAssertTrue(persisted.contains("smooth_scroll_enabled = false"))
        XCTAssertTrue(persisted.contains("[open_with]"))
        XCTAssertTrue(persisted.contains("enabled_target_ids = [\"finder\", \"vscode\", \"cursor\", \"xcode\"]"))
        XCTAssertTrue(persisted.contains("[error_reporting]"))
        XCTAssertTrue(persisted.contains("enabled = true"))
        XCTAssertTrue(persisted.contains("[updates]"))
        XCTAssertTrue(persisted.contains("channel = \"stable\""))
    }

    func test_store_reads_pane_settings_from_config_file_and_clamps_inactive_opacity() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [panes]
        show_labels = false
        inactive_opacity = 0.2
        show_project_icons = false
        smooth_scroll_enabled = true
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.panes.showLabels)
        XCTAssertEqual(store.current.panes.inactiveOpacity, 0.6, accuracy: 0.001)
        XCTAssertFalse(store.current.panes.showProjectIcons)
        XCTAssertTrue(store.current.panes.smoothScrollingEnabled)
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
            config.panes.smoothScrollingEnabled = true
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor", "finder"]
            config.errorReporting.enabled = false
            config.updates.channel = .beta
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
        XCTAssertTrue(persisted.contains("smooth_scroll_enabled = true"))
        XCTAssertTrue(persisted.contains("primary_target_id = \"cursor\""))
        XCTAssertTrue(persisted.contains("[error_reporting]"))
        XCTAssertTrue(persisted.contains("enabled = false"))
        XCTAssertTrue(persisted.contains("[updates]"))
        XCTAssertTrue(persisted.contains("channel = \"beta\""))
        XCTAssertTrue(persisted.contains("[[open_with.custom_apps]]"))
        XCTAssertTrue(persisted.contains("path = \"/Applications/BBEdit.app\""))
        XCTAssertFalse(store.current.errorReporting.enabled)
        XCTAssertEqual(store.current.updates.channel, .beta)
        XCTAssertEqual(store.current.openWith.customApps.map(\.id), ["custom:bbedit"])
    }

    func test_config_round_trips_server_detection_and_browser_preference() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.serverDetection.passiveDetectionEnabled = false
            config.serverDetection.preferredBrowserID = "custom:sizzy"
            config.serverDetection.enabledBrowserTargetIDs = ["firefox", "chrome", "custom:sizzy"]
            config.serverDetection.customBrowsers = [
                ServerBrowserCustomApp(
                    id: "custom:sizzy",
                    name: "Sizzy",
                    appPath: "/Applications/Sizzy.app",
                    bundleIdentifier: "com.sizzy.Sizzy"
                )
            ]
        }

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("[server_detection]"))
        XCTAssertTrue(persisted.contains("passive_detection_enabled = false"))
        XCTAssertTrue(persisted.contains("preferred_browser_id = \"custom:sizzy\""))
        XCTAssertTrue(persisted.contains("enabled_browser_target_ids"))
        XCTAssertTrue(persisted.contains("[[server_detection.custom_browsers]]"))
        XCTAssertTrue(persisted.contains("bundle_identifier = \"com.sizzy.Sizzy\""))

        let reloadedStore = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )
        XCTAssertFalse(reloadedStore.current.serverDetection.passiveDetectionEnabled)
        XCTAssertEqual(reloadedStore.current.serverDetection.preferredBrowserID, "custom:sizzy")
        XCTAssertEqual(
            reloadedStore.current.serverDetection.enabledBrowserTargetIDs,
            ["firefox", "chrome", "custom:sizzy"]
        )
        XCTAssertEqual(reloadedStore.current.serverDetection.customBrowsers, [
            ServerBrowserCustomApp(
                id: "custom:sizzy",
                name: "Sizzy",
                appPath: "/Applications/Sizzy.app",
                bundleIdentifier: "com.sizzy.Sizzy"
            )
        ])
    }

    func test_server_detection_enables_all_browsers_when_toml_key_absent() throws {
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

        [server_detection]
        passive_detection_enabled = true
        preferred_browser_id = "system-default"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        let expected = ServerBrowserCatalog.orderedBrowserTargetIDs(customBrowserIDs: [])
        XCTAssertEqual(store.current.serverDetection.enabledBrowserTargetIDs, expected)
    }

    func test_store_reads_error_reporting_preference_from_config_file() throws {
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

        [error_reporting]
        enabled = false
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.errorReporting.enabled)
    }

    func test_store_reads_update_channel_from_config_file() throws {
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

        [updates]
        channel = "beta"
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.updates.channel, .beta)
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

    func test_store_ignores_unknown_non_string_fields_in_open_with_custom_apps() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [open_with]
        primary_target_id = "custom:duplicate"
        enabled_target_ids = ["custom:duplicate", "custom:valid", "missing"]

        [[open_with.custom_apps]]
        id = "custom:valid"
        name = "Valid App"
        path = "/Applications/Valid.app"
        launch_count = 3

        [[open_with.custom_apps]]
        id = "custom:duplicate"
        name = "Duplicate Path"
        path = "/Applications/Valid.app"
        quarantined = false
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
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["custom:valid"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "custom:valid")
    }

    func test_store_ignores_unknown_non_string_fields_in_server_custom_browsers() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [server_detection]
        passive_detection_enabled = false
        preferred_browser_id = "custom:duplicate"
        enabled_browser_target_ids = ["custom:duplicate", "custom:valid", "missing"]

        [[server_detection.custom_browsers]]
        id = "custom:valid"
        name = "Valid Browser"
        path = "/Applications/Valid Browser.app"
        bundle_identifier = "com.example.ValidBrowser"
        priority = 10

        [[server_detection.custom_browsers]]
        id = "custom:duplicate"
        name = "Duplicate Browser"
        path = "/Applications/Valid Browser.app"
        supports_profiles = true
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.serverDetection.passiveDetectionEnabled)
        XCTAssertEqual(store.current.serverDetection.customBrowsers, [
            ServerBrowserCustomApp(
                id: "custom:valid",
                name: "Valid Browser",
                appPath: "/Applications/Valid Browser.app",
                bundleIdentifier: "com.example.ValidBrowser"
            )
        ])
        XCTAssertEqual(store.current.serverDetection.enabledBrowserTargetIDs, ["custom:valid"])
        XCTAssertEqual(store.current.serverDetection.preferredBrowserID, "custom:valid")
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
        shortcut = "command+control+y"

        [[shortcuts.bindings]]
        command_id = "sidebar.toggle"
        shortcut = "command+control+z"

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
                shortcut: .init(key: .character("z"), modifiers: [.command, .control])
            )
        ])
    }

    func test_store_persists_pane_split_behavior_preferences_in_toml() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.paneLayout.rightSplitBehaviorMode = .alwaysSplit
            config.paneLayout.visibleSplitWindowWidth = .px1920
        }

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[pane_layout]"))
        XCTAssertTrue(persisted.contains("right_split_behavior = \"alwaysSplit\""))
        XCTAssertTrue(persisted.contains("visible_split_window_width = 1920"))
    }

    func test_store_reads_pane_split_behavior_preferences_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [pane_layout]
        laptop = "compact"
        large_display = "balanced"
        ultrawide = "roomy"
        right_split_behavior = "alwaysAdd"
        visible_split_window_width = 1680
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.paneLayout.rightSplitBehaviorMode, .alwaysAdd)
        XCTAssertEqual(store.current.paneLayout.visibleSplitWindowWidth, .px1680)
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

    func test_default_config_has_no_local_appearance_overrides() {
        XCTAssertEqual(AppConfig.default.appearance, .default)
        XCTAssertNil(AppConfig.default.appearance.localThemeName)
        XCTAssertNil(AppConfig.default.appearance.localBackgroundOpacity)
        XCTAssertTrue(AppConfig.default.appearance.syncOpenCodeThemeWithTerminal)

        let persisted = AppConfigTOML.encode(.default)
        XCTAssertFalse(persisted.contains("[appearance]"))
        XCTAssertFalse(persisted.contains("local_theme_name"))
        XCTAssertFalse(persisted.contains("local_background_opacity"))
        XCTAssertFalse(persisted.contains("sync_opencode_theme_with_terminal"))
    }

    func test_store_persists_opencode_theme_sync_opt_out_in_toml() throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.appearance.localThemeName = persistedFallbackThemeName
            config.appearance.localBackgroundOpacity = 0.87
            config.appearance.syncOpenCodeThemeWithTerminal = false
        }

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("[appearance]"))
        XCTAssertTrue(persisted.contains("local_theme_name = \"\(persistedFallbackThemeName)\""))
        XCTAssertTrue(persisted.contains("local_background_opacity = 0.87"))
        XCTAssertTrue(persisted.contains("sync_opencode_theme_with_terminal = false"))

        XCTAssertEqual(store.current.appearance.localThemeName, persistedFallbackThemeName)
        XCTAssertEqual(Double(store.current.appearance.localBackgroundOpacity ?? 0), 0.87, accuracy: 0.0001)
        XCTAssertFalse(store.current.appearance.syncOpenCodeThemeWithTerminal)
    }

    func test_store_reads_local_appearance_overrides_from_config_file() throws {
        let persistedFallbackThemeName = GhosttyThemeLibrary.fallbackPersistedThemeName
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "balanced"
        ultrawide = "balanced"

        [appearance]
        local_theme_name = "\(persistedFallbackThemeName)"
        local_background_opacity = 0.83
        sync_opencode_theme_with_terminal = true
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertEqual(store.current.appearance.localThemeName, persistedFallbackThemeName)
        XCTAssertEqual(Double(store.current.appearance.localBackgroundOpacity ?? 0), 0.83, accuracy: 0.0001)
        XCTAssertTrue(store.current.appearance.syncOpenCodeThemeWithTerminal)
    }

    func test_store_reads_opencode_theme_sync_opt_out_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [sidebar]
        width = 260
        visibility = "pinnedOpen"

        [pane_layout]
        laptop = "balanced"
        large_display = "balanced"
        ultrawide = "balanced"

        [appearance]
        sync_opencode_theme_with_terminal = false
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.appearance.syncOpenCodeThemeWithTerminal)
    }

    func test_store_reads_restore_workspace_on_launch_preference_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [restore]
        restore_workspace_on_launch = false
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.restore.restoreWorkspaceOnLaunch)
    }

    func test_store_persists_restore_workspace_on_launch_preference_in_toml() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.restore.restoreWorkspaceOnLaunch = false
        }

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[restore]"))
        XCTAssertTrue(persisted.contains("restore_workspace_on_launch = false"))
        XCTAssertFalse(store.current.restore.restoreWorkspaceOnLaunch)
    }

    func test_store_defaults_agent_teams_to_disabled() {
        let store = AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.agentTeams.enabled)
    }

    func test_store_defaults_agent_caffeination_to_enabled() {
        let store = AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertTrue(store.current.agentCaffeination.enabled)
    }

    func test_store_reads_agent_caffeination_opt_out_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [agent_caffeination]
        enabled = false
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertFalse(store.current.agentCaffeination.enabled)
    }

    func test_store_persists_agent_caffeination_enabled_in_toml() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.agentCaffeination.enabled = false
        }

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[agent_caffeination]"))
        XCTAssertTrue(persisted.contains("enabled = false"))
        XCTAssertFalse(store.current.agentCaffeination.enabled)
    }

    func test_store_reads_agent_teams_enabled_from_config_file() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try """
        [agent_teams]
        enabled = true
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        XCTAssertTrue(store.current.agentTeams.enabled)
    }

    func test_store_persists_agent_teams_enabled_in_toml() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        let store = AppConfigStore(
            fileURL: fileURL,
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        try store.update { config in
            config.agentTeams.enabled = true
        }

        let persisted = try String(contentsOf: fileURL)
        XCTAssertTrue(persisted.contains("[agent_teams]"))
        XCTAssertTrue(persisted.contains("enabled = true"))
        XCTAssertTrue(store.current.agentTeams.enabled)
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let suiteName = "ZenttyTests.AppConfigStoreTests.\(suffix).\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}

@MainActor
final class AgentCaffeinationControllerTests: XCTestCase {
    private final class Token: NSObject {
        let id: Int

        init(id: Int) {
            self.id = id
        }
    }

    @MainActor
    private final class ManualReleaseHandle: AgentCaffeinationScheduledHandle {
        private(set) var isCancelled = false
        private let operation: @MainActor () -> Void

        init(operation: @escaping @MainActor () -> Void) {
            self.operation = operation
        }

        func cancel() {
            isCancelled = true
        }

        func run() {
            guard !isCancelled else { return }
            isCancelled = true
            operation()
        }
    }

    @MainActor
    private final class Harness {
        var beginCount = 0
        var endedTokenIDs: [Int] = []
        var scheduledIntervals: [TimeInterval] = []
        var handles: [ManualReleaseHandle] = []

        lazy var controller = AgentCaffeinationController(
            releaseDebounceInterval: 10,
            beginActivity: { [weak self] _ in
                guard let self else { return Token(id: -1) }
                self.beginCount += 1
                return Token(id: self.beginCount)
            },
            endActivity: { [weak self] token in
                guard let self, let token = token as? Token else { return }
                self.endedTokenIDs.append(token.id)
            },
            releaseScheduler: { [weak self] interval, operation in
                let handle = ManualReleaseHandle(operation: operation)
                self?.scheduledIntervals.append(interval)
                self?.handles.append(handle)
                return handle
            }
        )
    }

    func test_acquires_once_when_first_enabled_source_reports_running() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.endedTokenIDs, [])
    }

    func test_does_not_acquire_when_source_is_disabled() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: false, hasRunningAgent: true)

        XCTAssertEqual(harness.beginCount, 0)
        XCTAssertEqual(harness.endedTokenIDs, [])
    }

    func test_schedules_release_after_last_source_stops() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: false)

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.scheduledIntervals, [10])
        XCTAssertEqual(harness.endedTokenIDs, [])

        harness.handles.last?.run()

        XCTAssertEqual(harness.endedTokenIDs, [1])
    }

    func test_cancels_pending_release_when_running_returns_before_debounce_fires() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: false)
        let firstRelease = harness.handles.last

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)

        XCTAssertTrue(firstRelease?.isCancelled == true)
        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.endedTokenIDs, [])
    }

    func test_releases_immediately_when_source_is_disabled() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-1"), enabled: false, hasRunningAgent: true)

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.scheduledIntervals, [])
        XCTAssertEqual(harness.endedTokenIDs, [1])
    }

    func test_keeps_activity_while_any_source_is_running() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-2"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: false)

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.scheduledIntervals, [])
        XCTAssertEqual(harness.endedTokenIDs, [])

        harness.controller.setSource(id: WindowID("window-2"), enabled: true, hasRunningAgent: false)

        XCTAssertEqual(harness.scheduledIntervals, [10])
    }

    func test_disabled_source_does_not_release_activity_held_by_another_source() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-2"), enabled: true, hasRunningAgent: true)
        harness.controller.setSource(id: WindowID("window-1"), enabled: false, hasRunningAgent: true)

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.scheduledIntervals, [])
        XCTAssertEqual(harness.endedTokenIDs, [])
    }

    func test_remove_source_releases_after_debounce() {
        let harness = Harness()

        harness.controller.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        harness.controller.removeSource(id: WindowID("window-1"))

        XCTAssertEqual(harness.scheduledIntervals, [10])

        harness.handles.last?.run()

        XCTAssertEqual(harness.endedTokenIDs, [1])
    }

    func test_deinit_releases_active_activity() {
        let harness = Harness()
        var controller: AgentCaffeinationController? = harness.controller

        controller?.setSource(id: WindowID("window-1"), enabled: true, hasRunningAgent: true)
        controller = nil
        harness.controller = AgentCaffeinationController(
            beginActivity: { _ in Token(id: 2) },
            endActivity: { _ in },
            releaseScheduler: { _, operation in ManualReleaseHandle(operation: operation) }
        )

        XCTAssertEqual(harness.endedTokenIDs, [1])
    }
}
