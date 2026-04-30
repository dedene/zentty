import CoreGraphics
import XCTest
@testable import Zentty

final class SidebarWorklaneReorderModelTests: XCTestCase {
    func test_previewOrder_removesDraggedIDBeforeApplyingFinalInsertionIndex() {
        XCTAssertEqual(
            SidebarWorklaneReorderModel.previewOrder(
                currentOrder: ids("A", "B", "C", "D"),
                draggedID: WorklaneID("B"),
                insertionIndex: 3
            ),
            ids("A", "C", "D", "B")
        )

        XCTAssertEqual(
            SidebarWorklaneReorderModel.previewOrder(
                currentOrder: ids("A", "B", "C", "D"),
                draggedID: WorklaneID("D"),
                insertionIndex: 1
            ),
            ids("A", "D", "B", "C")
        )
    }

    func test_previewOrder_rejectsMissingDraggedIDAndOutOfBoundsIndex() {
        XCTAssertNil(
            SidebarWorklaneReorderModel.previewOrder(
                currentOrder: ids("A", "B"),
                draggedID: WorklaneID("missing"),
                insertionIndex: 1
            )
        )
        XCTAssertNil(
            SidebarWorklaneReorderModel.previewOrder(
                currentOrder: ids("A", "B"),
                draggedID: WorklaneID("A"),
                insertionIndex: 2
            )
        )
    }

    func test_insertionIndex_usesVariableHeightRowMidpointsAndSkipsDraggedRow() {
        let frames: [(WorklaneID, CGRect)] = [
            (WorklaneID("A"), CGRect(x: 0, y: 0, width: 220, height: 40)),
            (WorklaneID("B"), CGRect(x: 0, y: 46, width: 220, height: 90)),
            (WorklaneID("C"), CGRect(x: 0, y: 142, width: 220, height: 50)),
        ]

        XCTAssertEqual(
            SidebarWorklaneReorderModel.insertionIndex(
                cursorY: 45,
                rowFrames: frames,
                draggedID: WorklaneID("B")
            ),
            1
        )
        XCTAssertEqual(
            SidebarWorklaneReorderModel.insertionIndex(
                cursorY: 170,
                rowFrames: frames,
                draggedID: WorklaneID("B")
            ),
            2
        )
    }

    func test_insertionIndex_treatsSmallerYAsVisuallyEarlierSlot() {
        let frames: [(WorklaneID, CGRect)] = [
            (WorklaneID("A"), CGRect(x: 0, y: 0, width: 220, height: 40)),
            (WorklaneID("B"), CGRect(x: 0, y: 46, width: 220, height: 40)),
            (WorklaneID("C"), CGRect(x: 0, y: 92, width: 220, height: 40)),
        ]

        XCTAssertEqual(
            SidebarWorklaneReorderModel.insertionIndex(
                cursorY: -4,
                rowFrames: frames,
                draggedID: WorklaneID("B")
            ),
            0
        )
        XCTAssertEqual(
            SidebarWorklaneReorderModel.insertionIndex(
                cursorY: 140,
                rowFrames: frames,
                draggedID: WorklaneID("B")
            ),
            2
        )
    }

    func test_autoScrollVelocity_scalesNearEdges() {
        XCTAssertEqual(
            SidebarWorklaneReorderModel.autoScrollVelocity(
                cursorY: 100,
                visibleMinY: 100,
                visibleMaxY: 300,
                edgeZone: 30,
                maxSpeed: 240
            ),
            -240,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarWorklaneReorderModel.autoScrollVelocity(
                cursorY: 285,
                visibleMinY: 100,
                visibleMaxY: 300,
                edgeZone: 30,
                maxSpeed: 240
            ),
            120,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarWorklaneReorderModel.autoScrollVelocity(
                cursorY: 200,
                visibleMinY: 100,
                visibleMaxY: 300,
                edgeZone: 30,
                maxSpeed: 240
            ),
            0,
            accuracy: 0.001
        )
    }

    private func ids(_ values: String...) -> [WorklaneID] {
        values.map(WorklaneID.init)
    }
}
