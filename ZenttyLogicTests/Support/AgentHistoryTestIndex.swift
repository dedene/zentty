import Foundation
import XCTest
@testable import Zentty

/// A throwaway Agent History index for tests: a fresh `agent-history-<UUID>` temp directory,
/// injected `AgentHistoryPaths`, an `AgentHistoryStorage` over it, and teardown that closes the
/// writer and readers and removes the directory. Later milestones add fixture inserts through
/// the store. Used from the test's own thread only; `@unchecked Sendable` lets the teardown
/// block close the writer it holds.
final class AgentHistoryTestIndex: @unchecked Sendable {
    let directoryURL: URL
    let paths: AgentHistoryPaths
    let storage: AgentHistoryStorage
    private(set) var writerHandle: AgentHistoryWriterHandle?

    init(
        testCase: XCTestCase,
        options: AgentHistoryStorage.Options = .init(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_793_000_000) },
        appVersion: String = "test",
        fileManager: FileManager = .default
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        self.directoryURL = directoryURL
        self.paths = AgentHistoryPaths(directoryURL: directoryURL.appendingPathComponent("AgentHistory", isDirectory: true))
        self.storage = AgentHistoryStorage(paths: paths, options: options, fileManager: fileManager, now: now,
                                           appVersion: appVersion)
        let storage = self.storage
        testCase.addTeardownBlock { [weak self] in
            self?.writerHandle?.database.close()
            storage.readers.closeAll()
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    /// Opens the writer once and keeps it; later calls return the same connection.
    @discardableResult
    func openWriter() throws -> AgentHistoryDatabase {
        if let writerHandle, writerHandle.database.isOpen {
            return writerHandle.database
        }
        let handle = try storage.openWriter()
        writerHandle = handle
        return handle.database
    }

    /// Closes the writer so the next `openWriter()` reopens the file.
    func closeWriter() {
        writerHandle?.database.close()
        writerHandle = nil
    }
}

// MARK: - Store fixtures

extension AgentHistoryTestIndex {
    static let fixedNow = Date(timeIntervalSince1970: 1_793_000_000)

    /// A store over the (lazily opened) writer with a fixed clock.
    func makeStore() throws -> AgentHistoryStore {
        AgentHistoryStore(database: try openWriter(), now: { AgentHistoryTestIndex.fixedNow })
    }

    /// Inserts (or returns) the `(agent, root)` source row and returns its id.
    @discardableResult
    func makeSource(_ agent: AgentHistoryAgent = .claude, root: String = "/fixtures/claude") throws -> Int64 {
        try makeStore().upsertSource(agent: agent, root: root, currentAdapterVersion: 1).id
    }
}

/// Draft builders for store tests. Native ids are arbitrary strings: the store does not validate.
enum AgentHistoryFixtures {
    static func session(
        _ nativeID: String,
        title: String? = nil,
        kind: AgentHistoryTitleKind? = nil,
        cwd: String? = nil,
        repoRoot: String? = nil,
        branch: String? = nil,
        createdAtMs: Int64? = nil,
        updatedAtMs: Int64? = nil,
        parentNativeID: String? = nil
    ) -> AgentHistorySessionDraft {
        var draft = AgentHistorySessionDraft(nativeID: nativeID)
        draft.title = title
        draft.titleKind = kind
        draft.cwd = cwd
        draft.repoRoot = repoRoot
        draft.branch = branch
        draft.createdAtMs = createdAtMs
        draft.updatedAtMs = updatedAtMs
        draft.parentNativeID = parentNativeID
        return draft
    }

    static func message(
        _ nativeID: String, seq: Int, role: AgentHistoryRole = .user, atMs: Int64, text: String
    ) -> AgentHistoryMessageDraft {
        AgentHistoryMessageDraft(
            sessionNativeID: nativeID, seq: seq, role: role, atMs: atMs,
            text: text, searchText: AgentHistorySearchText.normalize(text)
        )
    }

    static func artifact(
        _ nativeID: String, seq: Int, kind: AgentHistoryArtifactKind = .path, value: String, atMs: Int64
    ) -> AgentHistoryArtifactDraft {
        AgentHistoryArtifactDraft(
            sessionNativeID: nativeID, seq: seq, kind: kind, value: value,
            searchText: AgentHistorySearchText.normalize(value), atMs: atMs
        )
    }

    static func batch(
        sourceID: Int64,
        unitKey: String,
        sessions: [AgentHistorySessionDraft] = [],
        messages: [AgentHistoryMessageDraft] = [],
        artifacts: [AgentHistoryArtifactDraft] = [],
        replaceContentOf: Set<String> = [],
        removedNativeIDs: Set<String> = []
    ) -> AgentHistoryIngestBatch {
        var batch = AgentHistoryIngestBatch(
            cursor: AgentHistoryCursor(sourceID: sourceID, unitKey: unitKey), hasMore: false
        )
        batch.sessions = sessions
        batch.messages = messages
        batch.artifacts = artifacts
        batch.replaceContentOf = replaceContentOf
        batch.removedNativeIDs = removedNativeIDs
        return batch
    }

    /// FTS rowids matching a quoted term, newest (highest rowid) first.
    static func ftsRowIDs(_ db: AgentHistoryDatabase, table: String = "messages_fts", matching term: String) throws -> [Int64] {
        try db.query(
            "SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY rowid DESC",
            [.text("\"\(term)\"")]
        ) { $0.int64(0) }
    }

    static func count(_ db: AgentHistoryDatabase, _ sql: String, _ bindings: [AgentHistoryValue] = []) throws -> Int {
        Int(try db.scalarInt64(sql, bindings) ?? 0)
    }
}
