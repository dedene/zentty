import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreTitleTests: XCTestCase {
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

    func test_setTitle_mutates_targeted_lane_only_and_emits_change() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        let subscription = store.subscribe { received.append($0) }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setTitle("Nimbu support", on: WorklaneID("wl_a"))

        XCTAssertTrue(applied)
        XCTAssertEqual(store.worklanes.first { $0.id == WorklaneID("wl_a") }?.title, "Nimbu support")
        XCTAssertEqual(store.worklanes.first { $0.id == WorklaneID("wl_b") }?.title, "other")
        XCTAssertTrue(received.contains { if case .worklaneListChanged = $0 { return true } else { return false } })
    }

    func test_setTitle_trims_whitespace() {
        let store = makeStore()

        let applied = store.setTitle("  Padded name  ", on: WorklaneID("wl_a"))

        XCTAssertTrue(applied)
        XCTAssertEqual(store.worklanes.first { $0.id == WorklaneID("wl_a") }?.title, "Padded name")
    }

    func test_setTitle_empty_and_whitespace_clear_the_title() {
        let store = makeStore()

        let cleared = store.setTitle("", on: WorklaneID("wl_b"))

        XCTAssertTrue(cleared)
        XCTAssertNil(store.worklanes.first { $0.id == WorklaneID("wl_b") }?.title)

        _ = store.setTitle("named again", on: WorklaneID("wl_b"))
        let clearedByWhitespace = store.setTitle("   ", on: WorklaneID("wl_b"))

        XCTAssertTrue(clearedByWhitespace)
        XCTAssertNil(store.worklanes.first { $0.id == WorklaneID("wl_b") }?.title)
    }

    func test_setTitle_same_value_is_noop_and_emits_no_change() {
        let store = makeStore()

        var emitted = 0
        let subscription = store.subscribe { _ in emitted += 1 }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setTitle("other", on: WorklaneID("wl_b"))
        let clearedNoop = store.setTitle(nil, on: WorklaneID("wl_a"))

        XCTAssertFalse(applied)
        XCTAssertFalse(clearedNoop)
        XCTAssertEqual(emitted, 0)
    }

    func test_setTitle_on_missing_id_returns_false_and_emits_no_change() {
        let store = makeStore()
        var emitted = 0
        let subscription = store.subscribe { _ in emitted += 1 }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setTitle("anything", on: WorklaneID("wl_missing"))

        XCTAssertFalse(applied)
        XCTAssertEqual(emitted, 0)
    }
}
