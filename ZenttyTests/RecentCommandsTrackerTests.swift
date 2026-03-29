@testable import Zentty
import XCTest

final class RecentCommandsTrackerTests: XCTestCase {
    func testEmptyByDefault() {
        let tracker = RecentCommandsTracker()
        XCTAssertTrue(tracker.recentItemIDs.isEmpty)
    }

    func testRecordsCommand() {
        var tracker = RecentCommandsTracker()
        tracker.record(.command(.toggleSidebar))
        XCTAssertEqual(tracker.recentItemIDs, [.command(.toggleSidebar)])
    }

    func testDuplicatesMovedToFront() {
        var tracker = RecentCommandsTracker()
        tracker.record(.command(.toggleSidebar))
        tracker.record(.command(.newWorklane))
        tracker.record(.command(.toggleSidebar))
        XCTAssertEqual(tracker.recentItemIDs, [.command(.toggleSidebar), .command(.newWorklane)])
    }

    func testCapsAtEight() {
        var tracker = RecentCommandsTracker()
        let ids: [CommandPaletteItemID] = [
            .command(.toggleSidebar), .command(.newWorklane), .command(.nextWorklane),
            .command(.previousWorklane), .command(.splitHorizontally), .command(.splitVertically),
            .command(.closeFocusedPane), .command(.focusLeftPane), .command(.focusRightPane),
        ]
        for id in ids {
            tracker.record(id)
        }
        XCTAssertEqual(tracker.recentItemIDs.count, 8)
        XCTAssertEqual(tracker.recentItemIDs.first, .command(.focusRightPane))
    }

    func testMostRecentFirst() {
        var tracker = RecentCommandsTracker()
        tracker.record(.command(.toggleSidebar))
        tracker.record(.command(.newWorklane))
        tracker.record(.command(.splitHorizontally))
        XCTAssertEqual(tracker.recentItemIDs, [.command(.splitHorizontally), .command(.newWorklane), .command(.toggleSidebar)])
    }

    func testTracksOpenWithTargets() {
        var tracker = RecentCommandsTracker()
        tracker.record(.command(.toggleSidebar))
        tracker.record(.openWith(stableID: "vscode"))
        tracker.record(.command(.newWorklane))
        XCTAssertEqual(tracker.recentItemIDs, [
            .command(.newWorklane),
            .openWith(stableID: "vscode"),
            .command(.toggleSidebar),
        ])
    }
}
