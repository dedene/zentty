import AppKit
import XCTest
@testable import Zentty

/// A float's outset (resize zones included) can reach over tile chrome: the
/// drag bar, the legend link and the dividers. The float's resize cursor
/// rects must be the only ones there, so the chrome leaves the strip's float
/// cursor-exclusion rects out of its cursor rects and doesn't set its own
/// cursor directly while the pointer is inside one.
final class PaneStripChromeFloatCursorExclusionTests: AppKitTestCase {
    private let leftDivider = PaneDivider.column(afterColumnID: PaneColumnID("column-left"))

    @MainActor
    func test_drag_zone_cursor_rects_leave_out_a_float_outset() throws {
        let paneStripView = makePaneStripView()
        paneStripView.render(twoColumnState(), animated: false)
        paneStripView.layoutSubtreeIfNeeded()
        let dragZone = try XCTUnwrap(paneStripView.dragZoneViewForTesting(PaneID("left")))
        let zoneInStrip = paneStripView.convert(dragZone.bounds, from: dragZone)
        XCTAssertEqual(dragZone.cursorRectsForTesting, [dragZone.bounds])

        let outset = CGRect(x: zoneInStrip.midX - 40, y: zoneInStrip.minY - 30, width: 80, height: 60)
        paneStripView.setFloatCursorExclusionRects([outset])

        let rectsInStrip = dragZone.cursorRectsForTesting.map { paneStripView.convert($0, from: dragZone) }
        assertCovers(rectsInStrip, source: zoneInStrip, minus: outset)

        paneStripView.setFloatCursorExclusionRects([])
        XCTAssertEqual(dragZone.cursorRectsForTesting, [dragZone.bounds])
    }

    @MainActor
    func test_drag_zone_does_not_set_its_cursor_where_a_float_owns_the_pointer() throws {
        let paneStripView = makePaneStripView()
        let window = hostInOffscreenWindow(paneStripView)
        paneStripView.render(twoColumnState(), animated: false)
        paneStripView.layoutSubtreeIfNeeded()
        let dragZone = try XCTUnwrap(paneStripView.dragZoneViewForTesting(PaneID("left")))
        let zoneInStrip = paneStripView.convert(dragZone.bounds, from: dragZone)
        let outset = CGRect(x: zoneInStrip.minX, y: zoneInStrip.minY - 30, width: 80, height: 60)
        paneStripView.setFloatCursorExclusionRects([outset])

        let covered = CGPoint(x: outset.midX, y: zoneInStrip.midY)
        let uncovered = CGPoint(x: outset.maxX + 40, y: zoneInStrip.midY)
        let claims = dragZone.cursorClaimCountForTesting

        dragZone.cursorUpdate(with: try cursorUpdateEvent(at: covered, in: paneStripView, window: window))
        XCTAssertEqual(dragZone.cursorClaimCountForTesting, claims, "the float's resize cursor stays")

        dragZone.cursorUpdate(with: try cursorUpdateEvent(at: uncovered, in: paneStripView, window: window))
        XCTAssertEqual(dragZone.cursorClaimCountForTesting, claims + 1)
    }

    @MainActor
    func test_legend_link_cursor_rects_leave_out_a_float_outset() throws {
        let paneStripView = makePaneStripView(width: 980)
        paneStripView.onPaneBorderContextClicked = { _ in }
        let paneID = PaneID("shell")
        paneStripView.render(
            PaneStripState(
                panes: [PaneState(id: paneID, title: "shell", width: 980)],
                focusedPaneID: paneID
            ),
            paneBorderContextByPaneID: [paneID: PaneBorderContextDisplayModel(text: "~/src/zentty")]
        )
        paneStripView.layoutSubtreeIfNeeded()
        let paneView = try XCTUnwrap(paneStripView.paneContainerViewForTesting(paneID))
        let linkInPane = try XCTUnwrap(paneView.interactiveBorderContextFrameInSelf)
        let linkInStrip = paneStripView.convert(linkInPane, from: paneView)
        XCTAssertEqual(paneStripView.borderContextCursorRectsForTesting, [linkInStrip])
        XCTAssertEqual(paneView.borderContextCursorRectsForTesting, [linkInPane])

        let outset = CGRect(x: linkInStrip.minX - 20, y: linkInStrip.minY - 20, width: 50, height: 80)
        paneStripView.setFloatCursorExclusionRects([outset])

        assertCovers(paneStripView.borderContextCursorRectsForTesting, source: linkInStrip, minus: outset)
        assertCovers(
            paneView.borderContextCursorRectsForTesting.map { paneStripView.convert($0, from: paneView) },
            source: linkInStrip,
            minus: outset
        )

        paneStripView.setFloatCursorExclusionRects([])
        XCTAssertEqual(paneStripView.borderContextCursorRectsForTesting, [linkInStrip])
        XCTAssertEqual(paneView.borderContextCursorRectsForTesting, [linkInPane])
    }

    @MainActor
    func test_divider_cursor_rects_leave_out_a_float_outset() throws {
        let paneStripView = makePaneStripView()
        paneStripView.render(twoColumnState(), animated: false)
        paneStripView.layoutSubtreeIfNeeded()
        let dividerFrame = try XCTUnwrap(paneStripView.dividerFrameForTesting(leftDivider))
        XCTAssertEqual(paneStripView.dividerCursorRectsForTesting(leftDivider), [dividerFrame])

        let outset = CGRect(x: dividerFrame.midX - 50, y: dividerFrame.minY - 10, width: 100, height: dividerFrame.height / 2)
        paneStripView.setFloatCursorExclusionRects([outset])

        assertCovers(
            try XCTUnwrap(paneStripView.dividerCursorRectsForTesting(leftDivider)),
            source: dividerFrame,
            minus: outset
        )

        paneStripView.setFloatCursorExclusionRects([])
        XCTAssertEqual(paneStripView.dividerCursorRectsForTesting(leftDivider), [dividerFrame])
    }

    @MainActor
    func test_divider_does_not_set_its_cursor_where_a_float_owns_the_pointer() throws {
        let paneStripView = makePaneStripView()
        let window = hostInOffscreenWindow(paneStripView)
        paneStripView.render(twoColumnState(), animated: false)
        paneStripView.layoutSubtreeIfNeeded()
        let dividerFrame = try XCTUnwrap(paneStripView.dividerFrameForTesting(leftDivider))
        let outset = CGRect(x: dividerFrame.midX - 50, y: dividerFrame.minY - 10, width: 100, height: dividerFrame.height / 2)
        paneStripView.setFloatCursorExclusionRects([outset])

        let covered = CGPoint(x: dividerFrame.midX, y: outset.midY)
        let uncovered = CGPoint(x: dividerFrame.midX, y: outset.maxY + 40)
        let claims = try XCTUnwrap(paneStripView.dividerCursorClaimCountForTesting(leftDivider))

        paneStripView.simulateDividerCursorUpdateForTesting(
            leftDivider,
            with: try cursorUpdateEvent(at: covered, in: paneStripView, window: window)
        )
        XCTAssertEqual(paneStripView.dividerCursorClaimCountForTesting(leftDivider), claims)

        paneStripView.simulateDividerCursorUpdateForTesting(
            leftDivider,
            with: try cursorUpdateEvent(at: uncovered, in: paneStripView, window: window)
        )
        XCTAssertEqual(paneStripView.dividerCursorClaimCountForTesting(leftDivider), claims + 1)
    }

    // MARK: - Helpers

    @MainActor
    private func makePaneStripView(width: CGFloat = 1200, height: CGFloat = 680) -> PaneStripView {
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
        )
        addTeardownBlock {
            MainActor.assumeIsolated {
                paneStripView.prepareForTestingTearDown()
            }
        }
        return paneStripView
    }

    /// A window that is never ordered front: the views get window
    /// coordinates for event locations without showing anything.
    @MainActor
    private func hostInOffscreenWindow(_ paneStripView: PaneStripView) -> NSWindow {
        let window = NSWindow(
            contentRect: paneStripView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        addTeardownBlock {
            window.close()
        }
        window.contentView = paneStripView
        return window
    }

    private func twoColumnState() -> PaneStripState {
        PaneStripState(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 420),
                PaneState(id: PaneID("right"), title: "right", width: 420),
            ],
            focusedPaneID: PaneID("left")
        )
    }

    @MainActor
    private func cursorUpdateEvent(at pointInStrip: CGPoint, in paneStripView: PaneStripView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .cursorUpdate,
                location: paneStripView.convert(pointInStrip, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
    }

    /// `rects` cover exactly `source` minus `cut`: none reaches into `cut`,
    /// and together they hold the rest of `source`.
    private func assertCovers(
        _ rects: [CGRect],
        source: CGRect,
        minus cut: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let overlap = source.intersection(cut)
        XCTAssertFalse(overlap.isNull || overlap.isEmpty, "the cut must reach the source", file: file, line: line)
        XCTAssertFalse(rects.isEmpty, "the uncovered part keeps its cursor", file: file, line: line)
        for rect in rects {
            let inside = rect.intersection(cut)
            XCTAssertTrue(
                inside.isNull || inside.width * inside.height < 0.001,
                "\(rect) reaches into \(cut)",
                file: file,
                line: line
            )
            XCTAssertTrue(source.insetBy(dx: -0.001, dy: -0.001).contains(rect), file: file, line: line)
        }
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        let expected = source.width * source.height - overlap.width * overlap.height
        XCTAssertEqual(area, expected, accuracy: 0.01, file: file, line: line)
    }
}
