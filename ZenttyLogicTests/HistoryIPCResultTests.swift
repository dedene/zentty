import XCTest
@testable import Zentty

final class HistoryIPCResultTests: XCTestCase {
    func test_search_response_round_trips_inside_response_result() throws {
        let history = HistoryIPCResult(search: makeSearchResponse(hitCount: 2))
        let response = AgentIPCResponse(id: "req-1", ok: true, result: AgentIPCResponseResult(history: history))

        let decoded = try JSONDecoder().decode(AgentIPCResponse.self, from: JSONEncoder().encode(response))

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.result?.history?.search?.results.count, 2)
        XCTAssertNil(decoded.result?.history?.show)
    }

    func test_response_without_history_payload_still_decodes() throws {
        // What an app that predates Agent History sends back for any successful request.
        let json = #"{"version":1,"id":"req-1","ok":true,"result":{"stdout":"hi"}}"#

        let decoded = try JSONDecoder().decode(AgentIPCResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.result?.stdout, "hi")
        XCTAssertNil(decoded.result?.history)
    }

    func test_search_json_uses_spec_keys() throws {
        let object = try jsonObject(makeSearchResponse(hitCount: 1))

        XCTAssertEqual(
            Set(object.keys),
            ["scope", "project", "indexedSessions", "complete", "contentIsUntrusted", "results"]
        )
        XCTAssertEqual(object["scope"] as? String, "project")
        XCTAssertEqual(object["contentIsUntrusted"] as? Bool, true)
        let hit = try XCTUnwrap((object["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(hit.keys),
            ["agent", "sessionId", "title", "cwd", "branch", "updatedAt", "live", "match", "resumeCommand"]
        )
        XCTAssertEqual(hit["sessionId"] as? String, "session-0")
        XCTAssertEqual(hit["updatedAt"] as? String, "2026-10-29T14:02:00Z")
    }

    func test_content_match_omits_metadata_fields_and_vice_versa() throws {
        let content = try jsonObject(
            HistoryIPCMatch.content(role: "user", at: "2026-10-29T13:40:00Z", snippet: "…the harness times out…")
        )
        XCTAssertEqual(Set(content.keys), ["role", "at", "snippet"])

        let metadata = try jsonObject(HistoryIPCMatch.metadata(field: "branch", value: "feat/agent-history"))
        XCTAssertEqual(Set(metadata.keys), ["field", "value"])
    }

    func test_truncate_utf8_respects_character_boundaries() {
        XCTAssertEqual(HistoryIPCText.truncateUTF8("short", maxBytes: 10).text, "short")
        XCTAssertFalse(HistoryIPCText.truncateUTF8("short", maxBytes: 5).truncated)

        // "é" is 2 bytes; a cut at 3 bytes must not split the second one.
        let accented = HistoryIPCText.truncateUTF8("éé", maxBytes: 3)
        XCTAssertEqual(accented.text, "é")
        XCTAssertTrue(accented.truncated)

        // A family emoji is one character of 25 bytes: it is kept whole or dropped whole.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(HistoryIPCText.truncateUTF8("a" + family, maxBytes: 10).text, "a")
        XCTAssertEqual(HistoryIPCText.truncateUTF8("a" + family + "b", maxBytes: 26).text, "a" + family)

        let capped = HistoryIPCText.truncateUTF8(String(repeating: "ü", count: 5_000), maxBytes: HistoryIPC.maxTurnBytes)
        XCTAssertEqual(capped.text.utf8.count, HistoryIPC.maxTurnBytes)
        XCTAssertTrue(capped.truncated)
    }

    func test_show_budget_drops_oldest_turns_and_counts_them() throws {
        // Quotes, backslashes and newlines each double in JSON, so raw text length undercounts.
        let escapeHeavy = String(repeating: "\"\\\n", count: 300)
        let turns = (0..<10).map { index in
            HistoryIPCTurn(role: "user", at: "2026-10-29T13:4\(index):00Z",
                           text: "turn \(index) " + escapeHeavy, truncated: false)
        }
        let response = makeShowResponse(turns: turns, omittedTurns: 3)
        let turnBytes = try JSONEncoder().encode(turns[0]).count
        XCTAssertGreaterThan(turnBytes, 1_800, "Escapes count double")
        let fullBytes = try JSONEncoder().encode(response).count
        // Three turns and their commas, less 4 bytes: only six of the ten fit.
        let budget = fullBytes - 3 * turnBytes - 4

        let fitted = try response.fittingByteBudget(budget)

        XCTAssertLessThanOrEqual(try JSONEncoder().encode(fitted).count, budget)
        XCTAssertEqual(fitted.turns, Array(turns.suffix(fitted.turns.count)), "Newest turns are kept")
        XCTAssertEqual(fitted.turns.count, 6)
        XCTAssertEqual(fitted.omittedTurns, 3 + 4)
        XCTAssertEqual(fitted.totalTurns, response.totalTurns)
        XCTAssertEqual(try response.fittingByteBudget(fullBytes), response, "A response that fits is untouched")
        XCTAssertThrowsError(try response.fittingByteBudget(100)) {
            XCTAssertEqual($0 as? HistoryIPCError, .responseTooLarge)
        }
    }

    func test_search_budget_drops_tail_hits() throws {
        let response = makeSearchResponse(hitCount: 8)
        let hitBytes = try JSONEncoder().encode(response.results[7]).count
        let fullBytes = try JSONEncoder().encode(response).count
        // One hit and its comma, less one byte: only six of the eight fit.
        let budget = fullBytes - hitBytes - 2

        let fitted = try response.fittingByteBudget(budget)

        XCTAssertLessThanOrEqual(try JSONEncoder().encode(fitted).count, budget)
        XCTAssertEqual(fitted.results, Array(response.results.prefix(6)), "Best-ranked hits are kept")
        XCTAssertEqual(fitted.indexedSessions, response.indexedSessions)
        XCTAssertEqual(try response.fittingByteBudget(fullBytes), response)
    }

    func test_iso8601_is_utc_and_parses_back() throws {
        let milliseconds: Int64 = 1_793_282_520_789 // 2026-10-29T14:02:00.789Z

        let formatted = HistoryIPCDates.iso8601(milliseconds: milliseconds)

        XCTAssertEqual(formatted, "2026-10-29T14:02:00Z")
        let parsed = try XCTUnwrap(HistoryIPCDates.parse(formatted))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_793_282_520)
        XCTAssertEqual(
            HistoryIPCDates.parse("2026-10-29T14:02:00.500Z")?.timeIntervalSince1970,
            1_793_282_520.5
        )
        XCTAssertNil(HistoryIPCDates.parse("yesterday"))
    }

    // MARK: - Fixtures

    private func makeSearchResponse(hitCount: Int) -> HistorySearchIPCResponse {
        HistorySearchIPCResponse(
            scope: "project",
            project: "/Users/someone/Development/zentty",
            indexedSessions: 42,
            complete: false,
            results: (0..<hitCount).map { index in
                HistorySearchIPCHit(
                    agent: "claude",
                    sessionId: "session-\(index)",
                    title: "Fix flaky virtual display tests \(index)",
                    cwd: "/Users/someone/Development/zentty",
                    branch: "feat/agent-history",
                    updatedAt: HistoryIPCDates.iso8601(milliseconds: 1_793_282_520_000),
                    live: index == 0,
                    match: .content(role: "user", at: "2026-10-29T13:40:00Z", snippet: "…the harness times out \(index)…"),
                    resumeCommand: "claude --resume session-\(index)"
                )
            }
        )
    }

    private func makeShowResponse(turns: [HistoryIPCTurn], omittedTurns: Int) -> HistoryShowIPCResponse {
        HistoryShowIPCResponse(
            scope: "project",
            project: "/Users/someone/Development/zentty",
            agent: "codex",
            sessionId: "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b",
            title: "Escape-heavy session",
            cwd: "/Users/someone/Development/zentty",
            branch: nil,
            model: "gpt-5-codex",
            effort: "high",
            createdAt: "2026-10-29T13:00:00Z",
            updatedAt: "2026-10-29T14:02:00Z",
            live: false,
            totalTurns: turns.count + omittedTurns,
            omittedTurns: omittedTurns,
            turns: turns,
            resumeCommand: "codex resume 019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
