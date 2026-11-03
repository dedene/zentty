import XCTest
@testable import Zentty

/// Mode-change motion through the real window, sampled from the layers'
/// presentation mid-flight (the code path running is not enough: these
/// check something is actually drawn in between). Reduce Motion is pinned
/// off.
@MainActor
final class FloatTransitionsHostedTests: XCTestCase {
    private let worklaneID = WorklaneID("wl-motion")
    private let tileID = PaneID("pane-a")
    private let floatID = PaneID("pane-b")

    private var controller: MainWindowController?

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = false
    }

    override func tearDown() {
        controller?.closeWindowBypassingConfirmation()
        controller = nil
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    func test_minimize_flies_the_float_into_its_pill() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        var departures: [FloatDeparture] = []
        layer.onDepartureForTesting = { _, departure in departures.append(departure) }

        store(controller).minimizePane(floatID)

        let pill = try XCTUnwrap(canvas(controller).pillBarView.pillViewForTesting(floatID))
        let pillInLayer = layer.convert(pill.frame, from: canvas(controller).pillBarView)
        XCTAssertEqual(departures, [.toFrame(pillInLayer)])
        XCTAssertEqual(layer.departingPaneIDsForTesting, [floatID])
        XCTAssertIdentical(host.superview, layer, "the float keeps drawing while it leaves")
        XCTAssertNil(layer.floatHostForTesting(floatID), "but the layer no longer counts it")
        XCTAssertNotNil(pill.layer?.animation(forKey: PillBarView.arrivalAnimationKey))

        waitFor(0.12)
        let ghost = try XCTUnwrap(host.layer?.presentation())
        XCTAssertLessThan(ghost.opacity, 0.95, "fading out")
        XCTAssertLessThan(ghost.frame.width, host.frame.width - 1, "shrinking toward the pill")
        let pillDrawn = try XCTUnwrap(pill.layer?.presentation())
        XCTAssertGreaterThan(pillDrawn.frame.width, pill.frame.width + 1, "the pill grows out of the float")

        waitFor(0.5)
        XCTAssertTrue(layer.departingPaneIDsForTesting.isEmpty)
        XCTAssertNil(host.superview, "gone once faded")
    }

    func test_restore_from_the_pill_grows_the_float_out_of_it() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        store(controller).minimizePane(floatID)
        waitFor(0.6)
        let pill = try XCTUnwrap(canvas(controller).pillBarView.pillViewForTesting(floatID))
        let pillInLayer = layer.convert(pill.frame, from: canvas(controller).pillBarView)
        var entries: [FloatEntry] = []
        layer.onEntryForTesting = { _, entry in entries.append(entry) }

        store(controller).restoreFloat(floatID)

        XCTAssertEqual(entries, [.fromFrame(pillInLayer)])
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        waitFor(0.1)
        let drawn = try XCTUnwrap(host.layer?.presentation())
        XCTAssertLessThan(drawn.opacity, 0.98, "fading in from 0.2")
        XCTAssertLessThan(drawn.frame.width, host.frame.width - 1, "still growing out of the pill")
    }

    func test_pip_to_pill_and_back_morph() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        store(controller).pipPane(floatID)
        waitFor(0.9)
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))

        store(controller).minimizePane(floatID)
        XCTAssertEqual(layer.departingPaneIDsForTesting, [floatID], "the PiP flies into its pill")
        XCTAssertIdentical(pip.superview, layer)
        waitFor(0.6)
        XCTAssertNil(pip.superview)

        var motions: [CGRect] = []
        layer.onPipMotionForTesting = { _, frame in motions.append(frame) }
        store(controller).pipPane(floatID)
        let newPip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        XCTAssertEqual(motions.count, 1, "springs out of the pill")
        XCTAssertNotNil(newPip.layer?.animation(forKey: FloatLayerView.fadeAnimationKey), "and fades in")
    }

    func test_hide_and_show_all_fade() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        var departures: [FloatDeparture] = []
        layer.onDepartureForTesting = { _, departure in departures.append(departure) }

        store(controller).toggleFloatsHidden()

        XCTAssertEqual(departures, [.hide])
        waitFor(0.08)
        XCTAssertLessThan(host.layer?.presentation()?.opacity ?? 1, 0.95)
        waitFor(0.4)
        XCTAssertNil(host.superview)

        var entries: [FloatEntry] = []
        layer.onEntryForTesting = { _, entry in entries.append(entry) }
        store(controller).toggleFloatsHidden()
        XCTAssertEqual(entries, [.reveal])
        let shown = try XCTUnwrap(layer.floatHostForTesting(floatID))
        waitFor(0.05)
        XCTAssertLessThan(shown.layer?.presentation()?.opacity ?? 1, 0.98, "fading in")
    }

    func test_close_fades_a_copy_that_takes_no_clicks() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let center = layer.convert(CGPoint(x: host.frame.midX, y: host.frame.midY), to: nil)
        var departures: [FloatDeparture] = []
        layer.onDepartureForTesting = { _, departure in departures.append(departure) }

        controller.rootViewControllerForTesting.handlePaneBorderAction(.close, paneID: floatID)

        XCTAssertEqual(departures, [.close])
        XCTAssertTrue(store(controller).activeWorklane?.containsPane(id: floatID) == false, "already closed")
        let contentView = try XCTUnwrap(controller.window.contentView)
        let hit = contentView.hitTest(contentView.convert(center, from: nil))
        XCTAssertFalse(hit?.isDescendant(of: host) == true, "the leaving copy is click-through")
        waitFor(0.4)
        XCTAssertNil(host.superview)
    }

    func test_closing_a_pill_from_its_own_action_fades_it_like_a_float() throws {
        let controller = try makeFloatedController()
        store(controller).minimizePane(floatID)
        waitFor(0.5)
        let bar = canvas(controller).pillBarView
        let pill = try XCTUnwrap(bar.pillViewForTesting(floatID))
        let size = pill.frame.size

        controller.rootViewControllerForTesting.handlePaneBorderAction(.close, paneID: floatID)

        XCTAssertTrue(store(controller).activeWorklane?.containsPane(id: floatID) == false, "already closed")
        XCTAssertEqual(bar.closingPaneIDsForTesting, [floatID])
        XCTAssertIdentical(pill.superview, bar)
        XCTAssertFalse(bar.isHidden, "the bar waits for the fade")
        waitFor(0.08)
        let drawn = try XCTUnwrap(pill.layer?.presentation())
        XCTAssertLessThan(drawn.opacity, 0.95, "fading out")
        XCTAssertLessThan(drawn.frame.width, size.width - 0.1, "shrinking a little")

        waitFor(0.4)
        XCTAssertNil(pill.superview, "gone once faded")
        XCTAssertTrue(bar.isHidden)
    }

    func test_restoring_while_the_copy_still_leaves_drops_the_copy() throws {
        let controller = try makeFloatedController()
        let layer = canvas(controller).floatLayerView
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))

        store(controller).minimizePane(floatID)
        store(controller).restoreFloat(floatID)

        XCTAssertTrue(layer.departingPaneIDsForTesting.isEmpty)
        XCTAssertNil(host.superview, "its terminal went to the new float")
        XCTAssertNotNil(layer.floatHostForTesting(floatID))
    }

    func test_dock_button_flies_the_tile_from_the_float() throws {
        let controller = try makeFloatedController()
        let floatFrame = try XCTUnwrap(canvas(controller).floatLayerView.floatHostForTesting(floatID)?.paneFrame)

        controller.rootViewControllerForTesting.handlePaneBorderAction(.dock, paneID: floatID)
        waitFor(0.08)

        let tile = try XCTUnwrap(canvas(controller).paneStripView.paneContainerViewForTesting(floatID))
        let drawn = try XCTUnwrap(tile.layer?.presentation()?.frame)
        let finalFrame = tile.frame
        let start = tile.superview.map { $0.convert(floatFrame, from: canvas(controller).floatLayerView) } ?? .zero
        XCTAssertGreaterThan(abs(drawn.width - finalFrame.width), 1, "mid-flight, not at its slot yet")
        XCTAssertLessThan(abs(drawn.midX - start.midX), abs(finalFrame.midX - start.midX), "on its way from the float")
    }

    // MARK: - Fixtures

    private func makeFloatedController() throws -> MainWindowController {
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in HostedSpyTerminalAdapter() })
        let controller = MainWindowController(runtimeRegistry: registry, configStore: nil)
            .prepareForHostedTesting()
        self.controller = controller
        controller.showWindow(nil)
        waitFor(0.15)
        controller.rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [PaneState(id: tileID, title: "a"), PaneState(id: floatID, title: "b")],
                    focusedPaneID: floatID
                ),
                auxiliaryStateByPaneID: [:]
            ),
        ], activeWorklaneID: worklaneID)
        waitFor(0.15)
        controller.toggleFloat(nil)
        waitFor(0.6)
        XCTAssertTrue(store(controller).activeWorklane?.isFloating(floatID) == true)
        return controller
    }

    private func store(_ controller: MainWindowController) -> WorklaneStore {
        controller.rootViewControllerForTesting.worklaneStore
    }

    private func canvas(_ controller: MainWindowController) -> AppCanvasView {
        controller.rootViewControllerForTesting.appCanvasViewForTesting
    }

    private func waitFor(_ delay: TimeInterval) {
        let settled = expectation(description: "waited \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settled.fulfill() }
        wait(for: [settled], timeout: delay + 2)
    }
}
