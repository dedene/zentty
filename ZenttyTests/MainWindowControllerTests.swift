import XCTest
@testable import Zentty

@MainActor
final class MainWindowControllerTests: XCTestCase {
    private var controller: MainWindowController?

    override func tearDown() {
        controller?.window.close()
        controller = nil
        super.tearDown()
    }

    private func makeController() -> MainWindowController {
        let c = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
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

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
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
        let initialCanvasWidth = initialAppCanvasView.bounds.width
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
        let controller = makeController()

        controller.newWorkspace(nil)

        XCTAssertEqual(controller.workspaceTitles, ["MAIN", "WS 2"])
        XCTAssertEqual(controller.activeWorkspaceTitle, "WS 2")
        XCTAssertEqual(controller.activePaneTitles, ["shell"])
    }

    func test_new_workspace_uses_reported_working_directory_of_focused_pane() throws {
        let adapterStore = MetadataAdapterStore()
        let controller = makeController(adapterStore: adapterStore)
        controller.showWindow(nil)
        waitForLayout()

        let initialPane = try XCTUnwrap(controller.window.contentView?.descendantPaneViews().first)
        let initialAdapter = try XCTUnwrap(adapterStore.adapters[initialPane.paneID])
        initialAdapter.emitWorkingDirectory("/tmp/project-a")

        controller.newWorkspace(nil)
        waitForLayout("workspace settled", delay: 0.05)

        XCTAssertEqual(controller.activeWorkspaceTitle, "WS 2")
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

    func test_new_workspace_uses_reported_working_directory_of_last_focused_pane() throws {
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

        let rightPane = paneViews[1]
        let rightAdapter = try XCTUnwrap(adapterStore.adapters[rightPane.paneID])
        rightAdapter.emitWorkingDirectory("/tmp/project-right")
        rightPane.focusTerminal()
        waitForLayout("focus settled", delay: 0.05)

        controller.newWorkspace(nil)
        waitForLayout("workspace settled", delay: 0.05)

        XCTAssertEqual(controller.activeWorkspaceTitle, "WS 2")
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

        let rightPane = paneViews[1]
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
}

@MainActor
private final class MetadataAdapterStore {
    var adapters: [PaneID: MetadataEmittingTerminalAdapter] = [:]
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
