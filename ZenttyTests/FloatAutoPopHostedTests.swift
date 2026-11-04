import XCTest
@testable import Zentty

/// Auto-pop and the hide-all capsule through the real window: a pill whose
/// agent needs input mounts as a bottom-right PiP without taking focus and
/// goes back when the agent resumes; the title-bar capsule counts floats +
/// PiPs and a real click hides and shows them.
@MainActor
final class FloatAutoPopHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-autopop")
    private let tileID = PaneID("pane-a")
    private let agentID = PaneID("pane-b")
    private let sessionID = "0c7a3a9e-0d1c-4f3e-8f0e-5a7d1e2b3c4d"

    private var controller: MainWindowController?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        adapters = [:]
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: - Auto-pop

    func test_needs_input_pops_the_pill_as_a_pip_and_resume_puts_it_back() throws {
        let controller = try makeFloatedController()
        store(controller).minimizePane(agentID)
        waitForLayout("minimized")
        XCTAssertNotNil(canvas(controller).pillBarView.pillViewForTesting(agentID), "precondition: pill")
        let spy = try XCTUnwrap(adapters[agentID]?.spyView)
        spy.suspensionLog.removeAll()
        spy.forcedSyncLog.removeAll()

        store(controller).applyAgentStatusPayload(payload(.needsInput))
        waitForLayout("popped")

        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(agentID))
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode, .pip(corner: .bottomRight, order: 0))
        XCTAssertNil(canvas(controller).pillBarView.pillViewForTesting(agentID))
        let layerBounds = canvas(controller).floatLayerView.bounds
        XCTAssertGreaterThan(pip.frame.midX, layerBounds.midX, "bottom-trailing corner")
        XCTAssertLessThan(pip.frame.midY, layerBounds.midY)
        XCTAssertEqual(store(controller).activeWorklane?.focusedPaneID, tileID, "the pop never takes focus")
        let responder = controller.window.firstResponder as? NSView
        XCTAssertFalse(responder?.isDescendant(of: pip) == true)
        XCTAssertFalse(spy.suspensionLog.contains { !$0.suspended && $0.wasInPip }, "never resumed while scaled")

        store(controller).applyAgentStatusPayload(payload(.running))
        waitForLayout("returned")

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode.wireName, "minimized")
        XCTAssertNil(canvas(controller).floatLayerView.pipHostForTesting(agentID))
        XCTAssertNotNil(canvas(controller).pillBarView.pillViewForTesting(agentID))
        XCTAssertEqual(adapters[agentID]?.closeCount ?? 0, 0, "the process lives through the round trip")
    }

    /// Regression: the touch used to land only on mouse-up, so an agent
    /// resuming mid-drag sent the popped PiP back to its pill (unmounting it
    /// under the pointer and dropping the drag).
    func test_resume_mid_drag_keeps_the_popped_pip_under_the_pointer() throws {
        let controller = try makeFloatedController()
        store(controller).minimizePane(agentID)
        waitForLayout("minimized")
        store(controller).applyAgentStatusPayload(payload(.needsInput))
        waitForLayout("popped")
        let pip = try XCTUnwrap(canvas(controller).floatLayerView.pipHostForTesting(agentID))
        let start = pip.convert(CGPoint(x: pip.bounds.midX, y: pip.bounds.midY), to: nil)

        pip.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: start, in: controller)))
        pip.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: CGPoint(x: start.x - 80, y: start.y + 40), in: controller)))
        store(controller).applyAgentStatusPayload(payload(.running))
        waitForLayout("resumed mid-drag")

        XCTAssertTrue(canvas(controller).floatLayerView.pipHostForTesting(agentID) === pip, "still mounted")
        XCTAssertNotNil(pip.drag, "the drag survives")
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode, .pip(corner: .bottomRight, order: 0))
        pip.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: CGPoint(x: start.x - 80, y: start.y + 40), in: controller)))
        waitForLayout("released")
        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: agentID)?.mode.wireName, "pip", "the user placed it")
    }

    func test_hidden_floats_keep_the_pill_amber_and_stay_hidden() throws {
        let controller = try makeFloatedController()
        store(controller).minimizePane(agentID)
        store(controller).setFloatsHidden(true)
        waitForLayout("hidden")

        store(controller).applyAgentStatusPayload(payload(.needsInput))
        waitForLayout("needs input")

        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, true)
        XCTAssertNil(canvas(controller).floatLayerView.pipHostForTesting(agentID))
        XCTAssertNotNil(canvas(controller).pillBarView.pillViewForTesting(agentID))
    }

    // MARK: - Hide-all capsule

    func test_capsule_counts_floats_and_pips_and_hides_at_zero() throws {
        let controller = try makeFloatedController()
        let chrome = controller.rootViewControllerForTesting.windowChromeViewForTesting
        XCTAssertEqual(chrome.floatVisibilityCapsuleForTesting.capsuleState.count, 1)
        XCTAssertGreaterThan(chrome.floatVisibilityControlFrame.width, 0)

        store(controller).pipPane(agentID)
        waitForLayout("pip")
        XCTAssertEqual(chrome.floatVisibilityCapsuleForTesting.capsuleState.count, 1, "a PiP counts")

        store(controller).minimizePane(agentID)
        waitForLayout("pill")
        XCTAssertEqual(chrome.floatVisibilityControlFrame, .zero, "pills don't count; hidden at zero")
    }

    func test_capsule_click_hides_and_shows_floats() throws {
        let controller = try makeFloatedController()
        let chrome = controller.rootViewControllerForTesting.windowChromeViewForTesting
        chrome.layoutSubtreeIfNeeded()
        let capsule = chrome.floatVisibilityCapsuleForTesting
        let point = capsule.convert(CGPoint(x: capsule.bounds.midX, y: capsule.bounds.midY), to: nil)
        let contentView = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(contentView.hitTest(contentView.convert(point, from: nil)) === capsule, "the capsule owns the click")

        try sendClick(at: point, in: controller)
        waitForLayout("hidden")

        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, true)
        XCTAssertTrue(capsule.capsuleState.isHidden)
        XCTAssertEqual(capsule.capsuleState.symbolName, "eye.slash")
        XCTAssertFalse(capsule.isHidden, "still there to bring them back")
        XCTAssertNil(canvas(controller).floatLayerView.floatHostForTesting(agentID))

        try sendClick(at: point, in: controller)
        waitForLayout("shown")

        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, false)
        XCTAssertFalse(capsule.capsuleState.isHidden)
        XCTAssertNotNil(canvas(controller).floatLayerView.floatHostForTesting(agentID))
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

    private func sendClick(at windowPoint: CGPoint, in controller: MainWindowController) throws {
        let mouseDown = try XCTUnwrap(mouseEvent(.leftMouseDown, at: windowPoint, in: controller))
        let mouseUp = try XCTUnwrap(mouseEvent(.leftMouseUp, at: windowPoint, in: controller))
        NSApp.postEvent(mouseUp, atStart: false)
        controller.window.sendEvent(mouseDown)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in controller: MainWindowController) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private func makeFloatedController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = HostedSpyTerminalAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let controller = MainWindowController(runtimeRegistry: registry).prepareForHostedTesting()
        self.controller = controller
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
        XCTAssertTrue(store(controller).activeWorklane?.isFloating(agentID) == true)
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
        wait(for: [settled], timeout: 2.0)
    }
}
