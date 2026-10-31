import Foundation
import XCTest
@testable import Zentty

final class ClaudeHistorySourceTests: XCTestCase {
    typealias F = AgentHistoryFixtures
    let t = F.claudeBaseMs
    let id = F.claudeSessionID
    let otherID = "7b0c4d2e-1111-4a2b-8c3d-9e8f7a6b5c4d"

    // MARK: - Helpers

    struct Fixture {
        let root: URL
        let source: ClaudeHistorySource
        var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
    }

    func makeFixture() throws -> Fixture {
        let directory = try F.makeTemporaryDirectory(self)
        let root = directory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        let source = ClaudeHistorySource(root: AgentHistorySourceRoot(
            agent: .claude, path: AgentHistoryPath.canonical(root.path), isDefault: false
        ))
        return Fixture(root: root, source: source)
    }

    @discardableResult
    func writeTranscript(
        _ lines: [String],
        in fixture: Fixture,
        project: String = F.claudeProjectDirectoryName(F.claudeCwd),
        fileName: String? = nil
    ) throws -> URL {
        let folder = fixture.projects.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName ?? "\(id).jsonl")
        try F.writeJSONL(lines, to: url)
        return url
    }

    func unit(_ fixture: Fixture, key: String? = nil) throws -> AgentHistoryUnit {
        let wanted = key ?? id
        return try XCTUnwrap(fixture.source.discoverUnits().first { $0.key == wanted }, "unit \(wanted)")
    }

    func context(
        messageLimit: Int = 500,
        sourceBytes: Int = 8 << 20,
        admission: AgentHistoryAdmission = .admitAll,
        repositories: RepositoryIdentityCache = RepositoryIdentityCache(resolve: { _ in nil }),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> AgentHistoryIngestContext {
        AgentHistoryIngestContext(
            limits: AgentHistoryIngestLimits(messages: messageLimit, sourceBytes: sourceBytes),
            admission: admission,
            repositories: repositories,
            isCancelled: isCancelled
        )
    }

    /// Ingests from the start and keeps going while `hasMore`, feeding each cursor back.
    func ingestAll(
        _ fixture: Fixture,
        unit: AgentHistoryUnit,
        context: AgentHistoryIngestContext? = nil,
        cursor: AgentHistoryCursor? = nil,
        mode: AgentHistoryIngestMode = .fromStart
    ) throws -> [AgentHistoryIngestBatch] {
        let context = context ?? self.context()
        var batches: [AgentHistoryIngestBatch] = []
        var batch = try fixture.source.ingest(unit: unit, cursor: cursor, mode: mode, context: context)
        batches.append(batch)
        while batch.hasMore {
            XCTAssertLessThan(batches.count, 100, "runaway batching")
            batch = try fixture.source.ingest(
                unit: unit, cursor: batch.cursor,
                mode: .fromOffset(batch.cursor.byteOffset, nextSeq: batch.cursor.nextSeq),
                context: context
            )
            batches.append(batch)
        }
        return batches
    }

    func merged(_ batches: [AgentHistoryIngestBatch]) -> AgentHistorySessionDraft? {
        batches.flatMap(\.sessions).reduce(nil) { AgentHistorySessionDraft.merged(existing: $0, update: $1) }
    }

    func artifacts(_ batches: [AgentHistoryIngestBatch], _ kind: AgentHistoryArtifactKind) -> [String] {
        batches.flatMap(\.artifacts).filter { $0.kind == kind }.map(\.value)
    }

    // MARK: - Discovery

    func test_discovers_top_level_only() throws {
        let fixture = try makeFixture()
        let line = try F.claudeUser("hello")
        let main = try writeTranscript([line], in: fixture)
        try writeTranscript([line], in: fixture, fileName: otherID.uppercased() + ".jsonl")
        let project = F.claudeProjectDirectoryName(F.claudeCwd)
        try writeTranscript([line], in: fixture, project: "\(project)/\(id)/subagents", fileName: "agent-a1b2.jsonl")
        try writeTranscript([line], in: fixture, project: "\(project)/\(id)/subagents", fileName: "\(otherID.dropLast(4))aaaa.jsonl")
        try writeTranscript([line], in: fixture, project: "\(project)/\(id)/tool-results", fileName: "\(otherID.dropLast(4))bbbb.jsonl")
        try writeTranscript([line], in: fixture, project: "\(project)/workflows", fileName: "\(otherID.dropLast(4))cccc.jsonl")
        try writeTranscript([line], in: fixture, fileName: "notes.txt")
        try F.writeJSONL([line], to: fixture.projects.appendingPathComponent("\(otherID.dropLast(4))dddd.jsonl"))

        let units = try fixture.source.discoverUnits()
        XCTAssertEqual(Set(units.map(\.key)), [id, otherID], "upper-case stems normalize to lower case")
        let mainUnit = try XCTUnwrap(units.first { $0.key == id })
        XCTAssertEqual(mainUnit.kind, .jsonl)
        XCTAssertEqual(mainUnit.nativeSessionID, id)
        XCTAssertEqual(mainUnit.path, main.path)
        XCTAssertEqual(mainUnit.identity, AgentHistoryFileIdentity.stat(path: main.path))
        XCTAssertEqual(fixture.source.estimatedSessionCount(), 2)
        XCTAssertEqual(fixture.source.adapterVersion, 1)
        XCTAssertEqual(fixture.source.agent, .claude)

        let projects = AgentHistoryPath.canonical(fixture.projects.path)
        XCTAssertEqual(fixture.source.watchPaths, [projects])
        XCTAssertEqual(fixture.source.eventTarget(forCanonicalPath: "\(projects)/\(project)/\(id).jsonl"), .unit(id))
        let realProjects = try XCTUnwrap(realpathString(fixture.projects.path))
        XCTAssertEqual(fixture.source.eventTarget(forCanonicalPath: "\(realProjects)/\(project)/\(id).jsonl"), .unit(id),
                       "FSEvents realpaths (with /private) map too")
        XCTAssertNil(fixture.source.eventTarget(forCanonicalPath: "\(projects)/\(project)/\(id)/subagents/agent-a1b2.jsonl"))
        XCTAssertNil(fixture.source.eventTarget(forCanonicalPath: "\(projects)/\(project)/notes.txt"))
        XCTAssertNil(fixture.source.eventTarget(forCanonicalPath: "\(projects)/\(id).jsonl"))
        XCTAssertNil(fixture.source.eventTarget(forCanonicalPath: "/elsewhere/projects/\(project)/\(id).jsonl"))
    }

    func test_invalid_stem_skipped() throws {
        let fixture = try makeFixture()
        let url = try writeTranscript([try F.claudeUser("hello")], in: fixture, fileName: "not-a-uuid.jsonl")
        XCTAssertEqual(try fixture.source.discoverUnits(), [])
        let projects = AgentHistoryPath.canonical(fixture.projects.path)
        XCTAssertNil(fixture.source.eventTarget(
            forCanonicalPath: "\(projects)/\(F.claudeProjectDirectoryName(F.claudeCwd))/not-a-uuid.jsonl"
        ))

        let forged = AgentHistoryUnit(
            key: "not-a-uuid", path: url.path, kind: .jsonl,
            identity: AgentHistoryFileIdentity.stat(path: url.path), nativeSessionID: "not-a-uuid"
        )
        let batch = try fixture.source.ingest(unit: forged, cursor: nil, mode: .fromStart, context: context())
        XCTAssertTrue(batch.sessions.isEmpty)
        XCTAssertTrue(batch.messages.isEmpty)
        XCTAssertFalse(batch.hasMore)
        XCTAssertEqual(batch.diagnostics.skippedSessions["not-a-uuid"], .invalidSessionID)
    }

    // MARK: - Messages

    func test_indexes_prompts_and_text() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.jsonLine(["type": "file-history-snapshot", "messageId": "m1", "snapshot": [:]]),
            try F.claudeUser("Fix the login bug", atMs: t),
            try F.claudeAssistant([
                ["type": "thinking", "thinking": "secret reasoning"],
                F.claudeTextPart("Looking at the login flow."),
                F.claudeToolUse("Grep", input: ["pattern": "login"]),
                F.claudeTextPart("Found it."),
            ], atMs: t + 1_000),
            try F.claudeUser([F.claudeTextPart("Also check"), F.claudeTextPart("the logout path"),
                              ["type": "image", "source": ["type": "base64", "data": "AAAA"]]], atMs: t + 2_000),
            try F.jsonLine(["type": "progress", "data": ["message": "noise"]]),
        ], in: fixture)

        let batches = try ingestAll(fixture, unit: try unit(fixture))
        XCTAssertEqual(batches.count, 1)
        let messages = batches[0].messages
        XCTAssertEqual(messages.map(\.role), [.user, .agent, .user])
        XCTAssertEqual(messages.map(\.text), ["Fix the login bug", "Looking at the login flow.\n\nFound it.", "Also check\n\nthe logout path"])
        XCTAssertEqual(messages.map(\.seq), [0, 1, 2])
        XCTAssertEqual(messages.map(\.atMs), [t, t + 1_000, t + 2_000])
        XCTAssertEqual(messages[0].searchText, AgentHistorySearchText.normalize("Fix the login bug"))
        XCTAssertEqual(messages.map(\.sessionNativeID), [id, id, id])
        XCTAssertFalse(messages.contains { $0.text.contains("secret reasoning") })

        let session = try XCTUnwrap(batches[0].sessions.first)
        XCTAssertEqual(session.nativeID, id)
        XCTAssertEqual(session.title, "Fix the login bug")
        XCTAssertEqual(session.titleKind, .firstPrompt)
        XCTAssertEqual(session.createdAtMs, t)
        XCTAssertEqual(session.updatedAtMs, t + 2_000)
        XCTAssertEqual(session.lastUserAtMs, t + 2_000)
        XCTAssertEqual(session.transcriptPath, try unit(fixture).path)
        XCTAssertEqual(batches[0].replaceContentOf, [id], "a read from byte 0 replaces stored content")
        XCTAssertEqual(batches[0].diagnostics.malformedLines, 0)
    }

    func test_skips_tool_result_thinking_meta_compact_sidechain_envelopes_nonhuman() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.claudeUser("meta caveat", extra: ["isMeta": true]),
            try F.claudeUser("This session is being continued…", extra: ["isCompactSummary": true]),
            try F.claudeUser("transcript-only", extra: ["isVisibleInTranscriptOnly": true]),
            try F.claudeUser("sidechain prompt", extra: ["isSidechain": true]),
            try F.claudeUser("queued notification", extra: ["origin": ["kind": "task-notification"]]),
            try F.claudeUser("typed by a person", atMs: t + 10, extra: ["origin": ["kind": "human"]]),
            try F.claudeUser([["type": "tool_result", "tool_use_id": "toolu_x", "content": "tool output text"]]),
            try F.claudeUser("result with toolUseResult", extra: ["toolUseResult": ["stdout": "x"]]),
            try F.claudeUser("<system-reminder>internal</system-reminder>"),
            try F.claudeUser("<local-command-stdout>Compacted</local-command-stdout>"),
            try F.claudeUser([F.claudeTextPart("real ask"), F.claudeTextPart("<system-reminder>noise</system-reminder>")], atMs: t + 20),
            try F.claudeAssistant([["type": "thinking", "thinking": "hmm"]]),
            try F.claudeAssistant([F.claudeTextPart("sidechain reply")], extra: ["isSidechain": true]),
            try F.claudeAssistant([F.claudeTextPart("API Error: overloaded")], model: "<synthetic>",
                                  extra: ["isApiErrorMessage": true]),
            try F.claudeAssistant([F.claudeTextPart("real reply")], atMs: t + 30),
        ], in: fixture)

        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        XCTAssertEqual(batch.messages.map(\.text), ["typed by a person", "real ask", "real reply"])
        XCTAssertEqual(batch.messages.map(\.role), [.user, .user, .agent])
        XCTAssertGreaterThanOrEqual(batch.diagnostics.skippedRecords, 8)
        XCTAssertEqual(batch.sessions.first?.title, "typed by a person")
    }

    func test_command_envelope_slash_text() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.claudeUser("<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>", atMs: t),
            try F.claudeUser("<command-name>review</command-name>\n<command-message>review</command-message>\n<command-args>pr 174</command-args>", atMs: t + 1),
            try F.claudeUser("<bash-input>git status --short</bash-input>", atMs: t + 2),
            try F.claudeUser("<bash-stdout>M file</bash-stdout><bash-stderr></bash-stderr>", atMs: t + 3),
            try F.claudeUser("Now summarize the diff", atMs: t + 4),
        ], in: fixture)

        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        XCTAssertEqual(batch.messages.map(\.text), ["/clear", "/review pr 174", "Now summarize the diff"])
        XCTAssertEqual(batch.messages.map(\.role), [.user, .user, .user])
        XCTAssertEqual(artifacts([batch], .command), ["git status --short"])
        XCTAssertEqual(batch.sessions.first?.title, "Now summarize the diff", "slash commands are not first prompts")
    }

    func test_skips_forked_copies() throws {
        let fixture = try makeFixture()
        let forked: [String: Any] = ["forkedFrom": ["sessionId": otherID, "messageUuid": UUID().uuidString.lowercased()]]
        try writeTranscript([
            try F.claudeUser("copied prompt", atMs: t, extra: forked),
            try F.claudeAssistant([F.claudeTextPart("copied reply"),
                                   F.claudeToolUse("Bash", input: ["command": "make copied"])],
                                  atMs: t + 1, requestedModel: "claude-haiku-5-5", extra: forked),
            try F.claudeTitle("custom-title", "Fork (Branch)"),
            try F.claudeUser("new prompt in the fork", atMs: t + 2),
            try F.claudeAssistant([F.claudeTextPart("new reply")], atMs: t + 3),
        ], in: fixture)

        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        XCTAssertEqual(batch.messages.map(\.text), ["new prompt in the fork", "new reply"])
        XCTAssertEqual(artifacts([batch], .command), [])
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.title, "Fork (Branch)")
        XCTAssertEqual(session.titleKind, .custom)
        XCTAssertEqual(session.model, "claude-opus-5-5", "forked records do not set metadata")
        XCTAssertEqual(session.createdAtMs, t + 2)
    }

    // MARK: - Titles

    func test_title_precedence_across_batches() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.claudeUser("First prompt text", atMs: t),
            try F.claudeTitle("ai-title", "Early AI title"),
            try F.claudeUser("Second prompt", atMs: t + 1),
            try F.claudeTitle("custom-title", "My custom name"),
            try F.claudeUser("Third prompt", atMs: t + 2),
            try F.claudeTitle("ai-title", "Later AI title"),
            try F.claudeUser("Fourth prompt", atMs: t + 3),
        ], in: fixture)
        try writeTranscript([
            try F.claudeUser("Only prompt", atMs: t, sessionID: otherID),
            try F.claudeTitle("summary", "Legacy summary", sessionID: otherID),
            try F.claudeUser("Next", atMs: t + 1, sessionID: otherID),
            try F.claudeTitle("ai-title", "Newer AI title", sessionID: otherID),
            try F.claudeUser("Last", atMs: t + 2, sessionID: otherID),
        ], in: fixture, fileName: "\(otherID).jsonl")

        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource()
        for key in [id, otherID] {
            let batches = try ingestAll(fixture, unit: try unit(fixture, key: key), context: context(messageLimit: 1))
            XCTAssertGreaterThan(batches.count, 2, "one message per batch")
            for batch in batches {
                try store.apply(batch, sourceID: sourceID, unitKey: key)
            }
        }

        let summaries = Dictionary(uniqueKeysWithValues: try store.allVisibleSessionSummaries().map { ($0.nativeID, $0) })
        XCTAssertEqual(summaries[id]?.title, "My custom name", "custom beats a later AI title")
        XCTAssertEqual(summaries[id]?.titleKind, .custom)
        XCTAssertEqual(summaries[id]?.turnCount, 4)
        XCTAssertEqual(summaries[otherID]?.title, "Newer AI title", "the latest generated title wins")
        XCTAssertEqual(summaries[otherID]?.titleKind, .generated)
    }

    func test_titles_are_redacted() throws {
        let fixture = try makeFixture()
        let token = F.fakeGitHubToken()
        let key = F.fakeOpenAIKey()
        try writeTranscript([
            try F.claudeUser("prompt with \(key)", atMs: t),
            try F.claudeTitle("summary", "Summary \(token)"),
            try F.claudeTitle("ai-title", "AI \(token)"),
            try F.claudeTitle("custom-title", "Custom \(key)"),
        ], in: fixture)

        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(session.titleKind, .custom)
        XCTAssertEqual(session.title, "Custom \(AgentHistoryRedactor.replacement)")

        try writeTranscript([
            try F.claudeUser("prompt \(token)", atMs: t, sessionID: otherID),
            try F.claudeTitle("ai-title", "AI \(token)", sessionID: otherID),
        ], in: fixture, fileName: "\(otherID).jsonl")
        let other = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture, key: otherID)).first?.sessions.first)
        XCTAssertEqual(other.title, "AI \(AgentHistoryRedactor.replacement)")
        XCTAssertFalse((other.title ?? "").contains(token))
    }

    // MARK: - Metadata

    func test_model_requested_effort_latest_synthetic_ignored() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.claudeUser("go", atMs: t),
            try F.claudeAssistant([F.claudeTextPart("one")], atMs: t + 1, model: "claude-opus-5-5",
                                  requestedModel: "claude-opus-5-5[1m]", effort: "high"),
            try F.claudeAssistant([F.claudeTextPart("two")], atMs: t + 2, model: "claude-sonnet-5", effort: "medium"),
            try F.claudeAssistant([F.claudeTextPart("API Error")], atMs: t + 3, model: "<synthetic>",
                                  effort: "low", extra: ["isApiErrorMessage": true]),
            try F.claudeAssistant([F.claudeTextPart("no model")], atMs: t + 4, model: "<synthetic>"),
        ], in: fixture)
        try writeTranscript([
            try F.claudeUser("go", atMs: t, sessionID: otherID),
            try F.claudeAssistant([F.claudeTextPart("one")], atMs: t + 1, model: "claude-opus-5-5",
                                  requestedModel: "claude-opus-5-5[1m]", effort: "xhigh", sessionID: otherID),
        ], in: fixture, fileName: "\(otherID).jsonl")

        let session = try XCTUnwrap(merged(ingestAll(fixture, unit: try unit(fixture))))
        XCTAssertEqual(session.model, "claude-sonnet-5", "latest record wins; <synthetic> is ignored")
        XCTAssertEqual(session.effort, "medium", "API error records do not count")
        let other = try XCTUnwrap(merged(ingestAll(fixture, unit: try unit(fixture, key: otherID))))
        XCTAssertEqual(other.model, "claude-opus-5-5[1m]", "requestedModel beats message.model")
        XCTAssertEqual(other.effort, "xhigh")
    }

    func test_cwd_project_encoding_branch_latest() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.claudeUser("started elsewhere", atMs: t, cwd: "/Users/example/dev", branch: "main"),
            try F.claudeUser("in the project", atMs: t + 1, cwd: F.claudeCwd, branch: "feature/login"),
            try F.claudeAssistant([F.claudeTextPart("ok")], atMs: t + 2, cwd: "/Users/example/dev/app/sub", branch: ""),
        ], in: fixture)
        let session = try XCTUnwrap(merged(ingestAll(fixture, unit: try unit(fixture))))
        XCTAssertEqual(session.cwd, AgentHistoryPath.canonical(F.claudeCwd), "the cwd matching the project folder wins")
        XCTAssertEqual(session.branch, "feature/login", "latest non-empty gitBranch")

        // No cwd matches the folder name: the first cwd is used.
        try writeTranscript([
            try F.claudeUser("one", atMs: t, cwd: "/Users/example/first", sessionID: otherID),
            try F.claudeUser("two", atMs: t + 1, cwd: "/Users/example/second", sessionID: otherID),
        ], in: fixture, project: "-renamed-project", fileName: "\(otherID).jsonl")
        let fallback = try XCTUnwrap(merged(ingestAll(fixture, unit: try unit(fixture, key: otherID))))
        XCTAssertEqual(fallback.cwd, AgentHistoryPath.canonical("/Users/example/first"))

        // Repository identity comes from the context cache, for an existing folder.
        let repo = try F.makeTemporaryDirectory(self).appendingPathComponent("repo", isDirectory: true)
        let worktree = repo.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let thirdID = "0d5e6f70-2222-4b3c-9d4e-0f1a2b3c4d5e"
        try writeTranscript([
            try F.claudeUser("in a worktree", atMs: t, cwd: worktree.path, sessionID: thirdID),
        ], in: fixture, project: F.claudeProjectDirectoryName(worktree.path), fileName: "\(thirdID).jsonl")
        let canonicalWorktree = AgentHistoryPath.canonical(worktree.path)
        let canonicalRepo = AgentHistoryPath.canonical(repo.path)
        let repositories = RepositoryIdentityCache(resolve: { directory in
            directory == canonicalWorktree
                ? RepositoryIdentity(repoRoot: canonicalWorktree, mainRepoRoot: canonicalRepo, isLinkedWorktree: true, headBranch: "wt")
                : nil
        })
        let third = try XCTUnwrap(merged(ingestAll(fixture, unit: try unit(fixture, key: thirdID),
                                                   context: context(repositories: repositories))))
        XCTAssertEqual(third.cwd, canonicalWorktree)
        XCTAssertEqual(third.repoRoot, canonicalWorktree)
        XCTAssertEqual(third.mainRepoRoot, canonicalRepo)
    }

    // MARK: - Artifacts

    func test_artifacts_paths_commands_pr_gitoperation_regex_pending_across_batches() throws {
        let fixture = try makeFixture()
        let cwd = F.claudeCwd
        try writeTranscript([
            try F.claudeUser("ship it", atMs: t),
            try F.claudeAssistant([
                F.claudeToolUse("Edit", input: ["file_path": "\(cwd)/Sources/App.swift", "old_string": "a", "new_string": "b"]),
                F.claudeToolUse("Write", input: ["file_path": "/etc/hosts", "content": "x"]),
                F.claudeToolUse("MultiEdit", input: ["file_path": "\(cwd)/Sources/Other.swift", "edits": []]),
                F.claudeToolUse("NotebookEdit", input: ["notebook_path": "\(cwd)/nb.ipynb", "new_source": ""]),
                F.claudeToolUse("Bash", input: ["command": "swift test   --parallel"]),
            ], atMs: t + 1),
            try F.claudeAssistant([
                F.claudeTextPart("Committing now."),
                F.claudeToolUse("Bash", id: "toolu_commit1", input: ["command": "git add . && git commit -m \"fix: login\""]),
            ], atMs: t + 2),
            // Batch boundary (message limit 2): the pending id must survive in adapterState.
            try F.claudeToolResult(toolUseID: "toolu_commit1", stdout: "[main 1a2b3c4] fix: login\n 1 file changed", atMs: t + 3),
            try F.claudeToolResult(toolUseID: "toolu_other", stdout: "[main deadbee] not pending", atMs: t + 4),
            try F.claudeToolResult(toolUseID: "toolu_gitop", stdout: "done",
                                   gitOperation: ["commit": ["sha": "56040c763", "kind": "committed"],
                                                  "pr": ["number": 7, "url": "https://github.com/acme/app/pull/7", "action": "created"]],
                                   atMs: t + 5),
            try F.claudePRLink("https://github.com/acme/app/pull/8", atMs: t + 6),
            try F.claudeUser("thanks", atMs: t + 7),
            try F.claudeAssistant([F.claudeTextPart("Opened https://gitlab.com/acme/app/-/merge_requests/9 for you.")], atMs: t + 8),
        ], in: fixture)

        let batches = try ingestAll(fixture, unit: try unit(fixture), context: context(messageLimit: 2))
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertNotNil(batches[0].cursor.adapterState)
        XCTAssertEqual(artifacts(batches, .path), ["Sources/App.swift", "/etc/hosts", "Sources/Other.swift", "nb.ipynb"])
        XCTAssertEqual(artifacts(batches, .command), ["swift test --parallel", "git add . && git commit -m \"fix: login\""])
        XCTAssertEqual(artifacts(batches, .commit), ["1a2b3c4", "56040c763"], "non-pending tool output is never decoded")
        XCTAssertEqual(artifacts(batches, .pr), [
            "https://github.com/acme/app/pull/7",
            "https://github.com/acme/app/pull/8",
            "https://gitlab.com/acme/app/-/merge_requests/9",
        ])
        let commit = try XCTUnwrap(batches.flatMap(\.artifacts).first { $0.value == "1a2b3c4" })
        XCTAssertEqual(commit.atMs, t + 3)
        XCTAssertEqual(commit.sessionNativeID, id)
    }

    func test_read_paths_excluded() throws {
        let fixture = try makeFixture()
        try writeTranscript([
            try F.claudeUser("look around", atMs: t),
            try F.claudeAssistant([
                F.claudeToolUse("Read", input: ["file_path": "\(F.claudeCwd)/README.md"]),
                F.claudeToolUse("Grep", input: ["pattern": "x", "path": "\(F.claudeCwd)/Sources"]),
                F.claudeToolUse("Glob", input: ["pattern": "**/*.swift", "path": F.claudeCwd]),
            ], atMs: t + 1),
        ], in: fixture)
        let batch = try XCTUnwrap(ingestAll(fixture, unit: try unit(fixture)).first)
        XCTAssertEqual(batch.artifacts, [])
    }

    // MARK: - Utilities

    func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
