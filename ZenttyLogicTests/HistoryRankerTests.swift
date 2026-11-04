import Foundation
import XCTest
@testable import Zentty

final class HistoryRankerTests: XCTestCase {
    private let dayMs: Int64 = 86_400_000
    private let nowMs: Int64 = 1_800_000_000_000
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }

    private func context(
        scope: AgentHistoryScope = .all,
        currentRepositoryKey: String? = nil
    ) -> HistorySearchContext {
        HistorySearchContext(scope: scope, currentRepositoryKey: currentRepositoryKey, now: now)
    }

    private func facts(
        ageDays: Double = 1000,
        opens: Int = 0,
        openedDaysAgo: Double? = nil,
        archived: Bool = false,
        mainRepoRoot: String? = nil,
        repoRoot: String? = nil
    ) -> HistoryRankFacts {
        HistoryRankFacts(
            updatedAtMs: nowMs - Int64(ageDays * Double(dayMs)),
            opens: opens,
            lastOpenedAtMs: openedDaysAgo.map { nowMs - Int64($0 * Double(dayMs)) },
            isArchived: archived,
            mainRepoRoot: mainRepoRoot,
            repoRoot: repoRoot
        )
    }

    private func hit(
        session: Int64,
        row: Int64,
        role: HistoryHitRole = .agent,
        atMs: Int64? = nil,
        quality: Double = 1.0,
        wordLevel: Bool? = nil,
        artifactValue: String? = nil
    ) -> HistoryContentHit {
        HistoryContentHit(
            sessionID: session,
            rowID: row,
            role: role,
            atMs: atMs ?? (nowMs - 10 * dayMs + row),
            gradedQuality: quality,
            isWordLevel: wordLevel ?? (quality >= 0.8),
            artifactValue: artifactValue
        )
    }

    private func summary(
        id: Int64,
        updatedDaysAgo: Double = 1000,
        title: String = "Session"
    ) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/agent-history-root", agent: .claude,
            nativeID: "native-\(id)", title: title, titleKind: .custom,
            createdAtMs: nowMs - 2000 * dayMs,
            updatedAtMs: nowMs - Int64(updatedDaysAgo * Double(dayMs)),
            turnCount: 3
        )
    }

    // MARK: - Grouping

    func test_groups_by_session_and_keeps_best_hit() {
        let hits = [
            hit(session: 1, row: 10, quality: 0.3, wordLevel: false),
            hit(session: 1, row: 11, quality: 1.25),
            hit(session: 1, row: 12, quality: 0.8),
            hit(session: 2, row: 20, quality: 1.0),
        ]
        let ranked = HistoryRanker.rankContent(
            hits: hits,
            facts: [1: facts(), 2: facts()],
            context: context()
        )

        XCTAssertEqual(ranked.results.map(\.sessionID), [1, 2])
        XCTAssertEqual(ranked.results[0].best.rowID, 11)
        XCTAssertEqual(ranked.results[0].totalHits, 3)
        XCTAssertEqual(ranked.results[0].bestQualityHits, 1)
        XCTAssertTrue(ranked.results[0].isWordLevel)
        XCTAssertEqual(ranked.results[1].best.rowID, 20)
        XCTAssertEqual(ranked.results[1].totalHits, 1)
        XCTAssertTrue(ranked.enrichments.isEmpty)
    }

    func test_tie_prefers_user_then_newest() {
        let hits = [
            hit(session: 1, row: 1, role: .agent, atMs: nowMs - 1 * dayMs),
            hit(session: 1, row: 2, role: .user, atMs: nowMs - 5 * dayMs),
            hit(session: 1, row: 3, role: .user, atMs: nowMs - 3 * dayMs),
            hit(session: 1, row: 4, role: .artifact(.path), atMs: nowMs, quality: 1.0 / 0.9),
        ]
        let ranked = HistoryRanker.rankContent(hits: hits, facts: [1: facts()], context: context())

        // Equal quality: the user hits beat the agent hit and the (discounted) artifact; of the
        // two user hits the newer wins.
        XCTAssertEqual(ranked.results.first?.best.rowID, 3)
        XCTAssertEqual(ranked.results.first?.bestQualityHits, 4)
    }

    func test_hits_multiplier_uses_best_quality_hits_only() {
        let oneBest = HistoryRanker.rankContent(
            hits: [hit(session: 1, row: 1, quality: 1.0)]
                + (2...6).map { hit(session: 1, row: $0, quality: 0.8) },
            facts: [1: facts()],
            context: context()
        ).results[0]
        let threeBest = HistoryRanker.rankContent(
            hits: (1...3).map { hit(session: 2, row: $0, quality: 1.0) },
            facts: [2: facts()],
            context: context()
        ).results[0]

        let usage = HistoryRanker.usage(facts(), now: now)
        XCTAssertEqual(oneBest.bestQualityHits, 1)
        XCTAssertEqual(oneBest.totalHits, 6)
        XCTAssertEqual(oneBest.score, 1.0 * (1 + 0.15 * log2(2.0)) * usage, accuracy: 1e-9)
        XCTAssertEqual(threeBest.bestQualityHits, 3)
        XCTAssertEqual(threeBest.score, 1.0 * (1 + 0.15 * log2(4.0)) * usage, accuracy: 1e-9)
    }

    // MARK: - Usage

    func test_usage_recency_decay_14_days() {
        XCTAssertEqual(HistoryRanker.usage(facts(ageDays: 0), now: now), 2.0, accuracy: 1e-9)
        XCTAssertEqual(HistoryRanker.usage(facts(ageDays: 14), now: now), 1.5, accuracy: 1e-9)
        XCTAssertEqual(HistoryRanker.usage(facts(ageDays: 28), now: now), 1.25, accuracy: 1e-9)
        XCTAssertEqual(HistoryRanker.usage(facts(ageDays: 1000), now: now), 1.0, accuracy: 1e-6)
        // A timestamp in the future counts as "now", never above it.
        XCTAssertEqual(HistoryRanker.usage(facts(ageDays: -3), now: now), 2.0, accuracy: 1e-9)
    }

    func test_usage_opens_term_and_cap_2_5() {
        // Opened once, just now: 0.5·log2(1 + 1) = 0.5.
        XCTAssertEqual(
            HistoryRanker.usage(facts(opens: 1, openedDaysAgo: 0), now: now), 1.5, accuracy: 1e-6)
        // Three opens, 14 days ago: 0.5·log2(1 + 3·0.5) = 0.5·log2(2.5).
        XCTAssertEqual(
            HistoryRanker.usage(facts(opens: 3, openedDaysAgo: 14), now: now),
            1 + 0.5 * log2(2.5), accuracy: 1e-6)
        // Opens without a last-opened time add nothing.
        XCTAssertEqual(HistoryRanker.usage(facts(opens: 5), now: now), 1.0, accuracy: 1e-6)
        // Fresh and opened a lot: capped.
        XCTAssertEqual(
            HistoryRanker.usage(facts(ageDays: 0, opens: 50, openedDaysAgo: 0), now: now), 2.5)
    }

    // MARK: - Boosts and penalties

    func test_repo_boost_only_in_all_scope_and_matches_main_or_repo_root() {
        let main = facts(mainRepoRoot: "/src/app", repoRoot: "/src/app-wt")
        let repoOnly = facts(repoRoot: "/src/app")
        let other = facts(mainRepoRoot: "/src/other", repoRoot: "/src/other")
        let none = facts()

        let all = context(currentRepositoryKey: "/src/app")
        XCTAssertEqual(HistoryRanker.repoBoost(main, context: all), 1.2)
        XCTAssertEqual(HistoryRanker.repoBoost(repoOnly, context: all), 1.2)
        XCTAssertEqual(HistoryRanker.repoBoost(other, context: all), 1.0)
        XCTAssertEqual(HistoryRanker.repoBoost(none, context: all), 1.0)
        XCTAssertEqual(
            HistoryRanker.repoBoost(facts(mainRepoRoot: "/src/x", repoRoot: "/src/app"), context: all), 1.2)

        let project = context(
            scope: .project(AgentHistoryProjectScope(key: "/src/app", displayName: "app", allowsCWDPrefix: true)),
            currentRepositoryKey: "/src/app"
        )
        XCTAssertEqual(HistoryRanker.repoBoost(main, context: project), 1.0)
        XCTAssertEqual(HistoryRanker.repoBoost(main, context: context(currentRepositoryKey: nil)), 1.0)

        // End to end: the boosted session wins an otherwise equal tie.
        let ranked = HistoryRanker.rankContent(
            hits: [hit(session: 1, row: 1, atMs: nowMs), hit(session: 2, row: 2, atMs: nowMs - 1)],
            facts: [1: other, 2: main],
            context: all
        )
        XCTAssertEqual(ranked.results.map(\.sessionID), [2, 1])
        XCTAssertEqual(ranked.results[0].score / ranked.results[1].score, 1.2, accuracy: 1e-9)
    }

    func test_archived_penalty() {
        XCTAssertEqual(HistoryRanker.archivedPenalty(facts(archived: true)), 0.8)
        XCTAssertEqual(HistoryRanker.archivedPenalty(facts(archived: false)), 1.0)

        let ranked = HistoryRanker.rankContent(
            hits: [hit(session: 1, row: 1, atMs: nowMs), hit(session: 2, row: 2, atMs: nowMs - 1)],
            facts: [1: facts(archived: true), 2: facts()],
            context: context()
        )
        XCTAssertEqual(ranked.results.map(\.sessionID), [2, 1])
        XCTAssertEqual(ranked.results[1].score / ranked.results[0].score, 0.8, accuracy: 1e-9)
    }

    // MARK: - Ordering

    func test_word_level_always_above_mid_word_even_with_higher_usage() {
        let ranked = HistoryRanker.rankContent(
            hits: [
                // Mid-word, phrase bonus, fresh, opened a lot, current repo.
                hit(session: 1, row: 1, quality: 0.55, wordLevel: false),
                hit(session: 1, row: 2, quality: 0.55, wordLevel: false),
                // Whole word, old, archived.
                hit(session: 2, row: 3, quality: 0.8, wordLevel: true),
            ],
            facts: [
                1: facts(ageDays: 0, opens: 40, openedDaysAgo: 0, mainRepoRoot: "/src/app"),
                2: facts(ageDays: 900, archived: true),
            ],
            context: context(currentRepositoryKey: "/src/app")
        )

        XCTAssertGreaterThan(ranked.results[1].score, ranked.results[0].score)
        XCTAssertEqual(ranked.results.map(\.sessionID), [2, 1])
        XCTAssertFalse(ranked.results[1].isWordLevel)
    }

    func test_equal_scores_order_by_best_hit_time_then_session_id() {
        let ranked = HistoryRanker.rankContent(
            hits: [
                hit(session: 1, row: 1, atMs: nowMs - 5),
                hit(session: 2, row: 2, atMs: nowMs - 1),
                hit(session: 3, row: 3, atMs: nowMs - 5),
            ],
            facts: [1: facts(), 2: facts(), 3: facts()],
            context: context()
        )
        XCTAssertEqual(ranked.results.map(\.sessionID), [2, 3, 1])
    }

    func test_excluded_sessions_become_enrichments() {
        let ranked = HistoryRanker.rankContent(
            hits: [
                hit(session: 1, row: 1),
                hit(session: 2, row: 2),
                hit(session: 2, row: 3, quality: 0.3, wordLevel: false),
                hit(session: 3, row: 4),
            ],
            facts: [1: facts(), 2: facts(), 3: facts()],
            context: context(),
            excludingSessionIDs: [2, 99]
        )

        XCTAssertEqual(Set(ranked.results.map(\.sessionID)), [1, 3])
        XCTAssertEqual(Set(ranked.enrichments.keys), [2])
        XCTAssertEqual(ranked.enrichments[2]?.best.rowID, 2)
        XCTAssertEqual(ranked.enrichments[2]?.totalHits, 2)
    }

    func test_content_limit_30() {
        let hits = (1...45).map { hit(session: Int64($0), row: Int64($0)) }
        let facts = Dictionary(uniqueKeysWithValues: (1...45).map { (Int64($0), self.facts()) })
        let ranked = HistoryRanker.rankContent(
            hits: hits, facts: facts, context: context(), excludingSessionIDs: [45, 44]
        )

        XCTAssertEqual(HistoryRanker.contentLimit, 30)
        XCTAssertEqual(ranked.results.count, 30)
        // Newest best hit first; the two excluded (newest) sessions are enrichments, not results.
        XCTAssertEqual(ranked.results.first?.sessionID, 43)
        XCTAssertEqual(ranked.results.last?.sessionID, 14)
        XCTAssertEqual(Set(ranked.enrichments.keys), [44, 45])
    }

    func test_artifact_quality_discount_loses_tie_to_message() {
        let artifact = hit(session: 1, row: 1, role: .artifact(.path), atMs: nowMs, artifactValue: "src/app.swift")
        XCTAssertEqual(artifact.quality, 0.9, accuracy: 1e-12)
        XCTAssertTrue(artifact.isWordLevel)

        let ranked = HistoryRanker.rankContent(
            hits: [
                artifact,
                hit(session: 2, row: 2, role: .agent, atMs: nowMs - dayMs),
                // Inside one session the message beats an artifact of the same grade.
                hit(session: 3, row: 3, role: .artifact(.command), atMs: nowMs, artifactValue: "make"),
                hit(session: 3, row: 4, role: .agent, atMs: nowMs - dayMs),
            ],
            facts: [1: facts(), 2: facts(), 3: facts()],
            context: context()
        )

        XCTAssertEqual(ranked.results.map(\.sessionID).first, 3)
        XCTAssertEqual(ranked.results.first?.best.rowID, 4)
        XCTAssertEqual(ranked.results.first?.bestQualityHits, 1)
        XCTAssertEqual(ranked.results.map(\.sessionID).last, 1)
    }

    func test_hits_without_facts_are_ignored() {
        let ranked = HistoryRanker.rankContent(
            hits: [hit(session: 1, row: 1), hit(session: 7, row: 2)],
            facts: [1: facts()],
            context: context()
        )
        XCTAssertEqual(ranked.results.map(\.sessionID), [1])
    }

    // MARK: - Merged (CLI)

    func test_merged_takes_max_and_respects_gate() {
        func metadata(_ id: Int64, score: Double, word: Bool) -> HistoryMetadataResult {
            HistoryMetadataResult(
                session: summary(id: id), score: score, isWordLevel: word, titleHighlights: [],
                note: .field(.branch, value: "main"))
        }
        func content(_ id: Int64, score: Double, word: Bool) -> HistoryContentResult {
            HistoryContentResult(
                session: summary(id: id),
                best: hit(session: id, row: id * 10, role: .user, atMs: nowMs - dayMs),
                bestQualityHits: 1, totalHits: 2, score: score, isWordLevel: word,
                snippet: nil, note: nil, titleHighlights: [])
        }

        let merged = HistoryRanker.merge(
            metadata: [
                metadata(1, score: 1.5, word: true),   // content 2.0 is higher → content
                metadata(2, score: 3.0, word: true),   // content 1.0 is lower → metadata
                metadata(3, score: 9.0, word: false),  // mid-word only: below every word-level row
                metadata(4, score: 1.0, word: true),   // mid-word content 5.0 cannot outrank it
            ],
            content: [
                content(1, score: 2.0, word: true),
                content(2, score: 1.0, word: true),
                content(4, score: 5.0, word: false),
                content(5, score: 1.2, word: true),
            ],
            limit: 10
        )

        XCTAssertEqual(merged.map(\.session.id), [2, 1, 5, 4, 3])
        XCTAssertEqual(merged.map(\.score), [3.0, 2.0, 1.2, 1.0, 9.0])
        XCTAssertEqual(merged[0].match, .metadata(note: .field(.branch, value: "main")))
        guard case .content(let role, let at, _, _) = merged[1].match else {
            return XCTFail("expected a content match for session 1")
        }
        XCTAssertEqual(role, .user)
        XCTAssertEqual(at, Date(timeIntervalSince1970: TimeInterval(nowMs - dayMs) / 1000))
        XCTAssertTrue(merged[3].isWordLevel)
        XCTAssertFalse(merged[4].isWordLevel)

        let limited = HistoryRanker.merge(
            metadata: [metadata(1, score: 1.5, word: true), metadata(2, score: 3.0, word: true)],
            content: [content(5, score: 1.2, word: true)],
            limit: 2
        )
        XCTAssertEqual(limited.map(\.session.id), [2, 1])
    }
}
