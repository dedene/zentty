import XCTest

@testable import Zentty

@MainActor
final class SidebarActiveWorklaneAutoScrollerTests: XCTestCase {
    func test_autoScroller_scrolls_after_two_deferred_passes_when_active_row_is_not_visible() {
        var deferredActions: [() -> Void] = []
        let scroller = SidebarActiveWorklaneAutoScroller { action in
            deferredActions.append(action)
        }
        let targetID = WorklaneID("worklane-api")
        var currentActiveID: WorklaneID? = targetID
        var layoutPassCount = 0
        var scrolledIDs: [WorklaneID] = []

        scroller.scrollToActiveWorklaneIfNeeded(
            targetID,
            currentActiveID: { currentActiveID },
            layoutIfNeeded: { layoutPassCount += 1 },
            isVisible: { _ in false },
            scroll: { scrolledIDs.append($0) }
        )

        XCTAssertEqual(deferredActions.count, 1)
        XCTAssertEqual(scrolledIDs, [])

        deferredActions.removeFirst()()
        XCTAssertEqual(layoutPassCount, 1)
        XCTAssertEqual(deferredActions.count, 1)
        XCTAssertEqual(scrolledIDs, [])

        deferredActions.removeFirst()()
        XCTAssertEqual(layoutPassCount, 2)
        XCTAssertEqual(scrolledIDs, [targetID])
        XCTAssertEqual(currentActiveID, targetID)
    }

    func test_autoScroller_does_not_scroll_when_row_is_visible_after_deferred_layout() {
        var deferredActions: [() -> Void] = []
        let scroller = SidebarActiveWorklaneAutoScroller { action in
            deferredActions.append(action)
        }
        let targetID = WorklaneID("worklane-api")
        var layoutPassCount = 0
        var scrollCount = 0

        scroller.scrollToActiveWorklaneIfNeeded(
            targetID,
            currentActiveID: { targetID },
            layoutIfNeeded: { layoutPassCount += 1 },
            isVisible: { _ in true },
            scroll: { _ in scrollCount += 1 }
        )

        deferredActions.removeFirst()()
        deferredActions.removeFirst()()

        XCTAssertEqual(layoutPassCount, 2)
        XCTAssertEqual(scrollCount, 0)
    }

    func test_autoScroller_cancels_when_active_row_changes_before_second_pass() {
        var deferredActions: [() -> Void] = []
        let scroller = SidebarActiveWorklaneAutoScroller { action in
            deferredActions.append(action)
        }
        let targetID = WorklaneID("worklane-api")
        let replacementID = WorklaneID("worklane-web")
        var currentActiveID: WorklaneID? = targetID
        var layoutPassCount = 0
        var scrolledIDs: [WorklaneID] = []

        scroller.scrollToActiveWorklaneIfNeeded(
            targetID,
            currentActiveID: { currentActiveID },
            layoutIfNeeded: { layoutPassCount += 1 },
            isVisible: { _ in false },
            scroll: { scrolledIDs.append($0) }
        )

        deferredActions.removeFirst()()
        currentActiveID = replacementID
        deferredActions.removeFirst()()

        XCTAssertEqual(layoutPassCount, 1)
        XCTAssertEqual(scrolledIDs, [])
    }

    func test_autoScroller_cancels_superseded_request_for_same_worklane() {
        var deferredActions: [() -> Void] = []
        let scroller = SidebarActiveWorklaneAutoScroller { action in
            deferredActions.append(action)
        }
        let targetID = WorklaneID("worklane-api")
        var layoutPassCount = 0
        var scrolledIDs: [WorklaneID] = []

        scroller.scrollToActiveWorklaneIfNeeded(
            targetID,
            currentActiveID: { targetID },
            layoutIfNeeded: { layoutPassCount += 1 },
            isVisible: { _ in false },
            scroll: { scrolledIDs.append($0) }
        )

        deferredActions.removeFirst()()
        XCTAssertEqual(layoutPassCount, 1)
        XCTAssertEqual(deferredActions.count, 1)
        let supersededSecondPass = deferredActions.removeFirst()

        scroller.scrollToActiveWorklaneIfNeeded(
            targetID,
            currentActiveID: { targetID },
            layoutIfNeeded: { layoutPassCount += 1 },
            isVisible: { _ in false },
            scroll: { scrolledIDs.append($0) }
        )

        supersededSecondPass()
        XCTAssertEqual(layoutPassCount, 1)
        XCTAssertEqual(scrolledIDs, [])

        deferredActions.removeFirst()()
        deferredActions.removeFirst()()
        XCTAssertEqual(layoutPassCount, 3)
        XCTAssertEqual(scrolledIDs, [targetID])
    }
}
