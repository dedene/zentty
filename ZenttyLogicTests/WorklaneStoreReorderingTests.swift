import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreReorderingTests: XCTestCase {
    func test_moveWorklane_byID_movesItemToFinalIndexAndPreservesActiveWorklane() {
        let store = makeStore(activeID: "B")
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        let didMove = store.moveWorklane(id: WorklaneID("A"), toIndex: 2)

        XCTAssertTrue(didMove)
        XCTAssertEqual(store.worklanes.map(\.id), ids("B", "C", "A"))
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("B"))
        XCTAssertEqual(changes, [.worklaneListChanged])
    }

    func test_moveWorklane_noOpsForSameOrderUnknownIDAndInvalidIndex() {
        let store = makeStore(activeID: "A")
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        XCTAssertFalse(store.moveWorklane(id: WorklaneID("A"), toIndex: 0))
        XCTAssertFalse(store.moveWorklane(id: WorklaneID("missing"), toIndex: 1))
        XCTAssertFalse(store.moveWorklane(id: WorklaneID("A"), toIndex: -1))
        XCTAssertFalse(store.moveWorklane(id: WorklaneID("A"), toIndex: 3))

        XCTAssertEqual(store.worklanes.map(\.id), ids("A", "B", "C"))
        XCTAssertTrue(changes.isEmpty)
    }

    func test_reorderWorklanes_acceptsExactPermutationAndRejectsInvalidOrders() {
        let store = makeStore(activeID: "C")
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        XCTAssertTrue(store.reorderWorklanes(to: ids("C", "A", "B")))
        XCTAssertEqual(store.worklanes.map(\.id), ids("C", "A", "B"))
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("C"))

        XCTAssertFalse(store.reorderWorklanes(to: ids("C", "A")))
        XCTAssertFalse(store.reorderWorklanes(to: ids("C", "A", "A")))
        XCTAssertFalse(store.reorderWorklanes(to: ids("C", "A", "missing")))
        XCTAssertFalse(store.reorderWorklanes(to: ids("C", "A", "B")))

        XCTAssertEqual(store.worklanes.map(\.id), ids("C", "A", "B"))
        XCTAssertEqual(changes, [.worklaneListChanged])
    }

    private func makeStore(activeID: String) -> WorklaneStore {
        WorklaneStore(
            worklanes: [
                makeWorklane("A"),
                makeWorklane("B"),
                makeWorklane("C"),
            ],
            activeWorklaneID: WorklaneID(activeID)
        )
    }

    private func makeWorklane(_ id: String) -> WorklaneState {
        let paneID = PaneID("pane-\(id)")
        return WorklaneState(
            id: WorklaneID(id),
            title: id,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: id),
                ],
                focusedPaneID: paneID
            )
        )
    }

    private func ids(_ values: String...) -> [WorklaneID] {
        values.map(WorklaneID.init)
    }
}
