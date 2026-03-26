import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func test_settings_window_shows_icon_sidebar_and_defaults_to_pane_layout() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()

        XCTAssertEqual(contentController.sectionTitles, ["Open With", "Pane Layout"])
        XCTAssertEqual(contentController.selectedSection, .paneLayout)
        XCTAssertEqual(contentController.contentSectionTitle, "Pane Layout")

        let paneLayoutController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )
        XCTAssertEqual(paneLayoutController.sectionTitles, ["Laptop", "Large Display", "Ultrawide Hybrid"])
        XCTAssertEqual(paneLayoutController.presetSummary, [
            "Laptop behavior: preserve the active pane, then scroll horizontally.",
            "Large Display behavior: preserve the active pane with slightly denser columns.",
            "Ultrawide Hybrid behavior: first split is 50/50, then keep horizontal scrolling.",
        ])
    }

    func test_settings_window_can_switch_to_open_with_section_and_read_config() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["finder", "cursor", "xcode"]
        }

        let controller = SettingsWindowController(
            configStore: store,
            openWithService: StubOpenWithService(
                detectedTargets: [
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "finder",
                            kind: .fileManager,
                            displayName: "Finder",
                            builtInID: .finder,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "cursor",
                            kind: .editor,
                            displayName: "Cursor",
                            builtInID: .cursor,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "xcode",
                            kind: .editor,
                            displayName: "Xcode",
                            builtInID: .xcode,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                ]
            ),
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .openWith, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()

        XCTAssertEqual(contentController.selectedSection, .openWith)
        XCTAssertEqual(contentController.contentSectionTitle, "Open With")

        let openWithController = try XCTUnwrap(
            contentController.currentSectionViewController as? OpenWithSettingsSectionViewController
        )
        XCTAssertEqual(openWithController.selectedPrimaryTargetStableID, "cursor")
        XCTAssertEqual(openWithController.enabledTargetStableIDs, ["cursor", "finder", "xcode"])
        XCTAssertEqual(openWithController.visibleTargetStableIDs, ["cursor", "finder", "xcode"])
        XCTAssertEqual(openWithController.checkedVisibleTargetStableIDs, ["cursor", "finder", "xcode"])
        XCTAssertEqual(openWithController.primaryTargetPopupStableIDs, ["cursor", "finder", "xcode"])
    }

    func test_open_with_section_shows_only_available_apps_and_cleans_unavailable_state() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "custom:missing"
            config.openWith.enabledTargetIDs = ["finder", "cursor", "vscode", "custom:bbedit", "custom:missing"]
            config.openWith.customApps = [
                OpenWithCustomApp(
                    id: "custom:bbedit",
                    name: "BBEdit Custom",
                    appPath: "/Applications/BBEdit.app"
                ),
                OpenWithCustomApp(
                    id: "custom:missing",
                    name: "Missing Custom",
                    appPath: "/Applications/Missing Custom.app"
                )
            ]
        }

        let controller = OpenWithSettingsSectionViewController(
            configStore: store,
            openWithService: StubOpenWithService(
                detectedTargets: [
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "finder",
                            kind: .fileManager,
                            displayName: "Finder",
                            builtInID: .finder,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "vscode",
                            kind: .editor,
                            displayName: "VS Code",
                            builtInID: .vscode,
                            appPath: nil
                        ),
                        isAvailable: false
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "cursor",
                            kind: .editor,
                            displayName: "Cursor",
                            builtInID: .cursor,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "custom:bbedit",
                            kind: .editor,
                            displayName: "BBEdit Custom",
                            builtInID: nil,
                            appPath: "/Applications/BBEdit.app"
                        ),
                        isAvailable: true
                    ),
                ]
            ),
            customAppPicker: { nil }
        )
        controller.loadViewIfNeeded()
        controller.apply(preferences: store.current.openWith)
        controller.prepareForPresentation()

        XCTAssertEqual(controller.visibleTargetStableIDs, ["cursor", "finder", "custom:bbedit"])
        XCTAssertEqual(controller.checkedVisibleTargetStableIDs, ["cursor", "finder", "custom:bbedit"])
        XCTAssertEqual(controller.primaryTargetPopupStableIDs, ["cursor", "finder", "custom:bbedit"])
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["cursor", "finder", "custom:bbedit"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "cursor")
        XCTAssertEqual(store.current.openWith.customApps.map(\.id), ["custom:bbedit"])
        XCTAssertEqual(controller.customAppNames, ["BBEdit Custom"])
    }

    func test_open_with_section_keeps_available_but_disabled_apps_unchecked() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "finder"
            config.openWith.enabledTargetIDs = ["finder", "xcode"]
        }

        let controller = OpenWithSettingsSectionViewController(
            configStore: store,
            openWithService: StubOpenWithService(
                detectedTargets: [
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "finder",
                            kind: .fileManager,
                            displayName: "Finder",
                            builtInID: .finder,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "cursor",
                            kind: .editor,
                            displayName: "Cursor",
                            builtInID: .cursor,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "xcode",
                            kind: .editor,
                            displayName: "Xcode",
                            builtInID: .xcode,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                ]
            ),
            customAppPicker: { nil }
        )
        controller.loadViewIfNeeded()
        controller.apply(preferences: store.current.openWith)
        controller.prepareForPresentation()

        XCTAssertEqual(controller.visibleTargetStableIDs, ["cursor", "finder", "xcode"])
        XCTAssertEqual(controller.checkedVisibleTargetStableIDs, ["finder", "xcode"])
        XCTAssertEqual(controller.primaryTargetPopupStableIDs, ["finder", "xcode"])
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["finder", "xcode"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "finder")
    }

    func test_open_with_section_can_add_custom_app_through_picker_and_enable_it() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = OpenWithSettingsSectionViewController(
            configStore: store,
            openWithService: StubOpenWithService(detectedTargets: []),
            customAppPicker: {
                OpenWithCustomApp(
                    id: "custom:zed-preview",
                    name: "Zed Preview",
                    appPath: "/Applications/Zed Preview.app"
                )
            }
        )
        controller.loadViewIfNeeded()

        controller.performAddCustomAppForTesting()

        XCTAssertEqual(store.current.openWith.customApps.map(\.name), ["Zed Preview"])
        XCTAssertEqual(store.current.openWith.customApps.map(\.appPath), ["/Applications/Zed Preview.app"])
        XCTAssertTrue(store.current.openWith.enabledTargetIDs.contains("custom:zed-preview"))
        XCTAssertEqual(controller.customAppNames, ["Zed Preview"])
    }

    func test_open_with_section_readding_existing_custom_app_reenables_existing_id_without_orphans() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.openWith.customApps = [
                OpenWithCustomApp(
                    id: "custom:zed-preview",
                    name: "Zed Preview",
                    appPath: "/Applications/Zed Preview.app"
                )
            ]
            config.openWith.enabledTargetIDs = ["finder"]
        }

        let controller = OpenWithSettingsSectionViewController(
            configStore: store,
            openWithService: StubOpenWithService(detectedTargets: []),
            customAppPicker: {
                OpenWithCustomApp(
                    id: "custom:new-random-id",
                    name: "Zed Preview",
                    appPath: "/Applications/Zed Preview.app"
                )
            }
        )
        controller.loadViewIfNeeded()

        controller.performAddCustomAppForTesting()

        XCTAssertEqual(store.current.openWith.customApps.map(\.id), ["custom:zed-preview"])
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["finder", "custom:zed-preview"])
    }

    func test_open_with_section_reconciles_unavailable_primary_target_to_available_fallback() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "vscode"
            config.openWith.enabledTargetIDs = ["vscode", "cursor"]
        }

        let controller = OpenWithSettingsSectionViewController(
            configStore: store,
            openWithService: StubOpenWithService(
                detectedTargets: [
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "vscode",
                            kind: .editor,
                            displayName: "VS Code",
                            builtInID: .vscode,
                            appPath: nil
                        ),
                        isAvailable: false
                    ),
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: "cursor",
                            kind: .editor,
                            displayName: "Cursor",
                            builtInID: .cursor,
                            appPath: nil
                        ),
                        isAvailable: true
                    ),
                ]
            ),
            customAppPicker: { nil }
        )
        controller.loadViewIfNeeded()

        controller.apply(preferences: store.current.openWith)
        controller.prepareForPresentation()

        XCTAssertEqual(controller.selectedPrimaryTargetStableID, "cursor")
        XCTAssertEqual(store.current.openWith.enabledTargetIDs, ["cursor"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "cursor")
    }
}

@MainActor
private final class StubOpenWithService: OpenWithServing {
    let detectedTargetsValue: [OpenWithDetectedTarget]

    init(detectedTargets: [OpenWithDetectedTarget]) {
        self.detectedTargetsValue = detectedTargets
    }

    func detectedTargets(preferences: AppConfig.OpenWith) -> [OpenWithDetectedTarget] {
        detectedTargetsValue
    }

    func availableTargets(preferences: AppConfig.OpenWith) -> [OpenWithResolvedTarget] {
        let detectedTargetsByID = Dictionary(uniqueKeysWithValues: detectedTargetsValue.map { ($0.target.stableID, $0) })
        let builtIns = OpenWithCatalog.macOSBuiltInTargets.compactMap { target -> OpenWithResolvedTarget? in
            guard let detectedTarget = detectedTargetsByID[target.id.rawValue], detectedTarget.isAvailable else {
                return nil
            }

            return detectedTarget.target
        }
        let customApps = preferences.customApps.compactMap { app -> OpenWithResolvedTarget? in
            guard let detectedTarget = detectedTargetsByID[app.id], detectedTarget.isAvailable else {
                return nil
            }

            return detectedTarget.target
        }

        return (builtIns + customApps).filter { preferences.enabledTargetIDs.contains($0.stableID) }
    }

    func primaryTarget(preferences: AppConfig.OpenWith) -> OpenWithResolvedTarget? {
        let availableTargetIDs = availableTargets(preferences: preferences).map(\.stableID)
        return OpenWithPreferencesResolver.primaryTarget(
            preferences: preferences,
            availableTargetIDs: availableTargetIDs
        )
    }

    func icon(for target: OpenWithResolvedTarget) -> NSImage? {
        nil
    }

    func open(target: OpenWithResolvedTarget, workingDirectory: String) -> Bool {
        false
    }
}
