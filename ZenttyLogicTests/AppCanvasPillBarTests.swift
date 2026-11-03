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

    func test_hovering_a_pill_lends_its_live_container_to_a_pip_above_it_and_leaving_gives_it_back() throws {
        let canvas = makeCanvas()
        let pillID = PaneID("pill")
        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])
        let pill = try XCTUnwrap(canvas.pillBarView.pillViewForTesting(pillID))
        var changes = 0
        canvas.onPillPeekChanged = { changes += 1 }

        pill.setHovered(true)

        let peek = canvas.pillPeekView
        XCTAssertFalse(peek.isHidden)
        XCTAssertEqual(peek.paneID, pillID)
        XCTAssertEqual(canvas.pillPeekedPaneIDs, [pillID])
        XCTAssertEqual(changes, 1)
        let pip = try XCTUnwrap(peek.pip)
        XCTAssertTrue(pip.isDisplayOnly)
        let container = try XCTUnwrap(pip.hostedContainer)
        XCTAssertNil(canvas.floatLayerView.containerForTesting(pillID), "lent, not mounted in the layer")
        XCTAssertTrue(container.terminalViewportSuspensionOwners.contains(.pillPeek))
        let floatSize = CGSize(width: 500, height: 300)
        // Bounds scaling: the scaled view keeps the float's size (AppKit
        // rounds a bounds it derives from a scaled frame).
        XCTAssertEqual(pip.scaleViewForTesting.bounds.width, floatSize.width, accuracy: 0.001)
        XCTAssertEqual(pip.scaleViewForTesting.bounds.height, floatSize.height, accuracy: 0.001)
        XCTAssertEqual(container.frame.size, floatSize)
        let pipSize = FloatLayout.pipSize(floatSize: floatSize, width: canvas.floatLayerView.pipWidth)
        XCTAssertEqual(peek.frame.size, pipSize)
        XCTAssertEqual(pip.frame, CGRect(origin: .zero, size: pipSize))
        let pillInCanvas = canvas.convert(pill.frame, from: canvas.pillBarView)
        XCTAssertEqual(peek.frame.minY, pillInCanvas.maxY + PillPeekView.anchorGap)
        XCTAssertNil(peek.hitTest(CGPoint(x: peek.frame.midX, y: peek.frame.midY)), "display only")

        pill.setHovered(false)

        XCTAssertNil(peek.paneID)
        XCTAssertNil(peek.pip)
        XCTAssertNil(container.superview, "given back and dropped")
        XCTAssertEqual(canvas.pillPeekedPaneIDs, [])
        XCTAssertEqual(changes, 2)
    }

    func test_restoring_the_hovered_pill_gives_the_container_back_before_the_layer_mounts_it() throws {
        let canvas = makeCanvas()
        let pillID = PaneID("pill")
        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])
        try XCTUnwrap(canvas.pillBarView.pillViewForTesting(pillID)).setHovered(true)
        let lent = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)

        render(canvas, floats: [float("pill", mode: .floating)])

        XCTAssertNil(canvas.pillPeekView.paneID)
        XCTAssertNil(canvas.pillPeekView.pip)
        XCTAssertTrue(canvas.pillPeekView.isHidden)
        XCTAssertNil(lent.superview)
        let mounted = try XCTUnwrap(canvas.floatLayerView.containerForTesting(pillID))
        XCTAssertFalse(mounted === lent)
        XCTAssertTrue(mounted.superview is FloatContainerView)
    }

    func test_hovering_another_pill_swaps_the_loan() throws {
        let canvas = makeCanvas()
        render(canvas, floats: [
            float("one", mode: .minimized(order: 0)),
            float("two", mode: .minimized(order: 1)),
        ])
        let one = try XCTUnwrap(canvas.pillBarView.pillViewForTesting(PaneID("one")))
        let two = try XCTUnwrap(canvas.pillBarView.pillViewForTesting(PaneID("two")))
        one.setHovered(true)
        let first = try XCTUnwrap(canvas.pillPeekView.pip?.hostedContainer)

        two.setHovered(true)
        one.setHovered(false)

        XCTAssertEqual(canvas.pillPeekView.paneID, PaneID("two"))
        XCTAssertEqual(canvas.pillPeekView.pip?.paneID, PaneID("two"))
        XCTAssertNil(first.superview)
        XCTAssertEqual(canvas.pillPeekedPaneIDs, [PaneID("two")])
    }

    func test_update_pills_refreshes_status_without_changing_the_set() throws {
        let canvas = makeCanvas()
        render(canvas, floats: [float("pill", mode: .minimized(order: 0))])
        try XCTUnwrap(canvas.pillBarView.pillViewForTesting(PaneID("pill"))).setHovered(true)

        canvas.updatePills(PillBarContent(items: [
            PillBarItem(paneID: PaneID("pill"), name: "pill", subtitle: nil, attention: .needsInput),
        ]))
        XCTAssertEqual(canvas.pillBarView.pillViewForTesting(PaneID("pill"))?.item.attention, .needsInput)
        XCTAssertEqual(canvas.pillPeekView.pip?.status?.attention, .needsInput, "the peek's strip follows")

        canvas.updatePills(PillBarContent(items: [
            PillBarItem(paneID: PaneID("other"), name: "other", subtitle: nil, attention: nil),
        ]))
        XCTAssertNil(canvas.pillBarView.pillViewForTesting(PaneID("other")), "a new set needs a full render")
    }
}
