import XCTest
@testable import Zentty

final class HistoryIPCFormattingTests: XCTestCase {
    private let home = "/Users/someone"
    private let utc = TimeZone(identifier: "UTC")!

    func test_search_text_prints_one_block_per_result() {
        let response = makeSearchResponse(results: [
            makeHit(
                sessionId: "3f2a",
                title: "Fix flaky virtual display tests",
                live: true,
                match: .content(role: "user", at: "2026-10-29T13:40:00Z", snippet: "…the harness times out…"),
                resumeCommand: "claude --resume 3f2a"
            ),
            makeHit(sessionId: "77bc", title: "Tidy the sidebar", live: false, match: nil, resumeCommand: nil),
        ])

        let text = HistoryIPCFormatting.searchText(response, query: "harness", homeDirectory: home, timeZone: utc)

        XCTAssertEqual(text, """
            2 sessions in ~/Development/zentty

            1. Fix flaky virtual display tests
               claude · feat/agent-history · ~/Development/zentty · 2026-10-29 14:02 · live
               You: …the harness times out…
               Resume: claude --resume 3f2a

            2. Tidy the sidebar
               claude · feat/agent-history · ~/Development/zentty · 2026-10-29 14:02
               Session: claude 77bc

            \(HistoryIPC.untrustedNote)
            """)
    }

    func test_search_text_notes_incomplete_index_and_untrusted_content() {
        let hit = makeHit(sessionId: "a", title: "One", live: false, match: nil, resumeCommand: nil)
        let incomplete = makeSearchResponse(complete: false, results: [hit])

        let text = HistoryIPCFormatting.searchText(incomplete, query: "one", homeDirectory: home, timeZone: utc)

        XCTAssertTrue(text.hasPrefix(
            "1 session in ~/Development/zentty  (index still building; older sessions may be missing)\n"
        ))
        XCTAssertTrue(text.hasSuffix("\n\n" + HistoryIPC.untrustedNote))

        let complete = HistoryIPCFormatting.searchText(
            makeSearchResponse(results: [hit]), query: "one", homeDirectory: home, timeZone: utc
        )
        XCTAssertFalse(complete.contains("still building"))

        let emptyIncomplete = HistoryIPCFormatting.searchText(
            makeSearchResponse(complete: false, results: []), query: "one", homeDirectory: home, timeZone: utc
        )
        XCTAssertTrue(emptyIncomplete.contains("The index is still building, so older sessions may be missing."))
    }

    func test_search_text_metadata_match_prints_reason_not_snippet() {
        XCTAssertEqual(HistoryIPCFormatting.matchReason(.metadata(field: "branch", value: "main")), "Branch: main")
        XCTAssertEqual(HistoryIPCFormatting.matchReason(.metadata(field: "path", value: "App.swift")), "Changed: App.swift")
        XCTAssertEqual(HistoryIPCFormatting.matchReason(.metadata(field: "command", value: "swift test")), "Ran: swift test")
        XCTAssertNil(HistoryIPCFormatting.matchReason(.metadata(field: "title", value: "Fix it")))
        XCTAssertEqual(
            HistoryIPCFormatting.matchReason(.content(role: "agent", at: "2026-10-29T13:40:00Z", snippet: "a\nb")),
            "Agent: a b"
        )

        let response = makeSearchResponse(results: [
            makeHit(sessionId: "a", title: "Title hit", live: false,
                    match: .metadata(field: "title", value: "Title hit"), resumeCommand: nil),
            makeHit(sessionId: "b", title: "Branch hit", live: false,
                    match: .metadata(field: "branch", value: "feat/x"), resumeCommand: nil),
        ])
        let text = HistoryIPCFormatting.searchText(response, query: "x", homeDirectory: home, timeZone: utc)
        let lines = text.components(separatedBy: "\n")

        let titleBlock = lines.drop { $0 != "1. Title hit" }.prefix { !$0.isEmpty }
        XCTAssertEqual(titleBlock.count, 3, "Title, meta and session lines only")
        XCTAssertTrue(lines.contains("   Branch: feat/x"))
    }

    func test_search_text_empty_project_scope_suggests_all() {
        let project = HistoryIPCFormatting.searchText(
            makeSearchResponse(results: []), query: "cache", homeDirectory: home, timeZone: utc
        )
        XCTAssertEqual(project, """
            No sessions in ~/Development/zentty match "cache".
            Try --all to search every project.
            """)

        let all = HistoryIPCFormatting.searchText(
            HistorySearchIPCResponse(scope: "all", project: nil, indexedSessions: 9, complete: true, results: []),
            query: "cache",
            homeDirectory: home,
            timeZone: utc
        )
        XCTAssertEqual(all, "No sessions in any project match \"cache\".")
    }

    func test_show_text_orders_oldest_first_and_marks_truncated() {
        let response = HistoryShowIPCResponse(
            scope: "project",
            project: "/Users/someone/Development/zentty",
            agent: "codex",
            sessionId: "019a",
            title: "Migrate the cache",
            cwd: "/Users/someone/Development/zentty",
            branch: "main",
            model: "gpt-5",
            effort: "high",
            createdAt: "2026-10-29T13:00:00Z",
            updatedAt: "2026-10-29T14:02:00Z",
            live: false,
            totalTurns: 12,
            omittedTurns: 10,
            turns: [
                HistoryIPCTurn(role: "user", at: "2026-10-29T13:40:00Z", text: "first line\nsecond line", truncated: false),
                HistoryIPCTurn(role: "agent", at: "2026-10-29T13:41:00Z", text: "done", truncated: true),
            ],
            resumeCommand: "codex resume 019a"
        )

        let text = HistoryIPCFormatting.showText(response, homeDirectory: home, timeZone: utc)

        XCTAssertEqual(text, """
            Migrate the cache
            codex · ~/Development/zentty · main · gpt-5 (high) · updated 2026-10-29 14:02
            Session: 019a · Resume: codex resume 019a
            Showing the last 2 of 12 turns.

            You · 2026-10-29 13:40
              first line
              second line

            Agent · 2026-10-29 13:41
              done
              [truncated]

            \(HistoryIPC.untrustedNote)
            """)
    }

    func test_paths_under_home_are_abbreviated() {
        XCTAssertEqual(HistoryIPCFormatting.abbreviated("/Users/someone", homeDirectory: home), "~")
        XCTAssertEqual(HistoryIPCFormatting.abbreviated("/Users/someone/src", homeDirectory: home), "~/src")
        XCTAssertEqual(HistoryIPCFormatting.abbreviated("/Users/someone/src", homeDirectory: home + "/"), "~/src")
        XCTAssertEqual(
            HistoryIPCFormatting.abbreviated("/Users/someoneelse/src", homeDirectory: home),
            "/Users/someoneelse/src",
            "Only whole path components count as the home directory"
        )
        XCTAssertEqual(HistoryIPCFormatting.abbreviated("/opt/src", homeDirectory: home), "/opt/src")
    }

    func test_quoted_text_cannot_carry_terminal_escapes() {
        let hit = makeHit(
            sessionId: "a",
            title: "Evil \u{1B}[2J title",
            live: false,
            match: .content(role: "user", at: "2026-10-29T13:40:00Z", snippet: "bell\u{07}"),
            resumeCommand: nil
        )

        let text = HistoryIPCFormatting.searchText(
            makeSearchResponse(results: [hit]), query: "q\u{1B}", homeDirectory: home, timeZone: utc
        )

        XCTAssertFalse(text.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{07}" })
        XCTAssertTrue(text.contains("Evil \\u{1B}[2J title"))
    }

    // MARK: - Fixtures

    private func makeSearchResponse(
        complete: Bool = true,
        results: [HistorySearchIPCHit]
    ) -> HistorySearchIPCResponse {
        HistorySearchIPCResponse(
            scope: "project",
            project: "/Users/someone/Development/zentty",
            indexedSessions: 42,
            complete: complete,
            results: results
        )
    }

    private func makeHit(
        sessionId: String,
        title: String,
        live: Bool,
        match: HistoryIPCMatch?,
        resumeCommand: String?
    ) -> HistorySearchIPCHit {
        HistorySearchIPCHit(
            agent: "claude",
            sessionId: sessionId,
            title: title,
            cwd: "/Users/someone/Development/zentty",
            branch: "feat/agent-history",
            updatedAt: "2026-10-29T14:02:00Z",
            live: live,
            match: match,
            resumeCommand: resumeCommand
        )
    }
}
