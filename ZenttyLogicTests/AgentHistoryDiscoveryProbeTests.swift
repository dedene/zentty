import Foundation
import XCTest
@testable import Zentty

/// A source that records which protocol methods the probe calls.
private final class ProbeRecordingSource: AgentHistorySource, @unchecked Sendable {
    let agent: AgentHistoryAgent
    let root: AgentHistorySourceRoot
    let adapterVersion = 1
    var watchPaths: [String] { [root.path] }

    private let estimate: Int?
    private let lock = NSLock()
    private var calls: [String] = []

    init(agent: AgentHistoryAgent, path: String, estimate: Int?) {
        self.agent = agent
        self.root = AgentHistorySourceRoot(agent: agent, path: path, isDefault: true)
        self.estimate = estimate
    }

    var recordedCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func record(_ name: String) {
        lock.lock()
        calls.append(name)
        lock.unlock()
    }

    func discoverUnits() throws -> [AgentHistoryUnit] {
        record("discoverUnits")
        return []
    }

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        record("eventTarget")
        return nil
    }

    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        record("classifyChange")
        return .unchanged
    }

    func ingest(
        unit: AgentHistoryUnit, cursor: AgentHistoryCursor?, mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        record("ingest")
        return AgentHistoryIngestBatch(cursor: AgentHistoryCursor(sourceID: 0, unitKey: unit.key), hasMore: false)
    }

    func existingNativeIDs() throws -> Set<String>? {
        record("existingNativeIDs")
        return nil
    }

    func estimatedSessionCount() -> Int? {
        record("estimatedSessionCount")
        return estimate
    }
}

final class AgentHistoryDiscoveryProbeTests: XCTestCase {
    private func makeDirectory(_ relativePath: String = "") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("{}\n".utf8)))
    }

    func test_probe_counts_file_sources_and_never_opens_databases() throws {
        let fileRoot = try makeDirectory("claude")
        let databaseRoot = try makeDirectory("opencode")
        let fileSource = ProbeRecordingSource(agent: .claude, path: fileRoot.path, estimate: 3)
        let databaseSource = ProbeRecordingSource(agent: .opencode, path: databaseRoot.path, estimate: nil)

        let results = AgentHistoryDiscoveryProbe.detect(
            sources: [databaseSource, fileSource],
            candidatePaths: { ["/checked/\($0.rawValue)"] }
        )

        XCTAssertEqual(results.map(\.agent), [.claude, .codex, .grok, .opencode])
        XCTAssertEqual(results[0], AgentHistoryDetectedSource(
            agent: .claude, rootPath: fileRoot.path, isFound: true, sessionCount: 3,
            checkedPaths: ["/checked/claude"], problem: nil
        ))
        XCTAssertEqual(results[3], AgentHistoryDetectedSource(
            agent: .opencode, rootPath: databaseRoot.path, isFound: true, sessionCount: nil,
            checkedPaths: ["/checked/opencode"], problem: nil
        ))

        // Only the stat-only estimate is consulted; nothing that could open a database runs.
        XCTAssertEqual(fileSource.recordedCalls, ["estimatedSessionCount"])
        XCTAssertEqual(databaseSource.recordedCalls, ["estimatedSessionCount"])
    }

    func test_probe_with_real_adapters_counts_files_and_leaves_databases_unopened() throws {
        let home = try makeDirectory("home")
        try touch(home.appendingPathComponent(".claude/projects/-Users-me-repo/11111111-1111-4111-8111-111111111111.jsonl"))
        try touch(home.appendingPathComponent(".claude/projects/-Users-me-repo/22222222-2222-4222-8222-222222222222.jsonl"))
        let openCodeDatabase = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try touch(openCodeDatabase)
        let before = try FileManager.default.contentsOfDirectory(atPath: openCodeDatabase.deletingLastPathComponent().path)
        let locator = AgentHistoryRootLocator(environment: [:], homeDirectory: home)

        let results = AgentHistoryDiscoveryProbe.detect(locator: locator)

        let claude = try XCTUnwrap(results.first { $0.agent == .claude })
        XCTAssertTrue(claude.isFound)
        XCTAssertEqual(claude.sessionCount, 2)
        let openCode = try XCTUnwrap(results.first { $0.agent == .opencode })
        XCTAssertTrue(openCode.isFound)
        XCTAssertNil(openCode.sessionCount)
        // Opening the database would leave -wal/-shm files or fail on the bogus content.
        let after = try FileManager.default.contentsOfDirectory(atPath: openCodeDatabase.deletingLastPathComponent().path)
        XCTAssertEqual(Set(after), Set(before))
    }

    func test_probe_reports_checked_paths_for_missing_agents() throws {
        let home = try makeDirectory("home")
        let locator = AgentHistoryRootLocator(environment: [:], homeDirectory: home)

        let results = AgentHistoryDiscoveryProbe.detect(locator: locator)

        XCTAssertEqual(results.map(\.agent), AgentHistoryAgent.allCases)
        for result in results {
            XCTAssertFalse(result.isFound, "\(result.agent)")
            XCTAssertNil(result.rootPath)
            XCTAssertNil(result.sessionCount)
            XCTAssertEqual(result.checkedPaths, locator.candidatePaths(for: result.agent))
            XCTAssertFalse(result.checkedPaths.isEmpty)
        }
        let canonicalHome = AgentHistoryPath.canonical(home.path)
        XCTAssertEqual(results.first { $0.agent == .claude }?.checkedPaths, [canonicalHome + "/.claude"])
        XCTAssertEqual(results.first { $0.agent == .opencode }?.checkedPaths, [canonicalHome + "/.local/share/opencode"])
    }

    func test_probe_marks_vanished_root_missing_without_counting() throws {
        let base = try makeDirectory()
        let gone = base.appendingPathComponent("gone").path
        let source = ProbeRecordingSource(agent: .grok, path: gone, estimate: 9)

        let results = AgentHistoryDiscoveryProbe.detect(sources: [source], candidatePaths: { _ in [] })

        let grok = try XCTUnwrap(results.first { $0.agent == .grok })
        XCTAssertFalse(grok.isFound)
        XCTAssertEqual(grok.problem, .rootMissing)
        XCTAssertNil(grok.sessionCount)
        XCTAssertTrue(source.recordedCalls.isEmpty)
    }
}
