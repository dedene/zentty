import AppKit
import XCTest
@testable import Zentty

@MainActor
final class GlobalSearchCoordinatorTests: XCTestCase {
    func test_update_query_fans_out_to_all_panes_and_aggregates_totals() {
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let runtime1 = makeRuntime(paneID: paneID1)
        let runtime2 = makeRuntime(paneID: paneID2)
        var endAllLocalSearchesCallCount = 0

        let coordinator = makeCoordinator(
            targets: [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ],
            runtimes: [
                paneID1: runtime1.runtime,
                paneID2: runtime2.runtime,
            ],
            navigateToTarget: { _, _, _ in },
            endAllLocalSearches: {
                endAllLocalSearchesCallCount += 1
            }
        )

        coordinator.updateQuery("build")
        coordinator.handleSearchEvent(for: paneID1, event: .total(2))
        coordinator.handleSearchEvent(for: paneID2, event: .total(1))

        XCTAssertEqual(endAllLocalSearchesCallCount, 1)
        XCTAssertEqual(runtime1.adapter.bindingActions, ["start_search", "search:build"])
        XCTAssertEqual(runtime2.adapter.bindingActions, ["start_search", "search:build"])
        XCTAssertEqual(
            coordinator.state,
            GlobalSearchState(
                needle: "build",
                selected: -1,
                total: 3,
                hasRememberedSearch: true,
                isHUDVisible: true
            )
        )
    }

    func test_find_next_wraps_across_panes_in_frozen_order() {
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let runtime1 = makeRuntime(paneID: paneID1)
        let runtime2 = makeRuntime(paneID: paneID2)
        var navigatedTargets: [GlobalSearchTarget] = []
        var pendingNavigationCompletion: (@MainActor () -> Void)?

        let coordinator = makeCoordinator(
            targets: [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ],
            runtimes: [
                paneID1: runtime1.runtime,
                paneID2: runtime2.runtime,
            ],
            navigateToTarget: { worklaneID, paneID, completion in
                navigatedTargets.append(GlobalSearchTarget(worklaneID: worklaneID, paneID: paneID))
                pendingNavigationCompletion = completion
            },
            endAllLocalSearches: {}
        )

        coordinator.updateQuery("build")
        coordinator.handleSearchEvent(for: paneID1, event: .total(1))
        coordinator.handleSearchEvent(for: paneID2, event: .total(1))

        coordinator.findNext()
        XCTAssertEqual(runtime1.adapter.bindingActions, ["start_search", "search:build"])
        XCTAssertNotNil(pendingNavigationCompletion)
        pendingNavigationCompletion?()
        pendingNavigationCompletion = nil
        XCTAssertEqual(runtime1.adapter.bindingActions, ["start_search", "search:build", "navigate_search:next"])

        coordinator.handleSearchEvent(for: paneID1, event: .selected(0))
        coordinator.findNext()

        XCTAssertEqual(
            navigatedTargets,
            [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ]
        )
        XCTAssertEqual(
            runtime1.adapter.bindingActions,
            ["start_search", "search:build", "navigate_search:next", "search:build"]
        )
        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:build"]
        )

        XCTAssertNotNil(pendingNavigationCompletion)
        pendingNavigationCompletion?()
        coordinator.handleSearchEvent(for: paneID2, event: .selected(0))

        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:build", "navigate_search:next"]
        )
        XCTAssertEqual(coordinator.state.selected, 1)
    }

    func test_find_previous_from_unselected_uses_last_matching_pane_and_last_match() {
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let runtime1 = makeRuntime(paneID: paneID1)
        let runtime2 = makeRuntime(paneID: paneID2)
        var navigatedTargets: [GlobalSearchTarget] = []
        var pendingNavigationCompletion: (@MainActor () -> Void)?

        let coordinator = makeCoordinator(
            targets: [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ],
            runtimes: [
                paneID1: runtime1.runtime,
                paneID2: runtime2.runtime,
            ],
            navigateToTarget: { worklaneID, paneID, completion in
                navigatedTargets.append(GlobalSearchTarget(worklaneID: worklaneID, paneID: paneID))
                pendingNavigationCompletion = completion
            },
            endAllLocalSearches: {}
        )

        coordinator.updateQuery("build")
        coordinator.handleSearchEvent(for: paneID1, event: .total(1))
        coordinator.handleSearchEvent(for: paneID2, event: .total(2))

        coordinator.findPrevious()

        XCTAssertEqual(
            navigatedTargets,
            [GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2)]
        )
        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:build"]
        )

        XCTAssertNotNil(pendingNavigationCompletion)
        pendingNavigationCompletion?()
        coordinator.handleSearchEvent(for: paneID2, event: .selected(1))

        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:build", "navigate_search:previous"]
        )
        XCTAssertEqual(coordinator.state.selected, 2)
    }

    func test_find_next_flushes_short_query_debounce_and_executes_when_totals_arrive() {
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let runtime1 = makeRuntime(paneID: paneID1)
        let runtime2 = makeRuntime(paneID: paneID2)
        var navigatedTargets: [GlobalSearchTarget] = []
        var pendingNavigationCompletion: (@MainActor () -> Void)?

        let coordinator = makeCoordinator(
            targets: [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ],
            runtimes: [
                paneID1: runtime1.runtime,
                paneID2: runtime2.runtime,
            ],
            navigateToTarget: { worklaneID, paneID, completion in
                navigatedTargets.append(GlobalSearchTarget(worklaneID: worklaneID, paneID: paneID))
                pendingNavigationCompletion = completion
            },
            endAllLocalSearches: {}
        )

        coordinator.updateQuery("ab")
        XCTAssertEqual(runtime1.adapter.bindingActions, [])
        XCTAssertEqual(runtime2.adapter.bindingActions, [])

        coordinator.findNext()
        XCTAssertEqual(runtime1.adapter.bindingActions, ["start_search", "search:ab"])
        XCTAssertEqual(runtime2.adapter.bindingActions, ["start_search", "search:ab"])
        XCTAssertTrue(navigatedTargets.isEmpty)

        coordinator.handleSearchEvent(for: paneID1, event: .total(0))
        XCTAssertTrue(navigatedTargets.isEmpty)

        coordinator.handleSearchEvent(for: paneID2, event: .total(1))

        XCTAssertEqual(
            navigatedTargets,
            [GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2)]
        )
        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:ab"]
        )

        XCTAssertNotNil(pendingNavigationCompletion)
        pendingNavigationCompletion?()

        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:ab", "navigate_search:next"]
        )
    }

    func test_cross_pane_navigation_waits_for_navigation_completion() {
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let runtime1 = makeRuntime(paneID: paneID1)
        let runtime2 = makeRuntime(paneID: paneID2)
        var navigatedTargets: [GlobalSearchTarget] = []
        var pendingNavigationCompletion: (@MainActor () -> Void)?

        let coordinator = makeCoordinator(
            targets: [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ],
            runtimes: [
                paneID1: runtime1.runtime,
                paneID2: runtime2.runtime,
            ],
            navigateToTarget: { worklaneID, paneID, completion in
                navigatedTargets.append(GlobalSearchTarget(worklaneID: worklaneID, paneID: paneID))
                pendingNavigationCompletion = completion
            },
            endAllLocalSearches: {}
        )

        coordinator.updateQuery("build")
        coordinator.handleSearchEvent(for: paneID1, event: .total(1))
        coordinator.handleSearchEvent(for: paneID2, event: .total(1))

        coordinator.findNext()
        coordinator.handleSearchEvent(for: paneID1, event: .selected(0))
        coordinator.findNext()

        XCTAssertEqual(
            navigatedTargets.last,
            GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2)
        )
        XCTAssertEqual(runtime2.adapter.bindingActions, ["start_search", "search:build"])

        XCTAssertNotNil(pendingNavigationCompletion)
        pendingNavigationCompletion?()

        XCTAssertEqual(
            runtime2.adapter.bindingActions,
            ["start_search", "search:build", "navigate_search:next"]
        )
    }

    func test_hide_ends_global_search_and_clears_all_pane_searches() {
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let runtime1 = makeRuntime(paneID: paneID1)
        let runtime2 = makeRuntime(paneID: paneID2)

        let coordinator = makeCoordinator(
            targets: [
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-1"), paneID: paneID1),
                GlobalSearchTarget(worklaneID: WorklaneID("worklane-2"), paneID: paneID2),
            ],
            runtimes: [
                paneID1: runtime1.runtime,
                paneID2: runtime2.runtime,
            ],
            navigateToTarget: { _, _, _ in },
            endAllLocalSearches: {}
        )

        coordinator.updateQuery("build")
        coordinator.handleSearchEvent(for: paneID1, event: .total(2))
        coordinator.handleSearchEvent(for: paneID2, event: .total(1))

        coordinator.hide()

        XCTAssertEqual(runtime1.adapter.bindingActions, ["start_search", "search:build", "end_search"])
        XCTAssertEqual(runtime2.adapter.bindingActions, ["start_search", "search:build", "end_search"])
        XCTAssertEqual(coordinator.state, GlobalSearchState())
    }

    private func makeCoordinator(
        targets: [GlobalSearchTarget],
        runtimes: [PaneID: PaneRuntime],
        navigateToTarget: @escaping (WorklaneID, PaneID, @escaping @MainActor () -> Void) -> Void,
        endAllLocalSearches: @escaping () -> Void
    ) -> GlobalSearchCoordinator {
        GlobalSearchCoordinator(
            orderedTargetsProvider: { targets },
            runtimeProvider: { paneID in
                runtimes[paneID]
            },
            navigateToTarget: navigateToTarget,
            endAllLocalSearches: endAllLocalSearches
        )
    }

    private func makeRuntime(
        paneID: PaneID
    ) -> (runtime: PaneRuntime, adapter: GlobalSearchCoordinatorTerminalAdapterSpy) {
        let adapter = GlobalSearchCoordinatorTerminalAdapterSpy()
        let runtime = PaneRuntime(
            pane: PaneState(id: paneID, title: "shell"),
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        return (runtime, adapter)
    }
}

@MainActor
private final class GlobalSearchCoordinatorTerminalAdapterSpy: TerminalAdapter, TerminalSearchControlling {
    let terminalView = NSView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var bindingActions: [String] = []

    func makeTerminalView() -> NSView { terminalView }
    func startSession(using request: TerminalSessionRequest) throws {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func close() {}

    func showSearch() {
        bindingActions.append("start_search")
        searchDidChange?(.started(needle: nil))
    }

    func useSelectionForFind() {
        bindingActions.append("search_selection")
        searchDidChange?(.started(needle: nil))
    }

    func updateSearch(needle: String) {
        bindingActions.append("search:\(needle)")
    }

    func findNext() {
        bindingActions.append("navigate_search:next")
    }

    func findPrevious() {
        bindingActions.append("navigate_search:previous")
    }

    func endSearch() {
        bindingActions.append("end_search")
        searchDidChange?(.ended)
    }
}
