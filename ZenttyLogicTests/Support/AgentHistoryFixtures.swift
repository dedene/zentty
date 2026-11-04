import Foundation
import XCTest
@testable import Zentty

/// Ingest fixtures for Agent History tests (the store draft builders live with
/// `AgentHistoryTestIndex`). Adapter commits extend this with per-agent JSONL line builders
/// and database fixtures.
extension AgentHistoryFixtures {
    /// A fresh `agent-history-<UUID>` directory under the temp dir, removed at teardown.
    static func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// One JSONL line (no trailing newline) built with `JSONSerialization`, keys sorted.
    static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes `lines` joined by `\n`, each newline-terminated.
    static func writeJSONL(_ lines: [String], to url: URL) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Sets the file's modification time (nanosecond precision is lost; seconds are enough to
    /// change `mtimeNs`).
    static func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// An ingest context over admit-all admission and a repository cache that never touches disk.
    static func context(
        messageLimit: Int = 500,
        admission: AgentHistoryAdmission = .admitAll,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> AgentHistoryIngestContext {
        var limits = AgentHistoryIngestLimits()
        limits.messages = messageLimit
        return AgentHistoryIngestContext(
            limits: limits,
            admission: admission,
            repositories: RepositoryIdentityCache(resolve: { _ in nil }),
            isCancelled: isCancelled
        )
    }

    // MARK: - Fake secrets (assembled at runtime so push protection never sees a literal)

    static func fakeGitHubToken() -> String {
        "gh" + "p_" + String(repeating: "aB3dE5gH7jK9", count: 3)
    }

    static func fakeOpenAIKey() -> String {
        "sk" + "-" + String(repeating: "Zq8Rt2Lm", count: 4)
    }
}
