import XCTest
@testable import Zentty

final class AgentHistoryResumeSourceTests: XCTestCase {
    func test_init_from_summary_copies_fields_and_source_root() {
        let summary = AgentHistorySessionSummary(
            id: 42,
            sourceID: 7,
            sourceRoot: "/Users/test/.claude-work",
            agent: .claude,
            nativeID: "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f",
            title: "Fix the flaky sidebar test",
            titleKind: .firstPrompt,
            cwd: "/Users/test/src/zentty-wt/Sources",
            repoRoot: "/Users/test/src/zentty-wt",
            mainRepoRoot: "/Users/test/src/zentty",
            branch: "feat/sidebar",
            model: "claude-opus-4[1m]",
            effort: "high",
            generation: "v1",
            transcriptPath: "/Users/test/.claude-work/projects/x/0b6c1d8e.jsonl",
            createdAtMs: 1_000,
            updatedAtMs: 2_000,
            turnCount: 3
        )

        let source = AgentHistoryResumeSource(summary: summary)

        XCTAssertEqual(source, AgentHistoryResumeSource(
            sessionRowID: 42,
            agent: .claude,
            nativeSessionID: "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f",
            title: "Fix the flaky sidebar test",
            workingDirectory: "/Users/test/src/zentty-wt/Sources",
            repoRoot: "/Users/test/src/zentty-wt",
            mainRepoRoot: "/Users/test/src/zentty",
            branch: "feat/sidebar",
            model: "claude-opus-4[1m]",
            effort: "high",
            generation: "v1",
            sourceRoot: "/Users/test/.claude-work"
        ))
        XCTAssertEqual(source.key, summary.key)
    }

    func test_init_from_summary_keeps_missing_metadata_nil_and_drops_empty_source_root() {
        let summary = AgentHistorySessionSummary(
            id: 9,
            sourceID: 1,
            sourceRoot: "",
            agent: .opencode,
            nativeID: "ses_abc123",
            title: "Untitled",
            titleKind: .firstPrompt,
            createdAtMs: 0,
            updatedAtMs: 0,
            turnCount: 0
        )

        let source = AgentHistoryResumeSource(summary: summary)

        XCTAssertEqual(source.sessionRowID, 9)
        XCTAssertEqual(source.agent, .opencode)
        XCTAssertNil(source.workingDirectory)
        XCTAssertNil(source.repoRoot)
        XCTAssertNil(source.mainRepoRoot)
        XCTAssertNil(source.branch)
        XCTAssertNil(source.model)
        XCTAssertNil(source.effort)
        XCTAssertNil(source.generation)
        XCTAssertNil(source.sourceRoot)
    }
}
