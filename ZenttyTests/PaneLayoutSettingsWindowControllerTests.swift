import AppKit
import Carbon.HIToolbox
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
        XCTAssertEqual(contentController.sectionTitles, ["General", "Shortcuts", "Open With", "Pane Layout"])
        XCTAssertEqual(contentController.selectedSection, .paneLayout)
        XCTAssertEqual(controller.window?.title, "Pane Layout")

        let paneLayoutController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )
        XCTAssertEqual(paneLayoutController.sectionTitles, ["Laptop", "Large Display", "Ultrawide Hybrid"])
        XCTAssertEqual(paneLayoutController.presetSummary.count, paneLayoutController.sectionTitles.count)
        XCTAssertTrue(paneLayoutController.presetSummary.allSatisfy { !$0.isEmpty })
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
        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Toggle Sidebar")
        XCTAssertEqual(
            shortcutsController.selectedCommandDescriptionForTesting,
            "Show or hide the sidebar so you can focus on the canvas or quickly jump between worklanes."
        )
        XCTAssertNil(shortcutsController.selectedCommandDefaultShortcutForTesting)
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
        XCTAssertEqual(shortcutsFrame.maxY, initialFrame.maxY, accuracy: 2.0)
    }

    func test_shortcuts_pane_uses_internal_browser_scroller() throws {
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

        XCTAssertTrue(shortcutsController.isSearchFieldFullyVisibleForTesting)
        XCTAssertTrue(shortcutsController.isFirstCategoryHeaderFullyVisibleForTesting)
        XCTAssertTrue(shortcutsController.browserHasVerticalScrollerForTesting)
        XCTAssertTrue(shortcutsController.visibleCommandTitles.contains("Toggle Sidebar"))
        XCTAssertTrue(shortcutsController.visibleCommandTitles.contains("Reset Pane Layout"))
    }

    func test_shortcuts_pane_shows_detail_content_for_selected_command() throws {
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

        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Toggle Sidebar")
        XCTAssertNil(shortcutsController.selectedCommandDefaultShortcutForTesting)
        XCTAssertTrue(shortcutsController.showsKeyboardPreviewForTesting)
        XCTAssertEqual(shortcutsController.previewPrimaryHighlightedKeyCodeForTesting, UInt16(kVK_ANSI_S))
    }

    func test_shortcuts_pane_initial_selection_is_fully_visible() throws {
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

        XCTAssertTrue(shortcutsController.isSelectedCommandFullyVisibleForTesting)
    }

    func test_shortcuts_pane_initial_selection_uses_highlighted_text_color() throws {
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

        XCTAssertTrue(shortcutsController.selectedRowUsesEmphasizedTextColorForTesting)
    }

    func test_shortcuts_pane_selected_row_uses_emphasized_text_color_when_emphasized() throws {
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

        shortcutsController.setSelectedRowEmphasizedForTesting(true)
        XCTAssertTrue(shortcutsController.selectedRowUsesEmphasizedTextColorForTesting)
    }

    func test_shortcuts_pane_selected_row_keeps_highlighted_text_color_when_emphasis_clears() throws {
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

        shortcutsController.setSelectedRowEmphasizedForTesting(true)
        XCTAssertTrue(shortcutsController.selectedRowUsesEmphasizedTextColorForTesting)

        shortcutsController.setSelectedRowEmphasizedForTesting(false)
        XCTAssertTrue(shortcutsController.selectedRowUsesEmphasizedTextColorForTesting)
    }

    func test_settings_window_applies_injected_appearance() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            appearance: NSAppearance(named: .darkAqua),
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        XCTAssertEqual(
            controller.window?.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            .darkAqua
        )
    }

    func test_settings_window_applyAppearance_updates_window_appearance() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            appearance: NSAppearance(named: .aqua),
            initialSection: .shortcuts
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        controller.applyAppearance(NSAppearance(named: .darkAqua))
        waitForLayout("appearance update settled", delay: 0.05)

        XCTAssertEqual(
            controller.window?.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            .darkAqua
        )
    }

    func test_shortcuts_pane_search_flattens_results() throws {
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

        shortcutsController.applySearchForTesting("focus left")

        XCTAssertEqual(shortcutsController.visibleCategoryTitles, [])
        XCTAssertEqual(shortcutsController.visibleCommandTitles, ["Focus Left Pane"])
        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Focus Left Pane")
    }

    func test_shortcuts_pane_uses_dia_style_shortcut_ordering() throws {
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

        XCTAssertEqual(shortcutsController.displayString(for: .copyFocusedPanePath), "⇧⌘C")
    }

    func test_shortcuts_pane_filters_live_while_typing() throws {
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

        shortcutsController.typeSearchTextForTesting("focus left")

        XCTAssertEqual(shortcutsController.visibleCategoryTitles, [])
        XCTAssertEqual(shortcutsController.visibleCommandTitles, ["Focus Left Pane"])
        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Focus Left Pane")
    }

    func test_shortcuts_pane_uses_fixed_browser_column_instead_of_resizable_split() throws {
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

        XCTAssertTrue(shortcutsController.usesFixedBrowserColumnForTesting)
    }

    func test_shortcuts_pane_uses_simplified_detail_editor() throws {
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

        XCTAssertNil(shortcutsController.selectedCommandDefaultShortcutForTesting)
        XCTAssertTrue(shortcutsController.shortcutEditorUsesFullWidthLayoutForTesting)
        XCTAssertTrue(shortcutsController.showsInlineClearAffordanceForTesting)
        XCTAssertFalse(shortcutsController.showsPerCommandRestoreActionForTesting)
        XCTAssertTrue(shortcutsController.showsResetAllShortcutsActionForTesting)
    }

    func test_shortcuts_conflict_message_can_jump_to_conflicting_command() throws {
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

        shortcutsController.selectCommandForTesting(.newWorklane)
        shortcutsController.attemptShortcutAssignmentForTesting(
            KeyboardShortcut(key: .character("s"), modifiers: [.command])
        )

        XCTAssertEqual(shortcutsController.conflictTargetTitleForTesting, "Toggle Sidebar")

        shortcutsController.activateConflictTargetForTesting()

        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Toggle Sidebar")
    }

    func test_shortcuts_preview_updates_when_selected_command_changes() throws {
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

        shortcutsController.selectCommandForTesting(.focusRightPane)

        XCTAssertEqual(shortcutsController.previewPrimaryHighlightedKeyCodeForTesting, UInt16(kVK_RightArrow))
    }

    func test_shortcuts_preview_has_no_primary_highlight_for_unassigned_command() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.shortcuts.bindings = [
                ShortcutBindingOverride(commandID: .copyFocusedPanePath, shortcut: nil)
            ]
        }
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

        shortcutsController.selectCommandForTesting(.copyFocusedPanePath)

        XCTAssertNil(shortcutsController.previewPrimaryHighlightedKeyCodeForTesting)
        XCTAssertTrue(shortcutsController.previewHighlightedModifierKeyCodesForTesting.isEmpty)
    }

    func test_switching_back_to_shortcuts_preserves_selected_command() throws {
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

        shortcutsController.selectCommandForTesting(.focusRightPane)
        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Focus Right Pane")

        controller.show(section: .paneLayout, sender: nil)
        waitForLayout("pane layout settled")
        controller.show(section: .shortcuts, sender: nil)
        waitForLayout("shortcuts restored", delay: 0.2)

        XCTAssertEqual(shortcutsController.selectedCommandTitleForTesting, "Focus Right Pane")
    }

    func test_settings_window_avoids_stock_directional_transition_between_sections() throws {
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
        let usesDirectionalSlide = contentController.transitionOptions.contains(.slideLeft)
            || contentController.transitionOptions.contains(.slideRight)
            || contentController.transitionOptions.contains(.slideUp)
            || contentController.transitionOptions.contains(.slideDown)

        XCTAssertFalse(usesDirectionalSlide)
        XCTAssertEqual(contentController.transitionOptions, [])
    }

    func test_shortcuts_pane_suppresses_scroller_during_transition_then_restores_it() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindow(nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )

        controller.show(section: .shortcuts, sender: nil)

        let shortcutsController = try XCTUnwrap(
            contentController.currentSectionViewController as? ShortcutsSettingsSectionViewController
        )
        XCTAssertTrue(shortcutsController.isScrollerSuppressedForTesting)

        waitForLayout("shortcuts transition settled", delay: 0.35)

        XCTAssertFalse(shortcutsController.isScrollerSuppressedForTesting)
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

    func test_settings_window_can_switch_to_general_section_and_shows_notification_controls() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            errorReportingBundleConfigurationProvider: {
                ErrorReportingBundleConfiguration(
                    dsn: "https://public@example.com/1",
                    releaseName: "Zentty@1.0",
                    dist: "167"
                )
            },
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        XCTAssertEqual(contentController.selectedSection, .general)
        XCTAssertEqual(controller.window?.title, "General")

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )
        XCTAssertEqual(generalController.selectedSoundName, "")
        XCTAssertTrue(generalController.availableSoundNames.contains(""))
        XCTAssertTrue(generalController.availableSoundNames.contains("Glass"))
        XCTAssertTrue(generalController.availableSoundNames.contains("Ping"))
        XCTAssertTrue(generalController.isErrorReportingSwitchOn)
        XCTAssertTrue(generalController.isErrorReportingControlEnabled)
    }

    func test_general_section_persists_sound_name_to_config() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.notifications.soundName = "Glass"
        }

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )
        XCTAssertEqual(generalController.selectedSoundName, "Glass")
    }

    func test_general_section_defaults_update_channel_to_stable() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )

        XCTAssertEqual(generalController.availableUpdateChannels, [.stable, .beta])
        XCTAssertEqual(generalController.selectedUpdateChannel, .stable)
    }

    func test_general_section_persists_update_channel_to_config() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )

        generalController.setUpdateChannelForTesting(.beta)

        XCTAssertEqual(store.current.updates.channel, .beta)
        XCTAssertEqual(generalController.selectedUpdateChannel, .beta)
    }

    func test_general_section_confirms_error_reporting_change_before_persisting() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        var requestedValue: Bool?
        let controller = SettingsWindowController(
            configStore: store,
            errorReportingBundleConfigurationProvider: {
                ErrorReportingBundleConfiguration(
                    dsn: "https://public@example.com/1",
                    releaseName: "Zentty@1.0",
                    dist: "167"
                )
            },
            errorReportingConfirmationPresenter: { _, newValue, completion in
                requestedValue = newValue
                completion(.restartLater)
            },
            runtimeErrorReportingEnabled: true,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )

        generalController.setErrorReportingEnabledForTesting(false)

        XCTAssertEqual(requestedValue, false)
        XCTAssertFalse(store.current.errorReporting.enabled)
        XCTAssertFalse(generalController.isErrorReportingSwitchOn)
        XCTAssertEqual(generalController.errorReportingRestartMessage, "Restart Zentty to apply this change.")
    }

    func test_general_section_cancels_error_reporting_change_without_persisting() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            errorReportingBundleConfigurationProvider: {
                ErrorReportingBundleConfiguration(
                    dsn: "https://public@example.com/1",
                    releaseName: "Zentty@1.0",
                    dist: "167"
                )
            },
            errorReportingConfirmationPresenter: { _, _, completion in
                completion(.cancel)
            },
            runtimeErrorReportingEnabled: true,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )

        generalController.setErrorReportingEnabledForTesting(false)

        XCTAssertTrue(store.current.errorReporting.enabled)
        XCTAssertTrue(generalController.isErrorReportingSwitchOn)
        XCTAssertNil(generalController.errorReportingRestartMessage)
    }

    func test_general_section_disables_error_reporting_controls_when_dsn_is_unavailable() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            errorReportingBundleConfigurationProvider: { nil },
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )

        XCTAssertFalse(generalController.isErrorReportingControlEnabled)
        XCTAssertEqual(
            generalController.errorReportingStatusMessage,
            "Error reporting is unavailable in this build."
        )
    }

    func test_general_section_restart_now_persists_and_requests_restart() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        var restartRequested = false
        let controller = SettingsWindowController(
            configStore: store,
            errorReportingBundleConfigurationProvider: {
                ErrorReportingBundleConfiguration(
                    dsn: "https://public@example.com/1",
                    releaseName: "Zentty@1.0",
                    dist: "167"
                )
            },
            errorReportingConfirmationPresenter: { _, _, completion in
                completion(.restartNow)
            },
            errorReportingRestartHandler: {
                restartRequested = true
            },
            runtimeErrorReportingEnabled: true,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let generalController = try XCTUnwrap(
            contentController.currentSectionViewController as? GeneralSettingsSectionViewController
        )

        generalController.setErrorReportingEnabledForTesting(false)

        XCTAssertFalse(store.current.errorReporting.enabled)
        XCTAssertTrue(restartRequested)
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
