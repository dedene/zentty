import XCTest

@testable import Zentty

/// Regression tests for the main-thread stall where every pane metadata
/// update re-derived every worklane's sidebar summary from disk.
final class SidebarMetadataHotPathTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var time: TimeInterval = 0
    }

    // MARK: - Git repository root cache

    func test_git_root_cache_resolves_a_path_once_within_time_to_live() {
        let clock = Clock()
        let cache = GitRepositoryRootCache(timeToLive: 2, now: { clock.time })
        var resolveCount = 0
        let resolve: (String) -> String? = { _ in
            resolveCount += 1
            return "/repo"
        }

        XCTAssertEqual(cache.root(for: "/repo/app", resolve: resolve), "/repo")
        clock.time = 1.9
        XCTAssertEqual(cache.root(for: "/repo/app", resolve: resolve), "/repo")

        XCTAssertEqual(resolveCount, 1)
    }

    func test_git_root_cache_remembers_paths_outside_a_repository() {
        let cache = GitRepositoryRootCache(timeToLive: 2, now: { 0 })
        var resolveCount = 0
        let resolve: (String) -> String? = { _ in
            resolveCount += 1
            return nil
        }

        XCTAssertNil(cache.root(for: "/tmp/scratch", resolve: resolve))
        XCTAssertNil(cache.root(for: "/tmp/scratch", resolve: resolve))

        XCTAssertEqual(resolveCount, 1)
    }

    func test_git_root_cache_picks_up_a_new_repository_after_time_to_live() {
        let clock = Clock()
        let cache = GitRepositoryRootCache(timeToLive: 2, now: { clock.time })
        var root: String?

        XCTAssertNil(cache.root(for: "/work/app") { _ in root })
        root = "/work/app"
        clock.time = 2
        XCTAssertEqual(cache.root(for: "/work/app") { _ in root }, "/work/app")
    }

    func test_git_root_cache_stays_bounded() {
        let cache = GitRepositoryRootCache(timeToLive: 60, maximumEntryCount: 4, now: { 0 })
        var resolveCount = 0
        for index in 0..<20 {
            _ = cache.root(for: "/path/\(index)") { _ in
                resolveCount += 1
                return nil
            }
        }

        // Still answers correctly after evicting.
        XCTAssertEqual(cache.root(for: "/path/19") { _ in "unexpected" }, nil)
        XCTAssertEqual(resolveCount, 20)
    }

    // MARK: - Summary memo

    func test_summary_memo_expires_entries() {
        let clock = Clock()
        let memo = WorklaneSidebarSummaryMemo<Int>(timeToLive: 2, now: { clock.time })
        let key: WorklaneSidebarSummaryMemo<Int>.Key = memoKey(worklane: makeWorklane("a"))

        XCTAssertEqual(memo.value(for: key) { 1 }, 1)
        XCTAssertEqual(memo.value(for: key) { 2 }, 1)
        clock.time = 2
        XCTAssertEqual(memo.value(for: key) { 3 }, 3)
        XCTAssertEqual(memo.buildCount, 2)
    }

    func test_summary_memo_keeps_before_and_after_states_of_one_worklane() {
        let memo = WorklaneSidebarSummaryMemo<String>(now: { 0 })
        let before = makeWorklane("a")
        var after = before
        after.title = "Renamed"

        XCTAssertEqual(memo.value(for: memoKey(worklane: before)) { "before" }, "before")
        XCTAssertEqual(memo.value(for: memoKey(worklane: after)) { "after" }, "after")
        XCTAssertEqual(memo.value(for: memoKey(worklane: before)) { "rebuilt" }, "before")
        XCTAssertEqual(memo.value(for: memoKey(worklane: after)) { "rebuilt" }, "after")
    }

    // MARK: - Builder

    func test_builder_only_rebuilds_the_worklane_that_changed() {
        var worklanes = ["a", "b", "c", "d"].map(makeWorklane)
        let activeID = worklanes[0].id
        WorklaneSidebarSummaryBuilder.resetSummaryMemoForTesting()

        let baseline = WorklaneSidebarSummaryBuilder.summaryBuildCountForTesting
        let first = WorklaneSidebarSummaryBuilder.summaries(for: worklanes, activeWorklaneID: activeID)
        XCTAssertEqual(WorklaneSidebarSummaryBuilder.summaryBuildCountForTesting - baseline, 4)

        let repeated = WorklaneSidebarSummaryBuilder.summaries(for: worklanes, activeWorklaneID: activeID)
        XCTAssertEqual(WorklaneSidebarSummaryBuilder.summaryBuildCountForTesting - baseline, 4)
        XCTAssertEqual(repeated, first)

        worklanes[2].title = "Renamed"
        let updated = WorklaneSidebarSummaryBuilder.summaries(for: worklanes, activeWorklaneID: activeID)
        XCTAssertEqual(WorklaneSidebarSummaryBuilder.summaryBuildCountForTesting - baseline, 5)
        XCTAssertEqual(updated[2].topLabel, "Renamed")
        XCTAssertEqual(updated[0], first[0])
    }

    func test_builder_memo_returns_the_same_summaries_as_a_fresh_build() {
        let worklanes = ["a", "b", "c"].map(makeWorklane)
        let activeID = worklanes[1].id
        let focusOverride = WorklaneSidebarFocusOverride(
            worklaneID: worklanes[2].id,
            paneID: PaneID("c-two")
        )

        WorklaneSidebarSummaryBuilder.resetSummaryMemoForTesting()
        let fresh = WorklaneSidebarSummaryBuilder.summaries(
            for: worklanes,
            activeWorklaneID: activeID,
            focusOverride: focusOverride
        )
        // Warm the memo with a different shape first, then ask again.
        _ = WorklaneSidebarSummaryBuilder.summaries(for: worklanes, activeWorklaneID: activeID)
        let memoized = WorklaneSidebarSummaryBuilder.summaries(
            for: worklanes,
            activeWorklaneID: activeID,
            focusOverride: focusOverride
        )

        XCTAssertEqual(memoized, fresh)
        XCTAssertTrue(memoized[2].isActive)
        XCTAssertFalse(memoized[1].isActive)
    }

    // MARK: - Theme equality

    func test_theme_copies_compare_equal() {
        let theme = ZenttyTheme.fallback(for: nil)
        let copy = theme

        XCTAssertEqual(theme, copy)
        XCTAssertEqual(theme, ZenttyTheme.fallback(for: nil))
    }

    // MARK: - Fixtures

    private func makeWorklane(_ name: String) -> WorklaneState {
        let first = PaneID("\(name)-one")
        return WorklaneState(
            id: WorklaneID("worklane-\(name)"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: first, title: "\(name) one"),
                    PaneState(id: PaneID("\(name)-two"), title: "\(name) two"),
                ],
                focusedPaneID: first
            )
        )
    }

    private func memoKey<Value>(worklane: WorklaneState) -> WorklaneSidebarSummaryMemo<Value>.Key {
        WorklaneSidebarSummaryMemo<Value>.Key(
            worklane: worklane,
            isActive: false,
            displayOrder: 1,
            focusOverride: nil,
            serverContext: nil,
            showsTemporaryFloats: true
        )
    }
}
