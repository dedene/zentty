import XCTest
@testable import Zentty

/// ⌥-drag docking with real window events: the float's own surface lands in
/// the strip (never a copy), refused or missing targets leave it a float.
@MainActor
final class FloatDockHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-dock")
    private let leftID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")
    private let rightID = PaneID("pane-c")
    private let seededFloatFrame = NormalizedRect(x: 0.3, y: 0.15, width: 0.35, height: 0.35)

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 2_000

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

    // MARK: - Docking

    func test_option_drag_onto_column_gap_docks_same_runtime() throws {
        let controller = try makeFloatedController()
        let runtime = try XCTUnwrap(registry?.runtime(for: floatID))
        let hostView = runtime.hostView
        let gap = try gapPoint(in: controller)

        try dragWithOption(to: gap, in: controller)
        XCTAssertEqual(layer(controller).dockCoordinator.currentTarget, .columnGap(index: 1))
        try send(.leftMouseUp, at: window(gap, controller), modifiers: [.option], in: controller)
        waitForLayout("docked", delay: 0.6)

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertFalse(worklane.isFloating(floatID))
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [leftID, floatID, rightID])
        XCTAssertEqual(worklane.allPanes.count, 3, "moved, never duplicated")
        XCTAssertTrue(registry?.runtime(for: floatID) === runtime)
        XCTAssertTrue(runtime.hostView === hostView)
        XCTAssertTrue(hostView.isDescendant(of: canvas(controller).paneStripView))
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
        XCTAssertNil(layer(controller).floatHostForTesting(floatID))
        XCTAssertTrue(layer(controller).dockPreviewView.subviews.isEmpty)
        XCTAssertEqual(try spyView().isViewportSyncSuspended, false, "the grid follows once it lands")
        XCTAssertTrue(
            try spyView().suspensionLog.contains { $0.suspended && $0.containerSize != nil },
            "the landing animation freezes the grid"
        )
    }

    func test_option_drag_onto_split_zone_after_dwell_docks_split() throws {
        let controller = try makeFloatedController()
        let left = try XCTUnwrap(columns(controller).first)
        let point = CGPoint(x: left.frame.midX, y: left.frame.maxY - 12)

        try dragWithOption(to: point, in: controller)
        XCTAssertNil(layer(controller).dockCoordinator.currentTarget, "the split waits for the dwell")
        waitForLayout("dwell", delay: 0.4)
        XCTAssertEqual(
            layer(controller).dockCoordinator.currentTarget,
            .split(target: leftID, axis: .vertical, leading: true)
        )
        try send(.leftMouseUp, at: window(point, controller), modifiers: [.option], in: controller)
        waitForLayout("docked", delay: 0.6)

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertFalse(worklane.isFloating(floatID))
        let leftColumn = worklane.paneStripState.columns.first { $0.panes.contains { $0.id == leftID } }
        XCTAssertEqual(leftColumn?.panes.map(\.id), [floatID, leftID], "docked above the target")
    }

    func test_option_drag_into_float_only_worklane_creates_first_column() throws {
        let controller = try makeSeededController(panes: [PaneState(id: leftID, title: "a"), PaneState(id: floatID, title: "b")])
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.6)
        // The sole tile can't float; closing it under the float empties the strip.
        controller.rootViewControllerForTesting.handlePaneBorderAction(.close, paneID: leftID)
        waitForLayout("last tile closed", delay: 0.3)
        XCTAssertTrue(store(controller).activeWorklane?.paneStripState.columns.isEmpty == true)
        let host = try XCTUnwrap(layer(controller).floatHostForTesting(floatID))
        let target = CGPoint(x: host.paneFrame.midX + 60, y: host.paneFrame.maxY - 40)

        try dragWithOption(to: target, in: controller)
        XCTAssertEqual(layer(controller).dockCoordinator.currentTarget, .columnGap(index: 0))
        try send(.leftMouseUp, at: window(target, controller), modifiers: [.option], in: controller)
        waitForLayout("docked", delay: 0.6)

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [floatID])
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
    }

    func test_dock_mode_float_alpha_and_label() throws {
        let controller = try makeFloatedController()
        let host = try XCTUnwrap(layer(controller).floatHostForTesting(floatID))
        let startFrame = host.paneFrame

        try dragWithOption(to: try gapPoint(in: controller), in: controller)

        XCTAssertEqual(host.alphaValue, 0.55, accuracy: 0.001)
        XCTAssertEqual(layer(controller).dockCoordinator.previewForTesting.labelText, "Dock here")
        let label = try XCTUnwrap(layer(controller).dockCoordinator.labelViewForTesting)
        XCTAssertTrue(label.isDescendant(of: layer(controller).dockPreviewView))
        let floatIndex = try XCTUnwrap(layer(controller).subviews.firstIndex { $0 === host })
        let previewIndex = try XCTUnwrap(layer(controller).subviews.firstIndex { $0 === layer(controller).dockPreviewView })
        XCTAssertLessThan(previewIndex, floatIndex, "previews sit below the floats")

        try sendEscape(in: controller)
        waitForLayout("cancelled", delay: 0.6)

        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(layer(controller).dockCoordinator.previewForTesting.labelText)
        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
        XCTAssertEqual(host.paneFrame, startFrame, "Escape springs it back")
    }

    func test_drop_without_target_leaves_float_at_drop_point() throws {
        let controller = try makeFloatedController()
        let host = try XCTUnwrap(layer(controller).floatHostForTesting(floatID))
        let startFrame = host.paneFrame
        let left = try XCTUnwrap(columns(controller).first)
        // The middle of the left tile: no gap, no split edge.
        let point = CGPoint(x: left.frame.midX, y: left.frame.midY)
        let start = bandPoint(of: startFrame)

        try dragWithOption(to: point, in: controller)
        XCTAssertNil(layer(controller).dockCoordinator.currentTarget)
        try send(.leftMouseUp, at: window(point, controller), modifiers: [.option], in: controller)
        waitForLayout("dropped", delay: 0.6)

        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
        let expected = FloatLayout.clamped(
            startFrame.offsetBy(dx: point.x - start.x, dy: point.y - start.y),
            in: layer(controller).bounds
        )
        XCTAssertFrameEqual(try storedFrame(in: controller), expected)
        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)
    }

    func test_target_closed_mid_drag_keeps_float() throws {
        let controller = try makeFloatedController()
        let right = try XCTUnwrap(columns(controller).last)
        let visible = right.frame.intersection(layer(controller).bounds)
        let point = CGPoint(x: visible.midX, y: right.frame.maxY - 12)

        try dragWithOption(to: point, in: controller)
        waitForLayout("dwell", delay: 0.4)
        XCTAssertEqual(
            layer(controller).dockCoordinator.currentTarget,
            .split(target: rightID, axis: .vertical, leading: true)
        )

        _ = store(controller).closePane(id: rightID)
        waitForLayout("closed")
        try send(.leftMouseUp, at: window(point, controller), modifiers: [.option], in: controller)
        waitForLayout("released", delay: 0.6)

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.isFloating(floatID), "its target went away: it stays a float")
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [leftID])
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
    }

    func test_option_toggled_mid_drag_enters_dock_mode() throws {
        let controller = try makeFloatedController()
        let host = try XCTUnwrap(layer(controller).floatHostForTesting(floatID))
        let start = bandPoint(of: host.paneFrame)
        let gap = try gapPoint(in: controller)

        try sendDown(at: window(start, controller), modifiers: [], in: controller)
        try send(.leftMouseDragged, at: window(start.offsetBy(dx: 20, dy: -10), controller), modifiers: [], in: controller)
        XCTAssertFalse(host.isDockModeForTesting)
        XCTAssertFalse(layer(controller).dockCoordinator.isActive)

        try sendFlagsChanged([.option], in: controller)
        XCTAssertTrue(host.isDockModeForTesting, "the local flags monitor sees ⌥ go down")
        XCTAssertTrue(layer(controller).dockCoordinator.isActive)
        XCTAssertEqual(host.alphaValue, 0.55, accuracy: 0.001)

        try send(.leftMouseDragged, at: window(gap, controller), modifiers: [.option], in: controller)
        try sendFlagsChanged([], in: controller)
        XCTAssertFalse(layer(controller).dockCoordinator.isActive, "releasing ⌥ resumes the plain move")
        try sendFlagsChanged([.option], in: controller)
        try send(.leftMouseUp, at: window(gap, controller), modifiers: [.option], in: controller)
        waitForLayout("docked", delay: 0.6)

        XCTAssertEqual(store(controller).activeWorklane?.paneStripState.panes.map(\.id), [leftID, floatID, rightID])
    }

    // MARK: - Gestures

    /// Presses the float's move band with ⌥ and drags to `point` (float-layer
    /// coordinates) in two steps, like a hand would.
    private func dragWithOption(to point: CGPoint, in controller: MainWindowController) throws {
        let host = try XCTUnwrap(layer(controller).floatHostForTesting(floatID))
        let start = bandPoint(of: host.paneFrame)
        let middle = CGPoint(x: (start.x + point.x) / 2, y: (start.y + point.y) / 2)
        try sendDown(at: window(start, controller), modifiers: [.option], in: controller)
        try send(.leftMouseDragged, at: window(middle, controller), modifiers: [.option], in: controller)
        try send(.leftMouseDragged, at: window(point, controller), modifiers: [.option], in: controller)
        XCTAssertTrue(host.isDockModeForTesting)
    }

    private func bandPoint(of paneFrame: CGRect) -> CGPoint {
        CGPoint(x: paneFrame.midX, y: paneFrame.maxY)
    }

    /// Between the left and right tile, in float-layer coordinates.
    private func gapPoint(in controller: MainWindowController) throws -> CGPoint {
        let columns = columns(controller)
        XCTAssertEqual(columns.count, 2)
        let left = try XCTUnwrap(columns.first)
        let right = try XCTUnwrap(columns.last)
        let point = CGPoint(x: (left.frame.maxX + right.frame.minX) / 2, y: left.frame.midY)
        XCTAssertTrue(layer(controller).bounds.contains(point), "the gap is on screen")
        return point
    }

    private func columns(_ controller: MainWindowController) -> [ColumnPresentation] {
        layer(controller).dockColumnsProvider?() ?? []
    }

    private func window(_ point: CGPoint, _ controller: MainWindowController) -> CGPoint {
        layer(controller).convert(point, to: nil)
    }

    private func makeEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags,
        in controller: MainWindowController
    ) throws -> NSEvent {
        clock += 0.1
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

    /// Posts and dequeues the mouse-down so it is `NSApp.currentEvent` while
    /// AppKit hit-tests it, like a real press.
    private func sendDown(
        at windowPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags,
        in controller: MainWindowController
    ) throws {
        let event = try makeEvent(.leftMouseDown, at: windowPoint, modifiers: modifiers, in: controller)
        NSApp.postEvent(event, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(
            matching: [.leftMouseDown],
            until: Date(),
            inMode: .default,
            dequeue: true
        ))
        controller.window.sendEvent(dequeued)
    }

    private func send(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags,
        in controller: MainWindowController
    ) throws {
        controller.window.sendEvent(try makeEvent(type, at: windowPoint, modifiers: modifiers, in: controller))
    }

    /// Through `NSApp.sendEvent`, so the gesture's local monitor sees it.
    private func sendFlagsChanged(_ modifiers: NSEvent.ModifierFlags, in controller: MainWindowController) throws {
        clock += 0.05
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: clock,
            windowNumber: controller.window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 58
        ))
        NSApp.postEvent(event, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(matching: .flagsChanged, until: Date(), inMode: .default, dequeue: true))
        NSApp.sendEvent(dequeued)
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

    private func storedFrame(in controller: MainWindowController) throws -> CGRect {
        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: floatID))
        return FloatLayerLayout.floatFrame(for: float, canvas: layer(controller).bounds)
    }

    private func spyView() throws -> HostedSpyTerminalView {
        try XCTUnwrap(adapters[floatID]?.spyView)
    }

    /// Tiles a | b | c with b focused, then b floated clear of the gap.
    private func makeFloatedController() throws -> MainWindowController {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.6)
        store(controller).moveFloat(floatID, frame: seededFloatFrame)
        waitForLayout("placed")
        XCTAssertEqual(store(controller).activeWorklane?.paneStripState.panes.map(\.id), [leftID, rightID])
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
                        PaneState(id: leftID, title: "a"),
                        PaneState(id: floatID, title: "b"),
                        PaneState(id: rightID, title: "c"),
                    ],
                    focusedPaneID: floatID
                )
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

    private func layer(_ controller: MainWindowController) -> FloatLayerView {
        canvas(controller).floatLayerView
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
