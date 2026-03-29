@testable import Zentty
import XCTest

final class RecentCommandsTrackerTests: XCTestCase {
    func testEmptyByDefault() {
        let tracker = RecentCommandsTracker()
        XCTAssertTrue(tracker.recentCommandIDs.isEmpty)
    }

    func testRecordsCommand() {
        var tracker = RecentCommandsTracker()
        tracker.record(.toggleSidebar)
        XCTAssertEqual(tracker.recentCommandIDs, [.toggleSidebar])
    }

    func testDuplicatesMovedToFront() {
        var tracker = RecentCommandsTracker()
        tracker.record(.toggleSidebar)
        tracker.record(.newWorklane)
        tracker.record(.toggleSidebar)
        XCTAssertEqual(tracker.recentCommandIDs, [.toggleSidebar, .newWorklane])
    }

    func testCapsAtEight() {
        var tracker = RecentCommandsTracker()
        let commands: [AppCommandID] = [
            .toggleSidebar, .newWorklane, .nextWorklane, .previousWorklane,
            .splitHorizontally, .splitVertically, .closeFocusedPane, .focusLeftPane,
            .focusRightPane,
        ]
        for command in commands {
            tracker.record(command)
        }
        XCTAssertEqual(tracker.recentCommandIDs.count, 8)
        XCTAssertEqual(tracker.recentCommandIDs.first, .focusRightPane)
    }

    func testMostRecentFirst() {
        var tracker = RecentCommandsTracker()
        tracker.record(.toggleSidebar)
        tracker.record(.newWorklane)
        tracker.record(.splitHorizontally)
        XCTAssertEqual(tracker.recentCommandIDs, [.splitHorizontally, .newWorklane, .toggleSidebar])
    }
}
