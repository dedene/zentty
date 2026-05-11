import XCTest
@testable import Zentty

final class DragReorderHapticClassifierTests: XCTestCase {
    // Source position: column "src", pane index 1.
    private func makeActiveState() -> PaneDragActiveState {
        PaneDragActiveState(
            draggedPaneID: PaneID("dragged"),
            sourceColumnID: PaneColumnID("src"),
            sourceColumnIndex: 0,
            sourcePaneIndex: 1,
            sourceFlatPaneIndex: 1,
            originalPaneState: PaneState(id: PaneID("dragged"), title: "dragged"),
            originalColumnWidth: 480,
            grabOffset: .zero,
            cursorPosition: .zero,
            currentDropTarget: .none,
            splitPreview: nil
        )
    }

    // MARK: - isNoOpDrop

    func test_isNoOpDrop_reorderInColumn_atSourceIndex_isTrue() {
        // PaneStripState.movePane treats `paneIndex == sourcePaneIndex` (in reduced-space)
        // as the only same-column no-op.
        let state = makeActiveState()
        XCTAssertTrue(state.isNoOpDrop(.reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 1)))
    }

    func test_isNoOpDrop_reorderInColumn_oneAfterSource_isFalse() {
        // Reduced-space gap one below source is a real move (e.g. [A,X,B,C] → [A,B,X,C]).
        let state = makeActiveState()
        XCTAssertFalse(state.isNoOpDrop(.reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 2)))
    }

    func test_isNoOpDrop_reorderInColumn_differentColumn_isFalse() {
        let state = makeActiveState()
        XCTAssertFalse(state.isNoOpDrop(.reorderInColumn(columnID: PaneColumnID("other"), paneIndex: 1)))
    }

    func test_isNoOpDrop_reorderInColumn_distantIndex_isFalse() {
        let state = makeActiveState()
        XCTAssertFalse(state.isNoOpDrop(.reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 5)))
    }

    func test_isNoOpDrop_reorderInColumn_atSourceIndex_inDuplicateMode_isFalse() {
        // Duplicate-drag always creates a new pane; nothing is a no-op.
        let state = makeActiveState()
        XCTAssertFalse(
            state.isNoOpDrop(
                .reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 1),
                isDuplicate: true
            )
        )
    }

    func test_isNoOpDrop_sidebarWorklane_matchesCurrent_isTrue() {
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertTrue(state.isNoOpDrop(.sidebarWorklane(worklane), currentSidebarWorklaneID: worklane))
    }

    func test_isNoOpDrop_sidebarWorklanePane_currentSlotBoundaries_areTrue() {
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertTrue(
            state.isNoOpDrop(
                .sidebarWorklanePane(worklane, paneIndex: 1),
                currentSidebarWorklaneID: worklane
            )
        )
        XCTAssertTrue(
            state.isNoOpDrop(
                .sidebarWorklanePane(worklane, paneIndex: 2),
                currentSidebarWorklaneID: worklane
            )
        )
    }

    func test_isNoOpDrop_sidebarWorklanePane_otherActiveBoundary_isFalse() {
        let state = makeActiveState()
        XCTAssertFalse(
            state.isNoOpDrop(
                .sidebarWorklanePane(WorklaneID("active"), paneIndex: 0),
                currentSidebarWorklaneID: WorklaneID("active")
            )
        )
    }

    func test_isNoOpDrop_sidebarWorklane_doesNotMatch_isFalse() {
        let state = makeActiveState()
        XCTAssertFalse(
            state.isNoOpDrop(
                .sidebarWorklane(WorklaneID("other")),
                currentSidebarWorklaneID: WorklaneID("active")
            )
        )
    }

    func test_isNoOpDrop_sidebarWorklane_inDuplicateMode_isFalse() {
        // Duplicate onto the active worklane creates a copy there — not a no-op.
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertFalse(
            state.isNoOpDrop(
                .sidebarWorklane(worklane),
                isDuplicate: true,
                currentSidebarWorklaneID: worklane
            )
        )
    }

    func test_isNoOpDrop_otherTargets_isFalse() {
        let state = makeActiveState()
        XCTAssertFalse(state.isNoOpDrop(.reorderGap(columnIndex: 0)))
        XCTAssertFalse(state.isNoOpDrop(.verticalSplit(targetPaneID: PaneID("x"), above: true)))
        XCTAssertFalse(state.isNoOpDrop(.horizontalSplit(targetPaneID: PaneID("x"), leading: true)))
        XCTAssertFalse(state.isNoOpDrop(.newWorklane))
        XCTAssertFalse(state.isNoOpDrop(.none))
    }

    // MARK: - Classifier event mapping

    func test_event_silentWhenTargetUnchanged() {
        let state = makeActiveState()
        let target: PaneDropTarget = .reorderGap(columnIndex: 3)
        XCTAssertEqual(DragReorderHapticClassifier.event(from: target, to: target, activeState: state), .silent)
    }

    func test_event_silentForTransitionToNone() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 1),
                to: .none,
                activeState: state
            ),
            .silent
        )
    }

    func test_event_silentForNoOpReorderSlot() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 4),
                to: .reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 1),
                activeState: state
            ),
            .silent
        )
    }

    func test_event_alignmentForNoOpReorderSlot_inDuplicateMode() {
        // Duplicate drop at the source slot creates a new pane there — fire alignment.
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 4),
                to: .reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 1),
                activeState: state,
                isDuplicate: true
            ),
            .alignment
        )
    }

    func test_event_silentForNoOpSidebarWorklane() {
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .none,
                to: .sidebarWorklane(worklane),
                activeState: state,
                currentSidebarWorklaneID: worklane
            ),
            .silent
        )
    }

    func test_event_alignmentForActiveSidebarPaneBoundaryThatMovesPane() {
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .none,
                to: .sidebarWorklanePane(worklane, paneIndex: 0),
                activeState: state,
                currentSidebarWorklaneID: worklane
            ),
            .alignment
        )
    }

    func test_event_silentForActiveSidebarPaneBoundaryAtCurrentSlot() {
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .none,
                to: .sidebarWorklanePane(worklane, paneIndex: 2),
                activeState: state,
                currentSidebarWorklaneID: worklane
            ),
            .silent
        )
    }

    func test_event_alignmentForActiveSidebarWorklane_inDuplicateMode() {
        // Duplicate onto the active worklane spawns a copy — fire alignment.
        let state = makeActiveState()
        let worklane = WorklaneID("active")
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .none,
                to: .sidebarWorklane(worklane),
                activeState: state,
                isDuplicate: true,
                currentSidebarWorklaneID: worklane
            ),
            .alignment
        )
    }

    func test_event_alignmentForReorderGap() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .none,
                to: .reorderGap(columnIndex: 2),
                activeState: state
            ),
            .alignment
        )
    }

    func test_event_alignmentForReorderInOtherColumn() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 1),
                to: .reorderInColumn(columnID: PaneColumnID("other"), paneIndex: 0),
                activeState: state
            ),
            .alignment
        )
    }

    func test_event_alignmentForSidebarWorklaneOther() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .none,
                to: .sidebarWorklane(WorklaneID("other")),
                activeState: state,
                currentSidebarWorklaneID: WorklaneID("active")
            ),
            .alignment
        )
    }

    func test_event_structuralForVerticalSplit() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 1),
                to: .verticalSplit(targetPaneID: PaneID("target"), above: true),
                activeState: state
            ),
            .structural
        )
    }

    func test_event_structuralForHorizontalSplit() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 1),
                to: .horizontalSplit(targetPaneID: PaneID("target"), leading: false),
                activeState: state
            ),
            .structural
        )
    }

    func test_event_structuralForNewWorklane() {
        let state = makeActiveState()
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .sidebarWorklane(WorklaneID("other")),
                to: .newWorklane,
                activeState: state
            ),
            .structural
        )
    }

    // MARK: - End-to-end transition recipe

    /// Walks a representative drag path and asserts the haptic emitted at each step.
    /// Source position is column "src", paneIndex 1; the active worklane is "active".
    func test_event_dragRecipe_sequence() {
        let state = makeActiveState()
        let activeWorklane = WorklaneID("active")

        // 1. Source slot → adjacent gap: alignment.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderInColumn(columnID: PaneColumnID("src"), paneIndex: 1),
                to: .reorderGap(columnIndex: 2),
                activeState: state
            ),
            .alignment
        )

        // 2. Gap → split: structural.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .reorderGap(columnIndex: 2),
                to: .verticalSplit(targetPaneID: PaneID("t1"), above: true),
                activeState: state
            ),
            .structural
        )

        // 3. Split → another split: structural.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .verticalSplit(targetPaneID: PaneID("t1"), above: true),
                to: .horizontalSplit(targetPaneID: PaneID("t2"), leading: false),
                activeState: state
            ),
            .structural
        )

        // 4. Split → sidebar worklane (other): alignment.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .horizontalSplit(targetPaneID: PaneID("t2"), leading: false),
                to: .sidebarWorklane(WorklaneID("other")),
                activeState: state,
                currentSidebarWorklaneID: activeWorklane
            ),
            .alignment
        )

        // 5. Sidebar (other) → active worklane (no-op): silent.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .sidebarWorklane(WorklaneID("other")),
                to: .sidebarWorklane(activeWorklane),
                activeState: state,
                currentSidebarWorklaneID: activeWorklane
            ),
            .silent
        )

        // 6. Sidebar → new worklane: structural.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .sidebarWorklane(activeWorklane),
                to: .newWorklane,
                activeState: state,
                currentSidebarWorklaneID: activeWorklane
            ),
            .structural
        )

        // 7. New worklane → none: silent.
        XCTAssertEqual(
            DragReorderHapticClassifier.event(
                from: .newWorklane,
                to: .none,
                activeState: state
            ),
            .silent
        )
    }
}
