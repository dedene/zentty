import XCTest
@testable import Zentty

@MainActor
final class MainWindowControllerTests: XCTestCase {
    private var controller: MainWindowController?
    private var testDefaultsSuiteNames: [String] = []

    private enum TrafficLightOverlayIdentifier {
        static let close = "trafficLightOverlay.close"
        static let mini = "trafficLightOverlay.mini"
        static let zoom = "trafficLightOverlay.zoom"
    }

    private func trafficLightSpacing(for closeButton: NSButton, miniButton: NSButton) -> CGFloat {
        miniButton.frame.minX - closeButton.frame.maxX
    }

    private func trafficLightTopInset(for closeButton: NSButton) throws -> CGFloat {
        let buttonSuperview = try XCTUnwrap(closeButton.superview)
        return buttonSuperview.bounds.maxY - closeButton.frame.maxY
    }

    private func assertTrafficLightsMatchChromeGeometry(
        closeButton: NSButton,
        miniButton: NSButton,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            closeButton.frame.minX,
            ChromeGeometry.trafficLightLeadingInset,
            accuracy: 1.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try trafficLightTopInset(for: closeButton),
            ChromeGeometry.trafficLightTopInset,
            accuracy: 1.0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            trafficLightSpacing(for: closeButton, miniButton: miniButton),
            ChromeGeometry.trafficLightSpacing,
            accuracy: 1.0,
            file: file,
            line: line
        )
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        testDefaultsSuiteNames.forEach {
            UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0)
        }
        testDefaultsSuiteNames.removeAll()
        super.tearDown()
    }

    private func makeController() -> MainWindowController {
        makeController(sidebarVisibilityMode: .pinnedOpen)
    }

    private func makeController(sidebarVisibilityMode: SidebarVisibilityMode) -> MainWindowController {
        let suiteName = "ZenttyTests.MainWindowControllerTests.\(UUID().uuidString)"
        let sidebarVisibilityDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        testDefaultsSuiteNames.append(suiteName)
        SidebarVisibilityPreference.persist(sidebarVisibilityMode, in: sidebarVisibilityDefaults)

        let c = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            sidebarVisibilityDefaults: sidebarVisibilityDefaults
        )
        controller = c
        return c
    }

    private func makeController(adapterStore: MetadataAdapterStore) -> MainWindowController {
        let c = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { paneID in
                let adapter = MetadataEmittingTerminalAdapter()
                adapterStore.adapters[paneID] = adapter
                return adapter
            })
        )
        controller = c
        return c
    }

    private func makeController(
        configStore: AppConfigStore,
        openWithService: OpenWithServing,
        adapterStore: MetadataAdapterStore
    ) -> MainWindowController {
        let c = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { paneID in
                let adapter = MetadataEmittingTerminalAdapter()
                adapterStore.adapters[paneID] = adapter
                return adapter
            }),
            configStore: configStore,
            openWithService: openWithService
        )
        controller = c
        return c
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }

    private func readableWidth(for appCanvasView: AppCanvasView) -> CGFloat {
        PaneLayoutSizing.edgeAligned.readableWidth(
            for: appCanvasView.bounds.width,
            leadingVisibleInset: appCanvasView.leadingVisibleInset
        )
    }

    private func makeRequestOnlyWorklane(
        workingDirectory: String?,
        worklaneID: WorklaneID = WorklaneID("worklane-main"),
        worklaneTitle: String = "MAIN",
        title: String = "shell"
    ) -> WorklaneState {
        let paneID = PaneID("\(worklaneID.rawValue)-shell")
        let pane = PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                surfaceContext: .window
            ),
            width: 720
        )

        return WorklaneState(
            id: worklaneID,
            title: worklaneTitle,
            paneStripState: PaneStripState(
                panes: [pane],
                focusedPaneID: paneID
            )
        )
    }

    private func makeMetadataOnlyInheritedWorklane(
        workingDirectory: String?,
        worklaneID: WorklaneID = WorklaneID("worklane-main"),
        worklaneTitle: String = "MAIN",
        title: String = "ssh"
    ) -> WorklaneState {
        let paneID = PaneID("\(worklaneID.rawValue)-shell")
        let pane = PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                inheritFromPaneID: PaneID("source-pane"),
                surfaceContext: .window
            ),
            width: 720
        )

        return WorklaneState(
            id: worklaneID,
            title: worklaneTitle,
            paneStripState: PaneStripState(
                panes: [pane],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    metadata: TerminalMetadata(
                        title: title,
                        currentWorkingDirectory: workingDirectory,
                        processName: title,
                        gitBranch: nil
                    )
                )
            ]
        )
    }

    func test_main_window_starts_with_expected_content_size() {
        let controller = makeController()
        controller.showWindow(nil)
        let settled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)

        let windowFrame = controller.window.frame
        let visibleFrame = controller.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        XCTAssertNil(controller.window.contentViewController)
        XCTAssertNotNil(controller.window.contentView)
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertNotNil(visibleFrame)
        XCTAssertLessThan(windowFrame.width, visibleFrame?.width ?? 0)
        XCTAssertLessThan(windowFrame.height, visibleFrame?.height ?? 0)
    }

    func test_main_window_keeps_resizable_style() {
        let controller = makeController()

        XCTAssertTrue(controller.window.styleMask.contains(.resizable))
    }

    func test_show_window_does_not_reset_manual_frame_changes() {
        let controller = makeController()
        controller.showWindow(nil)
        let showSettled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showSettled.fulfill() }
        wait(for: [showSettled], timeout: 2.0)

        let window = controller.window

        let manualFrame = NSRect(x: 120, y: 140, width: 1180, height: 760)
        window.setFrame(manualFrame, display: false)
        let frameSettled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { frameSettled.fulfill() }
        wait(for: [frameSettled], timeout: 2.0)

        XCTAssertEqual(window.frame.integral, manualFrame.integral)

        controller.showWindow(nil)
        let reshowSettled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { reshowSettled.fulfill() }
        wait(for: [reshowSettled], timeout: 2.0)

        XCTAssertEqual(window.frame.integral, manualFrame.integral)
    }

    func test_show_window_repositions_traffic_lights_with_comfortable_inset() throws {
        let controller = makeController()
        controller.showWindow(nil)
        let settled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let miniButton = try XCTUnwrap(controller.window.standardWindowButton(.miniaturizeButton))
        let buttonSuperview = try XCTUnwrap(closeButton.superview)
        let topInset = buttonSuperview.bounds.maxY - closeButton.frame.maxY

        XCTAssertEqual(closeButton.frame.minX, ChromeGeometry.trafficLightLeadingInset, accuracy: 1.0)
        XCTAssertEqual(topInset, ChromeGeometry.trafficLightTopInset, accuracy: 1.0)
        XCTAssertEqual(
            miniButton.frame.minX - closeButton.frame.maxX,
            ChromeGeometry.trafficLightSpacing,
            accuracy: 1.0
        )
    }

    func test_surface_closed_on_last_pane_closes_only_this_window() throws {
        let controller = makeController()
        controller.showWindow(nil)
        waitForLayout()

        let paneID = PaneID("worklane-main-shell")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.hasCommandHistory = true
        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                auxiliaryStateByPaneID: [paneID: auxiliaryState]
            )
        ], activeWorklaneID: WorklaneID("worklane-main"))
        waitForLayout("worklane replaced", delay: 0.05)

        controller.rootViewControllerForTesting.handleTerminalEventForTesting(
            paneID: paneID,
            event: .surfaceClosed
        )
        waitForLayout("window closed", delay: 0.05)

        XCTAssertFalse(controller.window.isVisible)
    }

    func test_close_focused_pane_closes_window_without_followup_window_confirmation() throws {
        let configStore = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController.CloseFocusedPane")
        )
        try configStore.update { config in
            config.confirmations.confirmBeforeClosingPane = false
            config.confirmations.confirmBeforeClosingWindow = true
            config.confirmations.confirmBeforeQuitting = true
        }

        let openWithService = RecordingOpenWithService(availableTargets: [], primaryTarget: nil)
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: configStore,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let paneID = PaneID("worklane-main-shell")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.hasCommandHistory = true
        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                auxiliaryStateByPaneID: [paneID: auxiliaryState]
            )
        ], activeWorklaneID: WorklaneID("worklane-main"))
        waitForLayout("worklane replaced", delay: 0.05)

        controller.rootViewControllerForTesting.handle(.pane(.closeFocusedPane))
        waitForLayout("window closed", delay: 0.05)

        XCTAssertFalse(controller.window.isVisible)
    }

    func test_show_settings_window_opens_settings_shell_on_general() throws {
        let controller = makeController()

        controller.showSettingsWindow(nil)

        let settingsWindow = try XCTUnwrap(controller.settingsWindow)
        let settingsViewController = try XCTUnwrap(
            settingsWindow.contentViewController as? SettingsViewController
        )
        settingsViewController.loadViewIfNeeded()

        XCTAssertEqual(settingsViewController.selectedSection, .general)
        XCTAssertEqual(settingsViewController.contentSectionTitle, "General")
    }

    func test_root_settings_callback_opens_settings_shell_on_general() throws {
        let controller = makeController()

        controller.rootViewControllerForTesting.onShowSettingsRequested?()

        let settingsWindow = try XCTUnwrap(controller.settingsWindow)
        let settingsViewController = try XCTUnwrap(
            settingsWindow.contentViewController as? SettingsViewController
        )
        settingsViewController.loadViewIfNeeded()

        XCTAssertEqual(settingsViewController.selectedSection, .general)
        XCTAssertEqual(settingsViewController.contentSectionTitle, "General")
    }

    func test_show_settings_window_can_route_existing_window_to_open_with() throws {
        let controller = makeController()

        controller.showSettingsWindow(nil)
        let firstSettingsWindow = try XCTUnwrap(controller.settingsWindow)

        controller.showSettingsWindow(section: .openWith, sender: nil)

        let routedSettingsWindow = try XCTUnwrap(controller.settingsWindow)
        let settingsViewController = try XCTUnwrap(
            routedSettingsWindow.contentViewController as? SettingsViewController
        )
        settingsViewController.loadViewIfNeeded()

        XCTAssertTrue(firstSettingsWindow === routedSettingsWindow)
        XCTAssertEqual(settingsViewController.selectedSection, .openWith)
        XCTAssertEqual(settingsViewController.contentSectionTitle, "Open With")
    }

    func test_show_settings_window_matches_terminal_appearance() throws {
        let controller = makeController()

        controller.showSettingsWindow(nil)
        waitForLayout()

        let settingsWindow = try XCTUnwrap(controller.settingsWindow)
        let expectedAppearance = try XCTUnwrap(controller.terminalAppearance)

        XCTAssertEqual(
            settingsWindow.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            expectedAppearance.bestMatch(from: [.darkAqua, .aqua])
        )
    }

    func test_window_resign_key_shows_non_black_inactive_traffic_light_overlay_when_sidebar_is_pinned_open() throws {
        let controller = makeController(sidebarVisibilityMode: .pinnedOpen)
        controller.showWindow(nil)
        waitForLayout()

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        waitForLayout("inactive traffic lights settled", delay: 0.05)

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let overlay = try XCTUnwrap(
            closeButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.close)
        )
        let backgroundColor = try XCTUnwrap(
            overlay.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )

        XCTAssertFalse(overlay.isHidden)
        XCTAssertGreaterThan(backgroundColor.alphaComponent, 0, "overlay background should not be transparent")
    }

    func test_application_resign_active_shows_non_black_inactive_traffic_light_overlay() throws {
        let controller = makeController(sidebarVisibilityMode: .hidden)
        controller.showWindow(nil)
        waitForLayout()

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let overlay = try XCTUnwrap(
            closeButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.close)
        )
        overlay.isHidden = true

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        waitForLayout("app resign active settled", delay: 0.05)

        let backgroundColor = try XCTUnwrap(
            overlay.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )

        XCTAssertFalse(overlay.isHidden)
        XCTAssertGreaterThan(backgroundColor.alphaComponent, 0, "overlay background should not be transparent")
    }

    func test_window_become_key_hides_inactive_traffic_light_overlay() throws {
        let controller = makeController(sidebarVisibilityMode: .pinnedOpen)
        controller.showWindow(nil)
        waitForLayout()

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        waitForLayout("inactive traffic lights settled", delay: 0.05)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        waitForLayout("active traffic lights settled", delay: 0.05)

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let overlay = try XCTUnwrap(
            closeButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.close)
        )

        XCTAssertTrue(overlay.isHidden)
    }

    func test_window_become_key_does_not_relayout_traffic_lights() throws {
        let controller = makeController(sidebarVisibilityMode: .pinnedOpen)
        controller.showWindow(nil)
        waitForLayout()

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let miniButton = try XCTUnwrap(controller.window.standardWindowButton(.miniaturizeButton))
        try assertTrafficLightsMatchChromeGeometry(closeButton: closeButton, miniButton: miniButton)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        waitForLayout("inactive traffic lights settled", delay: 0.05)
        try assertTrafficLightsMatchChromeGeometry(closeButton: closeButton, miniButton: miniButton)

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        waitForLayout("active traffic lights settled", delay: 0.05)

        try assertTrafficLightsMatchChromeGeometry(closeButton: closeButton, miniButton: miniButton)
    }

    func test_application_activation_does_not_relayout_traffic_lights() throws {
        let controller = makeController(sidebarVisibilityMode: .pinnedOpen)
        controller.showWindow(nil)
        waitForLayout()

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let miniButton = try XCTUnwrap(controller.window.standardWindowButton(.miniaturizeButton))
        try assertTrafficLightsMatchChromeGeometry(closeButton: closeButton, miniButton: miniButton)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        waitForLayout("application resign active settled", delay: 0.05)
        try assertTrafficLightsMatchChromeGeometry(closeButton: closeButton, miniButton: miniButton)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        waitForLayout("application become active settled", delay: 0.05)

        try assertTrafficLightsMatchChromeGeometry(closeButton: closeButton, miniButton: miniButton)
    }

    func test_inactive_traffic_light_overlay_tracks_standard_button_frames_after_resize() throws {
        let controller = makeController(sidebarVisibilityMode: .pinnedOpen)
        controller.showWindow(nil)
        waitForLayout()

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        waitForLayout("inactive traffic lights settled", delay: 0.05)

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let miniButton = try XCTUnwrap(controller.window.standardWindowButton(.miniaturizeButton))
        let closeOverlay = try XCTUnwrap(
            closeButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.close)
        )
        let miniOverlay = try XCTUnwrap(
            closeButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.mini)
        )

        XCTAssertEqual(closeOverlay.frame.integral, closeButton.frame.integral)
        XCTAssertEqual(miniOverlay.frame.integral, miniButton.frame.integral)

        let resizedFrame = NSRect(x: 120, y: 140, width: 1420, height: 880)
        controller.window.setFrame(resizedFrame, display: false)
        waitForLayout("resize settled", delay: 0.1)

        let resizedCloseButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let resizedMiniButton = try XCTUnwrap(controller.window.standardWindowButton(.miniaturizeButton))
        let resizedCloseOverlay = try XCTUnwrap(
            resizedCloseButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.close)
        )
        let resizedMiniOverlay = try XCTUnwrap(
            resizedCloseButton.superview?.descendant(withIdentifier: TrafficLightOverlayIdentifier.mini)
        )

        XCTAssertEqual(resizedCloseOverlay.frame.integral, resizedCloseButton.frame.integral)
        XCTAssertEqual(resizedMiniOverlay.frame.integral, resizedMiniButton.frame.integral)
    }

    func test_inactive_traffic_light_overlay_does_not_block_native_button_hit_testing() throws {
        let controller = makeController(sidebarVisibilityMode: .pinnedOpen)
        controller.showWindow(nil)
        waitForLayout()

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        waitForLayout("inactive traffic lights settled", delay: 0.05)

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let buttonSuperview = try XCTUnwrap(closeButton.superview)
        let overlay = try XCTUnwrap(
            buttonSuperview.descendant(withIdentifier: TrafficLightOverlayIdentifier.close)
        )
        let point = NSPoint(x: closeButton.frame.midX, y: closeButton.frame.midY)
        let hitView = buttonSuperview.hitTest(point)

        XCTAssertNotNil(hitView)
        XCTAssertFalse(hitView?.isDescendant(of: overlay) ?? false)
    }

    func test_programmatic_window_resize_relayouts_panes_without_inner_animation() throws {
        let controller = makeController()
        controller.showWindow(nil)
        let showSettled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showSettled.fulfill() }
        wait(for: [showSettled], timeout: 2.0)

        controller.splitRight(nil)
        let splitSettled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { splitSettled.fulfill() }
        wait(for: [splitSettled], timeout: 2.0)

        let initialAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let initialReadableWidth = readableWidth(for: initialAppCanvasView)
        let initialPaneViews = initialAppCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let initialWidths = initialPaneViews.map(\.frame.width)

        let resizedFrame = NSRect(x: 120, y: 140, width: 1420, height: 880)
        controller.window.setFrame(resizedFrame, display: false)
        let resizeSettled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { resizeSettled.fulfill() }
        wait(for: [resizeSettled], timeout: 2.0)

        let resizedAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let resizedPaneViews = resizedAppCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let resizedWidths = resizedPaneViews.map(\.frame.width)
        let expectedScaleFactor = readableWidth(for: resizedAppCanvasView) / initialReadableWidth
        let expectedTotalWidth = initialWidths.reduce(0, +) * expectedScaleFactor
        let paneWidthTolerance: CGFloat = 1.0

        XCTAssertEqual(initialWidths.count, 2)
        XCTAssertEqual(resizedWidths.count, 2)
        guard
            let initialLeftWidth = initialWidths.first,
            let initialRightWidth = initialWidths.dropFirst().first,
            let resizedLeftWidth = resizedWidths.first,
            let resizedRightWidth = resizedWidths.dropFirst().first
        else {
            XCTFail("Expected exactly two pane widths before and after resize")
            return
        }
        XCTAssertEqual(resizedLeftWidth, initialLeftWidth * expectedScaleFactor, accuracy: paneWidthTolerance)
        XCTAssertEqual(resizedRightWidth, initialRightWidth * expectedScaleFactor, accuracy: paneWidthTolerance)
        XCTAssertEqual(resizedWidths.reduce(0, +), expectedTotalWidth, accuracy: paneWidthTolerance)
        XCTAssertFalse(resizedAppCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_programmatic_window_resize_relayouts_stacked_panes_to_new_width_without_inner_animation() throws {
        let controller = makeController()
        controller.showWindow(nil)
        waitForLayout()

        controller.splitVertically(nil)
        waitForLayout("vertical split settled", delay: 0.05)

        let initialAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let initialReadableWidth = readableWidth(for: initialAppCanvasView)
        let initialPaneViews = initialAppCanvasView.descendantPaneViews().sorted { $0.frame.minY > $1.frame.minY }
        let initialWidths = initialPaneViews.map(\.frame.width)
        let initialHeights = initialPaneViews.map(\.frame.height)

        let resizedFrame = NSRect(x: 120, y: 140, width: 1420, height: 880)
        controller.window.setFrame(resizedFrame, display: false)
        waitForLayout("stack resize settled", delay: 0.1)

        let resizedAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let resizedReadableWidth = readableWidth(for: resizedAppCanvasView)
        let resizedPaneViews = resizedAppCanvasView.descendantPaneViews().sorted { $0.frame.minY > $1.frame.minY }
        let resizedWidths = resizedPaneViews.map(\.frame.width)
        let resizedHeights = resizedPaneViews.map(\.frame.height)
        let expectedWidthScaleFactor = resizedReadableWidth / initialReadableWidth

        XCTAssertEqual(initialWidths.count, 2)
        XCTAssertEqual(resizedWidths.count, 2)
        XCTAssertEqual(resizedWidths[0], initialWidths[0] * expectedWidthScaleFactor, accuracy: 1.0)
        XCTAssertEqual(resizedWidths[1], initialWidths[1] * expectedWidthScaleFactor, accuracy: 1.0)
        XCTAssertGreaterThan(abs(resizedWidths[0] - initialWidths[0]), 10)
        XCTAssertGreaterThan(abs(resizedWidths[1] - initialWidths[1]), 10)
        XCTAssertGreaterThan(abs(resizedHeights[0] - initialHeights[0]), 10)
        XCTAssertGreaterThan(abs(resizedHeights[1] - initialHeights[1]), 10)
        XCTAssertEqual(resizedWidths[0], resizedWidths[1], accuracy: 1.0)
        XCTAssertFalse(resizedAppCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_programmatic_window_resize_relayouts_mixed_split_widths_and_heights_without_inner_animation() throws {
        let controller = makeController()
        controller.showWindow(nil)
        waitForLayout()

        controller.splitRight(nil)
        waitForLayout("horizontal split settled", delay: 0.05)
        controller.splitVertically(nil)
        waitForLayout("mixed split settled", delay: 0.05)

        let initialAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let initialReadableWidth = readableWidth(for: initialAppCanvasView)
        let initialFramesByTitle = Dictionary(uniqueKeysWithValues: try initialAppCanvasView.descendantPaneViews().map {
            (try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText), $0.frame)
        })

        let resizedFrame = NSRect(x: 120, y: 140, width: 1420, height: 880)
        controller.window.setFrame(resizedFrame, display: false)
        waitForLayout("mixed resize settled", delay: 0.1)

        let resizedAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let resizedReadableWidth = readableWidth(for: resizedAppCanvasView)
        let resizedFramesByTitle = Dictionary(uniqueKeysWithValues: try resizedAppCanvasView.descendantPaneViews().map {
            (try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText), $0.frame)
        })
        let expectedScaleFactor = resizedReadableWidth / initialReadableWidth

        let initialShellFrame = try XCTUnwrap(initialFramesByTitle["shell"])
        let initialPane1Frame = try XCTUnwrap(initialFramesByTitle["pane 1"])
        let initialPane2Frame = try XCTUnwrap(initialFramesByTitle["pane 2"])
        let resizedShellFrame = try XCTUnwrap(resizedFramesByTitle["shell"])
        let resizedPane1Frame = try XCTUnwrap(resizedFramesByTitle["pane 1"])
        let resizedPane2Frame = try XCTUnwrap(resizedFramesByTitle["pane 2"])

        XCTAssertEqual(resizedShellFrame.width, initialShellFrame.width * expectedScaleFactor, accuracy: 1.0)
        XCTAssertEqual(resizedPane1Frame.width, initialPane1Frame.width * expectedScaleFactor, accuracy: 1.0)
        XCTAssertEqual(resizedPane2Frame.width, initialPane2Frame.width * expectedScaleFactor, accuracy: 1.0)
        XCTAssertGreaterThan(abs(resizedShellFrame.height - initialShellFrame.height), 20)
        XCTAssertGreaterThan(abs(resizedPane1Frame.height - initialPane1Frame.height), 20)
        XCTAssertGreaterThan(abs(resizedPane2Frame.height - initialPane2Frame.height), 20)
        XCTAssertFalse(resizedAppCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_new_worklane_action_creates_and_focuses_new_worklane() {
        let controller = makeController()

        controller.newWorklane(nil)

        XCTAssertEqual(controller.worklaneTitles, ["MAIN", "WS 1"])
        XCTAssertEqual(controller.activeWorklaneTitle, "WS 1")
        XCTAssertEqual(controller.activePaneTitles, ["shell"])
    }

    func test_new_worklane_uses_reported_working_directory_of_focused_pane() throws {
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(adapterStore: adapterStore)
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-a")

        controller.newWorklane(nil)
        waitForLayout("worklane settled", delay: 0.05)

        XCTAssertEqual(controller.activeWorklaneTitle, "WS 1")
        let activePane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let activeAdapter = try XCTUnwrap(adapterStore.adapters[activePane.paneID])
        XCTAssertEqual(activeAdapter.lastRequest?.workingDirectory, "/tmp/project-a")
    }

    func test_split_uses_reported_working_directory_of_focused_pane() throws {
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(adapterStore: adapterStore)
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-b")

        controller.splitRight(nil)
        waitForLayout("split settled", delay: 0.05)

        let paneViews = controller.window.contentView?
            .descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(paneViews?.count, 2)
        let insertedPane = try XCTUnwrap(paneViews?.last)
        let insertedAdapter = try XCTUnwrap(adapterStore.adapters[insertedPane.paneID])
        XCTAssertEqual(insertedAdapter.lastRequest?.workingDirectory, "/tmp/project-b")
    }

    func test_new_worklane_uses_reported_working_directory_of_last_focused_pane() throws {
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(adapterStore: adapterStore)
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-left")

        controller.splitRight(nil)
        waitForLayout("first split settled", delay: 0.05)

        let paneViews = try XCTUnwrap(controller.window.contentView?
            .descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX })
        XCTAssertEqual(paneViews.count, 2)

        let rightPane = try XCTUnwrap(paneViews.dropFirst().first)
        let rightAdapter = try XCTUnwrap(adapterStore.adapters[rightPane.paneID])
        rightAdapter.emitWorkingDirectory("/tmp/project-right")
        rightPane.focusTerminal()
        waitForLayout("focus settled", delay: 0.05)

        controller.newWorklane(nil)
        waitForLayout("worklane settled", delay: 0.05)

        XCTAssertEqual(controller.activeWorklaneTitle, "WS 1")
        let activePane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let activeAdapter = try XCTUnwrap(adapterStore.adapters[activePane.paneID])
        XCTAssertEqual(activeAdapter.lastRequest?.workingDirectory, "/tmp/project-right")
    }

    func test_split_uses_reported_working_directory_of_last_focused_pane() throws {
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(adapterStore: adapterStore)
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-left")

        controller.splitRight(nil)
        waitForLayout("first split settled", delay: 0.05)

        let paneViews = try XCTUnwrap(controller.window.contentView?
            .descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX })
        XCTAssertEqual(paneViews.count, 2)

        let rightPane = try XCTUnwrap(paneViews.dropFirst().first)
        let rightAdapter = try XCTUnwrap(adapterStore.adapters[rightPane.paneID])
        rightAdapter.emitWorkingDirectory("/tmp/project-right")
        rightPane.focusTerminal()
        waitForLayout("focus settled", delay: 0.05)

        controller.splitRight(nil)
        waitForLayout("second split settled", delay: 0.05)

        let updatedPaneViews = controller.window.contentView?
            .descendantPaneViews()
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(updatedPaneViews?.count, 3)
        let newestPane = try XCTUnwrap(updatedPaneViews?.last)
        let newestAdapter = try XCTUnwrap(adapterStore.adapters[newestPane.paneID])
        XCTAssertEqual(newestAdapter.lastRequest?.workingDirectory, "/tmp/project-right")
    }

    func test_split_and_focus_actions_route_through_root_dispatcher() {
        let controller = makeController()

        controller.splitRight(nil)
        controller.focusLeftPane(nil)

        XCTAssertEqual(controller.activePaneTitles, ["shell", "pane 1"])
        XCTAssertEqual(controller.focusedPaneTitle, "shell")
    }

    func test_open_with_primary_action_uses_focused_pane_working_directory() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor", "finder"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            ),
            iconsByStableID: [
                "cursor": NSImage(size: NSSize(width: 16, height: 16)),
                "finder": NSImage(size: NSSize(width: 16, height: 16))
            ]
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-open-with")
        controller.injectFocusedPaneShellContextForTesting(path: "/tmp/project-open-with")
        waitForLayout("metadata settled", delay: 0.05)

        controller.performOpenWithPrimaryActionForTesting()

        XCTAssertEqual(openWithService.openCalls.map(\.target.stableID), ["cursor"])
        XCTAssertEqual(openWithService.openCalls.map(\.workingDirectory), ["/tmp/project-open-with"])
    }

    func test_open_with_primary_action_uses_request_working_directory_before_pane_context_arrives() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            ),
            iconsByStableID: [
                "cursor": NSImage(size: NSSize(width: 16, height: 16)),
                "finder": NSImage(size: NSSize(width: 16, height: 16))
            ]
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let worklane = makeRequestOnlyWorklane(workingDirectory: "/tmp/request-only-open-with")
        controller.rootViewControllerForTesting.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        waitForLayout("worklane replaced", delay: 0.05)

        XCTAssertEqual(
            controller.rootViewControllerForTesting.focusedOpenWithContext?.workingDirectory,
            "/tmp/request-only-open-with"
        )
        XCTAssertEqual(controller.rootViewControllerForTesting.focusedOpenWithContext?.scope, .local)

        controller.performOpenWithPrimaryActionForTesting()

        XCTAssertEqual(openWithService.openCalls.map(\.target.stableID), ["cursor"])
        XCTAssertEqual(openWithService.openCalls.map(\.workingDirectory), ["/tmp/request-only-open-with"])
    }

    func test_open_with_menu_selection_remembers_selected_target_globally() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor", "xcode"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                ),
                OpenWithResolvedTarget(
                    stableID: "xcode",
                    kind: .editor,
                    displayName: "Xcode",
                    builtInID: .xcode,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            ),
            iconsByStableID: [
                "cursor": NSImage(size: NSSize(width: 16, height: 16)),
                "finder": NSImage(size: NSSize(width: 16, height: 16))
            ]
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-open-with")
        controller.injectFocusedPaneShellContextForTesting(path: "/tmp/project-open-with")
        waitForLayout("metadata settled", delay: 0.05)

        controller.performOpenWithMenuSelectionForTesting(stableID: "xcode")

        XCTAssertEqual(openWithService.openCalls.map(\.target.stableID), ["xcode"])
        XCTAssertEqual(openWithService.openCalls.map(\.workingDirectory), ["/tmp/project-open-with"])
        XCTAssertEqual(store.current.openWith.primaryTargetID, "xcode")
    }

    func test_open_with_menu_builds_native_items_with_icons_and_checked_primary_target() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor", "finder"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                ),
                OpenWithResolvedTarget(
                    stableID: "finder",
                    kind: .fileManager,
                    displayName: "Finder",
                    builtInID: .finder,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            ),
            iconsByStableID: [
                "cursor": NSImage(size: NSSize(width: 16, height: 16)),
                "finder": NSImage(size: NSSize(width: 16, height: 16))
            ]
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let menu = controller.openWithMenuForTesting()
        let targetItems = menu.items.filter { $0.representedObject is OpenWithResolvedTarget }

        XCTAssertEqual(targetItems.map(\.title), ["Cursor", "Finder"])
        XCTAssertTrue(targetItems.allSatisfy { $0.image != nil })
        XCTAssertEqual(targetItems.map(\.state), [.on, .off])
        XCTAssertEqual(menu.items.last?.title, "Choose Apps…")
    }

    func test_open_with_menu_disables_target_items_for_metadata_only_inherited_pane_but_keeps_settings_enabled() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            )
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let worklane = makeMetadataOnlyInheritedWorklane(workingDirectory: "/srv/ambiguous-project")
        controller.rootViewControllerForTesting.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        waitForLayout("worklane replaced", delay: 0.05)

        XCTAssertNil(controller.rootViewControllerForTesting.focusedOpenWithContext)

        let menu = controller.openWithMenuForTesting()
        let targetItems = menu.items.filter { $0.representedObject is OpenWithResolvedTarget }

        XCTAssertEqual(targetItems.map(\.isEnabled), [false])
        XCTAssertEqual(menu.items.last?.title, "Choose Apps…")
        XCTAssertEqual(menu.items.last?.isEnabled, true)
    }

    func test_open_with_menu_enables_rows_before_pane_context_arrives_for_local_pane() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            )
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let menu = controller.openWithMenuForTesting()
        let targetItems = menu.items.filter { $0.representedObject is OpenWithResolvedTarget }

        XCTAssertEqual(targetItems.map(\.isEnabled), [true])
    }

    func test_open_with_menu_choose_apps_routes_to_settings() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            )
        )
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: adapterStore
        )
        controller.showWindow(nil)
        waitForLayout()

        let menu = controller.openWithMenuForTesting()
        let settingsItem = try XCTUnwrap(menu.items.last)
        controller.performOpenWithMenuItemForTesting(settingsItem)

        let settingsWindow = try XCTUnwrap(controller.settingsWindow)
        let settingsViewController = try XCTUnwrap(
            settingsWindow.contentViewController as? SettingsViewController
        )
        settingsViewController.loadViewIfNeeded()

        XCTAssertEqual(settingsViewController.selectedSection, .openWith)
    }

    func test_open_with_menu_empty_state_shows_disabled_message_and_settings_item() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.enabledTargetIDs = []
        }

        let controller = makeController(
            configStore: store,
            openWithService: RecordingOpenWithService(
                availableTargets: [],
                primaryTarget: nil
            ),
            adapterStore: MetadataAdapterStore()
        )
        controller.showWindow(nil)
        waitForLayout()

        let menu = controller.openWithMenuForTesting()

        XCTAssertEqual(menu.items.map(\.title), ["No enabled installed apps", "", "Choose Apps…"])
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertTrue(menu.items.last?.isEnabled == true)
    }

    func test_open_with_targets_are_preloaded_when_config_is_applied_and_before_menu_is_built() throws {
        let store = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.MainWindowController")
        )
        try store.update { config in
            config.openWith.primaryTargetID = "cursor"
            config.openWith.enabledTargetIDs = ["cursor", "finder"]
        }

        let openWithService = RecordingOpenWithService(
            availableTargets: [
                OpenWithResolvedTarget(
                    stableID: "cursor",
                    kind: .editor,
                    displayName: "Cursor",
                    builtInID: .cursor,
                    appPath: nil
                ),
                OpenWithResolvedTarget(
                    stableID: "finder",
                    kind: .fileManager,
                    displayName: "Finder",
                    builtInID: .finder,
                    appPath: nil
                )
            ],
            primaryTarget: OpenWithResolvedTarget(
                stableID: "cursor",
                kind: .editor,
                displayName: "Cursor",
                builtInID: .cursor,
                appPath: nil
            )
        )
        let controller = makeController(
            configStore: store,
            openWithService: openWithService,
            adapterStore: MetadataAdapterStore()
        )
        controller.showWindow(nil)
        waitForLayout()

        XCTAssertEqual(openWithService.preloadCalls.map { $0.map(\.stableID) }, [["cursor", "finder"]])

        _ = controller.openWithMenuForTesting()

        XCTAssertEqual(openWithService.preloadCalls.map { $0.map(\.stableID) }, [["cursor", "finder"], ["cursor", "finder"]])
    }

    func test_proxy_window_drag_suppression_matches_padded_proxy_zone() throws {
        let controller = makeController()
        controller.showWindow(nil)
        waitForLayout()

        controller.injectFocusedPaneShellContextForTesting(path: "/tmp/project-proxy-drag")
        waitForLayout("proxy context settled", delay: 0.05)

        let proxyPoint = try XCTUnwrap(
            controller.rootViewControllerForTesting.chromeView.focusedProxyIconLeadingPaddingPointInWindowForTesting()
        )
        let outsidePoint = NSPoint(x: proxyPoint.x - 12, y: proxyPoint.y)

        XCTAssertTrue(controller.shouldSuppressWindowDragForTesting(at: proxyPoint, eventType: .leftMouseDown))
        XCTAssertTrue(controller.shouldSuppressWindowDragForTesting(at: proxyPoint, eventType: .leftMouseDragged))
        XCTAssertFalse(controller.shouldSuppressWindowDragForTesting(at: proxyPoint, eventType: .leftMouseUp))
        XCTAssertFalse(controller.shouldSuppressWindowDragForTesting(at: outsidePoint, eventType: .leftMouseDown))
    }

    func test_proxy_window_drag_suppression_restores_window_movable_state() throws {
        let controller = makeController()
        controller.showWindow(nil)
        waitForLayout()

        controller.injectFocusedPaneShellContextForTesting(path: "/tmp/project-proxy-drag")
        waitForLayout("proxy context settled", delay: 0.05)

        let proxyPoint = try XCTUnwrap(
            controller.rootViewControllerForTesting.chromeView.focusedProxyIconLeadingPaddingPointInWindowForTesting()
        )

        XCTAssertTrue(controller.isWindowMovableForTesting)

        controller.handleProxySuppressionEventForTesting(location: proxyPoint, eventType: .leftMouseDown)
        XCTAssertFalse(controller.isWindowMovableForTesting)

        controller.handleProxySuppressionEventForTesting(location: proxyPoint, eventType: .leftMouseUp)
        XCTAssertTrue(controller.isWindowMovableForTesting)
    }
}

@MainActor
private final class MetadataAdapterStore {
    var adapters: [PaneID: MetadataEmittingTerminalAdapter] = [:]
}

@MainActor
private final class RecordingOpenWithService: OpenWithServing {
    let availableTargetsValue: [OpenWithResolvedTarget]
    let primaryTargetValue: OpenWithResolvedTarget?
    private(set) var openCalls: [(target: OpenWithResolvedTarget, workingDirectory: String)] = []
    private(set) var preloadCalls: [[OpenWithResolvedTarget]] = []
    private let iconsByStableID: [String: NSImage]

    init(
        availableTargets: [OpenWithResolvedTarget],
        primaryTarget: OpenWithResolvedTarget?,
        iconsByStableID: [String: NSImage] = [:]
    ) {
        self.availableTargetsValue = availableTargets
        self.primaryTargetValue = primaryTarget
        self.iconsByStableID = iconsByStableID
    }

    func detectedTargets(preferences: AppConfig.OpenWith) -> [OpenWithDetectedTarget] {
        availableTargetsValue.map { OpenWithDetectedTarget(target: $0, isAvailable: true) }
    }

    func availableTargets(preferences: AppConfig.OpenWith) -> [OpenWithResolvedTarget] {
        availableTargetsValue
    }

    func primaryTarget(preferences: AppConfig.OpenWith) -> OpenWithResolvedTarget? {
        primaryTargetValue
    }

    func preloadIcons(for targets: [OpenWithResolvedTarget]) {
        preloadCalls.append(targets)
    }

    func icon(for target: OpenWithResolvedTarget) -> NSImage? {
        iconsByStableID[target.stableID]
    }

    func open(target: OpenWithResolvedTarget, workingDirectory: String) -> Bool {
        openCalls.append((target: target, workingDirectory: workingDirectory))
        return true
    }
}

@MainActor
private final class MetadataEmittingTerminalAdapter: TerminalAdapter {
    private let terminalView = MetadataTerminalView()

    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var lastRequest: TerminalSessionRequest?

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        lastRequest = request
        metadataDidChange?(TerminalMetadata(currentWorkingDirectory: request.workingDirectory))
    }

    func close() {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        _ = activity
    }

    func emitWorkingDirectory(_ path: String) {
        metadataDidChange?(TerminalMetadata(
            title: "shell",
            currentWorkingDirectory: path,
            processName: "zsh"
        ))
    }
}

private final class MetadataTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func descendant(withIdentifier identifier: String) -> NSView? {
        if self.identifier?.rawValue == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.descendant(withIdentifier: identifier) {
                return match
            }
        }

        return nil
    }

    func descendantPaneViews() -> [PaneContainerView] {
        var paneViews: [PaneContainerView] = []

        func walk(_ view: NSView) {
            if let paneView = view as? PaneContainerView {
                paneViews.append(paneView)
            }

            view.subviews.forEach(walk)
        }

        walk(self)
        return paneViews
    }
}
