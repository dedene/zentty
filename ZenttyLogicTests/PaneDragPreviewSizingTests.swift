import XCTest
@testable import Zentty

final class PaneDragPreviewSizingTests: XCTestCase {
    func test_sidebarScale_targets_oneQuarter_of_sidebar_bounds_width() {
        let scale = PaneDragPreviewSizing.sidebarScale(
            originalPaneWidth: 1200,
            sidebarBoundsWidth: 280,
            fallbackSidebarWidth: nil
        )

        XCTAssertEqual(scale, 70 / 1200, accuracy: 0.0001)
    }

    func test_sidebarScale_uses_fallback_sidebar_width_when_bounds_are_unavailable() {
        let scale = PaneDragPreviewSizing.sidebarScale(
            originalPaneWidth: 1200,
            sidebarBoundsWidth: 0,
            fallbackSidebarWidth: 320
        )

        XCTAssertEqual(scale, 80 / 1200, accuracy: 0.0001)
    }

    func test_sidebarScale_defaults_to_persisted_sidebar_default_when_no_width_is_available() {
        let scale = PaneDragPreviewSizing.sidebarScale(
            originalPaneWidth: 1200,
            sidebarBoundsWidth: 0,
            fallbackSidebarWidth: 0
        )

        XCTAssertEqual(scale, 70 / 1200, accuracy: 0.0001)
    }

    func test_sidebarScale_does_not_upscale_narrow_panes() {
        let scale = PaneDragPreviewSizing.sidebarScale(
            originalPaneWidth: 48,
            sidebarBoundsWidth: 280,
            fallbackSidebarWidth: nil
        )

        XCTAssertEqual(scale, 1, accuracy: 0.0001)
    }
}

final class PaneDragColumnGapPreviewTests: XCTestCase {
    func test_shouldRefreshInsertionLine_when_gap_index_changes() {
        XCTAssertTrue(
            PaneDragColumnGapPreview.shouldRefreshInsertionLine(
                reducedIndex: 2,
                currentReducedIndex: 1,
                currentStackGapHit: nil,
                isInsertionLineHidden: false,
                lineOrientation: .vertical
            )
        )
    }

    func test_shouldRefreshInsertionLine_when_line_is_hidden_in_same_gap() {
        XCTAssertTrue(
            PaneDragColumnGapPreview.shouldRefreshInsertionLine(
                reducedIndex: 1,
                currentReducedIndex: 1,
                currentStackGapHit: nil,
                isInsertionLineHidden: true,
                lineOrientation: .vertical
            )
        )
    }

    func test_shouldRefreshInsertionLine_when_line_has_wrong_orientation_in_same_gap() {
        XCTAssertTrue(
            PaneDragColumnGapPreview.shouldRefreshInsertionLine(
                reducedIndex: 1,
                currentReducedIndex: 1,
                currentStackGapHit: nil,
                isInsertionLineHidden: false,
                lineOrientation: .horizontal
            )
        )
    }

    func test_shouldRefreshInsertionLine_when_same_gap_line_is_already_visible_and_vertical() {
        XCTAssertFalse(
            PaneDragColumnGapPreview.shouldRefreshInsertionLine(
                reducedIndex: 1,
                currentReducedIndex: 1,
                currentStackGapHit: nil,
                isInsertionLineHidden: false,
                lineOrientation: .vertical
            )
        )
    }
}
