import XCTest
@testable import Zentty

@MainActor
final class NotificationStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> NotificationStore {
        NotificationStore(debounceInterval: 0.01)
    }

    private let worklaneA = WorklaneID("worklane-a")
    private let worklaneB = WorklaneID("worklane-b")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")

    /// Adds a notification and waits for it to commit through the debounce window.
    private func addAndWaitForCommit(
        _ store: NotificationStore,
        worklaneID: WorklaneID? = nil,
        paneID: PaneID? = nil,
        primaryText: String = "Test notification"
    ) async {
        let committed = XCTestExpectation(description: "notification committed")
        let previousOnChange = store.onChange
        store.onChange = {
            previousOnChange?()
            committed.fulfill()
        }
        store.add(
            worklaneID: worklaneID ?? worklaneA,
            paneID: paneID ?? paneA,
            tool: .claudeCode,
            interactionKind: .approval,
            interactionSymbolName: "exclamationmark.triangle",
            statusText: "Needs approval",
            primaryText: primaryText
        )
        await fulfillment(of: [committed], timeout: 5)
    }

    // MARK: - Tests

    func test_add_notification_commits_after_debounce() async {
        let store = makeStore()

        store.add(
            worklaneID: worklaneA,
            paneID: paneA,
            tool: .claudeCode,
            interactionKind: .approval,
            interactionSymbolName: "exclamationmark.triangle",
            statusText: "Needs approval",
            primaryText: "Run command?"
        )

        XCTAssertTrue(store.notifications.isEmpty, "notification should not appear immediately due to debounce")

        let committed = XCTestExpectation(description: "notification committed")
        store.onChange = { committed.fulfill() }
        await fulfillment(of: [committed], timeout: 5)

        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertEqual(store.notifications.first?.primaryText, "Run command?")
    }

    func test_resolve_before_debounce_suppresses_notification() async {
        let store = makeStore()

        let notCommitted = XCTestExpectation(description: "should not commit")
        notCommitted.isInverted = true
        store.onChange = { notCommitted.fulfill() }

        store.add(
            worklaneID: worklaneA,
            paneID: paneA,
            tool: .claudeCode,
            interactionKind: .approval,
            interactionSymbolName: "exclamationmark.triangle",
            statusText: "Needs approval",
            primaryText: "Should be suppressed"
        )

        store.resolve(worklaneID: worklaneA, paneID: paneA)

        // Wait longer than the 0.01s debounce to confirm suppression.
        await fulfillment(of: [notCommitted], timeout: 0.1)

        XCTAssertTrue(store.notifications.isEmpty, "notification resolved within debounce window should be suppressed")
    }

    func test_resolve_marks_committed_items_resolved() async {
        let store = makeStore()
        await addAndWaitForCommit(store, primaryText: "Resolve me")

        XCTAssertFalse(store.notifications[0].isResolved)

        store.resolve(worklaneID: worklaneA, paneID: paneA)

        XCTAssertTrue(store.notifications[0].isResolved)
        XCTAssertNotNil(store.notifications[0].resolvedAt)
    }

    func test_cap_at_50_prunes_oldest() async {
        let store = makeStore()

        for i in 0..<52 {
            await addAndWaitForCommit(
                store,
                paneID: PaneID("pane-\(i)"),
                primaryText: "Notification \(i)"
            )
        }

        XCTAssertEqual(store.notifications.count, 50)
        // The two oldest (indices 0 and 1) should have been pruned.
        XCTAssertFalse(
            store.notifications.contains(where: { $0.primaryText == "Notification 0" }),
            "oldest notification should be pruned"
        )
        XCTAssertFalse(
            store.notifications.contains(where: { $0.primaryText == "Notification 1" }),
            "second oldest notification should be pruned"
        )
    }

    func test_clear_all_empties_list() async {
        let store = makeStore()
        await addAndWaitForCommit(store, primaryText: "First")
        await addAndWaitForCommit(store, paneID: paneB, primaryText: "Second")

        XCTAssertFalse(store.notifications.isEmpty)

        store.clearAll()

        XCTAssertTrue(store.notifications.isEmpty)
    }

    func test_most_urgent_returns_newest_unresolved() async {
        let store = makeStore()
        await addAndWaitForCommit(store, paneID: PaneID("pane-1"), primaryText: "Oldest")
        await addAndWaitForCommit(store, paneID: PaneID("pane-2"), primaryText: "Middle")
        await addAndWaitForCommit(store, paneID: PaneID("pane-3"), primaryText: "Newest")

        // Resolve the newest.
        store.resolve(worklaneID: worklaneA, paneID: PaneID("pane-3"))

        let urgent = store.mostUrgentUnresolved()
        XCTAssertEqual(urgent?.primaryText, "Middle", "should return the newest unresolved notification")
    }

    func test_dismiss_removes_single_item() async {
        let store = makeStore()
        await addAndWaitForCommit(store, paneID: PaneID("pane-1"), primaryText: "Keep")
        await addAndWaitForCommit(store, paneID: PaneID("pane-2"), primaryText: "Remove")
        await addAndWaitForCommit(store, paneID: PaneID("pane-3"), primaryText: "Also keep")

        let idToRemove = store.notifications.first(where: { $0.primaryText == "Remove" })!.id
        store.dismiss(id: idToRemove)

        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertFalse(store.notifications.contains(where: { $0.id == idToRemove }))
        XCTAssertTrue(store.notifications.contains(where: { $0.primaryText == "Keep" }))
        XCTAssertTrue(store.notifications.contains(where: { $0.primaryText == "Also keep" }))
    }

    func test_unresolved_count_computed_correctly() async {
        let store = makeStore()
        await addAndWaitForCommit(store, paneID: PaneID("pane-1"), primaryText: "One")
        await addAndWaitForCommit(store, paneID: PaneID("pane-2"), primaryText: "Two")
        await addAndWaitForCommit(store, paneID: PaneID("pane-3"), primaryText: "Three")

        XCTAssertEqual(store.unresolvedCount, 3)

        store.resolve(worklaneID: worklaneA, paneID: PaneID("pane-2"))

        XCTAssertEqual(store.unresolvedCount, 2)
    }

    func test_on_change_fires_on_commit() async {
        let store = makeStore()
        let changeFired = XCTestExpectation(description: "onChange fired on commit")
        store.onChange = { changeFired.fulfill() }

        store.add(
            worklaneID: worklaneA,
            paneID: paneA,
            tool: .claudeCode,
            interactionKind: .approval,
            interactionSymbolName: "exclamationmark.triangle",
            statusText: "Needs approval",
            primaryText: "Trigger onChange"
        )

        await fulfillment(of: [changeFired], timeout: 5)
        XCTAssertEqual(store.notifications.count, 1)
    }
}
