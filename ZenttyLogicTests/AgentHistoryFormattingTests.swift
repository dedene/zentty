import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryFormattingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var formatting: AgentHistoryFormatting {
        AgentHistoryFormatting(locale: Locale(identifier: "en_US"), calendar: calendar)
    }

    /// 2026-10-31 14:30 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_457_000)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func status(
        _ state: AgentHistoryIndexerState,
        indexed: Int = 1284,
        updated: Date? = nil,
        tokenizer: AgentHistoryTokenizer? = .trigram,
        sources: [AgentHistorySourceHealth] = []
    ) -> AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = state
        status.indexedSessions = indexed
        status.lastUpdatedAt = updated
        status.tokenizer = tokenizer
        status.sources = sources
        return status
    }

    // MARK: - Times

    func test_relative_time_buckets() {
        XCTAssertEqual(formatting.relativeTime(ago(20), now: now), "just now")
        XCTAssertEqual(formatting.relativeTime(now.addingTimeInterval(300), now: now), "just now")
        XCTAssertEqual(formatting.relativeTime(ago(60), now: now), "1m ago")
        XCTAssertEqual(formatting.relativeTime(ago(59 * 60 + 59), now: now), "59m ago")
        XCTAssertEqual(formatting.relativeTime(ago(3 * 3600 + 120), now: now), "3h ago")
        XCTAssertEqual(formatting.relativeTime(ago(26 * 3600), now: now), "Yesterday")
        XCTAssertEqual(formatting.relativeTime(ago(4 * 86_400), now: now), "4 days ago")
        XCTAssertEqual(formatting.relativeTime(ago(19 * 86_400), now: now), "Oct 12")
        XCTAssertEqual(formatting.relativeTime(ago(400 * 86_400), now: now), "Sep 26, 2025")
    }

    // MARK: - Counts

    func test_session_count_and_matches_pluralize() {
        XCTAssertEqual(formatting.sessionCount(0), "0 sessions")
        XCTAssertEqual(formatting.sessionCount(1), "1 session")
        XCTAssertEqual(formatting.sessionCount(1284), "1,284 sessions")
        XCTAssertNil(formatting.matches(0))
        XCTAssertNil(formatting.matches(1))
        XCTAssertEqual(formatting.matches(2), "2 matches")
        XCTAssertEqual(formatting.matches(1500), "1,500 matches")
    }

    // MARK: - Footer

    func test_footer_health_for_watching_backfilling_and_limited_search() {
        XCTAssertEqual(
            formatting.footerHealth(status: status(.watching, updated: ago(10)), now: now),
            AgentHistoryFooterHealth(text: "1,284 sessions · updated just now", isWarning: false)
        )
        XCTAssertEqual(
            formatting.footerHealth(status: status(.watching, updated: ago(26 * 3600)), now: now).text,
            "1,284 sessions · updated yesterday"
        )
        XCTAssertEqual(formatting.footerHealth(status: status(.watching), now: now).text, "1,284 sessions")
        XCTAssertEqual(
            formatting.footerHealth(status: status(.watching, tokenizer: AgentHistoryTokenizer.none), now: now),
            AgentHistoryFooterHealth(text: "1,284 sessions · Limited search", isWarning: true)
        )
        XCTAssertEqual(
            formatting.footerHealth(
                status: status(.backfilling(AgentHistoryBackfillProgress(indexedSessions: 312, totalSessions: 1284))),
                now: now
            ),
            AgentHistoryFooterHealth(text: "Indexing 312 of 1,284 sessions", isWarning: false)
        )
    }

    func test_footer_health_for_paused_and_failed_states() {
        XCTAssertEqual(
            formatting.footerHealth(status: status(.paused(.lowPower, nil)), now: now),
            AgentHistoryFooterHealth(text: "Indexing paused while Low Power Mode is on", isWarning: true)
        )
        XCTAssertTrue(formatting.footerHealth(status: status(.paused(.diskFull, nil)), now: now).isWarning)
        XCTAssertEqual(
            formatting.footerHealth(status: status(.paused(.anotherInstance, nil), updated: ago(120)), now: now),
            AgentHistoryFooterHealth(text: "1,284 sessions · updated 2m ago", isWarning: false)
        )
        XCTAssertEqual(
            formatting.footerHealth(status: status(.failed(.corrupt)), now: now),
            AgentHistoryFooterHealth(text: "Index unavailable", isWarning: true)
        )
    }

    // MARK: - Problem link

    func test_problem_link_names_the_source_and_prefers_problem_over_skips() {
        XCTAssertNil(formatting.problemLink(status: status(.watching)))

        let skipped = AgentHistorySourceHealth(agent: .opencode, root: "/tmp/oc", isDefaultRoot: true, skipped: 2)
        XCTAssertEqual(formatting.problemLink(status: status(.watching, sources: [skipped])), "OpenCode: 2 skipped")

        let denied = AgentHistorySourceHealth(
            agent: .codex, root: "/tmp/codex", isDefaultRoot: true, skipped: 4, problem: .permissionDenied
        )
        XCTAssertEqual(formatting.problemLink(status: status(.watching, sources: [denied])), "Codex: Permission denied")
        XCTAssertEqual(
            formatting.problemLink(status: status(.watching, sources: [skipped, denied])),
            "2 sources have problems"
        )

        let disabled = AgentHistorySourceHealth(
            agent: .grok, root: "/tmp/grok", isDefaultRoot: true, isEnabled: false, skipped: 3
        )
        XCTAssertNil(formatting.problemLink(status: status(.watching, sources: [disabled])))
    }

    // MARK: - Notes and labels

    func test_note_text_for_fields_and_artifacts() {
        XCTAssertEqual(formatting.noteText(.field(.branch, value: "main")), "Branch: main")
        XCTAssertEqual(formatting.noteText(.field(.repo, value: "zentty")), "Repo: zentty")
        XCTAssertEqual(formatting.noteText(.field(.folder, value: "docs")), "Folder: docs")
        XCTAssertEqual(formatting.noteText(.artifact(.path, value: "a.swift")), "Changed: a.swift")
        XCTAssertEqual(formatting.noteText(.artifact(.command, value: "swift test")), "Ran: swift test")
        XCTAssertEqual(formatting.noteText(.artifact(.commit, value: "abc123")), "Commit: abc123")
        XCTAssertEqual(formatting.noteText(.artifact(.pr, value: "#12")), "PR: #12")
    }

    func test_row_accessibility_label_reads_the_whole_row() {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let summary = AgentHistorySessionSummary(
            id: 1, sourceID: 1, sourceRoot: "/tmp/claude", agent: .claude, nativeID: "n1",
            title: "Fix the sidebar", titleKind: .generated, cwd: "/tmp/zentty",
            repoRoot: "/tmp/zentty", branch: "main", createdAtMs: nowMs - 10_000_000,
            updatedAtMs: nowMs - 7_200_000, turnCount: 12, isArchived: true
        )
        var row = AgentHistoryResultRow(summary: summary)
        row.note = .artifact(.command, value: "swift test")
        row.hitCount = 3
        row.snippet = AgentHistorySnippetLine(role: .user, text: AgentHistoryHighlightedText("fix the sidebar"))

        XCTAssertEqual(
            formatting.rowAccessibilityLabel(row, isFolderGone: true, now: now),
            "Claude Code, Fix the sidebar, zentty, main, Ran: swift test, archived, folder gone, 3 matches, 2h ago, You said fix the sidebar"
        )

        let plain = AgentHistoryResultRow(summary: summary)
        XCTAssertEqual(
            formatting.rowAccessibilityLabel(plain, isFolderGone: false, now: now),
            "Claude Code, Fix the sidebar, zentty, main, archived, 2h ago"
        )
    }
}
