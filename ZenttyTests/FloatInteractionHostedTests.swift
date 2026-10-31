import XCTest
@testable import Zentty

/// Hosted float gestures with real window events: the float container
/// latches its presses through `hitTest`, so the terminal underneath never
/// sees a move, a resize or a ⌃⌘-drag, and the store hears one outcome.
@MainActor
final class FloatInteractionHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-interaction")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")
    /// A float frame clear of every canvas edge, so moves and resizes are
    /// never clamped.
    private let seededFloatFrame = NormalizedRect(x: 0.25, y: 0.25, width: 0.4, height: 0.4)

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 1_000

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = false
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        registry = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: - Latching (Step 1)

    func test_control_command_mouse_down_hits_float_container_and_skips_context_menu() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let spy = try spyView()
        let start = layer.convert(CGPoint(x: host.paneFrame.midX, y: host.paneFrame.midY), to: nil)

        let down = try dequeue(.leftMouseDown, at: start, modifiers: [.control, .command], in: controller)
        XCTAssertTrue(NSApp.currentEvent === down)
        let contentView = try XCTUnwrap(controller.window.contentView)
        let hit = contentView.hitTest(contentView.convert(start, from: nil))
        XCTAssertTrue(hit === host, "⌃⌘ anywhere on the float latches to its container, got \(String(describing: hit))")
        XCTAssertNil(host.menu(for: down))

        controller.window.sendEvent(down)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 40, dy: -20), in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 80, dy: -40), in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: 80, dy: -40), in: controller)

        XCTAssertEqual(spy.mouseEventTypes, [], "the terminal never sees the ⌃⌘ press")
        XCTAssertEqual(spy.menuRequestCount, 0, "no ⌃-click context menu")
        XCTAssertFalse(host.isGestureActiveForTesting)
    }

    // MARK: - Move

    func test_band_drag_moves_float_and_commits_once() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let commits = countGestureCommits(controller)
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.maxY), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 50, dy: -25), in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 100, dy: -50), in: controller)

        XCTAssertEqual(layer.interactiveFrameForTesting(floatID), startFrame.offsetBy(dx: 100, dy: -50))
        XCTAssertEqual(try storedFrame(in: controller), startFrame, "nothing is committed mid-drag")
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        XCTAssertTrue(host.isLifted)
        XCTAssertGreaterThan(host.frame.width, host.bounds.width, "lifted by bounds scaling")
        XCTAssertEqual(try spyView().isViewportSyncSuspended, true, "the grid is frozen while lifted")

        try send(.leftMouseUp, at: start.offsetBy(dx: 100, dy: -50), in: controller)
        waitForLayout("moved")

        XCTAssertEqual(commits.count, 1)
        XCTAssertFrameEqual(try storedFrame(in: controller), startFrame.offsetBy(dx: 100, dy: -50))
        XCTAssertNil(layer.interactiveFrameForTesting(floatID))
        XCTAssertFalse(host.isLifted)
        XCTAssertEqual(host.frame.size, host.bounds.size, "the lift is undone")
        XCTAssertEqual(try spyView().isViewportSyncSuspended, false)
        XCTAssertEqual(try spyView().mouseEventTypes, [])
    }

    func test_control_command_drag_on_content_moves_float() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.midY), to: nil)

        try sendDown(at: start, modifiers: [.control, .command], in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: -30, dy: 20), in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: -60, dy: 40), in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: -60, dy: 40), in: controller)
        waitForLayout("moved")

        XCTAssertFrameEqual(try storedFrame(in: controller), startFrame.offsetBy(dx: -60, dy: 40))
        XCTAssertEqual(try spyView().mouseEventTypes, [])
    }

    func test_plain_drag_on_content_reaches_terminal() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.midY), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 60, dy: 0), in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: 60, dy: 0), in: controller)
        waitForLayout("selected")

        XCTAssertEqual(try spyView().mouseEventTypes, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(try storedFrame(in: controller), startFrame)
        XCTAssertFalse(try XCTUnwrap(layer.floatHostForTesting(floatID)).isGestureActiveForTesting)
    }

    func test_rerender_mid_drag_keeps_interactive_frame() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.maxY), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 70, dy: 0), in: controller)
        // A store change lands mid-drag (another float op re-renders the layer).
        store(controller).moveFloat(floatID, frame: NormalizedRect(x: 0.05, y: 0.05, width: 0.3, height: 0.3))
        waitForLayout("re-rendered")

        XCTAssertEqual(host.paneFrame, startFrame.offsetBy(dx: 70, dy: 0), "the drag frame wins over the store")

        try send(.leftMouseUp, at: start.offsetBy(dx: 70, dy: 0), in: controller)
        waitForLayout("committed")
        XCTAssertFrameEqual(try storedFrame(in: controller), startFrame.offsetBy(dx: 70, dy: 0))
    }

    func test_escape_cancels_drag_and_restores_start_frame() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let commits = countGestureCommits(controller)
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.maxY), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 90, dy: -30), in: controller)
        XCTAssertTrue(host.isGestureActiveForTesting)

        try sendEscape(in: controller)

        XCTAssertFalse(host.isGestureActiveForTesting)
        XCTAssertNil(layer.interactiveFrameForTesting(floatID))
        XCTAssertEqual(host.paneFrame, startFrame)
        XCTAssertFalse(host.isLifted)
        XCTAssertEqual(try spyView().isViewportSyncSuspended, false)

        // The rest of the press is ignored.
        try send(.leftMouseDragged, at: start.offsetBy(dx: 120, dy: -30), in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: 120, dy: -30), in: controller)
        waitForLayout("released")
        XCTAssertEqual(commits.count, 0)
        XCTAssertEqual(try storedFrame(in: controller), startFrame)
    }

    func test_window_resign_key_cancels_gesture() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.maxY), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 40, dy: 0), in: controller)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: controller.window)

        XCTAssertFalse(host.isGestureActiveForTesting)
        XCTAssertEqual(host.paneFrame, startFrame)
    }

    func test_click_on_legend_copies_path_and_drag_on_it_moves() throws {
        let controller = try makeFloatedController()
        let root = controller.rootViewControllerForTesting
        var copied: [String] = []
        root.pasteboardStringWriterForTesting = { copied.append($0) }
        let container = try XCTUnwrap(canvas(controller).floatLayerView.containerForTesting(floatID))
        container.layoutSubtreeIfNeeded()
        let legend = try XCTUnwrap(container.paneBorderContextFrameForTesting)
        let start = container.convert(CGPoint(x: legend.midX, y: legend.midY), to: nil)
        let startFrame = try paneFrame(in: controller)

        try sendDown(at: start, in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: 1, dy: 0), in: controller)
        waitForLayout("clicked")
        XCTAssertEqual(copied, ["/tmp/float-cwd"], "a click on the legend copies the path")
        XCTAssertEqual(try storedFrame(in: controller), startFrame)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 30, dy: -30), in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: 30, dy: -30), in: controller)
        waitForLayout("moved")
        XCTAssertEqual(copied.count, 1, "a drag from the legend doesn't copy")
        XCTAssertFrameEqual(try storedFrame(in: controller), startFrame.offsetBy(dx: 30, dy: -30))
    }

    // MARK: - Resize and throw

    func test_resize_bottom_right_keeps_top_left_fixed() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.maxX, y: startFrame.minY), to: nil)

        try sendDown(at: start, in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 20, dy: -10), in: controller)
        try send(.leftMouseDragged, at: start.offsetBy(dx: 40, dy: -30), in: controller)
        try send(.leftMouseUp, at: start.offsetBy(dx: 40, dy: -30), in: controller)
        waitForLayout("resized")

        let frame = try storedFrame(in: controller)
        XCTAssertEqual(frame.minX, startFrame.minX, accuracy: 1)
        XCTAssertEqual(frame.maxY, startFrame.maxY, accuracy: 1)
        XCTAssertEqual(frame.width, startFrame.width + 40, accuracy: 1)
        XCTAssertEqual(frame.height, startFrame.height + 30, accuracy: 1)
        XCTAssertFalse(try XCTUnwrap(layer.floatHostForTesting(floatID)).isLifted, "resizing never lifts")
    }

    func test_fast_throw_sends_float_to_pip() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let startFrame = try paneFrame(in: controller)
        let start = layer.convert(CGPoint(x: startFrame.midX, y: startFrame.maxY), to: nil)

        try sendDown(at: start, in: controller)
        for step in 1...4 {
            try send(
                .leftMouseDragged,
                at: start.offsetBy(dx: CGFloat(step) * 30, dy: CGFloat(step) * -30),
                after: 0.01,
                in: controller
            )
        }
        try send(.leftMouseUp, at: start.offsetBy(dx: 120, dy: -120), after: 0.005, in: controller)
        waitForLayout("thrown")

        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: floatID))
        XCTAssertEqual(float.mode, .pip(corner: .bottomRight, order: 0))
        XCTAssertNotNil(layer.pipHostForTesting(floatID))
        XCTAssertEqual(float.floatFrame, seededFloatFrame, "the float keeps its pre-throw frame")
    }

    // MARK: - Lift in place and the empty strip

    func test_float_in_place_starts_at_tile_frame_and_unsuspends_after_animation() throws {
        let controller = try makeSeededController()
        let layer = canvas(controller).floatLayerView
        let tileFrame = try XCTUnwrap(canvas(controller).tileFrameInFloatLayer(for: floatID))
        let spy = try spyView()
        spy.suspensionLog.removeAll()
        let landed = expectation(description: "lift landed")
        layer.onLiftInPlaceFinishedForTesting = { paneID in
            if paneID == self.floatID { landed.fulfill() }
        }

        controller.toggleFloat(nil)

        let mountSuspend = try XCTUnwrap(spy.suspensionLog.last { $0.suspended })
        XCTAssertEqual(mountSuspend.containerSize, tileFrame.size, "mounted at the tile's slot, grid frozen")
        XCTAssertEqual(spy.isViewportSyncSuspended, true, "stays frozen while it grows")
        wait(for: [landed], timeout: 3)

        let floatFrame = try XCTUnwrap(layer.floatHostForTesting(floatID)?.paneFrame)
        XCTAssertNotEqual(floatFrame, tileFrame)
        XCTAssertEqual(spy.isViewportSyncSuspended, false)
        let resume = try XCTUnwrap(spy.suspensionLog.last { !$0.suspended })
        XCTAssertEqual(resume.containerSize, floatFrame.size, "the grid follows at the float size")
    }

    func test_floating_last_tile_shows_empty_strip_hint() throws {
        let controller = try makeSeededController(panes: [PaneState(id: floatID, title: "b")])
        XCTAssertNil(canvas(controller).paneStripView.emptyStripHintTextForTesting)

        controller.toggleFloat(nil)
        waitForLayout("floated")

        XCTAssertEqual(canvas(controller).paneStripView.emptyStripHintTextForTesting, "No tiled panes")

        controller.toggleFloat(nil)
        waitForLayout("docked")
        XCTAssertNil(canvas(controller).paneStripView.emptyStripHintTextForTesting)
    }

    // MARK: - Events

    private func makeEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags,
        after interval: TimeInterval,
        in controller: MainWindowController
    ) throws -> NSEvent {
        clock += interval
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: modifiers,
            timestamp: clock,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    /// Posts and dequeues the event, so it is `NSApp.currentEvent` while
    /// AppKit hit-tests it, like a real press.
    private func dequeue(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        in controller: MainWindowController
    ) throws -> NSEvent {
        let event = try makeEvent(type, at: windowPoint, modifiers: modifiers, after: 0.1, in: controller)
        NSApp.postEvent(event, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
            until: Date(),
            inMode: .default,
            dequeue: true
        ))
        XCTAssertEqual(dequeued.type, type)
        XCTAssertEqual(dequeued.timestamp, event.timestamp, accuracy: 0.0001)
        return dequeued
    }

    private func sendDown(
        at windowPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        in controller: MainWindowController
    ) throws {
        controller.window.sendEvent(try dequeue(.leftMouseDown, at: windowPoint, modifiers: modifiers, in: controller))
    }

    /// Drags and ups go to whichever view took the mouse-down.
    private func send(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        after interval: TimeInterval = 0.1,
        in controller: MainWindowController
    ) throws {
        controller.window.sendEvent(try makeEvent(type, at: windowPoint, modifiers: [], after: interval, in: controller))
    }

    private func sendEscape(in controller: MainWindowController) throws {
        clock += 0.05
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: clock,
            windowNumber: controller.window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        NSApp.postEvent(escape, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true))
        NSApp.sendEvent(dequeued)
    }

    // MARK: - Fixtures

    private final class CommitCounter {
        var count = 0
    }

    private func countGestureCommits(_ controller: MainWindowController) -> CommitCounter {
        let counter = CommitCounter()
        let layer = canvas(controller).floatLayerView
        let original = layer.onFloatGestureEnded
        layer.onFloatGestureEnded = { paneID, outcome, canvas in
            if outcome != .click {
                counter.count += 1
            }
            original?(paneID, outcome, canvas)
        }
        return counter
    }

    private func paneFrame(in controller: MainWindowController) throws -> CGRect {
        try XCTUnwrap(canvas(controller).floatLayerView.floatHostForTesting(floatID)?.paneFrame)
    }

    /// The store's frame for the float, resolved like the layer does.
    private func storedFrame(in controller: MainWindowController) throws -> CGRect {
        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: floatID))
        return FloatLayerLayout.floatFrame(for: float, canvas: canvas(controller).floatLayerView.bounds)
    }

    private func spyView() throws -> HostedSpyTerminalView {
        try XCTUnwrap(adapters[floatID]?.spyView)
    }

    private func makeFloatedController() throws -> MainWindowController {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.6)
        store(controller).moveFloat(floatID, frame: seededFloatFrame)
        waitForLayout("placed")
        XCTAssertTrue(store(controller).activeWorklane?.floatOwnsFocus == true)
        try spyView().resetMouseEventsForTesting()
        return controller
    }

    private func makeSeededController(panes: [PaneState]? = nil) throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = HostedSpyTerminalAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let controller = MainWindowController(runtimeRegistry: registry).prepareForHostedTesting()
        self.controller = controller
        self.registry = registry
        controller.showWindow(nil)
        waitForLayout()

        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: panes ?? [
                        PaneState(id: tileID, title: "a"),
                        PaneState(id: floatID, title: "b"),
                    ],
                    focusedPaneID: floatID
                ),
                auxiliaryStateByPaneID: [
                    floatID: PaneAuxiliaryState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/float-cwd",
                            home: nil,
                            user: nil,
                            host: nil
                        )
                    ),
                ]
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")
        XCTAssertNotNil(registry.runtime(for: floatID))
        return controller
    }

    private func store(_ controller: MainWindowController) -> WorklaneStore {
        controller.rootViewControllerForTesting.worklaneStore
    }

    private func canvas(_ controller: MainWindowController) -> AppCanvasView {
        controller.rootViewControllerForTesting.appCanvasViewForTesting
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.15) {
        let settled = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: 3.0)
    }
}

private func XCTAssertFrameEqual(
    _ lhs: CGRect,
    _ rhs: CGRect,
    accuracy: CGFloat = 1,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, "minX", file: file, line: line)
    XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, "minY", file: file, line: line)
    XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, "width", file: file, line: line)
    XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, "height", file: file, line: line)
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}
