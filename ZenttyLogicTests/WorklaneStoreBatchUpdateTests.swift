import XCTest
@testable import Zentty

/// Regression coverage for `WorklaneStore.batchUpdate` / `notify` coalescing.
///
/// The batch used to silently drop every change raised inside the closure and
/// relied on callers to hand-re-emit them; these tests lock in the replacement
/// behavior: changes are captured, deduplicated in emission order, and flushed
/// as one burst when the outermost batch exits.
@MainActor
final class WorklaneStoreBatchUpdateTests: XCTestCase {

    private let worklaneA = WorklaneID("wl_a")
    private let worklaneB = WorklaneID("wl_b")
    private let paneA = PaneID("pn_a")
    private let paneB = PaneID("pn_b")

    private func makeStore() -> WorklaneStore {
        WorklaneStore(
            windowID: WindowID("wd_batch"),
            worklanes: [
                WorklaneState(
                    id: WorklaneID("wl_seed"),
                    title: "SEED",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("pn_seed"), title: "shell")],
                        focusedPaneID: PaneID("pn_seed")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("wl_seed")
        )
    }

    func test_changesInsideBatch_reachSubscribersAfterExit() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.batchUpdate {
            store.notify(.paneStructure(self.worklaneA))
            store.notify(.activeWorklaneChanged)
        }

        XCTAssertEqual(received, [.paneStructure(worklaneA), .activeWorklaneChanged])
    }

    func test_noNotificationsDeliveredDuringBatch() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        var countObservedMidBatch = -1
        store.batchUpdate {
            store.notify(.paneStructure(self.worklaneA))
            store.notify(.focusChanged(self.worklaneA))
            countObservedMidBatch = received.count
        }

        XCTAssertEqual(countObservedMidBatch, 0, "no changes should be delivered while the batch is open")
        XCTAssertEqual(received, [.paneStructure(worklaneA), .focusChanged(worklaneA)])
    }

    func test_exactDuplicatesCoalesced_orderPreserved() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.batchUpdate {
            store.notify(.paneStructure(self.worklaneA))
            store.notify(.activeWorklaneChanged)
            store.notify(.paneStructure(self.worklaneA)) // exact duplicate — collapse
            store.notify(.worklaneListChanged)
            store.notify(.activeWorklaneChanged)          // exact duplicate — collapse
        }

        XCTAssertEqual(
            received,
            [.paneStructure(worklaneA), .activeWorklaneChanged, .worklaneListChanged]
        )
    }

    func test_distinctPayloadsArePreserved() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.batchUpdate {
            // Same case, different associated values — must NOT collapse.
            store.notify(.paneStructure(self.worklaneA))
            store.notify(.paneStructure(self.worklaneB))
            store.notify(.auxiliaryStateUpdated(self.worklaneA, self.paneA, .sidebar))
            store.notify(.auxiliaryStateUpdated(self.worklaneA, self.paneB, .sidebar))
            store.notify(.auxiliaryStateUpdated(self.worklaneA, self.paneA, .header))
        }

        XCTAssertEqual(received, [
            .paneStructure(worklaneA),
            .paneStructure(worklaneB),
            .auxiliaryStateUpdated(worklaneA, paneA, .sidebar),
            .auxiliaryStateUpdated(worklaneA, paneB, .sidebar),
            .auxiliaryStateUpdated(worklaneA, paneA, .header),
        ])
    }

    func test_nestedBatches_flushOnlyWhenOutermostExits() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        var countAfterInnerExit = -1
        store.batchUpdate {
            store.notify(.paneStructure(self.worklaneA))
            store.batchUpdate {
                store.notify(.activeWorklaneChanged)
            }
            // Inner batch exited but the outer batch is still open: nothing
            // should have been delivered yet.
            countAfterInnerExit = received.count
            store.notify(.worklaneListChanged)
        }

        XCTAssertEqual(countAfterInnerExit, 0, "inner batch exit must not flush while the outer batch is open")
        XCTAssertEqual(
            received,
            [.paneStructure(worklaneA), .activeWorklaneChanged, .worklaneListChanged]
        )
    }

    func test_notifyOutsideBatch_deliversImmediately() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.notify(.paneStructure(worklaneA))
        XCTAssertEqual(received, [.paneStructure(worklaneA)])
    }

    func test_emptyBatch_deliversNothing() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.batchUpdate { }

        XCTAssertTrue(received.isEmpty)
    }

    /// A subscriber that opens its own batch while receiving the flushed burst
    /// (the pattern `WorklaneRenderCoordinator.renderCurrentWorklane` uses) must
    /// deliver cleanly without dropping the original burst or looping.
    func test_subscriberOpeningBatchDuringFlush_doesNotDropOrLoop() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { change in
            received.append(change)
            // Re-entrant batch during delivery with a read-only body: must be a
            // harmless no-op, not a re-delivery or infinite loop.
            store.batchUpdate { }
        }

        store.batchUpdate {
            store.notify(.paneStructure(self.worklaneA))
            store.notify(.activeWorklaneChanged)
        }

        XCTAssertEqual(received, [.paneStructure(worklaneA), .activeWorklaneChanged])
    }

    // MARK: - withNotificationsSuppressed

    func test_changesInsideSuppression_areDropped() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.withNotificationsSuppressed {
            store.notify(.paneStructure(self.worklaneA))
            store.notify(.activeWorklaneChanged)
        }

        XCTAssertTrue(received.isEmpty, "changes raised inside withNotificationsSuppressed must never reach subscribers")
    }

    func test_suppressionNestedInsideBatch_drops_notReplayed() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.batchUpdate {
            store.notify(.paneStructure(self.worklaneA))
            store.withNotificationsSuppressed {
                store.notify(.activeWorklaneChanged)
            }
            store.notify(.worklaneListChanged)
        }

        XCTAssertEqual(
            received,
            [.paneStructure(worklaneA), .worklaneListChanged],
            "suppression nested inside batchUpdate must drop its changes, not queue them for replay"
        )
    }

    func test_batchNestedInsideSuppression_drops() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.withNotificationsSuppressed {
            store.notify(.paneStructure(self.worklaneA))
            store.batchUpdate {
                store.notify(.activeWorklaneChanged)
            }
            store.notify(.worklaneListChanged)
        }

        XCTAssertTrue(
            received.isEmpty,
            "batchUpdate nested inside withNotificationsSuppressed must not escape suppression by replaying on exit"
        )
    }

    func test_notifyAfterSuppressionExits_worksNormally() {
        let store = makeStore()
        var received: [WorklaneChange] = []
        store.subscribe { received.append($0) }

        store.withNotificationsSuppressed {
            store.notify(.paneStructure(self.worklaneA))
        }
        store.notify(.activeWorklaneChanged)

        XCTAssertEqual(
            received,
            [.activeWorklaneChanged],
            "notifications after suppression exits must deliver normally, unaffected by the dropped ones"
        )
    }
}
