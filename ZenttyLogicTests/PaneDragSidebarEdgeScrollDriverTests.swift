import CoreGraphics
import XCTest
@testable import Zentty

final class PaneDragSidebarEdgeScrollDriverTests: XCTestCase {
    func test_velocity_scrolls_up_near_visual_top_and_down_near_visual_bottom() {
        XCTAssertEqual(
            PaneDragSidebarEdgeScrollDriver.velocity(
                cursorY: 300,
                sidebarMinY: 100,
                sidebarMaxY: 300,
                edgeZone: 60,
                maxSpeed: 600
            ),
            -600,
            accuracy: 0.001
        )

        XCTAssertEqual(
            PaneDragSidebarEdgeScrollDriver.velocity(
                cursorY: 100,
                sidebarMinY: 100,
                sidebarMaxY: 300,
                edgeZone: 60,
                maxSpeed: 600
            ),
            600,
            accuracy: 0.001
        )
    }

    func test_velocity_returns_zero_away_from_sidebar_edges() {
        XCTAssertEqual(
            PaneDragSidebarEdgeScrollDriver.velocity(
                cursorY: 200,
                sidebarMinY: 100,
                sidebarMaxY: 300,
                edgeZone: 60,
                maxSpeed: 600
            ),
            0,
            accuracy: 0.001
        )
    }
}
