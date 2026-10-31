import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryBatchBuilderTests: XCTestCase {
    private func builder(firstSeq: Int = 0, messageLimit: Int = 500) -> AgentHistoryBatchBuilder {
        AgentHistoryBatchBuilder(
            session: AgentHistorySessionDraft(nativeID: "session-1"),
            firstSeq: firstSeq,
            context: AgentHistoryFixtures.context(messageLimit: messageLimit)
        )
    }

    func test_builder_allocates_seq_dedupes_artifacts_and_reports_full() {
        var builder = builder(firstSeq: 5, messageLimit: 3)
        builder.addArtifact(.command, rawValue: "ls", atMs: 900)
        XCTAssertTrue(builder.addMessage(role: .user, atMs: 1_000, rawText: "first"))
        XCTAssertFalse(builder.addMessage(role: .agent, atMs: 1_100, rawText: "  \n\u{1B}[0m  "), "empty after cleanup")
        XCTAssertTrue(builder.addMessage(role: .agent, atMs: 1_200, rawText: "second"))
        builder.addArtifact(.path, rawValue: "Sources/App.swift", atMs: 1_200)
        builder.addArtifact(.path, rawValue: "Sources/App.swift", atMs: 1_300)
        builder.addArtifact(.command, rawValue: "Sources/App.swift", atMs: 1_300)
        builder.addArtifact(.path, rawValue: "   ", atMs: 1_300)
        XCTAssertFalse(builder.isFull)
        XCTAssertTrue(builder.addMessage(role: .user, atMs: 1_400, rawText: "third"))
        XCTAssertTrue(builder.isFull)
        XCTAssertEqual(builder.nextSeq, 8)

        let (messages, artifacts) = builder.drafts()
        XCTAssertEqual(messages.map(\.seq), [5, 6, 7])
        XCTAssertEqual(messages.map(\.role), [.user, .agent, .user])
        XCTAssertEqual(messages.map(\.sessionNativeID), ["session-1", "session-1", "session-1"])
        XCTAssertEqual(artifacts.map(\.kind), [.command, .path, .command])
        XCTAssertEqual(artifacts.map(\.value), ["ls", "Sources/App.swift", "Sources/App.swift"])
        XCTAssertEqual(artifacts.map(\.seq), [4, 6, 6], "artifacts carry the latest message's seq")
        XCTAssertEqual(artifacts[1].atMs, 1_200, "the first occurrence wins")

        XCTAssertEqual(builder.session.createdAtMs, 1_000)
        XCTAssertEqual(builder.session.updatedAtMs, 1_400)
        XCTAssertEqual(builder.session.lastUserAtMs, 1_400)
    }

    func test_builder_redacts_messages_artifacts_and_titles() {
        let token = AgentHistoryFixtures.fakeGitHubToken()
        let key = AgentHistoryFixtures.fakeOpenAIKey()
        var builder = builder()
        builder.addMessage(role: .user, atMs: 1, rawText: "use \(token) please")
        builder.addArtifact(.command, rawValue: "curl -H 'x: \(key)' api", atMs: 1)
        builder.noteTitle("Fix \(token) leak", kind: .generated)

        let (messages, artifacts) = builder.drafts()
        let replacement = AgentHistoryRedactor.replacement
        XCTAssertEqual(messages.first?.text, "use \(replacement) please")
        XCTAssertFalse(messages.first?.searchText.contains(token.lowercased()) ?? true)
        XCTAssertEqual(artifacts.first?.value, "curl -H 'x: \(replacement)' api")
        XCTAssertEqual(builder.session.title, "Fix \(replacement) leak")
        XCTAssertEqual(builder.session.titleKind, .generated)

        var prompted = self.builder()
        prompted.noteFirstPrompt("deploy with \(key)")
        XCTAssertEqual(prompted.session.title, "deploy with \(replacement)")
        XCTAssertEqual(prompted.session.titleKind, .firstPrompt)
    }

    func test_builder_title_precedence_and_first_prompt_once() {
        var builder = builder()
        builder.noteFirstPrompt("first prompt\nsecond line")
        builder.noteFirstPrompt("another prompt")
        XCTAssertEqual(builder.session.title, "first prompt second line")

        builder.noteTitle("Generated", kind: .generated)
        XCTAssertEqual(builder.session.title, "Generated")
        builder.noteTitle("Custom", kind: .custom)
        builder.noteTitle("Later generated", kind: .generated)
        builder.noteTitle(nil, kind: .custom)
        builder.noteTitle("   ", kind: .custom)
        XCTAssertEqual(builder.session.title, "Custom")
        XCTAssertEqual(builder.session.titleKind, .custom)
        builder.noteTitle("Renamed", kind: .custom)
        XCTAssertEqual(builder.session.title, "Renamed")
    }

    func test_builder_search_text_uses_shared_normalizer() {
        var builder = builder()
        let raw = "Café “Déjà vu”\r\n\r\n\r\n\r\nNEXT"
        builder.addMessage(role: .agent, atMs: 5, rawText: raw)
        builder.addArtifact(.path, rawValue: "Docs/Résumé.md", atMs: 5)

        let (messages, artifacts) = builder.drafts()
        let display = AgentHistoryDisplayText.displayText(raw)
        XCTAssertEqual(messages.first?.text, display)
        XCTAssertEqual(messages.first?.searchText, AgentHistorySearchText.normalize(display ?? ""))
        XCTAssertEqual(artifacts.first?.searchText, AgentHistorySearchText.normalize("Docs/Résumé.md"))
        XCTAssertNil(builder.session.lastUserAtMs, "agent turns don't move last user activity")
    }

    func test_cursor_advanced_sets_read_state_and_clears_rejection() {
        let identity = AgentHistoryFileIdentity(dev: 1, ino: 2, size: 300, mtimeNs: 4)
        let start = AgentHistoryCursor(sourceID: 9, unitKey: "k", byteOffset: 10, nextSeq: 1, watermark: 77, isRejected: true)
        let advanced = start.advanced(
            identity: identity,
            byteOffset: 300,
            nextSeq: 12,
            fingerprint: 123,
            adapterState: Data([1, 2])
        )
        XCTAssertEqual(advanced.sourceID, 9)
        XCTAssertEqual(advanced.unitKey, "k")
        XCTAssertEqual(advanced.identity, identity)
        XCTAssertEqual(advanced.byteOffset, 300)
        XCTAssertEqual(advanced.nextSeq, 12)
        XCTAssertEqual(advanced.fingerprint, 123)
        XCTAssertEqual(advanced.adapterState, Data([1, 2]))
        XCTAssertEqual(advanced.watermark, 77)
        XCTAssertFalse(advanced.isRejected)
    }
}
