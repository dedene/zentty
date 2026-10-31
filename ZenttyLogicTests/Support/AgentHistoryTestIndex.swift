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
        appVersion: String = "test"
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        self.directoryURL = directoryURL
        self.paths = AgentHistoryPaths(directoryURL: directoryURL.appendingPathComponent("AgentHistory", isDirectory: true))
        self.storage = AgentHistoryStorage(paths: paths, options: options, now: now, appVersion: appVersion)
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
