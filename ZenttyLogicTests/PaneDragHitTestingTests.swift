import XCTest
@testable import Zentty

final class PaneDragHitTestingTests: XCTestCase {
    func test_stackReorderGapHit_detects_gap_between_panes() {
        let columns = [
            ColumnPresentation(
                columnID: PaneColumnID("stack"),
                frame: CGRect(x: 0, y: 0, width: 320, height: 920),
                panes: [
                    PanePresentation(
                        paneID: PaneID("top"),
                        columnID: PaneColumnID("stack"),
                        frame: CGRect(x: 0, y: 620, width: 320, height: 300),
                        emphasis: 1,
                        isFocused: false
                    ),
                    PanePresentation(
                        paneID: PaneID("middle"),
                        columnID: PaneColumnID("stack"),
                        frame: CGRect(x: 0, y: 300, width: 320, height: 300),
                        emphasis: 1,
                        isFocused: false
                    ),
                    PanePresentation(
                        paneID: PaneID("bottom"),
                        columnID: PaneColumnID("stack"),
                        frame: CGRect(x: 0, y: 0, width: 320, height: 280),
                        emphasis: 1,
                        isFocused: false
                    ),
                ]
            )
        ]

        let hit = PaneDragHitTest.stackReorderGapHit(
            cursorInContent: CGPoint(x: 160, y: 610),
            visibleColumns: columns,
            zoomScale: 1,
            previousHit: nil
        )

        XCTAssertEqual(hit, StackReorderGapHit(columnID: PaneColumnID("stack"), paneIndex: 1))
    }

    func test_stackReorderGapHit_retains_active_gap_within_retention_band() {
        let columns = [
            ColumnPresentation(
                columnID: PaneColumnID("stack"),
                frame: CGRect(x: 0, y: 0, width: 320, height: 920),
                panes: [
                    PanePresentation(
                        paneID: PaneID("top"),
                        columnID: PaneColumnID("stack"),
                        frame: CGRect(x: 0, y: 620, width: 320, height: 300),
                        emphasis: 1,
                        isFocused: false
                    ),
                    PanePresentation(
                        paneID: PaneID("middle"),
                        columnID: PaneColumnID("stack"),
                        frame: CGRect(x: 0, y: 300, width: 320, height: 300),
                        emphasis: 1,
                        isFocused: false
                    ),
                ]
            )
        ]

        let previousHit = StackReorderGapHit(columnID: PaneColumnID("stack"), paneIndex: 1)
        let hit = PaneDragHitTest.stackReorderGapHit(
            cursorInContent: CGPoint(x: 160, y: 588),
            visibleColumns: columns,
            zoomScale: 1,
            previousHit: previousHit
        )

        XCTAssertEqual(hit, previousHit)
    }

    func test_stackReorderGapHit_uses_outer_gap_center_not_pane_edge() {
        let columns = [
            ColumnPresentation(
                columnID: PaneColumnID("stack"),
                frame: CGRect(x: 0, y: 0, width: 320, height: 920),
                panes: [
                    PanePresentation(
                        paneID: PaneID("only"),
                        columnID: PaneColumnID("stack"),
                        frame: CGRect(x: 0, y: 20, width: 320, height: 880),
                        emphasis: 1,
                        isFocused: false
                    )
                ]
            )
        ]

        let edgeHit = PaneDragHitTest.stackReorderGapHit(
            cursorInContent: CGPoint(x: 160, y: 892),
            visibleColumns: columns,
            zoomScale: 1,
            previousHit: nil
        )
        let gapHit = PaneDragHitTest.stackReorderGapHit(
            cursorInContent: CGPoint(x: 160, y: 910),
            visibleColumns: columns,
            zoomScale: 1,
            previousHit: nil
        )

        XCTAssertNil(edgeHit)
        XCTAssertEqual(gapHit, StackReorderGapHit(columnID: PaneColumnID("stack"), paneIndex: 0))
    }

}
