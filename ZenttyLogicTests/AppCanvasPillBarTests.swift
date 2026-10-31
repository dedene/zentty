import AppKit
import XCTest
@testable import Zentty

/// The pill bar in the canvas: in flow (the strip gives up its height while
/// pills exist), PiPs stack above it, the peek opens above a hovered pill.
@MainActor
final class AppCanvasPillBarTests: AppKitTestCase {
    private let canvasFrame = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let tileID = PaneID("tile")

    private func makeCanvas() -> AppCanvasView {
        let canvas = AppCanvasView(
            frame: canvasFrame,
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
        )
        canvas.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                canvas.prepareForTestingTearDown()
            }
        }
        return canvas
    }

    private func float(_ id: String, mode: FloatingPaneMode) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: PaneID(id), title: id),
            mode: mode,
            floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            stackOrder: 0,
            origin: nil
        )
    }

    private func render(_ canvas: AppCanvasView, floats: [FloatingPaneState]) {
        let worklane = WorklaneState(
            id: WorklaneID("wl"),
            title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: tileID, title: "tile")], focusedPaneID: tileID),
            floatingPanes: floats
        )
        canvas.render(
            state: worklane.paneStripState,
            floats: FloatLayerContent(worklane: worklane),
            pills: PillBarContent(worklane: worklane),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        canvas.layoutSubtreeIfNeeded()
    }

    func test_pills_take_the_bar_height_from_the_strip_and_give_it_back() {
        let canvas = makeCanvas()
        var heightChanges = 0
        canvas.onPaneViewportHeightChanged = { heightChanges += 1 }

        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])

        XCTAssertEqual(canvas.pillBarReservedHeight, PillBarLayout.barHeight)
        XCTAssertEqual(canvas.paneViewportHeight, canvasFrame.height - PillBarLayout.barHeight)
        XCTAssertEqual(canvas.paneStripView.frame, CGRect(
            x: 0, y: PillBarLayout.barHeight,
            width: canvasFrame.width, height: canvasFrame.height - PillBarLayout.barHeight
        ))
        XCTAssertFalse(canvas.pillBarView.isHidden)
        XCTAssertEqual(canvas.pillBarView.frame.height, PillBarLayout.barHeight)
        XCTAssertEqual(canvas.pillBarView.frame.minY, 0)
        XCTAssertEqual(canvas.floatLayerView.bottomInset, PillBarLayout.barHeight)
        XCTAssertEqual(heightChanges, 1)

        render(canvas, floats: [float("pill", mode: .floating)])

        XCTAssertEqual(canvas.pillBarReservedHeight, 0)
        XCTAssertEqual(canvas.paneStripView.frame, canvasFrame)
        XCTAssertTrue(canvas.pillBarView.isHidden)
        XCTAssertEqual(canvas.floatLayerView.bottomInset, 0)
        XCTAssertEqual(heightChanges, 2)
    }

    func test_bottom_pips_sit_above_the_pill_bar() throws {
        let canvas = makeCanvas()
        render(canvas, floats: [
            float("pip", mode: .pip(corner: .bottomRight, order: 0)),
            float("pill", mode: .minimized(order: 0)),
        ])

        let pip = try XCTUnwrap(canvas.floatLayerView.pipHostForTesting(PaneID("pip")))
        XCTAssertEqual(pip.frame.minY, PillBarLayout.barHeight + FloatLayout.pipMargin)
    }

    func test_pill_bar_sits_above_the_floats() throws {
        let canvas = makeCanvas()
        render(canvas, floats: [
            float("float", mode: .floating),
            float("pill", mode: .minimized(order: 0)),
        ])

        let subviews = canvas.subviews
        let barIndex = try XCTUnwrap(subviews.firstIndex { $0 === canvas.pillBarView })
        let layerIndex = try XCTUnwrap(subviews.firstIndex { $0 === canvas.floatLayerView })
        let peekIndex = try XCTUnwrap(subviews.firstIndex { $0 === canvas.pillPeekView })
        XCTAssertGreaterThan(barIndex, layerIndex)
        XCTAssertGreaterThan(peekIndex, barIndex)
    }

    func test_hovering_a_pill_opens_the_peek_above_it_and_leaving_closes_it() throws {
        let canvas = makeCanvas()
        canvas.pillPeekView.textProvider = { _ in "$ make\nok" }
        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])
        let pill = try XCTUnwrap(canvas.pillBarView.pillViewForTesting(PaneID("pill")))

        pill.setHovered(true)

        let peek = canvas.pillPeekView
        XCTAssertFalse(peek.isHidden)
        XCTAssertTrue(peek.isPolling)
        XCTAssertEqual(peek.paneID, PaneID("pill"))
        let pillInCanvas = canvas.convert(pill.frame, from: canvas.pillBarView)
        XCTAssertEqual(peek.frame.minY, pillInCanvas.maxY + PillPeekView.anchorGap)
        XCTAssertEqual(peek.bodyTextForTesting, "$ make\nok")

        pill.setHovered(false)

        XCTAssertFalse(peek.isPolling)
        XCTAssertNil(peek.paneID)
    }

    func test_restoring_the_hovered_pill_closes_the_peek() throws {
        let canvas = makeCanvas()
        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])
        try XCTUnwrap(canvas.pillBarView.pillViewForTesting(PaneID("pill"))).setHovered(true)
        XCTAssertTrue(canvas.pillPeekView.isPolling)

        render(canvas, floats: [float("pill", mode: .floating)])

        XCTAssertFalse(canvas.pillPeekView.isPolling)
    }

    func test_update_pills_refreshes_status_without_changing_the_set() throws {
        let canvas = makeCanvas()
        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])

        canvas.updatePills(PillBarContent(items: [
            PillBarItem(paneID: PaneID("pill"), name: "pill", subtitle: nil, attention: .needsInput),
        ]))
        XCTAssertEqual(canvas.pillBarView.pillViewForTesting(PaneID("pill"))?.item.attention, .needsInput)

        canvas.updatePills(PillBarContent(items: [
            PillBarItem(paneID: PaneID("other"), name: "other", subtitle: nil, attention: nil),
        ]))
        XCTAssertNil(canvas.pillBarView.pillViewForTesting(PaneID("other")), "a new set needs a full render")
    }
}
