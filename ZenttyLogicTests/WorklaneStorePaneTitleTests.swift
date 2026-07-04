import XCTest
@testable import Zentty

@MainActor
final class WorklaneStorePaneTitleTests: XCTestCase {
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
                title: nil,
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneB, title: "shell")],
                    focusedPaneID: paneB
                )
            ),
        ])
        return store
    }

    func test_setPaneCustomTitle_mutates_targeted_pane_only_and_emits_change() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        let subscription = store.subscribe { received.append($0) }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setPaneCustomTitle("Nimbu API", on: PaneID("pn_a"))

        XCTAssertTrue(applied)
        XCTAssertEqual(
            store.worklanes.first { $0.id == WorklaneID("wl_a") }?
                .paneStripState.panes.first?.customTitle,
            "Nimbu API"
        )
        XCTAssertNil(
            store.worklanes.first { $0.id == WorklaneID("wl_b") }?
                .paneStripState.panes.first?.customTitle
        )
        XCTAssertTrue(received.contains {
            if case .paneStructure(let worklaneID) = $0 {
                return worklaneID == WorklaneID("wl_a")
            }
            return false
        })
    }

    func test_setPaneCustomTitle_trims_whitespace() {
        let store = makeStore()

        let applied = store.setPaneCustomTitle("  Padded name  ", on: PaneID("pn_a"))

        XCTAssertTrue(applied)
        XCTAssertEqual(
            store.worklanes.first { $0.id == WorklaneID("wl_a") }?
                .paneStripState.panes.first?.customTitle,
            "Padded name"
        )
    }

    func test_setPaneCustomTitle_empty_and_whitespace_clear_the_title() {
        let store = makeStore()
        _ = store.setPaneCustomTitle("Nimbu API", on: PaneID("pn_a"))

        let cleared = store.setPaneCustomTitle("", on: PaneID("pn_a"))

        XCTAssertTrue(cleared)
        XCTAssertNil(
            store.worklanes.first { $0.id == WorklaneID("wl_a") }?
                .paneStripState.panes.first?.customTitle
        )

        _ = store.setPaneCustomTitle("named again", on: PaneID("pn_a"))
        let clearedByWhitespace = store.setPaneCustomTitle("   ", on: PaneID("pn_a"))

        XCTAssertTrue(clearedByWhitespace)
        XCTAssertNil(
            store.worklanes.first { $0.id == WorklaneID("wl_a") }?
                .paneStripState.panes.first?.customTitle
        )
    }

    func test_setPaneCustomTitle_same_value_is_noop_and_emits_no_change() {
        let store = makeStore()
        _ = store.setPaneCustomTitle("Nimbu API", on: PaneID("pn_a"))

        var emitted = 0
        let subscription = store.subscribe { _ in emitted += 1 }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setPaneCustomTitle("Nimbu API", on: PaneID("pn_a"))
        let clearedNoop = store.setPaneCustomTitle(nil, on: PaneID("pn_b"))

        XCTAssertFalse(applied)
        XCTAssertFalse(clearedNoop)
        XCTAssertEqual(emitted, 0)
    }

    func test_setPaneCustomTitle_on_missing_id_returns_false_and_emits_no_change() {
        let store = makeStore()
        var emitted = 0
        let subscription = store.subscribe { _ in emitted += 1 }
        addTeardownBlock { store.unsubscribe(subscription) }

        let applied = store.setPaneCustomTitle("anything", on: PaneID("pn_missing"))

        XCTAssertFalse(applied)
        XCTAssertEqual(emitted, 0)
    }
}