import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Zentty

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private var savedSoundsDirectoryOverride: URL?
    private var tempSoundsDir: URL?

    override func setUp() {
        super.setUp()
        // Notification-sound settings tests can trigger pruneCustomSounds, which scans the
        // sounds directory. Redirect it at a temp dir so it never touches the real
        // ~/Library/Sounds (and never deletes a developer's installed custom sound).
        savedSoundsDirectoryOverride = NotificationSoundManager.soundsDirectoryOverride
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.SettingsWindow.Sounds.\(UUID().uuidString)", isDirectory: true)
        tempSoundsDir = tempDir
        NotificationSoundManager.soundsDirectoryOverride = tempDir
    }

    override func tearDown() {
        NSApp.windows.forEach { window in
            window.orderOut(nil)
            window.close()
        }

        let settled = XCTestExpectation(description: "AppKit window teardown settled")
        DispatchQueue.main.async { settled.fulfill() }
        _ = XCTWaiter.wait(for: [settled], timeout: 1.0)

        NotificationSoundManager.soundsDirectoryOverride = savedSoundsDirectoryOverride
        if let tempSoundsDir {
            try? FileManager.default.removeItem(at: tempSoundsDir)
        }

        super.tearDown()
    }

    func test_settings_window_uses_sidebar_split_shell_and_shows_requested_panes_section() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .paneLayout, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        // SettingsViewController is itself the window's split-view controller
        // (required for the full-height sidebar), so assert on it directly.
        let splitController: NSSplitViewController = contentController
        XCTAssertEqual(splitController.splitViewItems.count, 2)
        XCTAssertFalse(splitController.splitViewItems.first?.canCollapse == true)
        XCTAssertTrue(splitController.splitViewItems.first?.allowsFullHeightLayout == true)

        let visibleContentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(controller.window?.styleMask.contains(.resizable) == true)
        XCTAssertEqual(
            contentController.sectionTitles,
            [
                "General", "Appearance", "Shortcuts", "Notifications", "Updates & Privacy",
                "Panes", "Open With", "Dev Servers", "Agents",
            ]
        )
        XCTAssertEqual(contentController.selectedSection, .paneLayout)
        XCTAssertEqual(controller.window?.title, "Panes")

        let paneLayoutController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )
        XCTAssertTrue(paneLayoutController.showsPaneLabelsForTesting)
        XCTAssertEqual(paneLayoutController.inactivePaneOpacityPercentageForTesting, 70)
        XCTAssertEqual(paneLayoutController.selectedRightSplitBehaviorModeForTesting, .adaptive)
        XCTAssertEqual(paneLayoutController.visibleSplitWindowWidthForTesting, .px1920)
    }

    func test_settings_window_uses_configured_test_screen() throws {
        guard let screenName = ProcessInfo.processInfo.environment["ZENTTY_TEST_SCREEN_NAME"] else {
            throw XCTSkip("ZENTTY_TEST_SCREEN_NAME is not set")
        }
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)
        waitForLayout()

        let window = try XCTUnwrap(controller.window)
        let localizedName = try XCTUnwrap(window.screen?.localizedName)
        XCTAssertTrue(HostedTestDisplay.screenName(localizedName, matches: screenName))
    }

    func test_panes_section_reads_persisted_controls_from_config() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.panes.showLabels = false
            config.panes.showProjectIcons = false
            config.panes.inactiveOpacity = 0.85
            config.paneLayout.rightSplitBehaviorMode = .alwaysSplit
            config.paneLayout.visibleSplitWindowWidth = .px1920
        }

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .paneLayout, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        XCTAssertEqual(contentController.selectedSection, .paneLayout)
        let panesController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )

        XCTAssertFalse(panesController.showsPaneLabelsForTesting)
        XCTAssertFalse(panesController.showsProjectIconsForTesting)
        XCTAssertEqual(panesController.inactivePaneOpacityPercentageForTesting, 85)
        XCTAssertEqual(panesController.selectedRightSplitBehaviorModeForTesting, .alwaysSplit)
        XCTAssertEqual(panesController.visibleSplitWindowWidthForTesting, .px1920)
    }

    func test_panes_section_describes_adaptive_split_threshold_slider_in_points() throws {
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

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let panesController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )

        XCTAssertNotNil(
            panesController.view.firstDescendantLabel(stringValue: "Adaptive split threshold:")
        )
        XCTAssertNotNil(
            panesController.view.firstDescendantLabel(
                stringValue: "Below this width, ⌘D adds a pane. At this width or wider, it splits right."
            )
        )
    }

    func test_panes_section_threshold_slider_updates_pane_layout_state_immediately() throws {
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

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let panesController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )
        let thresholdSlider = try XCTUnwrap(
            panesController.view.firstDescendant(where: { view in
                guard let slider = view as? NSSlider else { return false }
                return slider.numberOfTickMarks == PaneVisibleSplitWindowWidth.allCases.count
            }) as? NSSlider
        )

        thresholdSlider.integerValue = try XCTUnwrap(
            PaneVisibleSplitWindowWidth.allCases.firstIndex(of: .px1920)
        )
        XCTAssertTrue(
            NSApp.sendAction(try XCTUnwrap(thresholdSlider.action), to: thresholdSlider.target, from: thresholdSlider)
        )

        XCTAssertEqual(panesController.visibleSplitWindowWidthForTesting, .px1920)
        XCTAssertEqual(store.current.paneLayout.visibleSplitWindowWidth, .px1920)
    }

    func test_panes_section_right_behavior_options_keep_equal_heights() throws {
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

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let panesController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )
        panesController.view.layoutSubtreeIfNeeded()

        let optionViews = panesController.view.descendants(ofType: PaneSplitBehaviorOptionView.self)
        XCTAssertEqual(optionViews.count, PaneSplitBehaviorMode.allCases.count)

        let roundedHeights = Set(optionViews.map { Int($0.frame.height.rounded()) })
        XCTAssertEqual(roundedHeights.count, 1)
    }

    func test_panes_section_unselected_right_behavior_options_use_light_surface_in_aqua() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .paneLayout, sender: nil)
        controller.window?.appearance = NSAppearance(named: .aqua)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let panesController = try XCTUnwrap(
            contentController.currentSectionViewController as? PaneLayoutSettingsSectionViewController
        )
        panesController.view.layoutSubtreeIfNeeded()

        let unselectedOptionViews = panesController.view
            .descendants(ofType: PaneSplitBehaviorOptionView.self)
            .filter { $0.mode != .adaptive }
        XCTAssertEqual(unselectedOptionViews.count, PaneSplitBehaviorMode.allCases.count - 1)

        for optionView in unselectedOptionViews {
            let backgroundColor = try XCTUnwrap(optionView.layer?.backgroundColor)
            let color = try XCTUnwrap(NSColor(cgColor: backgroundColor)?.usingColorSpace(.sRGB))
            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3

            XCTAssertGreaterThanOrEqual(color.alphaComponent, 0.95)
            XCTAssertGreaterThan(brightness, 0.9)
        }
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
            "Show or hide the sidebar."
        )
        XCTAssertNil(shortcutsController.selectedCommandDefaultShortcutForTesting)
        XCTAssertEqual(shortcutsController.displayString(for: .toggleSidebar), "⌘B")
        XCTAssertEqual(shortcutsController.displayString(for: .copyFocusedPanePath), "Unassigned")
    }

    func test_settings_window_can_present_appearance_section_when_requested() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .shortcuts
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .appearance, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )

        XCTAssertEqual(contentController.selectedSection, .appearance)

        let visibleContentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSSearchField.self))
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(visibleContentView.containsDescendant(named: "ThemePreviewPanel"))
    }

    func test_settings_window_switch_from_general_to_appearance_shows_theme_browser_content() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .appearance, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.select(section: .appearance)
        waitForLayout("appearance selected from general", delay: 0.2)

        XCTAssertEqual(contentController.selectedSection, .appearance)

        let visibleContentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSSearchField.self))
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(visibleContentView.containsDescendant(named: "ThemePreviewPanel"))
    }

    func test_settings_window_show_section_can_open_appearance_content() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .appearance
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .appearance, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )

        XCTAssertEqual(contentController.selectedSection, .appearance)

        let visibleContentView = try XCTUnwrap(controller.window?.contentView)
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSSearchField.self))
        XCTAssertNotNil(visibleContentView.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(visibleContentView.containsDescendant(named: "ThemePreviewPanel"))
    }

    func test_settings_window_can_switch_to_agents_section_and_read_agent_team_setting() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.agentTeams.enabled = true
        }
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .agents, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )

        XCTAssertEqual(contentController.selectedSection, .agents)
        XCTAssertEqual(controller.window?.title, "Agents")
        XCTAssertEqual(SettingsSection.agents.symbolName, "cpu")

        let agentsController = try XCTUnwrap(
            contentController.currentSectionViewController as? AgentsSettingsSectionViewController
        )
        XCTAssertTrue(agentsController.isAgentTeamsSwitchOn)
        XCTAssertTrue(agentsController.isAgentCaffeinationSwitchOn)
        XCTAssertEqual(agentsController.experimentalBadgeText, "EXPERIMENTAL")
    }

    func test_agents_section_updates_agent_caffeination_preference() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .agents
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .agents, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let agentsController = try XCTUnwrap(
            contentController.currentSectionViewController as? AgentsSettingsSectionViewController
        )

        XCTAssertTrue(agentsController.isAgentCaffeinationSwitchOn)

        agentsController.setAgentCaffeinationEnabledForTesting(false)

        XCTAssertFalse(store.current.agentCaffeination.enabled)
        XCTAssertFalse(agentsController.isAgentCaffeinationSwitchOn)
    }

    func test_agents_section_experimental_badge_is_optically_aligned_with_title() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .agents
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .agents, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let agentsController = try XCTUnwrap(
            contentController.currentSectionViewController as? AgentsSettingsSectionViewController
        )
        let offset = try XCTUnwrap(agentsController.experimentalBadgeTitleCenterYOffset)

        XCTAssertEqual(offset, 1, accuracy: 0.5)
    }

    func test_agents_section_confirms_enabling_agent_teams_before_persisting() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        var warningWasPresented = false
        let controller = SettingsWindowController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in
                warningWasPresented = true
                completion(.enable)
            },
            initialSection: .agents
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .agents, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let agentsController = try XCTUnwrap(
            contentController.currentSectionViewController as? AgentsSettingsSectionViewController
        )

        agentsController.setAgentTeamsEnabledForTesting(true)

        XCTAssertTrue(warningWasPresented)
        XCTAssertTrue(store.current.agentTeams.enabled)
        XCTAssertTrue(agentsController.isAgentTeamsSwitchOn)
    }

    func test_agents_section_cancels_enabling_agent_teams_without_persisting() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            agentTeamsEnableWarningPresenter: { _, completion in
                completion(.cancel)
            },
            initialSection: .agents
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .agents, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        let agentsController = try XCTUnwrap(
            contentController.currentSectionViewController as? AgentsSettingsSectionViewController
        )

        agentsController.setAgentTeamsEnabledForTesting(true)

        XCTAssertFalse(store.current.agentTeams.enabled)
        XCTAssertFalse(agentsController.isAgentTeamsSwitchOn)
    }

    func test_settings_window_size_is_stable_across_section_switch() throws {
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

        controller.show(section: .shortcuts, sender: nil)
        waitForLayout("shortcuts settled", delay: 0.2)

        let shortcutsFrame = try XCTUnwrap(controller.window?.frame)

        XCTAssertEqual(shortcutsFrame.width, initialFrame.width, accuracy: 1.0)
        XCTAssertEqual(shortcutsFrame.height, initialFrame.height, accuracy: 1.0)
    }

    func test_settings_window_has_back_forward_navigation_control() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(configStore: store, initialSection: .general)
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)
        waitForLayout()

        let segmented = try XCTUnwrap(controller.navigationSegmentedControlForTesting)
        XCTAssertEqual(segmented.segmentCount, 2)

        let identifiers = controller.navigationToolbarItemIdentifiersForTesting.map(\.rawValue)
        XCTAssertTrue(identifiers.contains("be.zenjoy.Zentty.settings.backForward"))
        XCTAssertTrue(identifiers.contains("be.zenjoy.Zentty.settings.sidebarTrackingSeparator"))
    }

    func test_back_and_forward_replay_visited_sections() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(configStore: store, initialSection: .general)
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.select(section: .appearance)
        contentController.select(section: .shortcuts)
        waitForLayout()

        contentController.goBack()
        XCTAssertEqual(contentController.selectedSection, .appearance)
        contentController.goBack()
        XCTAssertEqual(contentController.selectedSection, .general)
        XCTAssertFalse(contentController.canGoBack)
        XCTAssertTrue(contentController.canGoForward)

        contentController.goForward()
        XCTAssertEqual(contentController.selectedSection, .appearance)

        // The detail content follows the replayed section.
        XCTAssertTrue(
            contentController.currentSectionViewController is AppearanceSettingsSectionViewController
        )
    }

    func test_back_key_equivalent_allows_caps_lock_but_not_shift() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(configStore: store, initialSection: .general)
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.select(section: .appearance)

        let shiftedBack = try XCTUnwrap(settingsNavigationKeyEvent("[", modifiers: [.command, .shift]))
        XCTAssertFalse(contentController.handlePerformKeyEquivalent(shiftedBack))
        XCTAssertEqual(contentController.selectedSection, .appearance)

        let capsLockBack = try XCTUnwrap(settingsNavigationKeyEvent("[", modifiers: [.command, .capsLock]))
        XCTAssertTrue(contentController.handlePerformKeyEquivalent(capsLockBack))
        XCTAssertEqual(contentController.selectedSection, .general)
    }

    func test_navigating_after_going_back_truncates_forward_history() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(configStore: store, initialSection: .general)
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)
        waitForLayout()

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.select(section: .appearance)
        contentController.select(section: .shortcuts)
        contentController.goBack() // back to appearance

        contentController.select(section: .notifications)

        XCTAssertEqual(contentController.selectedSection, .notifications)
        XCTAssertFalse(contentController.canGoForward)
        XCTAssertTrue(contentController.canGoBack)
    }

    func test_navigation_control_enabled_state_tracks_history_ends() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(configStore: store, initialSection: .general)
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .general, sender: nil)
        waitForLayout()

        let segmented = try XCTUnwrap(controller.navigationSegmentedControlForTesting)
        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )

        XCTAssertFalse(segmented.isEnabled(forSegment: 0))
        XCTAssertFalse(segmented.isEnabled(forSegment: 1))

        contentController.select(section: .appearance)
        XCTAssertTrue(segmented.isEnabled(forSegment: 0))
        XCTAssertFalse(segmented.isEnabled(forSegment: 1))

        contentController.goBack()
        XCTAssertFalse(segmented.isEnabled(forSegment: 0))
        XCTAssertTrue(segmented.isEnabled(forSegment: 1))
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
        XCTAssertFalse(
            try XCTUnwrap(shortcutsController.view.firstDescendant(ofType: NSTableView.self)).floatsGroupRows
        )
        XCTAssertTrue(shortcutsController.visibleCommandTitles.contains("Toggle Sidebar"))
        XCTAssertTrue(shortcutsController.visibleCommandTitles.contains("Reset Pane Layout"))
    }

    func test_shortcuts_pane_balances_horizontal_content_insets() throws {
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
        // Measure insets relative to the section's own pane (the detail split
        // item), not the window — the sidebar offsets window coordinates.
        let windowContentView: NSView = shortcutsController.view
        shortcutsController.selectCommandForTesting(.navigateBack)
        waitForLayout()

        let browserCardView = try XCTUnwrap(
            shortcutsController.view.firstDescendant(ofType: SettingsCardView.self)
        )
        let keyboardPreviewView = try XCTUnwrap(
            shortcutsController.view.firstDescendant(ofType: KeyboardShortcutPreviewView.self)
        )

        let contentFrame = shortcutsController.contentView.convert(
            shortcutsController.contentView.bounds,
            to: windowContentView
        )
        let browserFrame = browserCardView.convert(browserCardView.bounds, to: windowContentView)
        let selectedCommandTitle = try XCTUnwrap(shortcutsController.selectedCommandTitleForTesting)
        let detailTitleLabel = try XCTUnwrap(
            shortcutsController.view.firstDescendant { view in
                guard let label = view as? NSTextField, label.stringValue == selectedCommandTitle else {
                    return false
                }

                let labelFrame = label.convert(label.bounds, to: windowContentView)
                return labelFrame.minX > browserFrame.maxX
            } as? NSTextField
        )
        let detailTitleBounds = detailTitleLabel.cell?.drawingRect(forBounds: detailTitleLabel.bounds)
            ?? detailTitleLabel.bounds
        let detailTitleFrame = detailTitleLabel.convert(detailTitleBounds, to: windowContentView)
        let keyboardKeyBounds = try XCTUnwrap(keyboardPreviewView.primaryRowKeyBoundsForTesting)
        let keyboardKeyFrame = keyboardPreviewView.convert(keyboardKeyBounds, to: windowContentView)
        let leadingInset = contentFrame.minX
        let trailingInset = windowContentView.bounds.maxX - contentFrame.maxX
        let detailTitleGap = detailTitleFrame.minX - browserFrame.maxX
        let keyboardLeadingGap = keyboardKeyFrame.minX - browserFrame.maxX
        let keyboardTrailingGap = windowContentView.bounds.maxX - keyboardKeyFrame.maxX

        XCTAssertEqual(leadingInset, 28, accuracy: 1.0)
        XCTAssertEqual(leadingInset, trailingInset, accuracy: 1.0)
        XCTAssertEqual(detailTitleGap, 28, accuracy: 1.0)
        XCTAssertEqual(keyboardLeadingGap, 28, accuracy: 1.0)
        XCTAssertEqual(keyboardTrailingGap, 28, accuracy: 1.0)
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

    func test_settings_window_follows_system_appearance() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .general
        )
        addTeardownBlock { controller.window?.close() }

        controller.showWindowForHostedTesting(nil)
        waitForLayout()

        // Settings follows the macOS system light/dark, so it must not pin its
        // own appearance to the terminal theme.
        XCTAssertNil(controller.window?.appearance)
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

    func test_notifications_section_shows_sound_controls() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .paneLayout
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .notifications, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        XCTAssertEqual(contentController.selectedSection, .notifications)
        XCTAssertEqual(controller.window?.title, "Notifications")

        let notificationsController = try XCTUnwrap(
            contentController.currentSectionViewController as? NotificationsSettingsSectionViewController
        )
        XCTAssertEqual(notificationsController.selectedSoundName, "")
        XCTAssertTrue(notificationsController.availableSoundNames.contains(""))
        XCTAssertTrue(notificationsController.availableSoundNames.contains("Glass"))
        XCTAssertTrue(notificationsController.availableSoundNames.contains("Ping"))
    }

    func test_updates_privacy_section_shows_error_reporting_enabled_when_available() throws {
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

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        XCTAssertEqual(contentController.selectedSection, .updatesPrivacy)
        XCTAssertEqual(controller.window?.title, "Updates & Privacy")

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )
        XCTAssertTrue(updatesController.isErrorReportingSwitchOn)
        XCTAssertTrue(updatesController.isErrorReportingControlEnabled)
        XCTAssertTrue(updatesController.isErrorReportingAvailabilityHidden)
    }

    func test_notifications_section_persists_sound_name_to_config() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.notifications.soundName = "Glass"
        }

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .notifications
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .notifications, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let notificationsController = try XCTUnwrap(
            contentController.currentSectionViewController as? NotificationsSettingsSectionViewController
        )
        XCTAssertEqual(notificationsController.selectedSoundName, "Glass")
    }

    func test_notifications_section_shows_custom_sound_entry_without_display_name() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let customName = "zentty-custom-sample.caf"
        try store.update { config in
            config.notifications.soundName = customName
            config.notifications.customSoundDisplayName = nil
        }

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .notifications
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .notifications, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let notificationsController = try XCTUnwrap(
            contentController.currentSectionViewController as? NotificationsSettingsSectionViewController
        )
        XCTAssertEqual(notificationsController.selectedSoundName, customName)
        XCTAssertEqual(notificationsController.selectedSoundTitle, "Custom: Custom Sound")
        XCTAssertTrue(notificationsController.availableSoundNames.contains(customName))
    }

    func test_notifications_section_clearsCustomDisplayName_whenSwitchingToSystemSound() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.notifications.soundName = "zentty-custom-sample.caf"
            config.notifications.customSoundDisplayName = "Personal Chime.mp3"
        }

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .notifications
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .notifications, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let notificationsController = try XCTUnwrap(
            contentController.currentSectionViewController as? NotificationsSettingsSectionViewController
        )
        notificationsController.selectSoundForTesting("Glass")

        XCTAssertEqual(store.current.notifications.soundName, "Glass")
        XCTAssertNil(store.current.notifications.customSoundDisplayName)
        // Regression: the custom file is pruned on switch, so its stale "Custom: …" popup
        // entry must be rebuilt away — otherwise reselecting it points at a deleted file.
        XCTAssertFalse(notificationsController.availableSoundNames.contains("zentty-custom-sample.caf"))
        XCTAssertEqual(notificationsController.selectedSoundName, "Glass")
    }

    func test_notifications_section_caps_custom_sound_popup_width_for_long_display_name() throws {
        let longName = String(repeating: "VeryLongCustomNotificationSoundName", count: 8) + ".aiff"
        let customName = "zentty-custom-sample.caf"
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        try store.update { config in
            config.notifications.soundName = customName
            config.notifications.customSoundDisplayName = longName
        }

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .notifications
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .notifications, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let notificationsController = try XCTUnwrap(
            contentController.currentSectionViewController as? NotificationsSettingsSectionViewController
        )
        XCTAssertEqual(notificationsController.selectedSoundName, customName)
        XCTAssertLessThanOrEqual(notificationsController.soundPopupWidthForTesting, 260)
        XCTAssertEqual(notificationsController.selectedSoundTooltip, "Custom: \(longName)")
    }

    func test_updates_privacy_section_defaults_update_channel_to_stable() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .updatesPrivacy
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )

        XCTAssertEqual(updatesController.availableUpdateChannels, [.stable, .beta])
        XCTAssertEqual(updatesController.selectedUpdateChannel, .stable)
    }

    func test_updates_privacy_section_persists_update_channel_to_config() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )

        let controller = SettingsWindowController(
            configStore: store,
            initialSection: .updatesPrivacy
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )

        updatesController.setUpdateChannelForTesting(.beta)

        XCTAssertEqual(store.current.updates.channel, .beta)
        XCTAssertEqual(updatesController.selectedUpdateChannel, .beta)
    }

    func test_general_section_persists_restore_workspace_preference_to_config() throws {
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

        XCTAssertTrue(generalController.isRestoreWorkspaceSwitchOn)

        generalController.setRestoreWorkspaceEnabledForTesting(false)

        XCTAssertFalse(store.current.restore.restoreWorkspaceOnLaunch)
        XCTAssertFalse(generalController.isRestoreWorkspaceSwitchOn)
    }

    func test_updates_privacy_section_confirms_error_reporting_change_before_persisting() throws {
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
            initialSection: .updatesPrivacy
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )

        updatesController.setErrorReportingEnabledForTesting(false)

        XCTAssertEqual(requestedValue, false)
        XCTAssertFalse(store.current.errorReporting.enabled)
        XCTAssertFalse(updatesController.isErrorReportingSwitchOn)
        XCTAssertEqual(updatesController.errorReportingRestartMessage, "Restart Zentty to apply this change.")
    }

    func test_updates_privacy_section_cancels_error_reporting_change_without_persisting() throws {
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
            initialSection: .updatesPrivacy
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )

        updatesController.setErrorReportingEnabledForTesting(false)

        XCTAssertTrue(store.current.errorReporting.enabled)
        XCTAssertTrue(updatesController.isErrorReportingSwitchOn)
        XCTAssertNil(updatesController.errorReportingRestartMessage)
    }

    func test_updates_privacy_section_disables_error_reporting_controls_when_dsn_is_unavailable() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let controller = SettingsWindowController(
            configStore: store,
            errorReportingBundleConfigurationProvider: { nil },
            initialSection: .updatesPrivacy
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )

        XCTAssertFalse(updatesController.isErrorReportingControlEnabled)
        XCTAssertFalse(updatesController.isErrorReportingAvailabilityHidden)
        XCTAssertEqual(updatesController.errorReportingAvailabilityText, "Unavailable")
        XCTAssertEqual(
            updatesController.errorReportingStatusMessage,
            "Error reporting is unavailable in this build."
        )
    }

    func test_updates_privacy_section_restart_now_persists_and_requests_restart() throws {
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
            initialSection: .updatesPrivacy
        )
        addTeardownBlock { controller.window?.close() }

        controller.show(section: .updatesPrivacy, sender: nil)

        let contentController = try XCTUnwrap(
            controller.window?.contentViewController as? SettingsViewController
        )
        contentController.loadViewIfNeeded()
        waitForLayout()

        let updatesController = try XCTUnwrap(
            contentController.currentSectionViewController as? UpdatesPrivacySettingsSectionViewController
        )

        updatesController.setErrorReportingEnabledForTesting(false)

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

    func test_open_with_section_refreshes_document_height_after_rebuilding_many_target_rows() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.SettingsWindow")
        )
        let builtInTargets = Array(OpenWithCatalog.macOSBuiltInTargets.prefix(5))
        try store.update { config in
            config.openWith.primaryTargetID = builtInTargets[0].id.rawValue
            config.openWith.enabledTargetIDs = builtInTargets.map(\.id.rawValue)
        }

        let controller = OpenWithSettingsSectionViewController(
            configStore: store,
            openWithService: StubOpenWithService(
                detectedTargets: builtInTargets.map { target in
                    OpenWithDetectedTarget(
                        target: OpenWithResolvedTarget(
                            stableID: target.id.rawValue,
                            kind: target.kind,
                            displayName: target.displayName,
                            builtInID: target.id,
                            appPath: nil
                        ),
                        isAvailable: true
                    )
                }
            ),
            customAppPicker: { nil }
        )
        controller.loadViewIfNeeded()

        controller.apply(preferences: store.current.openWith)

        let documentView = try XCTUnwrap(controller.scrollView.documentView)
        let expectedMinimumHeight = controller.contentView.fittingSize.height + 50

        XCTAssertGreaterThanOrEqual(documentView.frame.height, expectedMinimumHeight)
    }
}

@MainActor
private extension SettingsWindowControllerTests {
    func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }

    func settingsNavigationKeyEvent(
        _ character: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: character == "[" ? 33 : 30
        )
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.descendants(ofType: type)
            if let match = subview as? T {
                matches.insert(match, at: 0)
            }
            return matches
        }
    }

    func firstDescendant(where predicate: (NSView) -> Bool) -> NSView? {
        for subview in subviews {
            if predicate(subview) {
                return subview
            }
            if let match = subview.firstDescendant(where: predicate) {
                return match
            }
        }

        return nil
    }

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

    func firstDescendantLabel(stringValue: String) -> NSTextField? {
        if let label = self as? NSTextField, label.stringValue == stringValue {
            return label
        }

        for subview in subviews {
            if let label = subview.firstDescendantLabel(stringValue: stringValue) {
                return label
            }
        }

        return nil
    }

    func containsDescendant(named className: String) -> Bool {
        subviews.contains { subview in
            String(describing: type(of: subview)) == className || subview.containsDescendant(named: className)
        }
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
