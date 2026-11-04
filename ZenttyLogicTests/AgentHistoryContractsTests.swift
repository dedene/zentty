import Foundation
import XCTest
@testable import Zentty

/// Shared merge table for `AgentHistorySessionDraft.merged` and the SQL session upsert.
///
/// Every row's `existing` draft is fully populated (title, kind, every location and run column with
/// a distinct value, created, updated, archived) so the storage layer can insert it as a real row
/// and run `update` through the SQL upsert; the expected result must match in both places.
/// Distinct values per column make a swapped or mis-numbered column in the SQL fail.
enum AgentHistoryMergeTable {
    struct Case {
        let name: String
        let existing: AgentHistorySessionDraft
        let update: AgentHistorySessionDraft
        let expected: AgentHistorySessionDraft
    }

    static let nativeID = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"

    static func draft(
        title: String? = nil,
        kind: AgentHistoryTitleKind? = nil,
        cwd: String? = nil,
        repoRoot: String? = nil,
        mainRepoRoot: String? = nil,
        branch: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        generation: String? = nil,
        transcriptPath: String? = nil,
        createdAtMs: Int64? = nil,
        updatedAtMs: Int64? = nil,
        lastUserAtMs: Int64? = nil,
        archived: Bool? = nil,
        parentNativeID: String? = nil
    ) -> AgentHistorySessionDraft {
        var draft = AgentHistorySessionDraft(nativeID: nativeID)
        draft.title = title
        draft.titleKind = kind
        draft.cwd = cwd
        draft.repoRoot = repoRoot
        draft.mainRepoRoot = mainRepoRoot
        draft.branch = branch
        draft.model = model
        draft.effort = effort
        draft.generation = generation
        draft.transcriptPath = transcriptPath
        draft.createdAtMs = createdAtMs
        draft.updatedAtMs = updatedAtMs
        draft.lastUserAtMs = lastUserAtMs
        draft.archived = archived
        draft.parentNativeID = parentNativeID
        return draft
    }

    /// A stored row: first prompt title, a distinct value in every location and run column,
    /// created 1000, updated 2000, not archived.
    static func stored(
        title: String = "first prompt",
        kind: AgentHistoryTitleKind = .firstPrompt,
        cwd: String? = "/repo",
        repoRoot: String? = "/work/linked-root",
        mainRepoRoot: String? = "/work/main-root",
        branch: String? = "main",
        model: String? = "stored-model",
        effort: String? = "stored-effort",
        generation: String? = "stored-generation",
        transcriptPath: String? = "/transcripts/stored.jsonl",
        createdAtMs: Int64 = 1_000,
        updatedAtMs: Int64 = 2_000,
        lastUserAtMs: Int64? = nil,
        archived: Bool = false,
        parentNativeID: String? = "stored-parent"
    ) -> AgentHistorySessionDraft {
        draft(
            title: title, kind: kind, cwd: cwd, repoRoot: repoRoot, mainRepoRoot: mainRepoRoot,
            branch: branch, model: model, effort: effort, generation: generation,
            transcriptPath: transcriptPath, createdAtMs: createdAtMs, updatedAtMs: updatedAtMs,
            lastUserAtMs: lastUserAtMs, archived: archived, parentNativeID: parentNativeID
        )
    }

    static let cases: [Case] = [
        // Title precedence
        Case(
            name: "generated replaces first prompt",
            existing: stored(),
            update: draft(title: "Generated", kind: .generated),
            expected: stored(title: "Generated", kind: .generated)
        ),
        Case(
            name: "custom replaces generated",
            existing: stored(title: "Generated", kind: .generated),
            update: draft(title: "Custom", kind: .custom),
            expected: stored(title: "Custom", kind: .custom)
        ),
        Case(
            name: "first prompt never replaces generated",
            existing: stored(title: "Generated", kind: .generated),
            update: draft(title: "later prompt", kind: .firstPrompt),
            expected: stored(title: "Generated", kind: .generated)
        ),
        Case(
            name: "generated never replaces custom",
            existing: stored(title: "Custom", kind: .custom),
            update: draft(title: "Generated", kind: .generated),
            expected: stored(title: "Custom", kind: .custom)
        ),
        Case(
            name: "equal rank custom takes the update",
            existing: stored(title: "Custom one", kind: .custom),
            update: draft(title: "Custom two", kind: .custom),
            expected: stored(title: "Custom two", kind: .custom)
        ),
        Case(
            name: "equal rank generated takes the update",
            existing: stored(title: "Generated one", kind: .generated),
            update: draft(title: "Generated two", kind: .generated),
            expected: stored(title: "Generated two", kind: .generated)
        ),
        Case(
            name: "equal rank first prompt keeps the earliest",
            existing: stored(title: "first prompt"),
            update: draft(title: "second prompt", kind: .firstPrompt),
            expected: stored(title: "first prompt")
        ),
        Case(
            name: "empty incoming title never wins",
            existing: stored(title: "first prompt"),
            update: draft(title: "", kind: .custom),
            expected: stored(title: "first prompt")
        ),
        Case(
            name: "nil incoming title keeps the stored one",
            existing: stored(title: "Generated", kind: .generated),
            update: draft(),
            expected: stored(title: "Generated", kind: .generated)
        ),
        Case(
            name: "stored empty title always loses",
            existing: stored(title: "", kind: .custom),
            update: draft(title: "a prompt", kind: .firstPrompt),
            expected: stored(title: "a prompt", kind: .firstPrompt)
        ),
        // Timestamps
        Case(
            name: "created takes the minimum",
            existing: stored(createdAtMs: 1_000),
            update: draft(createdAtMs: 500),
            expected: stored(createdAtMs: 500)
        ),
        Case(
            name: "later created keeps the stored minimum",
            existing: stored(createdAtMs: 1_000),
            update: draft(createdAtMs: 1_500),
            expected: stored(createdAtMs: 1_000)
        ),
        Case(
            name: "updated takes the maximum",
            existing: stored(updatedAtMs: 2_000),
            update: draft(updatedAtMs: 3_000),
            expected: stored(updatedAtMs: 3_000)
        ),
        Case(
            name: "older updated keeps the stored maximum",
            existing: stored(updatedAtMs: 2_000),
            update: draft(updatedAtMs: 1_500),
            expected: stored(updatedAtMs: 2_000)
        ),
        Case(
            name: "nil timestamps never clear",
            existing: stored(createdAtMs: 1_000, updatedAtMs: 2_000, lastUserAtMs: 1_800),
            update: draft(),
            expected: stored(createdAtMs: 1_000, updatedAtMs: 2_000, lastUserAtMs: 1_800)
        ),
        Case(
            name: "last user fills from nil",
            existing: stored(lastUserAtMs: nil),
            update: draft(lastUserAtMs: 1_900),
            expected: stored(lastUserAtMs: 1_900)
        ),
        Case(
            name: "last user takes the maximum",
            existing: stored(lastUserAtMs: 1_900),
            update: draft(lastUserAtMs: 1_700),
            expected: stored(lastUserAtMs: 1_900)
        ),
        // Other fields
        Case(
            name: "non-nil fields replace",
            existing: stored(cwd: "/repo", branch: "main", model: "old"),
            update: draft(cwd: "/repo/sub", branch: "feature", model: "new"),
            expected: stored(cwd: "/repo/sub", branch: "feature", model: "new")
        ),
        Case(
            name: "nil fields never clear",
            existing: stored(cwd: "/repo", branch: "main", model: "old"),
            update: draft(),
            expected: stored(cwd: "/repo", branch: "main", model: "old")
        ),
        Case(
            name: "non-nil location and run fields replace",
            existing: stored(),
            update: draft(
                repoRoot: "/next/linked-root", mainRepoRoot: "/next/main-root", effort: "next-effort",
                generation: "next-generation", transcriptPath: "/transcripts/next.jsonl", parentNativeID: "next-parent"
            ),
            expected: stored(
                repoRoot: "/next/linked-root", mainRepoRoot: "/next/main-root", effort: "next-effort",
                generation: "next-generation", transcriptPath: "/transcripts/next.jsonl", parentNativeID: "next-parent"
            )
        ),
        Case(
            name: "repo root alone leaves main repo root",
            existing: stored(),
            update: draft(repoRoot: "/next/linked-root"),
            expected: stored(repoRoot: "/next/linked-root")
        ),
        Case(
            name: "main repo root alone leaves repo root",
            existing: stored(),
            update: draft(mainRepoRoot: "/next/main-root"),
            expected: stored(mainRepoRoot: "/next/main-root")
        ),
        Case(
            name: "nil location and run fields never clear",
            existing: stored(),
            update: draft(title: "Generated", kind: .generated),
            expected: stored(title: "Generated", kind: .generated)
        ),
        Case(
            name: "archived is set by the update",
            existing: stored(archived: false),
            update: draft(archived: true),
            expected: stored(archived: true)
        ),
        Case(
            name: "archived can be cleared explicitly",
            existing: stored(archived: true),
            update: draft(archived: false),
            expected: stored(archived: false)
        ),
        Case(
            name: "nil archived keeps the stored value",
            existing: stored(archived: true),
            update: draft(),
            expected: stored(archived: true)
        ),
    ]
}

final class AgentHistoryContractsTests: XCTestCase {
    // MARK: - Agent

    func test_agent_tool_round_trip_and_unsupported_tools_are_nil() {
        for agent in AgentHistoryAgent.allCases {
            XCTAssertEqual(AgentHistoryAgent(tool: agent.agentTool), agent)
            XCTAssertEqual(agent.displayName, agent.agentTool.displayName)
        }
        XCTAssertEqual(AgentHistoryAgent(tool: .claudeCode), .claude)
        XCTAssertEqual(AgentHistoryAgent(tool: .codex), .codex)
        XCTAssertEqual(AgentHistoryAgent(tool: .grok), .grok)
        XCTAssertEqual(AgentHistoryAgent(tool: .openCode), .opencode)
        XCTAssertNil(AgentHistoryAgent(tool: .amp))
        XCTAssertNil(AgentHistoryAgent(tool: .gemini))
        XCTAssertNil(AgentHistoryAgent(tool: .pi))
        XCTAssertNil(AgentHistoryAgent(tool: .custom("X")))
        XCTAssertNil(AgentHistoryAgent(tool: .custom("Claude Code")))
        XCTAssertEqual(AgentHistoryAgent.allCases.map(\.rawValue), ["claude", "codex", "grok", "opencode"])
    }

    func test_normalized_session_id_lowercases_uuids_and_rejects_unsafe() {
        let upper = "0B6C1D8E-4B1A-4C55-9A1E-3F4B2C6D7E8F"
        XCTAssertEqual(AgentHistoryAgent.claude.normalizedSessionID(upper), upper.lowercased())
        XCTAssertNil(AgentHistoryAgent.claude.normalizedSessionID("not-a-uuid"))
        XCTAssertNil(AgentHistoryAgent.claude.normalizedSessionID(""))

        XCTAssertEqual(AgentHistoryAgent.codex.normalizedSessionID(upper), upper.lowercased())
        XCTAssertEqual(AgentHistoryAgent.codex.normalizedSessionID("thread_01-x"), "thread_01-x")
        XCTAssertNil(AgentHistoryAgent.codex.normalizedSessionID("$(id)"))
        XCTAssertNil(AgentHistoryAgent.codex.normalizedSessionID("a b"))

        XCTAssertEqual(AgentHistoryAgent.grok.normalizedSessionID(upper), upper.lowercased())
        XCTAssertEqual(AgentHistoryAgent.grok.normalizedSessionID("abcd1234"), "abcd1234")
        XCTAssertNil(AgentHistoryAgent.grok.normalizedSessionID("ab;rm"))

        XCTAssertEqual(AgentHistoryAgent.opencode.normalizedSessionID("ses_Abc123"), "ses_Abc123")
        XCTAssertNil(AgentHistoryAgent.opencode.normalizedSessionID("ses_a;b"))
        XCTAssertNil(AgentHistoryAgent.opencode.normalizedSessionID("abc123"))
    }

    func test_session_key_codable_round_trip() throws {
        let key = AgentHistorySessionKey(agent: .opencode, nativeID: "ses_Abc123")
        let data = try JSONEncoder().encode(key)
        XCTAssertEqual(try JSONDecoder().decode(AgentHistorySessionKey.self, from: data), key)
    }

    func test_title_kind_rank_and_order() {
        XCTAssertEqual(AgentHistoryTitleKind.firstPrompt.rank, 1)
        XCTAssertEqual(AgentHistoryTitleKind.generated.rank, 2)
        XCTAssertEqual(AgentHistoryTitleKind.custom.rank, 3)
        XCTAssertLessThan(AgentHistoryTitleKind.firstPrompt, .generated)
        XCTAssertLessThan(AgentHistoryTitleKind.generated, .custom)
        XCTAssertEqual([AgentHistoryTitleKind.custom, .firstPrompt, .generated].sorted(), [.firstPrompt, .generated, .custom])
        XCTAssertEqual(AgentHistoryTitleKind.firstPrompt.rawValue, "first_prompt")
        XCTAssertEqual(AgentHistoryTitleKind(rawValue: "generated"), .generated)
        XCTAssertEqual(AgentHistoryArtifactKind.allCases.map(\.rawValue), ["path", "command", "commit", "pr"])
    }

    // MARK: - Merge

    func test_merge_table() {
        for row in AgentHistoryMergeTable.cases {
            let merged = AgentHistorySessionDraft.merged(existing: row.existing, update: row.update)
            XCTAssertEqual(merged, row.expected, row.name)
        }
    }

    func test_merge_without_existing_returns_update() {
        let update = AgentHistoryMergeTable.draft(title: "hello", kind: .firstPrompt, updatedAtMs: 5)
        XCTAssertEqual(AgentHistorySessionDraft.merged(existing: nil, update: update), update)
    }

    func test_merge_nil_kind_counts_as_first_prompt() {
        let existing = AgentHistoryMergeTable.stored(title: "first prompt")
        let update = AgentHistoryMergeTable.draft(title: "other")
        XCTAssertEqual(AgentHistorySessionDraft.merged(existing: existing, update: update).title, "first prompt")

        let emptyStored = AgentHistoryMergeTable.stored(title: "")
        let merged = AgentHistorySessionDraft.merged(existing: emptyStored, update: update)
        XCTAssertEqual(merged.title, "other")
        XCTAssertEqual(merged.titleKind, .firstPrompt)
    }

    // MARK: - File identity

    func test_file_identity_stat_reports_size_and_nanosecond_mtime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("a.jsonl")
        try Data("hello\n".utf8).write(to: file)
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)

        let identity = try XCTUnwrap(AgentHistoryFileIdentity.stat(path: file.path))
        XCTAssertEqual(identity.size, 6)
        XCTAssertGreaterThan(identity.ino, 0)
        XCTAssertEqual(Double(identity.mtimeNs) / 1e9, 1_700_000_000.25, accuracy: 0.001)
        XCTAssertEqual(AgentHistoryFileIdentity.stat(path: file.path), identity)

        try Data("hello\nworld\n".utf8).write(to: file)
        XCTAssertEqual(AgentHistoryFileIdentity.stat(path: file.path)?.size, 12)
        XCTAssertNil(AgentHistoryFileIdentity.stat(path: directory.appendingPathComponent("missing").path))
    }

    func test_cursor_defaults() {
        let cursor = AgentHistoryCursor(sourceID: 3, unitKey: "u")
        XCTAssertNil(cursor.identity)
        XCTAssertEqual(cursor.byteOffset, 0)
        XCTAssertEqual(cursor.nextSeq, 0)
        XCTAssertNil(cursor.watermark)
        XCTAssertNil(cursor.fingerprint)
        XCTAssertFalse(cursor.isRejected)
        XCTAssertNil(cursor.adapterState)

        let batch = AgentHistoryIngestBatch(cursor: cursor, hasMore: false)
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertTrue(batch.replaceContentOf.isEmpty)
        XCTAssertEqual(batch.diagnostics, AgentHistoryIngestDiagnostics())
        XCTAssertNil(batch.problem)
    }
}
