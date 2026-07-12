import XCTest

@testable import Zentty

final class PaneDropResolverTests: XCTestCase {

    // MARK: - Helpers

    private func makeInput(
        draggedPaneID: PaneID = PaneID("dragged"),
        dropTarget: PaneDropTarget = .none,
        stackGapHit: StackReorderGapHit? = nil,
        splitHit: SplitZoneHit? = nil,
        insertionColumnIndex: Int? = nil,
        isDuplicate: Bool = false
    ) -> PaneDropResolver.Input {
        PaneDropResolver.Input(
            draggedPaneID: draggedPaneID,
            dropTarget: dropTarget,
            stackGapHit: stackGapHit,
            splitHit: splitHit,
            insertionColumnIndex: insertionColumnIndex,
            isDuplicate: isDuplicate
        )
    }

    // MARK: - Canvas gestures

    func test_columnInsertion_resolvesToReorder() {
        let resolution = PaneDropResolver.resolve(
            makeInput(insertionColumnIndex: 2)
        )
        XCTAssertEqual(
            resolution,
            .commit(.reorder(paneID: PaneID("dragged"), columnIndex: 2, isDuplicate: false))
        )
    }

    func test_stackGap_resolvesToReorderInColumn() {
        let resolution = PaneDropResolver.resolve(
            makeInput(stackGapHit: StackReorderGapHit(columnID: PaneColumnID("col"), paneIndex: 1))
        )
        XCTAssertEqual(
            resolution,
            .commit(.reorderInColumn(
                paneID: PaneID("dragged"), columnID: PaneColumnID("col"), paneIndex: 1, isDuplicate: false
            ))
        )
    }

    func test_split_resolvesToSplitDrop() {
        let resolution = PaneDropResolver.resolve(
            makeInput(splitHit: SplitZoneHit(
                targetPaneID: PaneID("target"),
                targetColumnID: PaneColumnID("col"),
                axis: .horizontal,
                leading: true
            ))
        )
        XCTAssertEqual(
            resolution,
            .commit(.splitDrop(
                paneID: PaneID("dragged"),
                targetPaneID: PaneID("target"),
                axis: .horizontal,
                leading: true,
                isDuplicate: false
            ))
        )
    }

    func test_split_allAxisAndLeadingCombinations() {
        let combos: [(PaneSplitPreview.Axis, Bool)] = [
            (.horizontal, true),
            (.horizontal, false),
            (.vertical, true),
            (.vertical, false),
        ]
        for (axis, leading) in combos {
            let resolution = PaneDropResolver.resolve(
                makeInput(splitHit: SplitZoneHit(
                    targetPaneID: PaneID("target"),
                    targetColumnID: PaneColumnID("col"),
                    axis: axis,
                    leading: leading
                ))
            )
            XCTAssertEqual(
                resolution,
                .commit(.splitDrop(
                    paneID: PaneID("dragged"),
                    targetPaneID: PaneID("target"),
                    axis: axis,
                    leading: leading,
                    isDuplicate: false
                )),
                "axis=\(axis) leading=\(leading)"
            )
        }
    }

    // MARK: - Sidebar gestures

    func test_sidebarWorklane_resolvesToCrossWorklaneAppend() {
        let resolution = PaneDropResolver.resolve(
            makeInput(dropTarget: .sidebarWorklane(WorklaneID("lane")))
        )
        XCTAssertEqual(
            resolution,
            .commit(.crossWorklane(
                paneID: PaneID("dragged"), worklaneID: WorklaneID("lane"), paneIndex: nil, isDuplicate: false
            ))
        )
    }

    func test_sidebarWorklanePane_resolvesToCrossWorklaneAtIndex() {
        let resolution = PaneDropResolver.resolve(
            makeInput(dropTarget: .sidebarWorklanePane(WorklaneID("lane"), paneIndex: 3))
        )
        XCTAssertEqual(
            resolution,
            .commit(.crossWorklane(
                paneID: PaneID("dragged"), worklaneID: WorklaneID("lane"), paneIndex: 3, isDuplicate: false
            ))
        )
    }

    func test_newWorklane_resolvesToNewWorklaneAppend() {
        let resolution = PaneDropResolver.resolve(
            makeInput(dropTarget: .newWorklane)
        )
        XCTAssertEqual(
            resolution,
            .commit(.newWorklane(paneID: PaneID("dragged"), insertionIndex: nil, isDuplicate: false))
        )
    }

    func test_newWorklaneAtIndex_resolvesToNewWorklaneAtIndex() {
        let resolution = PaneDropResolver.resolve(
            makeInput(dropTarget: .newWorklaneAtIndex(4))
        )
        XCTAssertEqual(
            resolution,
            .commit(.newWorklane(paneID: PaneID("dragged"), insertionIndex: 4, isDuplicate: false))
        )
    }

    // MARK: - Precedence pins

    /// Sidebar targets beat any canvas hit, including a stack gap.
    func test_precedence_sidebarBeatsStackGap() {
        let resolution = PaneDropResolver.resolve(
            makeInput(
                dropTarget: .sidebarWorklane(WorklaneID("lane")),
                stackGapHit: StackReorderGapHit(columnID: PaneColumnID("col"), paneIndex: 1),
                splitHit: SplitZoneHit(
                    targetPaneID: PaneID("target"),
                    targetColumnID: PaneColumnID("col"),
                    axis: .vertical,
                    leading: false
                ),
                insertionColumnIndex: 0
            )
        )
        XCTAssertEqual(
            resolution,
            .commit(.crossWorklane(
                paneID: PaneID("dragged"), worklaneID: WorklaneID("lane"), paneIndex: nil, isDuplicate: false
            ))
        )
    }

    /// A stack gap beats a split hit when both are present.
    func test_precedence_stackGapBeatsSplit() {
        let resolution = PaneDropResolver.resolve(
            makeInput(
                stackGapHit: StackReorderGapHit(columnID: PaneColumnID("col"), paneIndex: 2),
                splitHit: SplitZoneHit(
                    targetPaneID: PaneID("target"),
                    targetColumnID: PaneColumnID("col"),
                    axis: .vertical,
                    leading: false
                ),
                insertionColumnIndex: 0
            )
        )
        XCTAssertEqual(
            resolution,
            .commit(.reorderInColumn(
                paneID: PaneID("dragged"), columnID: PaneColumnID("col"), paneIndex: 2, isDuplicate: false
            ))
        )
    }

    /// A split hit beats a column-insertion index when both are present.
    func test_precedence_splitBeatsColumnInsertion() {
        let resolution = PaneDropResolver.resolve(
            makeInput(
                splitHit: SplitZoneHit(
                    targetPaneID: PaneID("target"),
                    targetColumnID: PaneColumnID("col"),
                    axis: .horizontal,
                    leading: false
                ),
                insertionColumnIndex: 5
            )
        )
        XCTAssertEqual(
            resolution,
            .commit(.splitDrop(
                paneID: PaneID("dragged"),
                targetPaneID: PaneID("target"),
                axis: .horizontal,
                leading: false,
                isDuplicate: false
            ))
        )
    }

    // MARK: - Cancel

    func test_noTargetNoHits_resolvesToCancel() {
        let resolution = PaneDropResolver.resolve(makeInput())
        XCTAssertEqual(resolution, .cancel)
    }

    /// A non-sidebar `dropTarget` (e.g. `.reorderGap`) with no canvas hits still cancels —
    /// the canvas fields, not `dropTarget`, drive canvas dispatch.
    func test_nonSidebarDropTargetWithoutCanvasHits_resolvesToCancel() {
        let resolution = PaneDropResolver.resolve(
            makeInput(dropTarget: .reorderGap(columnIndex: 1))
        )
        XCTAssertEqual(resolution, .cancel)
    }

    // MARK: - isDuplicate propagation

    func test_isDuplicate_propagatesToEveryOutcome() {
        let reorder = PaneDropResolver.resolve(makeInput(insertionColumnIndex: 0, isDuplicate: true))
        XCTAssertEqual(reorder, .commit(.reorder(paneID: PaneID("dragged"), columnIndex: 0, isDuplicate: true)))

        let inColumn = PaneDropResolver.resolve(
            makeInput(stackGapHit: StackReorderGapHit(columnID: PaneColumnID("c"), paneIndex: 0), isDuplicate: true)
        )
        XCTAssertEqual(
            inColumn,
            .commit(.reorderInColumn(paneID: PaneID("dragged"), columnID: PaneColumnID("c"), paneIndex: 0, isDuplicate: true))
        )

        let split = PaneDropResolver.resolve(
            makeInput(splitHit: SplitZoneHit(
                targetPaneID: PaneID("t"), targetColumnID: PaneColumnID("c"), axis: .vertical, leading: true
            ), isDuplicate: true)
        )
        XCTAssertEqual(
            split,
            .commit(.splitDrop(paneID: PaneID("dragged"), targetPaneID: PaneID("t"), axis: .vertical, leading: true, isDuplicate: true))
        )

        let cross = PaneDropResolver.resolve(
            makeInput(dropTarget: .sidebarWorklanePane(WorklaneID("l"), paneIndex: 1), isDuplicate: true)
        )
        XCTAssertEqual(
            cross,
            .commit(.crossWorklane(paneID: PaneID("dragged"), worklaneID: WorklaneID("l"), paneIndex: 1, isDuplicate: true))
        )

        let newLane = PaneDropResolver.resolve(
            makeInput(dropTarget: .newWorklaneAtIndex(2), isDuplicate: true)
        )
        XCTAssertEqual(
            newLane,
            .commit(.newWorklane(paneID: PaneID("dragged"), insertionIndex: 2, isDuplicate: true))
        )
    }

    // MARK: - draggedPaneID threading

    func test_draggedPaneID_threadsThroughEveryOutcome() {
        let paneID = PaneID("specific-pane")

        let cases: [(PaneDropResolver.Input, PaneID)] = [
            (makeInput(draggedPaneID: paneID, insertionColumnIndex: 0), paneID),
            (makeInput(draggedPaneID: paneID, stackGapHit: StackReorderGapHit(columnID: PaneColumnID("c"), paneIndex: 0)), paneID),
            (makeInput(draggedPaneID: paneID, splitHit: SplitZoneHit(
                targetPaneID: PaneID("t"), targetColumnID: PaneColumnID("c"), axis: .horizontal, leading: true
            )), paneID),
            (makeInput(draggedPaneID: paneID, dropTarget: .sidebarWorklane(WorklaneID("l"))), paneID),
            (makeInput(draggedPaneID: paneID, dropTarget: .newWorklane), paneID),
        ]

        for (input, expected) in cases {
            guard case .commit(let outcome) = PaneDropResolver.resolve(input) else {
                return XCTFail("expected commit")
            }
            XCTAssertEqual(outcome.paneID, expected)
        }
    }
}

// Test-only accessor for the pane identity carried by each outcome.
private extension PaneDragOutcome {
    var paneID: PaneID {
        switch self {
        case .reorder(let paneID, _, _),
             .reorderInColumn(let paneID, _, _, _),
             .splitDrop(let paneID, _, _, _, _),
             .crossWorklane(let paneID, _, _, _),
             .newWorklane(let paneID, _, _):
            return paneID
        }
    }
}
