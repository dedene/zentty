import Foundation
import XCTest
@testable import Zentty

/// Ranking quality (spec §11.3). The synthetic golden set guards the ranking rules in CI; the
/// local golden set measures real-world quality against Peter's own index and never runs in CI.
final class HistoryRankingGoldenTests: XCTestCase {
    private typealias Golden = HistoryRankingGoldenFixture

    private static let resultLimit = 10

    // MARK: - Synthetic set

    func test_golden_top1_all_cases() throws {
        for tokenizer in [AgentHistoryTokenizer.trigram, .unicode61] {
            let ranks = try syntheticRanks(tokenizer: tokenizer)
            let failures = ranks.compactMap { entry -> String? in
                guard entry.top.first != entry.goldenCase.expectedNativeID else { return nil }
                return "[\(tokenizer.rawValue)] \(entry.goldenCase.name): query \"\(entry.goldenCase.query)\" "
                    + "expected \(entry.goldenCase.expectedNativeID), got \(entry.top.prefix(3))"
            }
            XCTAssertTrue(failures.isEmpty, "top-1 misses:\n" + failures.joined(separator: "\n"))
        }
    }

    func test_golden_mrr_is_1() throws {
        let ranks = try syntheticRanks(tokenizer: .trigram)
        XCTAssertGreaterThanOrEqual(ranks.count, 20, "the golden set keeps at least 20 cases")
        let mrr = Self.meanReciprocalRank(ranks.map(\.rank))
        XCTAssertEqual(mrr, 1, accuracy: 1e-12, "ranks: \(ranks.map { ($0.goldenCase.name, $0.rank) })")
    }

    private struct SyntheticRank {
        let goldenCase: Golden.Case
        let top: [String]
        let rank: Int?
    }

    private func syntheticRanks(tokenizer: AgentHistoryTokenizer) throws -> [SyntheticRank] {
        let fixture = try HistorySearchFixture(testCase: self, tokenizer: tokenizer)
        try Golden.populate(fixture)
        let engine = try fixture.engine()
        return try Golden.cases.map { goldenCase in
            let results = try engine.searchMerged(
                HistorySearchFixture.query(goldenCase.query),
                context: Golden.context(for: goldenCase, fixture: fixture),
                limit: Self.resultLimit,
                cancellation: HistorySearchCancellation())
            let top = results.map(\.session.nativeID)
            return SyntheticRank(
                goldenCase: goldenCase, top: top,
                rank: top.firstIndex(of: goldenCase.expectedNativeID).map { $0 + 1 })
        }
    }

    // MARK: - Local set

    /// One `[{query, agent, sessionId}]` entry of the local golden set.
    private struct LocalCase: Decodable {
        let query: String
        let agent: String
        let sessionId: String
    }

    /// Runs Peter's local golden set against read-only connections to a real index.
    /// Configure both with the `TEST_RUNNER_` prefix so xcodebuild forwards them:
    /// `TEST_RUNNER_ZENTTY_HISTORY_GOLDEN_SET=/path/golden.json` and
    /// `TEST_RUNNER_ZENTTY_HISTORY_INDEX=/path/AgentHistory` (folder or `index.sqlite`).
    /// The set file stays local and untracked.
    func test_local_golden_set_if_configured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let setPath = environment["ZENTTY_HISTORY_GOLDEN_SET"], !setPath.isEmpty,
              let indexPath = environment["ZENTTY_HISTORY_INDEX"], !indexPath.isEmpty
        else {
            throw XCTSkip("set ZENTTY_HISTORY_GOLDEN_SET and ZENTTY_HISTORY_INDEX to run the local golden set")
        }

        let cases = try JSONDecoder().decode([LocalCase].self, from: Data(contentsOf: URL(fileURLWithPath: setPath)))
        XCTAssertFalse(cases.isEmpty, "the local golden set is empty")
        let engine = try Self.readOnlyEngine(indexURL: Self.databaseURL(forIndexPath: indexPath))
        let readers = engine.readers
        addTeardownBlock { readers.closeAll() }

        var ranks: [Int?] = []
        var misses: [String] = []
        for localCase in cases {
            guard let agent = AgentHistoryAgent(rawValue: localCase.agent) else {
                XCTFail("unknown agent \(localCase.agent) for query \"\(localCase.query)\"")
                continue
            }
            let results = try engine.searchMerged(
                HistoryQueryParser.parse(localCase.query),
                context: HistorySearchContext(scope: .all),
                limit: Self.resultLimit,
                cancellation: HistorySearchCancellation())
            let rank = results.firstIndex {
                $0.session.agent == agent && $0.session.nativeID == localCase.sessionId
            }.map { $0 + 1 }
            ranks.append(rank)
            if rank != 1 {
                misses.append("\"\(localCase.query)\" → rank \(rank.map(String.init) ?? "miss")")
            }
        }

        let total = Double(max(ranks.count, 1))
        let top1 = Double(ranks.filter { $0 == 1 }.count) / total
        let top3 = Double(ranks.filter { ($0 ?? .max) <= 3 }.count) / total
        let mrr = Self.meanReciprocalRank(ranks)
        print(String(format: "Agent History local golden set: %d cases, top-1 %.3f, top-3 %.3f, MRR %.3f",
                     ranks.count, top1, top3, mrr))
        for miss in misses { print("  not top-1: \(miss)") }
        XCTAssertGreaterThanOrEqual(top3, 0.9, "ship gate: top-3 ≥ 90%")
    }

    private static func databaseURL(forIndexPath path: String) -> URL {
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url.appendingPathComponent(AgentHistoryPaths.databaseFileName)
        }
        return url
    }

    /// A search engine over `.readOnly` reader connections (`query_only`); no writer is opened,
    /// so the index is never migrated, checkpointed or changed.
    private static func readOnlyEngine(indexURL: URL) throws -> HistorySearchEngine {
        let readers = AgentHistoryReaderPool(
            databaseURL: indexURL, readerCount: 1, busyTimeoutMilliseconds: 2_000,
            availabilityBox: AgentHistoryAvailabilityBox())
        let (summaries, tokenizer) = try readers.withReader { db in
            (try AgentHistoryStore(database: db, now: Date.init).allVisibleSessionSummaries(),
             try AgentHistorySchema.storedTokenizer(db) ?? .none)
        }
        let snapshot = AgentHistoryMetadataSnapshot(generation: 1, sessions: summaries, isComplete: true)
        let exclusions = AgentHistoryExclusionMatcher(folders: [])
        return HistorySearchEngine(
            readers: readers,
            metadataIndex: HistoryMetadataIndex(snapshot: { snapshot }, exclusions: { exclusions }),
            tokenizer: { tokenizer },
            exclusions: { exclusions })
    }

    private static func meanReciprocalRank(_ ranks: [Int?]) -> Double {
        guard !ranks.isEmpty else { return 0 }
        return ranks.reduce(0) { $0 + ($1.map { 1 / Double($0) } ?? 0) } / Double(ranks.count)
    }
}
