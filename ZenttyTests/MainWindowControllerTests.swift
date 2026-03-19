import XCTest
@testable import Zentty

@MainActor
final class MainWindowControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalAdapterRegistry.useMockAdapters()
    }

    func test_main_window_starts_with_expected_content_size() {
        let controller = MainWindowController()
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
        let controller = MainWindowController()

        XCTAssertTrue(controller.window.styleMask.contains(.resizable))
    }

    func test_show_window_does_not_reset_manual_frame_changes() {
        let controller = MainWindowController()
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
        let controller = MainWindowController()
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

    func test_programmatic_window_resize_relayouts_panes_without_inner_animation() throws {
        let controller = MainWindowController()
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
        let expectedTotalWidth = initialWidths.reduce(0, +) * expectedScaleFactor
        let paneWidthTolerance: CGFloat = 1.0

        XCTAssertEqual(initialWidths.count, 2)
        XCTAssertEqual(resizedWidths.count, 2)
        XCTAssertEqual(resizedWidths[0], initialWidths[0] * expectedScaleFactor, accuracy: paneWidthTolerance)
        XCTAssertEqual(resizedWidths[1], initialWidths[1] * expectedScaleFactor, accuracy: paneWidthTolerance)
        XCTAssertEqual(resizedWidths.reduce(0, +), expectedTotalWidth, accuracy: paneWidthTolerance)
        XCTAssertFalse(resizedAppCanvasView.lastPaneStripRenderWasAnimatedForTesting)
    }

    func test_new_workspace_action_creates_and_focuses_new_workspace() {
        let controller = MainWindowController()

        controller.newWorkspace(nil)

        XCTAssertEqual(controller.workspaceTitles, ["MAIN", "WS 2"])
        XCTAssertEqual(controller.activeWorkspaceTitle, "WS 2")
        XCTAssertEqual(controller.activePaneTitles, ["shell"])
    }

    func test_split_and_focus_actions_route_through_root_dispatcher() {
        let controller = MainWindowController()

        controller.splitRight(nil)
        controller.focusLeftPane(nil)

        XCTAssertEqual(controller.activePaneTitles, ["shell", "pane 1"])
        XCTAssertEqual(controller.focusedPaneTitle, "shell")
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
