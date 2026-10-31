import Carbon.HIToolbox
import XCTest
@testable import Zentty

/// Float commands from a key-down: default shortcut resolution, the
/// availability gate and the router, as the root view controller's shortcut
/// monitor runs them.
@MainActor
final class FloatCommandsHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-commands")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")
    private let otherTileID = PaneID("pane-c")

    private var controller: MainWindowController?
    private var registry: PaneRuntimeRegistry?
    private var adapters: [PaneID: HostedSpyTerminalAdapter] = [:]
    private var clock: TimeInterval = 3_000

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

    func test_cmd_w_closes_focused_float_only() throws {
        let controller = try makeFloatedController()

        try press("w", keyCode: kVK_ANSI_W, modifiers: [.command], in: controller)
        waitForLayout("closed")

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [tileID, otherTileID])
        XCTAssertEqual(adapters[floatID]?.closeCount, 1)
        XCTAssertEqual(adapters[tileID]?.closeCount, 0)
        XCTAssertEqual(adapters[otherTileID]?.closeCount, 0)
    }

    func test_option_command_m_minimizes_focused_float() throws {
        let controller = try makeFloatedController()

        try press("m", keyCode: kVK_ANSI_M, modifiers: [.command, .option], in: controller)
        waitForLayout("minimized")

        XCTAssertEqual(store(controller).activeWorklane?.floatingPane(id: floatID)?.mode, .minimized(order: 0))
        XCTAssertNil(canvas(controller).floatLayerView.containerForTesting(floatID))
        XCTAssertEqual(adapters[floatID]?.closeCount, 0, "minimized floats keep running")
        XCTAssertFalse(controller.window.isMiniaturized, "⌥⌘M is not the window's ⌘M")
    }

    func test_option_command_p_pips_focused_float() throws {
        let controller = try makeFloatedController()

        try press("p", keyCode: kVK_ANSI_P, modifiers: [.command, .option], in: controller)
        waitForLayout("pipped", delay: 0.3)

        XCTAssertEqual(
            store(controller).activeWorklane?.floatingPane(id: floatID)?.mode,
            .pip(corner: .bottomRight, order: 0)
        )
        XCTAssertNotNil(canvas(controller).floatLayerView.pipHostForTesting(floatID))
    }

    func test_option_command_period_hides_and_shows_floats() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView

        try press(".", keyCode: kVK_ANSI_Period, modifiers: [.command, .option], in: controller)
        waitForLayout("hidden")

        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, true)
        XCTAssertNil(layer.containerForTesting(floatID))
        XCTAssertTrue(controller.rootViewControllerForTesting.floatsAreHidden)
        let menuItem = NSMenuItem(
            title: "",
            action: #selector(MainWindowController.toggleFloatsHidden(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Show Floating Panes")

        try press(".", keyCode: kVK_ANSI_Period, modifiers: [.command, .option], in: controller)
        waitForLayout("shown")

        XCTAssertEqual(store(controller).activeWorklane?.floatsHidden, false)
        XCTAssertNotNil(layer.containerForTesting(floatID))
        XCTAssertEqual(adapters[floatID]?.closeCount, 0)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Hide Floating Panes")
    }

    func test_option_command_n_opens_centred_float_with_focus() throws {
        let controller = try makeSeededController()
        let layer = canvas(controller).floatLayerView

        try press("n", keyCode: kVK_ANSI_N, modifiers: [.command, .option], in: controller)
        waitForLayout("opened", delay: 0.3)

        let worklane = try XCTUnwrap(store(controller).activeWorklane)
        let float = try XCTUnwrap(worklane.floatingPanes.first)
        XCTAssertEqual(worklane.floatingPanes.count, 1)
        XCTAssertTrue(worklane.floatOwnsFocus)
        XCTAssertEqual(worklane.focusedFloatID, float.pane.id)
        XCTAssertEqual(worklane.paneStripState.panes.count, 3, "the strip is untouched")
        let frame = try XCTUnwrap(layer.floatHostForTesting(float.pane.id)?.paneFrame)
        XCTAssertEqual(frame.midX, layer.bounds.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, layer.bounds.midY, accuracy: 1)
        XCTAssertEqual(frame.width, (layer.bounds.width * 0.6).rounded(), accuracy: 1)
    }

    func test_option_command_backtick_cycles_floats() throws {
        let controller = try makeFloatedController()
        store(controller).focusPane(id: tileID)
        waitForLayout("tile focused")
        XCTAssertFalse(store(controller).activeWorklane?.floatOwnsFocus ?? true)

        try press("`", keyCode: kVK_ANSI_Grave, modifiers: [.command, .option], in: controller)
        waitForLayout("cycled")

        XCTAssertEqual(store(controller).activeWorklane?.focusedPaneID, floatID)
    }

    func test_find_targets_focused_float() throws {
        let controller = try makeFloatedController()
        let floatHost = try XCTUnwrap(registry?.runtime(for: floatID)?.hostView)
        let tileHost = try XCTUnwrap(registry?.runtime(for: tileID)?.hostView)

        try press("f", keyCode: kVK_ANSI_F, modifiers: [.command], in: controller)
        waitForLayout("search shown")

        XCTAssertFalse(floatHost.isSearchHUDHiddenForTesting, "find opens on the focused float")
        XCTAssertTrue(tileHost.isSearchHUDHiddenForTesting)
    }

    func test_float_commands_ignored_during_divider_drag() throws {
        let controller = try makeFloatedController()
        let strip = canvas(controller).paneStripView
        let firstColumn = try XCTUnwrap(store(controller).activeWorklane?.paneStripState.columns.first?.id)
        _ = try XCTUnwrap(strip.beginDividerDragForTesting(
            .column(afterColumnID: firstColumn),
            locationInDividerView: CGPoint(x: 4, y: 2)
        ))
        XCTAssertTrue(strip.isDividerDragActive)
        let before = try XCTUnwrap(store(controller).activeWorklane)

        try press("m", keyCode: kVK_ANSI_M, modifiers: [.command, .option], in: controller)
        try press(".", keyCode: kVK_ANSI_Period, modifiers: [.command, .option], in: controller)
        try press("n", keyCode: kVK_ANSI_N, modifiers: [.command, .option], in: controller)
        controller.toggleFloat(nil)
        waitForLayout("ignored")

        let after = try XCTUnwrap(store(controller).activeWorklane)
        XCTAssertEqual(after.floatingPanes.map(\.pane.id), before.floatingPanes.map(\.pane.id))
        XCTAssertEqual(after.floatingPane(id: floatID)?.mode, .floating)
        XCTAssertFalse(after.floatsHidden)
        XCTAssertEqual(after.paneStripState.panes.map(\.id), before.paneStripState.panes.map(\.id))
        strip.cancelDividerDragForTesting()
    }

    // MARK: - Events

    /// Resolves a key-down the way the root view controller's shortcut
    /// monitor does (default bindings, availability gate) and hands the
    /// action to it. The hosted app can't be the key window (`.prohibited`
    /// activation), so the monitor's key-window check is the only step skipped.
    private func press(
        _ character: String,
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        in controller: MainWindowController
    ) throws {
        clock += 0.05
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: clock,
            windowNumber: controller.window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
        let shortcut = try XCTUnwrap(KeyboardShortcut(event: event))
        let commandID = try XCTUnwrap(ShortcutManager(shortcuts: .default).commandID(for: shortcut))
        let root = controller.rootViewControllerForTesting
        guard root.isCommandAvailable(commandID) else { return }
        root.handle(AppCommandRegistry.definition(for: commandID).action)
    }

    // MARK: - Fixtures

    private func makeFloatedController() throws -> MainWindowController {
        let controller = try makeSeededController()
        controller.toggleFloat(nil)
        waitForLayout("floated", delay: 0.4)
        XCTAssertTrue(store(controller).activeWorklane?.floatOwnsFocus == true)
        return controller
    }

    private func makeSeededController() throws -> MainWindowController {
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
                    panes: [
                        PaneState(id: tileID, title: "a"),
                        PaneState(id: floatID, title: "b"),
                        PaneState(id: otherTileID, title: "c"),
                    ],
                    focusedPaneID: floatID
                )
            ),
        ], activeWorklaneID: worklaneID)
        waitForLayout("seeded")
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
