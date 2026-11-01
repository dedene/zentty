import Foundation
import XCTest
@testable import Zentty

final class AgentHistorySettingsFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = "/Users/tester"

    private func makeFormatter() -> AgentHistorySettingsFormatter {
        let fixedNow = now
        return AgentHistorySettingsFormatter(
            locale: Locale(identifier: "en_US"),
            homeDirectory: home,
            now: { fixedNow }
        )
    }

    private func status(
        isEnabled: Bool = true,
        hasConsented: Bool = true,
        enabledAgents: Set<AgentHistoryAgent> = Set(AgentHistoryAgent.allCases),
        state: AgentHistoryIndexerState = .watching,
        sources: [AgentHistorySourceHealth] = [],
        indexedSessions: Int = 0,
        indexSizeBytes: Int64 = 0,
        lastUpdatedAt: Date? = nil,
        tokenizer: AgentHistoryTokenizer? = .trigram
    ) -> AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isEnabled = isEnabled
        status.hasConsented = hasConsented
        status.enabledAgents = enabledAgents
        status.state = state
        status.sources = sources
        status.indexedSessions = indexedSessions
        status.indexExists = indexSizeBytes > 0
        status.indexSizeBytes = indexSizeBytes
        status.lastUpdatedAt = lastUpdatedAt
        status.tokenizer = tokenizer
        return status
    }

    private func row(_ rows: [AgentHistorySettingsSourceRow], _ agent: AgentHistoryAgent) -> AgentHistorySettingsSourceRow? {
        rows.first { $0.agent == agent }
    }

    // MARK: - Summary

    func test_summary_formats_counts_size_and_relative_time() {
        let formatter = makeFormatter()
        let value = status(
            indexedSessions: 1_284,
            indexSizeBytes: 412_000_000,
            lastUpdatedAt: now.addingTimeInterval(-180)
        )

        XCTAssertEqual(formatter.summary(for: value), "1,284 sessions · 412 MB on disk · updated 3 minutes ago")

        let single = status(indexedSessions: 1, indexSizeBytes: 2_000_000, lastUpdatedAt: now.addingTimeInterval(-7_200))
        XCTAssertEqual(formatter.summary(for: single), "1 session · 2 MB on disk · updated 2 hours ago")
    }

    func test_summary_says_just_now_under_a_minute() {
        let formatter = makeFormatter()

        let recent = status(indexedSessions: 12, indexSizeBytes: 5_000_000, lastUpdatedAt: now.addingTimeInterval(-59))
        XCTAssertEqual(formatter.summary(for: recent), "12 sessions · 5 MB on disk · updated just now")

        // A clock that moved backwards must not read "in 5 seconds".
        let future = status(indexedSessions: 12, indexSizeBytes: 5_000_000, lastUpdatedAt: now.addingTimeInterval(5))
        XCTAssertEqual(formatter.summary(for: future), "12 sessions · 5 MB on disk · updated just now")
    }

    func test_summary_off_states_before_and_after_consent() {
        let formatter = makeFormatter()

        let neverConsented = status(isEnabled: false, hasConsented: false, state: .off)
        XCTAssertEqual(formatter.summary(for: neverConsented), "Off. Nothing has been read.")

        let consented = status(
            isEnabled: false, hasConsented: true, state: .off,
            indexedSessions: 40, indexSizeBytes: 9_000_000, lastUpdatedAt: now.addingTimeInterval(-600)
        )
        XCTAssertEqual(formatter.summary(for: consented), "Off. The index is kept until you delete it.")
    }

    func test_summary_not_indexed_yet() {
        let formatter = makeFormatter()
        let value = status(state: .starting, indexedSessions: 0, lastUpdatedAt: nil)

        XCTAssertEqual(formatter.summary(for: value), "Not indexed yet")
    }

    // MARK: - Activity

    func test_activity_lines_for_backfilling_paused_failed_and_newer_schema() {
        let formatter = makeFormatter()
        let progress = AgentHistoryBackfillProgress(indexedSessions: 312, totalSessions: 1_284)

        XCTAssertEqual(
            formatter.activity(for: status(state: .backfilling(progress))),
            AgentHistorySettingsActivity(text: "Indexing 312 of 1,284 sessions", isWarning: false)
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .paused(.lowPower, progress))),
            AgentHistorySettingsActivity(text: "Paused while Low Power Mode is on", isWarning: true)
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .paused(.thermal, nil))),
            AgentHistorySettingsActivity(text: "Paused while the Mac is hot", isWarning: true)
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .paused(.diskFull, nil))),
            AgentHistorySettingsActivity(text: "Paused: the disk is full", isWarning: true)
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .paused(.anotherInstance, nil)))?.isWarning,
            false
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .failed(.openFailed(code: 14)))),
            AgentHistorySettingsActivity(
                text: "Indexing failed: the index couldn't be opened (SQLite error 14).",
                isWarning: true
            )
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .failed(.corrupt))),
            AgentHistorySettingsActivity(
                text: "Indexing failed: the index is damaged. Rebuild it to start over.",
                isWarning: true
            )
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .failed(.newerSchema(found: 9)))),
            AgentHistorySettingsActivity(
                text: "Index was created by a newer Zentty. Rebuild it to keep searching.",
                isWarning: true
            )
        )
        XCTAssertEqual(
            formatter.activity(for: status(state: .failed(.removalsUnreadable))),
            AgentHistorySettingsActivity(
                text: "Indexing stopped: the list of removed sessions can't be read. Delete the index to start over.",
                isWarning: true
            )
        )
        XCTAssertEqual(
            formatter.activity(for: status(tokenizer: AgentHistoryTokenizer.none)),
            AgentHistorySettingsActivity(text: "Limited search", isWarning: true)
        )
    }

    func test_activity_line_nil_for_idle_and_watching() {
        let formatter = makeFormatter()

        XCTAssertNil(formatter.activity(for: status(isEnabled: false, state: .off)))
        XCTAssertNil(formatter.activity(for: status(state: .watching)))
        XCTAssertNil(formatter.activity(for: status(state: .watching, tokenizer: nil)))
        XCTAssertNil(formatter.activity(for: status(state: .watching, tokenizer: .unicode61)))
        // An index that is off says nothing about its tokenizer.
        XCTAssertNil(formatter.activity(for: status(isEnabled: false, state: .off, tokenizer: AgentHistoryTokenizer.none)))
    }

    // MARK: - Progress

    func test_progress_fraction_clamped_and_nil_for_zero_total() {
        let formatter = makeFormatter()

        let quarter = AgentHistoryBackfillProgress(indexedSessions: 25, totalSessions: 100)
        XCTAssertEqual(formatter.progressFraction(for: status(state: .backfilling(quarter))) ?? -1, 0.25, accuracy: 0.0001)

        let over = AgentHistoryBackfillProgress(indexedSessions: 140, totalSessions: 100)
        XCTAssertEqual(formatter.progressFraction(for: status(state: .backfilling(over))), 1)

        let pausedHalf = AgentHistoryBackfillProgress(indexedSessions: 5, totalSessions: 10)
        XCTAssertEqual(formatter.progressFraction(for: status(state: .paused(.thermal, pausedHalf))) ?? -1, 0.5, accuracy: 0.0001)

        let empty = AgentHistoryBackfillProgress(indexedSessions: 0, totalSessions: 0)
        XCTAssertNil(formatter.progressFraction(for: status(state: .backfilling(empty))))
        XCTAssertNil(formatter.progressFraction(for: status(state: .paused(.lowPower, nil))))
        XCTAssertNil(formatter.progressFraction(for: status(state: .watching)))
    }

    // MARK: - Sources

    func test_source_counts_sum_over_roots() {
        let formatter = makeFormatter()
        let value = status(sources: [
            AgentHistorySourceHealth(
                agent: .claude, root: "\(home)/.claude", isDefaultRoot: true,
                discovered: 1_800, indexed: 1_780, skipped: 20
            ),
            AgentHistorySourceHealth(
                agent: .claude, root: "/Volumes/Work/claude-alt", isDefaultRoot: false,
                discovered: 79, indexed: 70, skipped: 9
            ),
        ])

        let rows = formatter.sourceRows(for: value, detected: [])
        XCTAssertEqual(rows.map(\.agent), AgentHistoryAgent.allCases)

        let claude = row(rows, .claude)
        XCTAssertEqual(claude?.title, AgentHistoryAgent.claude.displayName)
        XCTAssertEqual(claude?.isDetected, true)
        XCTAssertEqual(claude?.isEnabled, true)
        XCTAssertEqual(claude?.summaryText, "1,879 found · 1,850 indexed · 29 skipped")
        XCTAssertEqual(claude?.rootsText, "~/.claude\n/Volumes/Work/claude-alt")
        XCTAssertNil(claude?.errorText)
        XCTAssertNil(claude?.checkedPathsText)
    }

    func test_source_error_uses_latest_root_with_tilde_path() {
        let formatter = makeFormatter()
        let value = status(
            enabledAgents: [.claude],
            sources: [
                AgentHistorySourceHealth(
                    agent: .claude, root: "/Volumes/Work/claude-alt", isDefaultRoot: false,
                    problem: .busy, lastError: "Database busy", lastScanAt: now.addingTimeInterval(-600)
                ),
                AgentHistorySourceHealth(
                    agent: .claude, root: "\(home)/.claude", isDefaultRoot: true,
                    problem: .permissionDenied, lastError: "Permission denied", lastScanAt: now.addingTimeInterval(-60)
                ),
                AgentHistorySourceHealth(
                    agent: .claude, root: "\(home)/.claude-work", isDefaultRoot: false,
                    lastScanAt: now
                ),
                AgentHistorySourceHealth(
                    agent: .codex, root: "\(home)/.codex", isDefaultRoot: true,
                    problem: .metadataFromTranscripts, lastError: nil, lastScanAt: now
                ),
            ]
        )

        let rows = formatter.sourceRows(for: value, detected: [])
        XCTAssertEqual(row(rows, .claude)?.errorText, "~/.claude: Permission denied")
        XCTAssertEqual(row(rows, .codex)?.errorText, "~/.codex: Thread catalog unavailable; using transcripts")
        XCTAssertEqual(row(rows, .codex)?.isEnabled, false)

        // Before indexing runs, the probe's problem is shown for a found root.
        let off = status(isEnabled: false, state: .off)
        let probed = formatter.sourceRows(for: off, detected: [
            AgentHistoryDetectedSource(
                agent: .grok, rootPath: "\(home)/.grok", isFound: true, sessionCount: nil,
                checkedPaths: ["\(home)/.grok"], problem: .permissionDenied
            ),
        ])
        XCTAssertEqual(row(probed, .grok)?.errorText, "~/.grok: Permission denied")
        XCTAssertEqual(row(probed, .grok)?.summaryText, "Found")
    }

    func test_undetected_source_shows_not_found_and_checked_paths() {
        let formatter = makeFormatter()
        let off = status(isEnabled: false, state: .off)
        let detected = [
            AgentHistoryDetectedSource(
                agent: .claude, rootPath: "\(home)/.claude", isFound: true, sessionCount: 1_284,
                checkedPaths: ["\(home)/.claude"], problem: nil
            ),
            AgentHistoryDetectedSource(
                agent: .opencode, rootPath: nil, isFound: false, sessionCount: nil,
                checkedPaths: ["\(home)/.local/share/opencode", "/opt/opencode"], problem: nil
            ),
        ]

        let rows = formatter.sourceRows(for: off, detected: detected)

        let claude = row(rows, .claude)
        XCTAssertEqual(claude?.isDetected, true)
        XCTAssertEqual(claude?.summaryText, "1,284 found")
        XCTAssertEqual(claude?.rootsText, "~/.claude")

        let opencode = row(rows, .opencode)
        XCTAssertEqual(opencode?.isDetected, false)
        XCTAssertEqual(opencode?.summaryText, "Not found")
        XCTAssertNil(opencode?.rootsText)
        XCTAssertNil(opencode?.errorText)
        XCTAssertEqual(opencode?.checkedPathsText, "~/.local/share/opencode\n/opt/opencode")

        // No health and no probe result yet: nothing is claimed either way.
        let codex = row(rows, .codex)
        XCTAssertEqual(codex?.isDetected, false)
        XCTAssertNil(codex?.summaryText)
        XCTAssertNil(codex?.checkedPathsText)
    }
}
