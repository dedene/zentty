import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreColorTests: XCTestCase {
    private func makeStore() -> WorklaneStore {
        let store = WorklaneStore()
        let paneA = PaneID("pn_a")
        let paneB = PaneID("pn_b")
        store.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("wl_a"),
                title: nil,
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneA, title: "shell")],
                    focusedPaneID: paneA
                )
            ),
            WorklaneState(
                id: WorklaneID("wl_b"),
                title: "other",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneB, title: "shell")],
                    focusedPaneID: paneB
                )
            ),
        ])
        return store
    }

    func test_setColor_mutates_targeted_lane_only_and_emits_change() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        let subscription = store.subscribe { received.append($0) }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setColor(.red, on: WorklaneID("wl_a"))

        XCTAssertTrue(applied)
        XCTAssertEqual(store.worklanes.first { $0.id == WorklaneID("wl_a") }?.color, .red)
        XCTAssertNil(store.worklanes.first { $0.id == WorklaneID("wl_b") }?.color)
        XCTAssertTrue(received.contains { if case .worklaneListChanged = $0 { return true } else { return false } })
    }

    func test_setColor_same_value_is_noop_and_emits_no_change() {
        let store = makeStore()
        _ = store.setColor(.red, on: WorklaneID("wl_a"))

        var emitted = 0
        let subscription = store.subscribe { _ in emitted += 1 }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setColor(.red, on: WorklaneID("wl_a"))

        XCTAssertFalse(applied)
        XCTAssertEqual(emitted, 0)
    }

    func test_setColor_nil_resets_previously_set_color() {
        let store = makeStore()
        _ = store.setColor(.blue, on: WorklaneID("wl_a"))
        let applied = store.setColor(nil, on: WorklaneID("wl_a"))

        XCTAssertTrue(applied)
        XCTAssertNil(store.worklanes.first { $0.id == WorklaneID("wl_a") }?.color)
    }

    func test_setColor_on_missing_id_returns_false_and_emits_no_change() {
        let store = makeStore()
        var emitted = 0
        let subscription = store.subscribe { _ in emitted += 1 }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setColor(.red, on: WorklaneID("wl_missing"))

        XCTAssertFalse(applied)
        XCTAssertEqual(emitted, 0)
    }
}
