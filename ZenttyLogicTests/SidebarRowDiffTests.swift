import XCTest
@testable import Zentty

final class SidebarRowDiffTests: XCTestCase {
    // MARK: - Empty transitions

    func test_empty_to_empty() {
        let diff = SidebarRowDiff.compute(old: [], new: [])

        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertTrue(diff.updates.isEmpty)
        XCTAssertFalse(diff.hasStructuralChange)
    }

    func test_empty_to_one() {
        let a = makeSummary("A")
        let diff = SidebarRowDiff.compute(old: [], new: [a])

        XCTAssertEqual(diff.insertions.count, 1)
        XCTAssertEqual(diff.insertions[0].index, 0)
        XCTAssertEqual(diff.insertions.first!.summary.worklaneID, WorklaneID("A"))
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertTrue(diff.hasStructuralChange)
    }

    func test_one_to_empty() {
        let a = makeSummary("A")
        let diff = SidebarRowDiff.compute(old: [a], new: [])

        XCTAssertEqual(diff.removals.count, 1)
        XCTAssertEqual(diff.removals[0].index, 0)
        XCTAssertEqual(diff.removals[0].worklaneID, WorklaneID("A"))
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertTrue(diff.hasStructuralChange)
    }

    // MARK: - Insertions

    func test_append_one() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let diff = SidebarRowDiff.compute(old: [a], new: [a, b])

        XCTAssertEqual(diff.insertions.count, 1)
        XCTAssertEqual(diff.insertions[0].index, 1)
        XCTAssertEqual(diff.insertions.first!.summary.worklaneID, WorklaneID("B"))
        XCTAssertTrue(diff.removals.isEmpty)
    }

    func test_insert_at_front() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let diff = SidebarRowDiff.compute(old: [b], new: [a, b])

        XCTAssertEqual(diff.insertions.count, 1)
        XCTAssertEqual(diff.insertions[0].index, 0)
        XCTAssertEqual(diff.insertions.first!.summary.worklaneID, WorklaneID("A"))
    }

    // MARK: - Removals

    func test_remove_middle() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let c = makeSummary("C")
        let diff = SidebarRowDiff.compute(old: [a, b, c], new: [a, c])

        XCTAssertEqual(diff.removals.count, 1)
        XCTAssertEqual(diff.removals[0].index, 1)
        XCTAssertEqual(diff.removals[0].worklaneID, WorklaneID("B"))
        XCTAssertTrue(diff.insertions.isEmpty)
    }

    // MARK: - Moves

    func test_move_reorder() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let c = makeSummary("C")
        let diff = SidebarRowDiff.compute(old: [a, b, c], new: [c, a, b])

        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertFalse(diff.moves.isEmpty)
        XCTAssertTrue(diff.hasStructuralChange)

        // All three are at different positions.
        let movedIDs = Set(diff.moves.map(\.worklaneID))
        XCTAssertTrue(movedIDs.contains(WorklaneID("C")))
        XCTAssertTrue(movedIDs.contains(WorklaneID("A")))
    }

    // MARK: - Updates

    func test_content_change_without_reorder() {
        let a = makeSummary("A", primaryText: "old")
        let aUpdated = makeSummary("A", primaryText: "new")
        let b = makeSummary("B")
        let diff = SidebarRowDiff.compute(old: [a, b], new: [aUpdated, b])

        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertFalse(diff.hasStructuralChange)
        XCTAssertEqual(diff.updates.count, 1)
        XCTAssertEqual(diff.updates[0].worklaneID, WorklaneID("A"))
        XCTAssertEqual(diff.updates[0].summary.primaryText, "new")
    }

    func test_identical_summaries_produce_no_updates() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let diff = SidebarRowDiff.compute(old: [a, b], new: [a, b])

        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertTrue(diff.updates.isEmpty)
        XCTAssertFalse(diff.hasStructuralChange)
    }

    // MARK: - Mixed mutations

    func test_mixed_insert_remove() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let c = makeSummary("C")
        let d = makeSummary("D")
        let e = makeSummary("E")

        // [A, B, C] → [D, A, E]
        let diff = SidebarRowDiff.compute(old: [a, b, c], new: [d, a, e])

        // Removed: B (old index 1), C (old index 2)
        let removedIDs = Set(diff.removals.map(\.worklaneID))
        XCTAssertEqual(removedIDs, [WorklaneID("B"), WorklaneID("C")])

        // Inserted: D (new index 0), E (new index 2)
        let insertedIDs = Set(diff.insertions.map(\.summary.worklaneID))
        XCTAssertEqual(insertedIDs, [WorklaneID("D"), WorklaneID("E")])

        // A moved from index 0 to index 1
        let aMoves = diff.moves.filter { $0.worklaneID == WorklaneID("A") }
        XCTAssertEqual(aMoves.count, 1)
        XCTAssertEqual(aMoves[0].fromIndex, 0)
        XCTAssertEqual(aMoves[0].toIndex, 1)
    }

    func test_full_replacement() {
        let a = makeSummary("A")
        let b = makeSummary("B")
        let c = makeSummary("C")
        let diff = SidebarRowDiff.compute(old: [a], new: [b, c])

        XCTAssertEqual(diff.removals.count, 1)
        XCTAssertEqual(diff.removals[0].worklaneID, WorklaneID("A"))
        XCTAssertEqual(diff.insertions.count, 2)
        XCTAssertEqual(diff.insertions.first!.summary.worklaneID, WorklaneID("B"))
        XCTAssertEqual(diff.insertions[1].summary.worklaneID, WorklaneID("C"))
    }

    // MARK: - Helpers

    private func makeSummary(
        _ id: String,
        primaryText: String = "shell",
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID(id),
            badgeText: "1",
            primaryText: primaryText,
            isActive: isActive
        )
    }
}
