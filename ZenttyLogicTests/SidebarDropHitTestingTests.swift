import CoreGraphics
import XCTest
@testable import Zentty

final class SidebarDropHitTestingTests: XCTestCase {
    func test_target_returns_hovered_non_active_worklane() {
        XCTAssertEqual(
            SidebarDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 152),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .row(WorklaneID("B"))
        )
    }

    func test_target_excludes_active_worklane() {
        XCTAssertEqual(
            SidebarDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 152),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("B"),
                sidebarBottomY: 0
            ),
            .none
        )
    }

    func test_target_returns_new_worklane_below_last_row() {
        XCTAssertEqual(
            SidebarDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 60),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .newWorklane
        )
    }

    func test_target_returns_none_outside_rows_and_new_worklane_zone() {
        XCTAssertEqual(
            SidebarDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 300),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .none
        )
    }

    func test_target_maps_empty_sidebar_lower_area_to_new_worklane() {
        XCTAssertEqual(
            SidebarDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 32),
                worklaneFrames: [],
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane
        )
    }

    private var worklaneFrames: [(WorklaneID, CGRect)] {
        [
            (WorklaneID("A"), CGRect(x: 0, y: 180, width: 220, height: 44)),
            (WorklaneID("B"), CGRect(x: 0, y: 130, width: 220, height: 44)),
            (WorklaneID("C"), CGRect(x: 0, y: 80, width: 220, height: 44)),
        ]
    }
}
