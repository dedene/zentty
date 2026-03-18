import XCTest
@testable import Zentty

@MainActor
final class MainWindowControllerTests: XCTestCase {
    override func tearDown() {
        SidebarWidthPreference.resetForTesting()
        SidebarVisibilityPreference.resetForTesting()
        PaneLayoutPreferenceStore.resetForTesting()
        super.tearDown()
    }

    private func makeController() -> MainWindowController {
        MainWindowController(
            sidebarWidthDefaults: SidebarWidthPreference.userDefaultsForTesting(),
            sidebarVisibilityDefaults: SidebarVisibilityPreference.userDefaultsForTesting(),
            paneLayoutDefaults: PaneLayoutPreferenceStore.userDefaultsForTesting()
        )
    }

    func test_main_window_starts_with_expected_content_size() {
        let controller = makeController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

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
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let window = controller.window

        let manualFrame = NSRect(x: 120, y: 140, width: 1180, height: 760)
        window.setFrame(manualFrame, display: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(window.frame.integral, manualFrame.integral)

        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(window.frame.integral, manualFrame.integral)
    }

    func test_show_window_repositions_traffic_lights_with_comfortable_inset() throws {
        let controller = makeController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let closeButton = try XCTUnwrap(controller.window.standardWindowButton(.closeButton))
        let miniButton = try XCTUnwrap(controller.window.standardWindowButton(.miniaturizeButton))
        let buttonSuperview = try XCTUnwrap(closeButton.superview)
        let topInset = buttonSuperview.bounds.maxY - closeButton.frame.maxY

        XCTAssertEqual(closeButton.frame.minX, ChromeGeometry.trafficLightLeadingInset, accuracy: 1.0)
        XCTAssertEqual(topInset, ChromeGeometry.trafficLightTopInset, accuracy: 1.0)
        XCTAssertEqual(
            closeButton.frame.minX - ChromeGeometry.shellInset,
            ChromeGeometry.trafficLightOpticalLeadingOffset,
            accuracy: 1.0
        )
        XCTAssertEqual(
            topInset - ChromeGeometry.shellInset,
            ChromeGeometry.trafficLightOpticalTopOffset,
            accuracy: 1.0
        )
        XCTAssertEqual(
            miniButton.frame.minX - closeButton.frame.maxX,
            ChromeGeometry.trafficLightSpacing,
            accuracy: 1.0
        )
    }

    func test_show_window_places_sidebar_toggle_beside_traffic_lights() throws {
        let controller = makeController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let zoomButton = try XCTUnwrap(controller.window.standardWindowButton(.zoomButton))
        let buttonSuperview = try XCTUnwrap(zoomButton.superview)
        let zoomAnchorInWindow = buttonSuperview.convert(
            NSPoint(x: zoomButton.frame.maxX, y: zoomButton.frame.midY),
            to: nil
        )
        let zoomAnchorInContent = try XCTUnwrap(controller.window.contentView).convert(zoomAnchorInWindow, from: nil)

        XCTAssertEqual(
            controller.sidebarToggleMinXForTesting - zoomAnchorInContent.x,
            12,
            accuracy: 1.0
        )
        XCTAssertEqual(controller.sidebarToggleMidYForTesting, zoomAnchorInContent.y, accuracy: 1.0)
        XCTAssertTrue(controller.isSidebarToggleActiveForTesting)
    }

    func test_programmatic_window_resize_relayouts_panes_without_inner_animation() throws {
        let controller = makeController()
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        controller.splitRight(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let initialAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let initialCanvasWidth = initialAppCanvasView.bounds.width
        let initialPaneViews = initialAppCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let initialWidths = initialPaneViews.map(\.frame.width)

        let resizedFrame = NSRect(x: 120, y: 140, width: 1420, height: 880)
        controller.window.setFrame(resizedFrame, display: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let resizedAppCanvasView = try XCTUnwrap(
            controller.window.contentView?.firstDescendant(ofType: AppCanvasView.self)
        )
        let resizedPaneViews = resizedAppCanvasView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let resizedWidths = resizedPaneViews.map(\.frame.width)
        let expectedScaleFactor = resizedAppCanvasView.bounds.width / initialCanvasWidth

        XCTAssertEqual(initialWidths.count, 2)
        XCTAssertEqual(resizedWidths.count, 2)
        XCTAssertEqual(resizedWidths[0], initialWidths[0] * expectedScaleFactor, accuracy: 1.0)
        XCTAssertEqual(resizedWidths[1], initialWidths[1] * expectedScaleFactor, accuracy: 1.0)
        XCTAssertFalse(resizedAppCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_new_workspace_action_creates_and_focuses_new_workspace() {
        let controller = makeController()

        controller.newWorkspace(nil)

        XCTAssertEqual(controller.workspaceTitlesForTesting, ["MAIN", "WS 2"])
        XCTAssertEqual(controller.activeWorkspaceTitleForTesting, "WS 2")
        XCTAssertEqual(controller.activePaneTitlesForTesting, ["shell"])
    }

    func test_split_and_focus_actions_route_through_root_dispatcher() {
        let controller = makeController()

        controller.splitRight(nil)
        controller.focusLeftPane(nil)

        XCTAssertEqual(controller.activePaneTitlesForTesting, ["shell", "pane 1"])
        XCTAssertEqual(controller.focusedPaneTitleForTesting, "shell")
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
