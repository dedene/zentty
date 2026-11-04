import XCTest
@testable import Zentty

/// The pill peek through the real window: hovering a pill lends the
/// minimized pane's live terminal to a display-only PiP above it (scaled,
/// viewport frozen under `.pillPeek`, un-occluded, never focused); hover-out
/// gives it back occluded with that suspension released at the float size.
/// A restore, an auto-pop or a close during the peek takes the pane back
/// cleanly.
@MainActor
final class PillPeekHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-pill-peek")
    private let tileID = PaneID("pane-a")
    private let agentID = PaneID("pane-b")
    private let sessionID = "5d0c1f44-6a7e-4f21-9b1e-0f3a2c4d5e6f"

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 9_000

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        registry = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: - Hover

    func test_hover_hosts_the_live_container_scaled_with_sync_frozen_and_the_runtime_visible() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        let spy = try XCTUnwrap(adapters[agentID]?.spyView)
        XCTAssertEqual(adapters[agentID]?.lastActivity?.isVisible, false, "precondition: occluded")
        spy.suspensionLog.removeAll()
        spy.forcedSyncLog.removeAll()

        try hoverPill(in: controller)

        let peek = canvas.pillPeekView
        XCTAssertFalse(peek.isHidden)
        XCTAssertEqual(peek.alphaValue, 1)
        let pip = try XCTUnwrap(peek.pip)
        let container = try XCTUnwrap(pip.hostedContainer)
        let floatSize = try floatSize(in: controller)
        XCTAssertTrue(container.superview === pip.scaleViewForTesting)
        // Bounds scaling: the scaled view keeps the float's size (AppKit
        // rounds a bounds it derives from a scaled frame).
        XCTAssertEqual(pip.scaleViewForTesting.bounds.width, floatSize.width, accuracy: 0.001)
        XCTAssertEqual(pip.scaleViewForTesting.bounds.height, floatSize.height, accuracy: 0.001)
        XCTAssertEqual(container.frame.size, floatSize)
        XCTAssertEqual(
            peek.frame.size,
            FloatLayout.pipSize(floatSize: floatSize, width: canvas.floatLayerView.pipWidth),
            "PiP-sized"
        )
        XCTAssertTrue(spy.isDescendant(of: pip), "the pane's own terminal, not a copy")
        XCTAssertEqual(container.terminalViewportSuspensionOwners, [.pillPeek])
        XCTAssertEqual(spy.isViewportSyncSuspended, true)
        XCTAssertFalse(spy.suspensionLog.contains { !$0.suspended && $0.wasInPip }, "never resumed while scaled")
        XCTAssertFalse(spy.forcedSyncLog.contains { $0.wasInPip }, "never synced while scaled")
        let pillFrame = try pillFrameInCanvas(controller)
        XCTAssertEqual(peek.frame.minY, pillFrame.maxY + PillPeekView.anchorGap, accuracy: 0.5)
        XCTAssertTrue(canvas.floatLayerView.frame.contains(peek.frame), "inside the canvas")

        XCTAssertEqual(adapters[agentID]?.lastActivity?.isVisible, true, "renders live while peeked")
        XCTAssertEqual(adapters[agentID]?.lastActivity?.isFocused, false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        waitForLayout("window activation")
        XCTAssertEqual(adapters[agentID]?.lastActivity?.isFocused, false, "a peek never takes focus")
        let responder = controller.window.firstResponder as? NSView
        XCTAssertFalse(responder?.isDescendant(of: pip) == true)
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode.wireName, "minimized")
    }

    func test_hover_out_gives_the_container_back_occluded_with_its_suspension_released_unscaled() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        let spy = try XCTUnwrap(adapters[agentID]?.spyView)
        try hoverPill(in: controller)
        let container = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)
        let floatSize = try floatSize(in: controller)
        spy.suspensionLog.removeAll()

        try unhoverPill(in: controller)

        XCTAssertNil(canvas.pillPeekView.pip)
        XCTAssertNil(canvas.pillPeekView.paneID)
        XCTAssertTrue(canvas.pillPeekView.isHidden)
        XCTAssertNil(container.superview, "unmounted again")
        XCTAssertNil(spy.window)
        XCTAssertEqual(container.terminalViewportSuspensionOwners, [], "the peek let go of its suspension")
        let resume = try XCTUnwrap(spy.suspensionLog.last)
        XCTAssertFalse(resume.suspended)
        XCTAssertFalse(resume.wasInPip, "resumed only once out of the scaled host")
        XCTAssertEqual(resume.containerSize, floatSize, "at the float's own size: the grid does not change")
        XCTAssertEqual(adapters[agentID]?.lastActivity?.isVisible, false, "occluded again")
        XCTAssertEqual(adapters[agentID]?.closeCount, 0)
    }

    func test_hover_out_occludes_at_once_and_gives_back_after_the_fade() throws {
        FloatMotion.reduceMotionOverride = false
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        try hoverPill(in: controller)
        let container = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)

        try unhoverPill(in: controller, settle: false)

        XCTAssertNotNil(canvas.pillPeekView.pip, "still drawn while it fades")
        XCTAssertEqual(adapters[agentID]?.lastActivity?.isVisible, false, "occluded when the fade starts")
        waitForLayout("faded", delay: PillPeekView.fadeDuration + 0.3)
        XCTAssertNil(canvas.pillPeekView.pip)
        XCTAssertNil(container.superview)
        XCTAssertEqual(container.terminalViewportSuspensionOwners, [])
    }

    // MARK: - The pane moves on during a peek

    func test_clicking_the_pill_during_a_peek_restores_from_the_pill() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        let spy = try XCTUnwrap(adapters[agentID]?.spyView)
        try hoverPill(in: controller)
        let lent = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)
        let layer = canvas.floatLayerView
        let bar = canvas.pillBarView
        let pill = try XCTUnwrap(bar.pillViewForTesting(agentID))
        let pillInLayer = layer.convert(pill.frame, from: bar)
        var entries: [(PaneID, FloatEntry)] = []
        layer.onEntryForTesting = { entries.append(($0, $1)) }
        let point = bar.convert(CGPoint(x: pill.frame.midX, y: pill.frame.midY), to: nil)

        try sendDown(at: point, in: controller)
        try send(.leftMouseUp, at: point, in: controller)
        waitForLayout("restored", delay: 0.4)

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode, .floating)
        let host = try XCTUnwrap(layer.floatHostForTesting(agentID))
        let mounted = try XCTUnwrap(layer.containerForTesting(agentID))
        XCTAssertFalse(mounted === lent)
        XCTAssertTrue(spy.isDescendant(of: host), "the float owns the terminal now")
        XCTAssertNil(lent.superview)
        XCTAssertNil(canvas.pillPeekView.pip)
        XCTAssertTrue(canvas.pillPeekView.isHidden)
        XCTAssertEqual(entries.first?.0, agentID)
        XCTAssertEqual(entries.first?.1, .fromFrame(pillInLayer), "the restore grows out of the pill")
        XCTAssertFalse(mounted.isTerminalViewportSyncSuspended)
        XCTAssertFalse(spy.suspensionLog.contains { !$0.suspended && $0.wasInPip })
        XCTAssertEqual(adapters[agentID]?.startCount, 1, "same runtime")
        XCTAssertEqual(adapters[agentID]?.lastActivity?.isVisible, true)
    }

    func test_auto_pop_during_a_peek_mounts_the_pip_from_the_pill() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        let spy = try XCTUnwrap(adapters[agentID]?.spyView)
        try hoverPill(in: controller)
        let lent = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)
        let layer = canvas.floatLayerView
        let pillInLayer = layer.convert(
            try XCTUnwrap(canvas.pillBarView.pillViewForTesting(agentID)).frame,
            from: canvas.pillBarView
        )
        var motions: [(PaneID, CGRect)] = []
        layer.onPipMotionForTesting = { motions.append(($0, $1)) }

        store(controller).applyAgentStatusPayload(payload(.needsInput))
        waitForLayout("popped", delay: 0.3)

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode, .pip(corner: .bottomRight, order: 0))
        let pip = try XCTUnwrap(layer.pipHostForTesting(agentID))
        let mounted = try XCTUnwrap(pip.hostedContainer)
        XCTAssertFalse(mounted === lent)
        XCTAssertTrue(spy.isDescendant(of: pip))
        XCTAssertNil(lent.superview)
        XCTAssertNil(canvas.pillPeekView.pip)
        XCTAssertEqual(mounted.terminalViewportSuspensionOwners, [.pip])
        XCTAssertEqual(motions.first?.0, agentID)
        XCTAssertEqual(motions.first?.1, pillInLayer, "the PiP flies in from the pill")
        XCTAssertFalse(spy.suspensionLog.contains { !$0.suspended && $0.wasInPip })
        XCTAssertEqual(store(controller).activeWorklane?.focusedPaneID, tileID, "the pop never takes focus")
    }

    func test_closing_the_pane_during_a_peek_leaves_no_peek_behind() throws {
        let controller = try makeMinimizedController()
        let canvas = canvas(controller)
        try hoverPill(in: controller)
        let lent = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)

        controller.closePane(id: agentID)
        waitForLayout("closed", delay: 0.4)

        XCTAssertNil(store(controller).activeWorklane?.floatingPane(id: agentID))
        XCTAssertNil(registry?.runtime(for: agentID))
        XCTAssertEqual(adapters[agentID]?.closeCount, 1)
        XCTAssertNil(canvas.pillPeekView.pip)
        XCTAssertNil(canvas.pillPeekView.paneID)
        XCTAssertTrue(canvas.pillPeekView.isHidden)
        XCTAssertNil(lent.superview)
        XCTAssertEqual(canvas.pillPeekedPaneIDs, [])
    }

    // MARK: - Hover helpers

    private func hoverPill(in controller: MainWindowController) throws {
        try XCTUnwrap(canvas(controller).pillBarView.pillViewForTesting(agentID)).setHovered(true)
        waitForLayout("peeked")
    }

    private func unhoverPill(in controller: MainWindowController, settle: Bool = true) throws {
        try XCTUnwrap(canvas(controller).pillBarView.pillViewForTesting(agentID)).setHovered(false)
        if settle {
            waitForLayout("unpeeked")
        }
    }

    private func floatSize(in controller: MainWindowController) throws -> CGSize {
        let float = try XCTUnwrap(store(controller).activeWorklane?.floatingPane(id: agentID))
        return FloatLayerLayout.floatFrame(for: float, canvas: canvas(controller).floatLayerView.bounds).size
    }

    private func pillFrameInCanvas(_ controller: MainWindowController) throws -> CGRect {
        let canvas = canvas(controller)
        let pill = try XCTUnwrap(canvas.pillBarView.pillViewForTesting(agentID))
        return canvas.convert(pill.frame, from: canvas.pillBarView)
    }

    // MARK: - Events

    private func makeEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        in controller: MainWindowController
    ) throws -> NSEvent {
        clock += 0.1
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: clock,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    /// Posted and dequeued, so it is `NSApp.currentEvent` while AppKit
    /// hit-tests it, like a real press.
    private func sendDown(at windowPoint: CGPoint, in controller: MainWindowController) throws {
        NSApp.postEvent(try makeEvent(.leftMouseDown, at: windowPoint, in: controller), atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(
            matching: [.leftMouseDown],
            until: Date(),
            inMode: .default,
            dequeue: true
        ))
        controller.window.sendEvent(dequeued)
    }

    private func send(_ type: NSEvent.EventType, at windowPoint: CGPoint, in controller: MainWindowController) throws {
        controller.window.sendEvent(try makeEvent(type, at: windowPoint, in: controller))
    }

    // MARK: - Fixtures

    private func payload(_ state: PaneAgentState) -> AgentStatusPayload {
        AgentStatusPayload(
            windowID: nil,
            worklaneID: worklaneID,
            paneID: agentID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitAPI,
            toolName: "Claude Code",
            text: state == .needsInput ? "Approval requested" : nil,
            interactionKind: state == .needsInput ? .approval : nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func makeMinimizedController() throws -> MainWindowController {
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

        let shellContext = PaneShellContext(scope: .local, path: "/tmp", home: "/Users/test", user: "test", host: nil)
        let agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            workingDirectory: "/tmp",
            sessionID: sessionID
        )
        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [
                        PaneState(id: tileID, title: "a"),
                        PaneState(id: agentID, title: "b"),
                    ],
                    focusedPaneID: agentID
                ),
                auxiliaryStateByPaneID: [
                    tileID: PaneAuxiliaryState(shellContext: shellContext),
                    agentID: PaneAuxiliaryState(shellContext: shellContext, agentStatus: agentStatus),
                ]
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.4)
        store(controller).minimizePane(agentID)
        waitForLayout("minimized", delay: 0.3)
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode, .minimized(order: 0))
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
