import Foundation
import os
import XCTest
@testable import Zentty

final class HistoryMetadataIndexTests: XCTestCase {
    private let dayMs: Int64 = 86_400_000
    /// 2026-11-01 12:00:00 UTC.
    private let nowMs: Int64 = 1_793_534_400_000
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Mutable exclusions read by the index on every call, like the controller's mirror.
    private final class ExclusionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var matcher = AgentHistoryExclusionMatcher(folders: [])

        var value: AgentHistoryExclusionMatcher {
            lock.lock()
            defer { lock.unlock() }
            return matcher
        }

        func set(_ folders: [String]) {
            let next = AgentHistoryExclusionMatcher(folders: folders)
            lock.lock()
            matcher = next
            lock.unlock()
        }
    }

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: AgentHistoryMetadataSnapshot

        init(_ snapshot: AgentHistoryMetadataSnapshot) {
            self.snapshot = snapshot
        }

        var value: AgentHistoryMetadataSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func set(_ next: AgentHistoryMetadataSnapshot) {
            lock.lock()
            snapshot = next
            lock.unlock()
        }
    }

    private func session(
        _ id: Int64,
        title: String,
        agent: AgentHistoryAgent = .claude,
        cwd: String? = nil,
        repoRoot: String? = nil,
        mainRepoRoot: String? = nil,
        branch: String? = nil,
        createdDaysAgo: Double? = nil,
        updatedDaysAgo: Double = 1000,
        archived: Bool = false,
        opens: Int = 0,
        openedDaysAgo: Double? = nil
    ) -> AgentHistorySessionSummary {
        let updatedAtMs = nowMs - Int64(updatedDaysAgo * Double(dayMs))
        let createdAtMs = createdDaysAgo.map { nowMs - Int64($0 * Double(dayMs)) } ?? (updatedAtMs - dayMs)
        return AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/nonexistent-zt/roots/\(agent.rawValue)", agent: agent,
            nativeID: "native-\(id)", title: title, titleKind: .custom,
            cwd: cwd, repoRoot: repoRoot, mainRepoRoot: mainRepoRoot, branch: branch,
            createdAtMs: createdAtMs, updatedAtMs: updatedAtMs,
            turnCount: 3, isArchived: archived, opens: opens,
            lastOpenedAtMs: openedDaysAgo.map { nowMs - Int64($0 * Double(dayMs)) }
        )
    }

    private func snapshot(_ sessions: [AgentHistorySessionSummary], generation: UInt64 = 1) -> AgentHistoryMetadataSnapshot {
        let ordered = sessions.sorted { ($0.updatedAtMs, $0.id) > ($1.updatedAtMs, $1.id) }
        return AgentHistoryMetadataSnapshot(generation: generation, sessions: ordered, isComplete: true)
    }

    private func makeIndex(
        _ sessions: [AgentHistorySessionSummary],
        exclusions: ExclusionsBox = ExclusionsBox()
    ) -> HistoryMetadataIndex {
        let snapshot = snapshot(sessions)
        return HistoryMetadataIndex(snapshot: { snapshot }, exclusions: { exclusions.value })
    }

    private func context(_ scope: AgentHistoryScope = .all, currentRepositoryKey: String? = nil) -> HistorySearchContext {
        HistorySearchContext(scope: scope, currentRepositoryKey: currentRepositoryKey, now: now)
    }

    private func query(_ raw: String) -> HistoryQuery {
        HistoryQueryParser.parse(raw, calendar: utc)
    }

    private func search(
        _ index: HistoryMetadataIndex,
        _ raw: String,
        scope: AgentHistoryScope = .all,
        limit: Int = HistoryMetadataIndex.defaultLimit
    ) -> [HistoryMetadataResult] {
        index.search(query(raw), context: context(scope), limit: limit).results
    }

    private func projectScope(_ key: String, allowsCWDPrefix: Bool = true) -> AgentHistoryScope {
        .project(AgentHistoryProjectScope(
            key: key, displayName: (key as NSString).lastPathComponent, allowsCWDPrefix: allowsCWDPrefix))
    }

    // MARK: - Field weights

    func test_title_weight_beats_branch_repo_folder() {
        let index = makeIndex([
            session(1, title: "Tidy the folder", cwd: "/nonexistent-zt/scratch/payments", updatedDaysAgo: 3),
            session(2, title: "Tidy the repo", mainRepoRoot: "/nonexistent-zt/src/payments",
                    updatedDaysAgo: 3),
            session(3, title: "Tidy the branch", branch: "payments", updatedDaysAgo: 3),
            session(4, title: "Fix payments", updatedDaysAgo: 3),
        ])

        let results = search(index, "payments")

        XCTAssertEqual(results.map(\.session.id), [4, 3, 2, 1])
        XCTAssertTrue(results.allSatisfy(\.isWordLevel))
        let multiplier = HistoryRanker.sessionMultiplier(
            HistoryRankFacts(summary: results[0].session), context: context())
        XCTAssertEqual(results[0].score, 1.0 * multiplier, accuracy: 1e-9)
        XCTAssertEqual(results[1].score, 0.6 * multiplier, accuracy: 1e-9)
        XCTAssertEqual(results[2].score, 0.4 * multiplier, accuracy: 1e-9)
        XCTAssertEqual(results[3].score, 0.3 * multiplier, accuracy: 1e-9)
    }

    func test_branch_whole_word_is_word_level_despite_weight() {
        let index = makeIndex([
            // Old, never opened: a low usage multiplier.
            session(1, title: "Tidy up", branch: "feature/payments", updatedDaysAgo: 400),
            // Fresh and opened a lot, but the title only matches mid-word (0.3).
            session(2, title: "Repayments ledger", updatedDaysAgo: 0, opens: 50, openedDaysAgo: 0),
        ])

        let results = search(index, "payments")

        XCTAssertEqual(results.map(\.session.id), [1, 2])
        XCTAssertTrue(results[0].isWordLevel)
        XCTAssertFalse(results[1].isWordLevel)
        // The mid-word row has the higher score; the word-level gate still puts the branch first.
        XCTAssertGreaterThan(results[1].score, results[0].score)
        XCTAssertEqual(results[0].note, .field(.branch, value: "feature/payments"))
    }

    func test_note_reports_non_title_field() {
        let index = makeIndex([
            session(1, title: "Fix login", branch: "main", updatedDaysAgo: 1),
            session(2, title: "login main", branch: "main", updatedDaysAgo: 2),
            session(3, title: "Fix login", repoRoot: "/nonexistent-zt/src/main", updatedDaysAgo: 3),
            session(4, title: "Fix login", cwd: "/nonexistent-zt/scratch/main", updatedDaysAgo: 4),
        ])

        let results = search(index, "login main")
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.session.id, $0) })

        XCTAssertEqual(Set(byID.keys), [1, 2, 3, 4])
        XCTAssertEqual(byID[1]?.note, .field(.branch, value: "main"))
        XCTAssertNil(byID[2]?.note, "every term matched in the title")
        XCTAssertEqual(byID[3]?.note, .field(.repo, value: "main"))
        XCTAssertEqual(byID[4]?.note, .field(.folder, value: "main"))
        // The title-only row also earns the title phrase bonus.
        XCTAssertEqual(results.first?.session.id, 2)
        XCTAssertEqual(byID[1]?.titleHighlights, [NSRange(location: 4, length: 5)])
        XCTAssertEqual(byID[2]?.titleHighlights, [NSRange(location: 0, length: 5), NSRange(location: 6, length: 4)])
    }

    func test_every_term_must_match_some_field() {
        let index = makeIndex([
            session(1, title: "Fix login", branch: "main", updatedDaysAgo: 1),
            session(2, title: "Fix login", updatedDaysAgo: 1),
        ])

        XCTAssertEqual(search(index, "login main").map(\.session.id), [1])
        XCTAssertEqual(search(index, "logout").map(\.session.id), [])
    }

    func test_archived_session_ranks_below_equal_match() {
        let index = makeIndex([
            session(1, title: "Deploy pipeline", updatedDaysAgo: 5, archived: true),
            session(2, title: "Deploy pipeline", updatedDaysAgo: 5),
        ])

        let results = search(index, "deploy")

        XCTAssertEqual(results.map(\.session.id), [2, 1])
        XCTAssertEqual(results[1].score, results[0].score * 0.8, accuracy: 1e-9)
    }

    // MARK: - Filters

    func test_filters_agent_repo_branch_dates_scope() {
        let index = makeIndex([
            session(1, title: "Deploy app", agent: .claude, mainRepoRoot: "/nonexistent-zt/src/App",
                    branch: "feat/Deploy-Fix", createdDaysAgo: 40, updatedDaysAgo: 30),
            session(2, title: "Deploy app", agent: .codex, repoRoot: "/nonexistent-zt/src/other",
                    branch: "main", createdDaysAgo: 12, updatedDaysAgo: 10),
            session(3, title: "Deploy app", agent: .grok, repoRoot: "/nonexistent-zt/worktrees/app",
                    mainRepoRoot: "/nonexistent-zt/src/App", branch: "release", createdDaysAgo: 3,
                    updatedDaysAgo: 1),
            session(4, title: "Unrelated", agent: .codex, branch: "feat/x", updatedDaysAgo: 1),
        ])

        XCTAssertEqual(search(index, "agent:codex deploy").map(\.session.id), [2])
        XCTAssertEqual(Set(search(index, "agent:claude agent:grok deploy").map(\.session.id)), [1, 3])
        // Repo by basename of the main repo root or the repo root, case-insensitively.
        XCTAssertEqual(Set(search(index, "repo:app deploy").map(\.session.id)), [1, 3])
        XCTAssertEqual(search(index, "repo:OTHER deploy").map(\.session.id), [2])
        XCTAssertEqual(search(index, "repo:/nonexistent-zt/worktrees/app deploy").map(\.session.id), [3])
        XCTAssertEqual(search(index, "repo:ap deploy").map(\.session.id), [])
        // Branch by case-insensitive substring; several values are OR-ed.
        XCTAssertEqual(search(index, "branch:deploy-fix deploy").map(\.session.id), [1])
        XCTAssertEqual(Set(search(index, "branch:main branch:release deploy").map(\.session.id)), [2, 3])

        // after: updated on or after the day; before: created before the day.
        let day = { (daysAgo: Int) -> String in
            let date = Date(timeIntervalSince1970: TimeInterval(self.nowMs - Int64(daysAgo) * self.dayMs) / 1000)
            let parts = self.utc.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        XCTAssertEqual(Set(search(index, "after:\(day(10)) deploy").map(\.session.id)), [2, 3])
        XCTAssertEqual(Set(search(index, "before:\(day(12)) deploy").map(\.session.id)), [1])
        XCTAssertEqual(Set(search(index, "before:\(day(11)) deploy").map(\.session.id)), [1, 2])

        XCTAssertEqual(
            Set(search(index, "deploy", scope: projectScope("/nonexistent-zt/src/App")).map(\.session.id)), [1, 3])
    }

    func test_repository_scope_admits_cwd_only_for_repo_less_sessions() {
        let index = makeIndex([
            session(1, title: "Build cache", cwd: "/nonexistent-zt/src/app/Sources",
                    mainRepoRoot: "/nonexistent-zt/src/app", updatedDaysAgo: 1),
            session(2, title: "Build cache", cwd: "/nonexistent-zt/src/app/scripts", updatedDaysAgo: 2),
            session(3, title: "Build cache", cwd: "/nonexistent-zt/src/app/vendor/lib",
                    repoRoot: "/nonexistent-zt/src/app/vendor/lib", updatedDaysAgo: 3),
            session(4, title: "Build cache", cwd: "/nonexistent-zt/src/application", updatedDaysAgo: 4),
        ])

        let scope = projectScope("/nonexistent-zt/src/app")
        XCTAssertEqual(search(index, "build", scope: scope).map(\.session.id), [1, 2])
        XCTAssertEqual(index.recent(limit: 10, scope: scope).map(\.id), [1, 2])
        XCTAssertEqual(index.sessionCount(scope: scope), 2)

        let exactOnly = projectScope("/nonexistent-zt/src/app", allowsCWDPrefix: false)
        XCTAssertEqual(search(index, "build", scope: exactOnly).map(\.session.id), [1])
    }

    func test_filters_only_query_sorted_by_recency() {
        let index = makeIndex([
            session(1, title: "Oldest", agent: .codex, updatedDaysAgo: 30, opens: 90, openedDaysAgo: 0),
            session(2, title: "Newest", agent: .codex, updatedDaysAgo: 1),
            session(3, title: "Middle", agent: .codex, updatedDaysAgo: 5, archived: true),
            session(4, title: "Other agent", agent: .claude, updatedDaysAgo: 0),
        ])

        let response = index.search(query("agent:codex"), context: context())

        XCTAssertEqual(response.results.map(\.session.id), [2, 3, 1])
        XCTAssertTrue(response.results.allSatisfy { $0.titleHighlights.isEmpty && $0.note == nil })
        XCTAssertEqual(response.generation, 1)
    }

    func test_limit_20() {
        let sessions = (1...30).map { session(Int64($0), title: "Refactor parser \($0)", updatedDaysAgo: Double($0)) }
        let index = makeIndex(sessions)

        let results = search(index, "refactor")
        XCTAssertEqual(results.count, 20)
        // Same match quality everywhere: usage (recency) decides, so the 20 newest win in order.
        XCTAssertEqual(results.map(\.session.id), (1...20).map(Int64.init))

        XCTAssertEqual(search(index, "refactor", limit: 5).map(\.session.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(search(index, "agent:claude", limit: 20).count, 20)
    }

    func test_recent_returns_10_newest_in_scope() {
        var sessions = (1...15).map {
            session(Int64($0), title: "In repo \($0)", mainRepoRoot: "/nonexistent-zt/src/app",
                    updatedDaysAgo: Double($0) * 2)
        }
        sessions += (16...25).map {
            session(Int64($0), title: "Elsewhere \($0)", mainRepoRoot: "/nonexistent-zt/src/other",
                    updatedDaysAgo: Double($0 - 15) * 2 - 1)
        }
        let index = makeIndex(sessions)

        XCTAssertEqual(
            index.recent(limit: 10, scope: projectScope("/nonexistent-zt/src/app")).map(\.id),
            (1...10).map(Int64.init))
        let all = index.recent(limit: 10, scope: .all)
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(all.map(\.updatedAtMs), all.map(\.updatedAtMs).sorted(by: >))
        XCTAssertEqual(index.sessionCount(scope: .all), 25)
    }

    func test_live_sessions_are_indexed_hidden_or_not_indexed() {
        let one = session(1, title: "One", agent: .claude, updatedDaysAgo: 1)
        let two = session(2, title: "Two", agent: .codex, updatedDaysAgo: 2)
        let index = makeIndex([one, two])

        let lookups = index.liveSessions([
            (key: two.key, workingDirectory: nil),
            (key: AgentHistorySessionKey(agent: .grok, nativeID: "native-1"), workingDirectory: "/nonexistent-zt/src"),
            (key: one.key, workingDirectory: nil),
        ])
        XCTAssertEqual(lookups, [.indexed(two), .notIndexed, .indexed(one)])
        XCTAssertEqual(index.summary(forSessionID: 2)?.title, "Two")
        XCTAssertNil(index.summary(forSessionID: 99))
    }

    /// Generations restart with every indexer, so two empty snapshots can share one.
    func test_live_lookup_follows_removals_when_an_empty_snapshot_repeats_a_generation() {
        let key = AgentHistorySessionKey(agent: .claude, nativeID: "removed")
        let current = OSAllocatedUnfairLock(
            initialState: AgentHistoryMetadataSnapshot(generation: 1, sessions: [], isComplete: true)
        )
        let index = HistoryMetadataIndex(
            snapshot: { current.withLock { $0 } },
            exclusions: { AgentHistoryExclusionMatcher(folders: []) }
        )
        XCTAssertEqual(index.liveSessions([(key: key, workingDirectory: nil)]), [.notIndexed])

        current.withLock {
            $0 = AgentHistoryMetadataSnapshot(generation: 1, sessions: [], isComplete: true, removedKeys: [key])
        }

        XCTAssertEqual(index.liveSessions([(key: key, workingDirectory: nil)]), [.hidden])
    }

    func test_live_sessions_the_index_hides_are_told_apart_from_not_indexed_ones() {
        let exclusions = ExclusionsBox()
        exclusions.set(["/nonexistent-zt/private"])
        let shown = session(1, title: "Shown", agent: .claude, cwd: "/nonexistent-zt/src/app", updatedDaysAgo: 1)
        let excluded = session(2, title: "Excluded", agent: .claude, cwd: "/nonexistent-zt/private/notes", updatedDaysAgo: 2)
        let codex = session(3, title: "Codex", agent: .codex, cwd: "/nonexistent-zt/src/app", updatedDaysAgo: 3)
        let removed = AgentHistorySessionKey(agent: .claude, nativeID: "removed")
        let snapshot = AgentHistoryMetadataSnapshot(
            generation: 1, sessions: [shown, excluded, codex], isComplete: true, removedKeys: [removed])
        let index = HistoryMetadataIndex(
            snapshot: { snapshot }, exclusions: { exclusions.value }, enabledAgents: { [.claude] })

        let lookups = index.liveSessions([
            (key: shown.key, workingDirectory: "/nonexistent-zt/src/app"),
            (key: removed, workingDirectory: "/nonexistent-zt/src/app"),
            (key: excluded.key, workingDirectory: "/nonexistent-zt/src/app"),
            (key: codex.key, workingDirectory: "/nonexistent-zt/src/app"),
            (key: AgentHistorySessionKey(agent: .codex, nativeID: "new"), workingDirectory: "/nonexistent-zt/src/app"),
            (key: AgentHistorySessionKey(agent: .claude, nativeID: "new"), workingDirectory: "/nonexistent-zt/private/x"),
            (key: AgentHistorySessionKey(agent: .claude, nativeID: "new"), workingDirectory: "/nonexistent-zt/src/app"),
        ])
        XCTAssertEqual(lookups, [
            .indexed(shown),
            .hidden, // removed from History
            .hidden, // its indexed folder is excluded, whatever the pane's folder
            .hidden, // its agent is turned off
            .hidden, // not indexed, but its agent is turned off
            .hidden, // not indexed, but the pane's folder is excluded
            .notIndexed,
        ])
    }

    // MARK: - Exclusions and snapshots

    func test_excluded_folder_hidden_at_query_time() {
        let exclusions = ExclusionsBox()
        let index = makeIndex([
            session(1, title: "Secret plan", cwd: "/nonexistent-zt/private/notes", updatedDaysAgo: 1),
            session(2, title: "Secret recipe", cwd: "/nonexistent-zt/src/app", updatedDaysAgo: 2),
        ], exclusions: exclusions)

        XCTAssertEqual(search(index, "secret").map(\.session.id), [1, 2])

        // Excluded after indexing: hidden before the purge removes the rows.
        exclusions.set(["/nonexistent-zt/private"])

        XCTAssertEqual(search(index, "secret").map(\.session.id), [2])
        XCTAssertEqual(index.search(query(""), context: context()).results.map(\.session.id), [2])
        XCTAssertEqual(index.recent(limit: 10, scope: .all).map(\.id), [2])
        XCTAssertEqual(index.sessionCount(scope: .all), 1)
        XCTAssertNil(index.summary(forSessionID: 1))
        XCTAssertEqual(
            index.liveSessions([(key: AgentHistorySessionKey(agent: .claude, nativeID: "native-1"), workingDirectory: nil)]),
            [.hidden])

        exclusions.set([])
        XCTAssertEqual(search(index, "secret").map(\.session.id), [1, 2])
    }

    func test_new_snapshot_generation_is_picked_up() {
        let box = SnapshotBox(snapshot([session(1, title: "Alpha", updatedDaysAgo: 1)], generation: 1))
        let index = HistoryMetadataIndex(snapshot: { box.value }, exclusions: { AgentHistoryExclusionMatcher(folders: []) })

        XCTAssertEqual(index.search(query("beta"), context: context()).results.count, 0)

        box.set(snapshot([
            session(1, title: "Alpha", updatedDaysAgo: 1),
            session(2, title: "Beta", updatedDaysAgo: 0),
        ], generation: 2))

        let response = index.search(query("beta"), context: context())
        XCTAssertEqual(response.generation, 2)
        XCTAssertEqual(response.results.map(\.session.id), [2])
        XCTAssertEqual(index.summary(forSessionID: 2)?.title, "Beta")
    }

    func test_restarted_indexer_reusing_a_generation_is_not_served_from_cache() {
        let box = SnapshotBox(snapshot([session(1, title: "Alpha", updatedDaysAgo: 1)], generation: 3))
        let index = HistoryMetadataIndex(snapshot: { box.value }, exclusions: { AgentHistoryExclusionMatcher(folders: []) })
        XCTAssertEqual(index.search(query("alpha"), context: context()).results.map(\.session.id), [1])

        // Turned off and on: the new indexer counts generations from zero again and reaches 3
        // with different sessions before the next keystroke.
        box.set(snapshot([session(7, title: "Gamma", updatedDaysAgo: 1)], generation: 3))

        XCTAssertEqual(index.search(query("alpha"), context: context()).results.count, 0)
        XCTAssertEqual(index.search(query("gamma"), context: context()).results.map(\.session.id), [7])
        XCTAssertNil(index.summary(forSessionID: 1))
    }

    // MARK: - Budget

    func test_search_10k_sessions_under_budget() {
        let words = ["login", "crash", "parser", "deploy", "refactor", "cache", "payments", "migration",
                     "flaky", "test", "sidebar", "render", "build", "index", "search", "worker"]
        let repos = (0..<40).map { "/nonexistent-zt/src/repo\($0)" }
        let sessions: [AgentHistorySessionSummary] = (0..<10_000).map { i in
            let title = (0..<4).map { words[(i * 7 + $0 * 5 + i / 13) % words.count] }.joined(separator: " ")
            return session(
                Int64(i + 1),
                title: "\(title) \(i)",
                agent: AgentHistoryAgent.allCases[i % AgentHistoryAgent.allCases.count],
                cwd: repos[i % repos.count] + "/Sources",
                mainRepoRoot: repos[i % repos.count],
                branch: i % 3 == 0 ? "feature/\(words[i % words.count])-\(i)" : "main",
                updatedDaysAgo: Double(i % 365),
                opens: i % 11,
                openedDaysAgo: i % 11 == 0 ? nil : Double(i % 30)
            )
        }
        let index = makeIndex(sessions)
        let queries = ["login crash", "pay", "refactor parser agent:codex", "migr", "repo:repo7 build", "zzzz"]
            .map(query)
        let scope = projectScope("/nonexistent-zt/src/repo3")

        // Warm the per-generation cache.
        _ = index.search(queries[0], context: context())

        var samples: [Double] = []
        for _ in 0..<5 {
            for q in queries {
                let start = DispatchTime.now().uptimeNanoseconds
                let response = index.search(q, context: context())
                _ = index.search(q, context: context(scope))
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 2_000_000)
                XCTAssertLessThanOrEqual(response.results.count, 20)
            }
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let strict = ProcessInfo.processInfo.environment["ZENTTY_HISTORY_BENCH"] == "1"
        let budget = strict ? 5.0 : 25.0
        print("HistoryMetadataIndex 10k median \(String(format: "%.2f", median)) ms (budget \(budget) ms)")
        XCTAssertLessThan(median, budget)
        XCTAssertFalse(index.search(queries[0], context: context()).results.isEmpty)
    }
}
