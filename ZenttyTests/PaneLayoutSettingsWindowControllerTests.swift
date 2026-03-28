import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func test_settings_window_uses_toolbar_tab_shell_and_defaults_to_pane_layout() throws {
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
        waitForLayout()

        let tabController = try XCTUnwrap(controller.window?.contentViewController as? NSTabViewController)

        XCTAssertEqual(tabController.tabStyle, .toolbar)
        XCTAssertNotNil(controller.window?.toolbar)
        XCTAssertFalse(controller.window?.styleMask.contains(.resizable) == true)
        XCTAssertEqual(contentController.sectionTitles, ["Shortcuts", "Open With", "Pane Layout"])
        XCTAssertEqual(contentController.selectedSection, .paneLayout)
        XCTAssertEqual(controller.window?.title, "Pane Layout")

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

    func test_settings_window_can_switch_to_shortcuts_section_and_read_effective_bindings() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
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

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .shortcuts, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        XCTAssertEqual(contentController.selectedSection, .shortcuts)
        XCTAssertEqual(controller.window?.title, "Shortcuts")

        let shortcutsController = try XCTUnwrap(
            contentController.currentSectionViewController as? ShortcutsSettingsSectionViewController
        )
        XCTAssertNotNil(shortcutsController.view.firstDescendantScrollView())
        XCTAssertEqual(shortcutsController.visibleCategoryTitles, ["General", "Worklanes", "Panes", "Notifications"])
        XCTAssertEqual(shortcutsController.displayString(for: .toggleSidebar), "⌘B")
        XCTAssertEqual(shortcutsController.displayString(for: .copyFocusedPanePath), "Unassigned")
    }

    func test_settings_window_auto_sizes_height_for_selected_pane_without_exceeding_screen_cap() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .paneLayout, sender: nil)
        waitForLayout()

        let initialFrame = try XCTUnwrap(controller.window?.frame)
        let maxAllowedHeight = ((controller.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height) ?? 0) * (2.0 / 3.0)

        controller.show(section: .shortcuts, sender: nil)
        waitForLayout("shortcuts settled", delay: 0.2)

        let shortcutsFrame = try XCTUnwrap(controller.window?.frame)

        XCTAssertEqual(shortcutsFrame.width, initialFrame.width, accuracy: 1.0)
        XCTAssertGreaterThan(shortcutsFrame.height, initialFrame.height)
        XCTAssertLessThanOrEqual(shortcutsFrame.height, maxAllowedHeight + 2.0)
    }

    func test_shortcuts_pane_scrolls_when_content_exceeds_window_height_cap() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .shortcuts
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .shortcuts, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let shortcutsController = try XCTUnwrap(
            contentController.currentSectionViewController as? ShortcutsSettingsSectionViewController
        )
        let scrollView = try XCTUnwrap(shortcutsController.view.firstDescendantScrollView())
        let documentHeight = scrollView.documentView?.fittingSize.height ?? 0

        XCTAssertGreaterThan(documentHeight, scrollView.contentSize.height)
        XCTAssertTrue(scrollView.hasVerticalScroller)
    }

    @objc
    func test_shortcuts_pane_opens_scrolled_to_top() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .shortcuts
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .shortcuts, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let shortcutsController = try XCTUnwrap(
            contentController.currentSectionViewController as? ShortcutsSettingsSectionViewController
        )
        let scrollView = try XCTUnwrap(shortcutsController.view.firstDescendantScrollView())

        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1.0)
    }

    @objc
    func test_switching_back_to_shortcuts_resets_scroll_position_to_top() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .shortcuts
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .shortcuts, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let shortcutsController = try XCTUnwrap(
            contentController.currentSectionViewController as? ShortcutsSettingsSectionViewController
        )
        let scrollView = try XCTUnwrap(shortcutsController.view.firstDescendantScrollView())
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let viewportHeight = scrollView.contentSize.height
        let bottomOffset = max(0, documentHeight - viewportHeight)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 1.0)

        controller.show(section: .paneLayout, sender: nil)
        waitForLayout("pane layout settled")
        controller.show(section: .shortcuts, sender: nil)
        waitForLayout("shortcuts restored", delay: 0.2)

        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1.0)
    }

    @objc
    func test_settings_window_uses_slide_and_fade_transition_between_sections() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .shortcuts, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let usesHorizontalSlide = contentController.transitionOptions.contains(.slideLeft)
            || contentController.transitionOptions.contains(.slideRight)

        XCTAssertTrue(contentController.transitionOptions.contains(.crossfade))
        XCTAssertTrue(usesHorizontalSlide)
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
        waitForLayout()

        XCTAssertEqual(contentController.selectedSection, .openWith)
        XCTAssertEqual(controller.window?.title, "Open With")

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
private extension SettingsWindowControllerTests {
    func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }
}

private extension NSView {
    func firstDescendantScrollView() -> NSScrollView? {
        if let scrollView = self as? NSScrollView {
            return scrollView
        }

        for subview in subviews {
            if let scrollView = subview.firstDescendantScrollView() {
                return scrollView
            }
        }

        return nil
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
