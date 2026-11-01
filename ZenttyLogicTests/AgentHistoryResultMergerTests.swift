import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryResultMergerTests: XCTestCase {
    private let nowMs: Int64 = 1_800_000_000_000

    private func summary(_ id: Int64, title: String = "Session") -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/agent-history-root", agent: .codex,
            nativeID: "native-\(id)", title: "\(title) \(id)", titleKind: .generated,
            createdAtMs: nowMs - 10_000, updatedAtMs: nowMs - id * 1000, turnCount: 4
        )
    }

    private func metadata(_ id: Int64) -> HistoryMetadataResult {
        HistoryMetadataResult(
            session: summary(id), score: 1, isWordLevel: true,
            titleHighlights: [NSRange(location: 0, length: 3)], note: .field(.branch, value: "main")
        )
    }

    private func content(_ id: Int64, hits: Int = 2) -> HistoryContentResult {
        HistoryContentResult(
            session: summary(id),
            best: HistoryContentHit(
                sessionID: id, rowID: id * 10, role: .user, atMs: nowMs - 5000,
                gradedQuality: 1, isWordLevel: true
            ),
            bestQualityHits: 1, totalHits: hits, score: 1, isWordLevel: true,
            snippet: HistorySnippet(
                text: "fix the crash", highlights: [NSRange(location: 8, length: 5)],
                truncatedStart: false, truncatedEnd: false
            ),
            note: nil, titleHighlights: []
        )
    }

    private func query(_ raw: String = "crash") -> HistoryQuery {
        HistoryQueryParser.parse(raw)
    }

    private func contentResponse(
        _ results: [HistoryContentResult],
        enrichments: [Int64: HistoryContentResult] = [:]
    ) -> HistoryContentResponse {
        HistoryContentResponse(
            query: query(), generation: 1, results: results, enrichments: enrichments,
            mode: .fts, truncated: false, elapsed: 0
        )
    }

    // MARK: - Limits

    func test_limits_sessions_to_20_and_conversations_to_30() {
        let metadataResponse = HistoryMetadataResponse(
            query: query(), generation: 1, results: (1...25).map { metadata(Int64($0)) }, elapsed: 0
        )
        let sessions = AgentHistoryResultMerger.metadataRows(metadataResponse)
        XCTAssertEqual(sessions.count, AgentHistoryResultMerger.sessionsLimit)
        XCTAssertEqual(sessions.first?.title, AgentHistoryHighlightedText("Session 1", ranges: [NSRange(location: 0, length: 3)]))
        XCTAssertEqual(sessions.first?.note, .field(.branch, value: "main"))

        let merge = AgentHistoryResultMerger.applyContent(
            response: contentResponse((100...140).map { content(Int64($0)) }),
            to: [],
            metadataIDs: []
        )
        XCTAssertEqual(merge.conversations.count, AgentHistoryResultMerger.conversationsLimit)
        XCTAssertEqual(merge.conversations.first?.sessionID, 100)
    }

    func test_content_row_carries_snippet_hits_and_match_time() {
        let row = AgentHistoryResultRow(content: content(7, hits: 3))
        XCTAssertEqual(row.key, AgentHistorySessionKey(agent: .codex, nativeID: "native-7"))
        XCTAssertEqual(row.hitCount, 3)
        XCTAssertEqual(row.snippet?.role, .user)
        XCTAssertEqual(row.snippet?.text.ranges, [NSRange(location: 8, length: 5)])
        XCTAssertEqual(row.matchedAt, Date(timeIntervalSince1970: TimeInterval(nowMs - 5000) / 1000))
        XCTAssertEqual(row.displayDate, row.matchedAt)
        XCTAssertFalse(row.isStale)
    }

    // MARK: - Enrichment

    func test_enrichment_updates_metadata_row_and_never_duplicates_it() {
        let sessions = [AgentHistoryResultRow(metadata: metadata(1)), AgentHistoryResultRow(metadata: metadata(2))]
        let merge = AgentHistoryResultMerger.applyContent(
            response: contentResponse([content(2), content(3)], enrichments: [1: content(1, hits: 5)]),
            to: sessions,
            metadataIDs: [1, 2]
        )
        XCTAssertEqual(merge.sessions.map(\.sessionID), [1, 2])
        XCTAssertEqual(merge.sessions[0].hitCount, 5)
        XCTAssertEqual(merge.sessions[0].title, sessions[0].title)
        XCTAssertEqual(merge.sessions[1].hitCount, 0)
        XCTAssertEqual(merge.conversations.map(\.sessionID), [3])
    }

    func test_duplicate_content_results_keep_the_first() {
        let merge = AgentHistoryResultMerger.applyContent(
            response: contentResponse([content(4), content(4, hits: 9)]),
            to: [],
            metadataIDs: []
        )
        XCTAssertEqual(merge.conversations.map(\.hitCount), [2])
    }

    // MARK: - Stale rows

    func test_first_response_replaces_stale_rows() {
        let stale = AgentHistoryResultMerger.staleContent(
            [AgentHistoryResultRow(content: content(8)), AgentHistoryResultRow(content: content(9))],
            droppingSessionsIn: []
        )
        XCTAssertTrue(stale.allSatisfy(\.isStale))

        let merge = AgentHistoryResultMerger.applyContent(
            response: contentResponse([content(10)]), to: [], metadataIDs: []
        )
        XCTAssertEqual(merge.conversations.map(\.sessionID), [10])
        XCTAssertFalse(merge.conversations.contains(where: \.isStale))
    }

    func test_stale_rows_drop_sessions_now_in_metadata_tier() {
        let previous = [8, 9, 10].map { AgentHistoryResultRow(content: content(Int64($0))) }
        let stale = AgentHistoryResultMerger.staleContent(previous, droppingSessionsIn: [9])
        XCTAssertEqual(stale.map(\.sessionID), [8, 10])
        XCTAssertTrue(stale.allSatisfy(\.isStale))
    }

    // MARK: - Selection

    func test_selection_is_preserved_by_key() {
        let rows = [3, 1, 2].map { AgentHistoryResultRow(summary: summary(Int64($0))) }
        let selected = AgentHistoryResultMerger.resolveSelection(
            previous: summary(2).key, previousIndex: 0, in: rows
        )
        XCTAssertEqual(selected, summary(2).key)
    }

    func test_selection_clamps_to_previous_index_when_row_is_gone() {
        let rows = [1, 2, 3].map { AgentHistoryResultRow(summary: summary(Int64($0))) }
        XCTAssertEqual(
            AgentHistoryResultMerger.resolveSelection(previous: summary(9).key, previousIndex: 1, in: rows),
            summary(2).key
        )
        XCTAssertEqual(
            AgentHistoryResultMerger.resolveSelection(previous: summary(9).key, previousIndex: 7, in: rows),
            summary(3).key
        )
        XCTAssertEqual(
            AgentHistoryResultMerger.resolveSelection(previous: nil, previousIndex: nil, in: rows),
            summary(1).key
        )
        XCTAssertNil(AgentHistoryResultMerger.resolveSelection(previous: summary(1).key, previousIndex: 0, in: []))
    }

    // MARK: - Rows and pills

    func test_live_only_row_uses_pane_name_and_live_time() {
        let key = AgentHistorySessionKey(agent: .claude, nativeID: "1b9f3c1e-0000-4000-8000-000000000001")
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        let live = LiveAgentSessionLocation(
            key: key, windowID: WindowID("window"), worklaneID: WorklaneID("worklane"), paneID: PaneID("pane"),
            tool: .claudeCode, rawSessionID: key.nativeID, pid: 42, paneDisplayName: "Fix sidebar",
            worklaneDisplayName: "zentty", windowTitle: "Zentty", workingDirectory: "/tmp/zentty",
            updatedAt: updated, matchSource: .status
        )
        let row = AgentHistoryResultRow(live: live, summary: nil)
        XCTAssertEqual(row.key, key)
        XCTAssertNil(row.sessionID)
        XCTAssertEqual(row.title.text, "Fix sidebar")
        XCTAssertEqual(row.displayDate, updated)
    }

    func test_filter_pills_skip_invalid_values_and_mark_pending() {
        let pills = AgentHistoryFilterPill.pills(for: query("crash agent:codex repo: before:notadate"))
        XCTAssertEqual(pills.map(\.label), ["Agent: codex", "Repo:"])
        XCTAssertEqual(pills.map(\.isPending), [false, true])
        XCTAssertEqual(pills[1].accessibilityLabel, "Repo filter, waiting for a value")
    }
}
