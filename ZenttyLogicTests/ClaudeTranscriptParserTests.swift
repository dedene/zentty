import XCTest

@testable import Zentty

/// Unit tests for the Claude Code JSONL adapter: line parsing / normalization,
/// the cwd-slug path encoding, and the line-buffering tail that guards against
/// mid-write truncated lines.
final class ClaudeTranscriptParserTests: XCTestCase {
    // MARK: - Fixture

    /// Loads the distilled real-session fixture from the source tree (the repo's
    /// established `#filePath`-relative convention for test data).
    private func fixtureLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-session-fixture.jsonl")
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func entries(fromFixture: Bool = true) throws -> [CompanionTranscriptEntry] {
        try fixtureLines().flatMap { ClaudeTranscriptParser.entries(fromLine: $0) }
    }

    // MARK: - Fixture parsing

    func testFixtureProducesNormalizedRolesAndSkipsMeta() throws {
        let entries = try entries()

        // summary, file-history-snapshot and mode lines are dropped; every other
        // line maps to one entry except the assistant text+tool_use line (two).
        XCTAssertEqual(entries.map(\.role), [
            .user,        // "Can you add a transcript feed?"
            .assistant,   // "On it — let me check the build."
            .toolUse,     // Bash
            .toolResult,  // build output
            .assistant,   // "Build passed. Done."
            .system       // away_summary content
        ])
    }

    func testUserAndAssistantTextArePreserved() throws {
        let entries = try entries()
        XCTAssertEqual(entries.first?.text, "Can you add a transcript feed?")
        XCTAssertEqual(entries.first(where: { $0.role == .system })?.text, "User stepped away; summarized progress.")
    }

    func testToolUseCarriesNameAndInput() throws {
        let toolUse = try XCTUnwrap(try entries().first { $0.role == .toolUse })
        XCTAssertEqual(toolUse.toolName, "Bash")
        guard case .object(let input)? = toolUse.toolInput else {
            return XCTFail("Expected an object toolInput, got \(String(describing: toolUse.toolInput))")
        }
        XCTAssertEqual(input["command"], .string("swift build"))
        XCTAssertEqual(input["description"], .string("Build the package"))
    }

    func testToolResultIsSummarizedWithStatus() throws {
        let result = try XCTUnwrap(try entries().first { $0.role == .toolResult })
        XCTAssertEqual(result.toolResultSummary, "Compiling target...\nBuild complete!")
        XCTAssertEqual(result.status, "ok")
        XCTAssertNil(result.text)
    }

    func testTimestampsParseToEpochMilliseconds() throws {
        let first = try XCTUnwrap(try entries().first)
        // 2026-07-20T17:50:44.687Z
        XCTAssertEqual(first.ts, 1_784_569_844_687)
    }

    func testMultiBlockLineGetsStableIndexedIds() throws {
        let entries = try entries()
        let assistantText = try XCTUnwrap(entries.first { $0.role == .assistant })
        let toolUse = try XCTUnwrap(entries.first { $0.role == .toolUse })
        // Same source line (uuid-assistant-1) → suffixed, distinct ids.
        XCTAssertEqual(assistantText.id, "uuid-assistant-1#0")
        XCTAssertEqual(toolUse.id, "uuid-assistant-1#1")
        // A single-entry line keeps the bare uuid.
        XCTAssertEqual(entries.first?.id, "uuid-user-1")
    }

    // MARK: - Robustness

    func testMalformedLineYieldsNothing() {
        XCTAssertTrue(ClaudeTranscriptParser.entries(fromLine: "{not valid json").isEmpty)
        XCTAssertTrue(ClaudeTranscriptParser.entries(fromLine: "").isEmpty)
    }

    func testEmptyTextBlocksAreDropped() {
        let line = #"{"type":"assistant","uuid":"a","timestamp":"2026-07-20T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"   "}]}}"#
        XCTAssertTrue(ClaudeTranscriptParser.entries(fromLine: line).isEmpty)
    }

    func testToolResultSummaryIsTruncated() throws {
        let body = String(repeating: "x", count: 900)
        let line = "{\"type\":\"user\",\"uuid\":\"u\",\"timestamp\":\"2026-07-20T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t\",\"is_error\":true,\"content\":\"\(body)\"}]}}"
        let entry = try XCTUnwrap(ClaudeTranscriptParser.entries(fromLine: line).first)
        let summary = try XCTUnwrap(entry.toolResultSummary)
        XCTAssertEqual(summary.count, ClaudeTranscriptParser.toolResultSummaryLimit + 1) // +1 for the ellipsis
        XCTAssertEqual(entry.status, "error")
    }

    // MARK: - Slug encoding

    func testProjectSlugReplacesNonAlphanumericWithDash() {
        XCTAssertEqual(
            ClaudeTranscriptLocator.encodedProjectSlug(
                forWorkingDirectory: "/Users/peter/Development/Personal/worktrees/feature/mobile-companion"
            ),
            "-Users-peter-Development-Personal-worktrees-feature-mobile-companion"
        )
        // Dots and other punctuation collapse to dashes too.
        XCTAssertEqual(
            ClaudeTranscriptLocator.encodedProjectSlug(forWorkingDirectory: "/tmp/a.b_c"),
            "-tmp-a-b-c"
        )
    }

    func testFallbackURLComposesProjectsPath() throws {
        let url = try XCTUnwrap(ClaudeTranscriptLocator.transcriptURL(
            sessionID: "abc-123",
            workingDirectory: "/tmp/project",
            liveTranscriptPath: nil
        ))
        XCTAssertEqual(url.lastPathComponent, "abc-123.jsonl")
        XCTAssertTrue(url.path.contains("/.claude/projects/-tmp-project/"))
    }

    func testLivePathIsPreferredOverFallback() {
        let url = ClaudeTranscriptLocator.transcriptURL(
            sessionID: "abc",
            workingDirectory: "/tmp/project",
            liveTranscriptPath: "/var/live/session.jsonl"
        )
        XCTAssertEqual(url?.path, "/var/live/session.jsonl")
    }

    func testMissingSessionAndCwdYieldsNoURL() {
        XCTAssertNil(ClaudeTranscriptLocator.transcriptURL(
            sessionID: nil,
            workingDirectory: "/tmp/project",
            liveTranscriptPath: nil
        ))
    }

    // MARK: - Mid-write truncation

    func testTailBuffersPartialLineUntilNewlineArrives() {
        let tail = ClaudeTranscriptTail()
        let line = #"{"type":"user","uuid":"u1","timestamp":"2026-07-20T00:00:00.000Z","message":{"role":"user","content":"hi"}}"#

        // A torn write: half the JSON, no newline yet → nothing parses.
        let split = line.index(line.startIndex, offsetBy: 40)
        let firstHalf = String(line[..<split])
        let secondHalf = String(line[split...])
        XCTAssertTrue(tail.consume(Data(firstHalf.utf8)).isEmpty)

        // The rest of the line lands (still no newline) → still buffered.
        XCTAssertTrue(tail.consume(Data(secondHalf.utf8)).isEmpty)

        // The terminating newline completes the line → it parses.
        let entries = tail.consume(Data("\n".utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "hi")
    }

    func testTailEmitsCompleteLinesAndHoldsTrailingPartial() {
        let tail = ClaudeTranscriptTail()
        let complete = #"{"type":"user","uuid":"u1","timestamp":"2026-07-20T00:00:00.000Z","message":{"role":"user","content":"one"}}"#
        let secondLine = #"{"type":"user","uuid":"u2","timestamp":"2026-07-20T00:00:01.000Z","message":{"role":"user","content":"two"}}"#
        let cut = secondLine.index(secondLine.startIndex, offsetBy: 70)
        let partial = String(secondLine[..<cut])
        let remainder = String(secondLine[cut...])

        // One full line + a torn second line in the same chunk.
        let first = tail.consume(Data((complete + "\n" + partial).utf8))
        XCTAssertEqual(first.compactMap(\.text), ["one"])

        // Completing the second line resumes cleanly.
        let rest = tail.consume(Data((remainder + "\n").utf8))
        XCTAssertEqual(rest.compactMap(\.text), ["two"])
    }
}
