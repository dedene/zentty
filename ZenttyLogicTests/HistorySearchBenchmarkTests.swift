import Foundation
import XCTest
@testable import Zentty

/// Search budgets of spec §10 against the synthetic corpus. The smoke test always runs on a 20k
/// message corpus with loose bounds; the 1M-message content benchmark and the strict metadata
/// benchmark only run with `TEST_RUNNER_ZENTTY_HISTORY_BENCH=1` (xcodebuild forwards it to
/// xctest as `ZENTTY_HISTORY_BENCH`). The scheme tests the Debug (`-Onone`) build, so Swift-side
/// grading runs slower than in a release build; the printed percentiles and slowest queries are
/// the useful output when a budget fails. The 1M corpus takes ~13 min to build and ~7 GB of temp
/// disk (removed in teardown).
final class HistorySearchBenchmarkTests: XCTestCase {
    private typealias Corpus = HistorySyntheticCorpus
    private typealias Fixture = HistorySearchFixture

    private static var isBenchmarkRun: Bool {
        ProcessInfo.processInfo.environment["ZENTTY_HISTORY_BENCH"] == "1"
    }

    private func requireBenchmarkRun() throws {
        guard Self.isBenchmarkRun else {
            throw XCTSkip("set TEST_RUNNER_ZENTTY_HISTORY_BENCH=1 to run the Agent History search benchmarks")
        }
    }

    // MARK: - Smoke (always)

    func test_small_corpus_smoke() throws {
        let corpus = Corpus(.small)
        XCTAssertEqual(corpus.vocabulary.count, 5_000)
        XCTAssertEqual(Set(corpus.vocabulary).count, corpus.vocabulary.count, "the vocabulary has no duplicates")
        XCTAssertEqual(corpus.repoRoots.count, 40)

        // Generation is a pure function of the seed.
        let plans = corpus.sessions()
        let again = Corpus(.small).sessions()
        XCTAssertEqual(plans.map(\.nativeID), again.map(\.nativeID))
        XCTAssertEqual(corpus.messages(for: plans[7]).map(\.text), Corpus(.small).messages(for: again[7]).map(\.text))
        XCTAssertEqual(plans.map(\.messageCount).reduce(0, +), 20_000)
        XCTAssertTrue(plans.allSatisfy { $0.messageCount >= 2 }, "every session has a prompt and a reply")

        let fixture = try Fixture(testCase: self)
        let stats = try corpus.populate(fixture)
        print(String(format: "Synthetic corpus (small): %d sessions, %d messages, %d artifacts, %.1f MB text, %.2f s",
                     stats.sessions, stats.messages, stats.artifacts, Double(stats.characters) / 1_048_576,
                     stats.populateSeconds))

        // Shape.
        let writer = try fixture.writer
        XCTAssertEqual(stats.messages, 20_000)
        XCTAssertEqual(try AgentHistoryFixtures.count(writer, "SELECT count(*) FROM messages"), 20_000)
        XCTAssertEqual(try fixture.store().visibleSessionCount(), 200)
        XCTAssertGreaterThan(stats.artifacts, 0)
        XCTAssertEqual(stats.agents, Set(AgentHistoryAgent.allCases))
        XCTAssertGreaterThan(stats.repos.count, 10)
        XCTAssertLessThanOrEqual(stats.repos.count, 40)
        XCTAssertGreaterThan(stats.longMessages, 50, "about 1 % of messages exceed 8 KB")
        XCTAssertLessThan(stats.longMessages, 400)
        XCTAssertEqual(Self.median(stats.userLengths), 200, accuracy: 60)
        XCTAssertEqual(Self.median(stats.agentLengths), 900, accuracy: 250)
        let spanDays = Double(stats.maxAtMs - stats.minAtMs) / Double(Fixture.dayMs)
        XCTAssertGreaterThan(spanDays, 600, "timestamps cover about two years")
        XCTAssertLessThan(stats.maxAtMs, Fixture.nowMs)
        XCTAssertFalse(stats.hexes.values.isEmpty)
        XCTAssertFalse(stats.paths.values.isEmpty)
        XCTAssertFalse(stats.codeTokens.values.isEmpty)
        XCTAssertFalse(stats.phrases.values.isEmpty)

        // Every query kind runs; hashes, paths and code tokens taken from the corpus are found;
        // a miss stays empty. Loose bounds: CI machines vary.
        let engine = try fixture.engine()
        let queries = corpus.mixedQueries(count: 42, stats: stats)
        let samples = try measureContent(queries, engine: engine, fixture: fixture) { query, response in
            if query.raw.hasPrefix("zq") {
                XCTAssertTrue(response.results.isEmpty, "miss \"\(query.raw)\" matched")
            }
            if stats.hexes.values.contains(where: { $0.hasPrefix(query.raw) })
                || stats.paths.values.contains(where: { $0.hasSuffix(query.raw) })
                || stats.codeTokens.values.contains(query.raw) {
                XCTAssertFalse(response.results.isEmpty, "corpus token \"\(query.raw)\" not found")
            }
            XCTAssertLessThanOrEqual(response.results.count, 30)
        }
        let percentiles = Self.percentiles(samples)
        print(String(format: "Content tier (20k messages): p50 %.1f ms, p95 %.1f ms, p99 %.1f ms",
                     percentiles.p50, percentiles.p95, percentiles.p99))
        print("  slowest: \(Self.slowest(queries, samples))")
        XCTAssertLessThan(percentiles.p95, 2_000)

        let merged = try engine.searchMerged(
            Fixture.query(corpus.vocabulary[40]), context: fixture.context(), limit: 20,
            cancellation: HistorySearchCancellation())
        XCTAssertFalse(merged.isEmpty)
        let metadata = engine.metadataIndex.search(
            Fixture.query(String(plans[0].title.prefix(4))), context: fixture.context())
        XCTAssertFalse(metadata.results.isEmpty)
    }

    // MARK: - Benchmarks (bench env only)

    func test_content_tier_p95_p99_1m_messages() throws {
        try requireBenchmarkRun()
        let corpus = Corpus(.benchmark)
        let fixture = try Fixture(testCase: self)
        let stats = try corpus.populate(fixture)
        let paths = fixture.index.paths
        let databaseBytes = [paths.databaseURL, paths.walURL].reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        print(String(format: "Synthetic corpus (benchmark): %d sessions, %d messages, %d artifacts, %.0f MB text, "
                     + "index %.0f MB, populated in %.0f s",
                     stats.sessions, stats.messages, stats.artifacts, Double(stats.characters) / 1_048_576,
                     Double(databaseBytes) / 1_048_576, stats.populateSeconds))
        XCTAssertEqual(stats.sessions, 10_000)
        XCTAssertEqual(stats.messages, 1_000_000)

        let engine = try fixture.engine()
        let queries = corpus.mixedQueries(count: 200, stats: stats)
        // Warm the page cache and the statement paths.
        _ = try measureContent(Array(queries.prefix(14)), engine: engine, fixture: fixture) { _, _ in }

        let samples = try measureContent(queries, engine: engine, fixture: fixture) { _, _ in }
        let percentiles = Self.percentiles(samples)
        print(String(format: "Content tier (1M messages, trigram): p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, max %.1f ms",
                     percentiles.p50, percentiles.p95, percentiles.p99, samples.max() ?? 0))
        print("  slowest: \(Self.slowest(queries, samples))")
        XCTAssertLessThan(percentiles.p95, 60, "spec §10: content tier p95 < 60 ms")
        XCTAssertLessThan(percentiles.p99, 150, "spec §10: content tier p99 < 150 ms")
    }

    func test_metadata_tier_10k_strict() throws {
        try requireBenchmarkRun()
        // Metadata only reads sessions; two turns each keeps population fast.
        var configuration = Corpus.Configuration.benchmark
        configuration.messageCount = 20_000
        let corpus = Corpus(configuration)
        let fixture = try Fixture(testCase: self)
        let stats = try corpus.populate(fixture)
        XCTAssertEqual(stats.sessions, 10_000)
        let index = try fixture.metadataIndex()

        // Typed keystroke by keystroke, in the global and a project scope.
        let typed = corpus.mixedQueries(count: 28, stats: stats).map(\.raw)
        let scope = Fixture.projectScope(corpus.repoRoots[3])
        _ = index.search(Fixture.query(typed[0]), context: fixture.context())

        var samples: [Double] = []
        for text in typed {
            for length in 1...text.count {
                let query = Fixture.query(String(text.prefix(length)))
                for context in [fixture.context(), fixture.context(scope)] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let response = index.search(query, context: context)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    XCTAssertLessThanOrEqual(response.results.count, HistoryMetadataIndex.defaultLimit)
                }
            }
        }
        let percentiles = Self.percentiles(samples)
        print(String(format: "Metadata tier (10k sessions): %d keystrokes, p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                     samples.count, percentiles.p50, percentiles.p95, samples.max() ?? 0))
        XCTAssertLessThan(percentiles.p95, 5, "spec §10: metadata tier < 5 ms per keystroke")
    }

    // MARK: - Helpers

    /// Runs each query through the content tier on the calling (test) thread, the way
    /// `searchContentAsync` runs it on the search queue, and returns each wall time in ms.
    private func measureContent(
        _ queries: [Corpus.Query],
        engine: HistorySearchEngine,
        fixture: Fixture,
        check: (Corpus.Query, HistoryContentResponse) -> Void
    ) throws -> [Double] {
        try queries.map { query in
            let context = query.scopeKey.map { fixture.context(Fixture.projectScope($0)) } ?? fixture.context()
            let start = DispatchTime.now().uptimeNanoseconds
            let response = try engine.searchContent(
                Fixture.query(query.raw), context: context, excludingSessionIDs: [],
                cancellation: HistorySearchCancellation())
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            check(query, response)
            return elapsed
        }
    }

    private static func slowest(_ queries: [Corpus.Query], _ samples: [Double]) -> String {
        zip(queries, samples).sorted { $0.1 > $1.1 }.prefix(5)
            .map { String(format: "%@%@ %.1f ms", $0.0.raw, $0.0.scopeKey == nil ? "" : " (scoped)", $0.1) }
            .joined(separator: " | ")
    }

    private static func median(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : Double(sorted[sorted.count / 2])
    }

    private static func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double, p99: Double) {
        let sorted = samples.sorted()
        func at(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(Int((Double(sorted.count) * fraction).rounded(.up)) - 1, sorted.count - 1)]
        }
        return (at(0.5), at(0.95), at(0.99))
    }
}
