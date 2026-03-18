import CoreGraphics
import XCTest
@testable import Zentty

final class WindowChromeRowLayoutPlannerTests: XCTestCase {
    func test_planner_keeps_preferred_widths_when_visible_lane_can_fit_everything() {
        let plan = WindowChromeRowLayoutPlanner.plan(
            availableWidth: 900,
            items: [
                .init(kind: .focusedLabel, preferredWidth: 243, minimumWidth: 0),
                .init(kind: .branch, preferredWidth: 30, minimumWidth: 30),
            ]
        )

        XCTAssertEqual(plan.preferredTotalWidth, plan.finalTotalWidth, accuracy: 0.5)
        XCTAssertEqual(plan.overflowBeforeCompression, 0, accuracy: 0.5)
        XCTAssertFalse(plan.didCompressItems)
        XCTAssertFalse(plan.didDropReviewChips)
        assertAssignedWidths(plan.items.map(\.assignedWidth), equal: [243, 30])
    }

    func test_planner_keeps_long_path_long_branch_and_pr_at_preferred_widths_when_they_fit() {
        let plan = WindowChromeRowLayoutPlanner.plan(
            availableWidth: 1200,
            items: [
                .init(kind: .focusedLabel, preferredWidth: 484, minimumWidth: 0),
                .init(kind: .branch, preferredWidth: 267.5, minimumWidth: 267.5),
                .init(kind: .pullRequest, preferredWidth: 55, minimumWidth: 55),
            ]
        )

        XCTAssertEqual(plan.preferredTotalWidth, plan.finalTotalWidth, accuracy: 0.5)
        XCTAssertEqual(plan.overflowBeforeCompression, 0, accuracy: 0.5)
        XCTAssertFalse(plan.didCompressItems)
        assertAssignedWidths(plan.items.map(\.assignedWidth), equal: [484, 267.5, 55])
    }

    func test_planner_keeps_last_review_chip_and_compresses_focused_label_before_branch_and_pr() {
        let plan = WindowChromeRowLayoutPlanner.plan(
            availableWidth: 360,
            items: [
                .init(kind: .focusedLabel, preferredWidth: 484, minimumWidth: 0),
                .init(kind: .branch, preferredWidth: 30, minimumWidth: 30),
                .init(kind: .pullRequest, preferredWidth: 55, minimumWidth: 55),
                .init(kind: .reviewChip, preferredWidth: 88, minimumWidth: 0),
            ]
        )

        XCTAssertGreaterThan(plan.overflowBeforeCompression, 0)
        XCTAssertFalse(plan.didDropReviewChips)
        assertAssignedWidths(plan.items.map(\.assignedWidth), equal: [155, 30, 55, 88])
    }

    private func assertAssignedWidths(_ actual: [CGFloat], equal expected: [CGFloat], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualWidth, expectedWidth) in zip(actual, expected) {
            XCTAssertEqual(actualWidth, expectedWidth, accuracy: 0.5, file: file, line: line)
        }
    }
}
