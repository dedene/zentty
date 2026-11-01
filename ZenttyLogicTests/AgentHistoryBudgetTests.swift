import Darwin
import Foundation
import XCTest
@testable import Zentty

/// Release-gate budgets of spec §10 for backfill and launch, against a synthetic Claude corpus
/// on disk (`AgentHistoryBudgetCorpus`) and the real controller, indexer, adapter and storage.
/// Every test only runs with `TEST_RUNNER_ZENTTY_HISTORY_BENCH=1` (xcodebuild forwards it to
/// xctest as `ZENTTY_HISTORY_BENCH`) and skips otherwise. The ~2 GB corpus is written to a temp
/// directory and removed in teardown; `TEST_RUNNER_ZENTTY_HISTORY_BENCH_CORPUS_MB` resizes it.
/// The scheme tests the Debug (`-Onone`) build, so ingest runs slower than in a release build;
/// the printed numbers are the useful output when a budget fails.
@MainActor
final class AgentHistoryBudgetTests: XCTestCase {
    private typealias Corpus = AgentHistoryBudgetCorpus

    private static let peakMemoryBudgetBytes: UInt64 = 200 << 20
    private static let firstSessionsBudgetSeconds = 10.0
    private static let backfillTimeout: TimeInterval = 3_600

    private func requireBenchmarkRun() throws {
        guard ProcessInfo.processInfo.environment["ZENTTY_HISTORY_BENCH"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_ZENTTY_HISTORY_BENCH=1 to run the Agent History budget harnesses")
        }
    }

    // MARK: - Budgets

    /// Spec §10: peak memory added during backfill < 200 MB. `phys_footprint` is sampled every
    /// 10 ms from consent until the indexer reports `watching`; the kernel's lifetime maximum
    /// catches a spike between samples.
    func test_backfill_peak_memory_under_200mb_synthetic() throws {
        try requireBenchmarkRun()
        let fixture = try makeFixture(Corpus(.benchmark))
        let baseline = MemoryFootprint.current()
        let sampler = MemoryFootprint.Sampler()

        let started = DispatchTime.now().uptimeNanoseconds
        fixture.controller.enable(agents: [.claude]) { _ in }
        waitForStatus(fixture.controller, "backfill finished", timeout: Self.backfillTimeout) { $0.state == .watching }
        let backfillSeconds = Self.seconds(since: started)
        let peak = sampler.stop()

        let after = MemoryFootprint.current()
        // The lifetime maximum only says something about this backfill when it rose during it.
        let peakFootprint = max(peak, after.lifetimePeak > baseline.lifetimePeak ? after.lifetimePeak : 0)
        let added = peakFootprint > baseline.footprint ? peakFootprint - baseline.footprint : 0
        let indexed = fixture.controller.metadataSnapshot.sessions.count
        print(String(format: "Backfill (%.0f MB, %d sessions, %d text messages): %.1f s, %.1f MB/s; "
                     + "footprint baseline %.0f MB, sampled peak %.0f MB (%d samples), lifetime peak %.0f MB, "
                     + "added %.0f MB; index %.0f MB",
                     Self.megabytes(fixture.summary.totalBytes), fixture.summary.sessions.count,
                     fixture.summary.textMessages, backfillSeconds,
                     Self.megabytes(fixture.summary.totalBytes) / max(backfillSeconds, 0.001),
                     Self.megabytes(baseline.footprint), Self.megabytes(peak), sampler.sampleCount,
                     Self.megabytes(after.lifetimePeak), Self.megabytes(added),
                     Self.megabytes(fixture.controller.status.indexSizeBytes)))
        // Index size is reported, not budgeted (§10): file split and ratio to the stored text.
        let textBytes = try fixture.controller.storage?.readers.withReader { db in
            try db.scalarInt64("SELECT sum(length(CAST(text AS BLOB))) FROM messages")
        } ?? 0
        let fileBytes = { (url: URL) in
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let databaseBytes = fileBytes(fixture.paths.databaseURL)
        print(String(format: "Index: database %.0f MB, WAL %.0f MB; message text %.0f MB (database %.1fx text)",
                     Self.megabytes(databaseBytes), Self.megabytes(fileBytes(fixture.paths.walURL)),
                     Self.megabytes(textBytes), Double(databaseBytes) / Double(max(textBytes, 1))))

        XCTAssertEqual(indexed, fixture.summary.sessions.count, "every session is indexed")
        XCTAssertLessThan(added, Self.peakMemoryBudgetBytes, "spec §10: peak memory added during backfill < 200 MB")
    }

    /// Spec §10: the first 50 newest sessions are searchable < 10 s after consent. Timed from
    /// `enable` (consent) to the first snapshot with 50 sessions; those must be the 50 newest
    /// by mtime, and their messages must already be in the index. The rank-3 session is 120 MB.
    func test_first_50_sessions_published_under_10s_synthetic() throws {
        try requireBenchmarkRun()
        let fixture = try makeFixture(Corpus(.benchmark))
        let threshold = AgentHistoryIndexer.snapshotPublishThreshold
        let reached = expectation(description: "first \(threshold) sessions published")
        var elapsed: Double?
        var published: Set<String> = []
        let started = DispatchTime.now().uptimeNanoseconds
        let observer = fixture.controller.addSnapshotObserver { snapshot in
            guard elapsed == nil, snapshot.sessions.count >= threshold else {
                return
            }
            elapsed = Self.seconds(since: started)
            published = Set(snapshot.sessions.map(\.nativeID))
            reached.fulfill()
        }
        fixture.controller.enable(agents: [.claude]) { _ in }
        wait(for: [reached], timeout: Self.backfillTimeout)
        fixture.controller.removeObserver(observer)

        let newest = fixture.summary.sessions.prefix(threshold)
        let newestIDs = Set(newest.map(\.nativeID))
        let searchable = try fixture.controller.storage?.readers.withReader { db in
            try db.query(
                "SELECT DISTINCT s.native_id FROM messages m JOIN sessions s ON s.id = m.session_id"
            ) { $0.string(0) }
        } ?? []
        print(String(format: "First %d sessions published %.2f s after consent (newest %d hold %.0f MB)",
                     threshold, elapsed ?? -1, threshold,
                     Self.megabytes(newest.map(\.bytes).reduce(0, +))))

        XCTAssertTrue(newestIDs.isSubset(of: published), "the first snapshot holds the 50 newest sessions")
        XCTAssertTrue(newestIDs.isSubset(of: Set(searchable)), "their messages are in the index")
        XCTAssertLessThan(elapsed ?? .infinity, Self.firstSessionsBudgetSeconds,
                          "spec §10: first 50 newest sessions searchable < 10 s after consent")
    }

    /// Spec §10: 0 ms added main-thread work at launch. `configure` and
    /// `scheduleStartAfterLaunch` only store references and arm a timer (no disk, no sources);
    /// after the launch delay every source call (discovery, stat, ingest) and `makeSources` run
    /// off main, and main never stalls while the indexer starts and backfills.
    func test_main_thread_untouched_at_launch() throws {
        try requireBenchmarkRun()
        let probe = MainThreadProbe()
        let fixture = try makeFixture(Corpus(.small), launchDelay: 0.3, probe: probe)
        try AgentHistoryStateStore(fileURL: fixture.paths.stateURL).update { state in
            state.enabled = true
            state.consentedAt = Date()
            AgentHistoryAgent.allCases.forEach { state.setSource($0, enabled: $0 == .claude) }
        }
        let configStore = AppConfigStore(fileURL: fixture.directoryURL.appendingPathComponent("config.toml"))
        let stalls = MainThreadStallMonitor()

        let launchStarted = DispatchTime.now().uptimeNanoseconds
        fixture.controller.configure(configStore: configStore, paths: fixture.paths)
        let decided = expectation(description: "launch decision")
        var started = false
        fixture.controller.scheduleStartAfterLaunch { result in
            started = result
            decided.fulfill()
        }
        let launchPathMs = Self.seconds(since: launchStarted) * 1_000

        XCTAssertEqual(probe.calls, [], "nothing touches a source on the launch path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.databaseURL.path),
                       "the index is not opened on the launch path")
        XCTAssertNil(fixture.controller.indexer, "no indexer before the launch delay")

        wait(for: [decided], timeout: 10)
        XCTAssertTrue(started)
        waitForStatus(fixture.controller, "backfill finished", timeout: 600) { $0.state == .watching }
        let maxStallMs = stalls.stop()

        let calls = probe.calls
        let onMain = calls.filter(\.onMain).map(\.name)
        print(String(format: "Launch path %.3f ms on main; %d source calls, %d on main; max main stall %.1f ms "
                     + "while the indexer started and backfilled %d sessions",
                     launchPathMs, calls.count, onMain.count, maxStallMs,
                     fixture.controller.metadataSnapshot.sessions.count))

        XCTAssertTrue(calls.contains { $0.name == "ingest" }, "the backfill ran")
        XCTAssertEqual(onMain, [], "no indexer work runs on main")
        XCTAssertLessThan(launchPathMs, 5, "configure + schedule only store references and arm a timer")
        XCTAssertLessThan(maxStallMs, 50, "main stays responsive while the indexer starts and backfills")
    }

    // MARK: - Fixture

    private struct Fixture {
        let directoryURL: URL
        let paths: AgentHistoryPaths
        let controller: AgentHistoryController
        let summary: AgentHistoryBudgetCorpus.Summary
    }

    /// Generates `corpus` under a fresh temp directory and builds a controller over it with the
    /// real indexer, fake system conditions (no low-power or thermal pauses) and temp paths.
    /// Without `probe` the controller is also configured (state not consented); with one the
    /// test configures it itself, to time the launch path.
    private func makeFixture(
        _ corpus: AgentHistoryBudgetCorpus,
        launchDelay: TimeInterval = 0,
        probe: MainThreadProbe? = nil
    ) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        let claudeRoot = base.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        let summary = try corpus.generate(into: claudeRoot)
        print(String(format: "Budget corpus: %d sessions, %.0f MB, %d text messages, %d lines >= 1 MB, written in %.1f s",
                     summary.sessions.count, Self.megabytes(summary.totalBytes), summary.textMessages,
                     summary.longLines, summary.seconds))

        let paths = AgentHistoryPaths(directoryURL: base.appendingPathComponent("AgentHistory", isDirectory: true))
        let claude = ClaudeHistorySource(root: AgentHistorySourceRoot(
            agent: .claude, path: AgentHistoryPath.canonical(claudeRoot.path), isDefault: false
        ))
        let sources: [any AgentHistorySource] = [probe.map { ThreadRecordingSource(claude, probe: $0) } ?? claude]
        let makeSources: @Sendable () -> [any AgentHistorySource] = {
            probe?.record("makeSources")
            return sources
        }
        let controller = AgentHistoryController(
            launchDelay: launchDelay,
            makeSources: makeSources,
            makeIndexer: { storage, stateStore, configuration, callbacks in
                AgentHistoryIndexer(
                    storage: storage,
                    stateStore: stateStore,
                    makeSources: makeSources,
                    configuration: configuration,
                    systemConditions: FakeSystemConditions(),
                    onStatusChange: callbacks.onStatusChange,
                    onSnapshotChange: callbacks.onSnapshotChange
                )
            }
        )
        // Registered after the directory removal, so it runs first: the indexer has closed its
        // writer before its directory goes.
        addTeardownBlock { @MainActor in
            let indexer = controller.indexer
            controller.stop()
            indexer?.stopAndWait()
        }
        if probe == nil {
            let configStore = AppConfigStore(fileURL: base.appendingPathComponent("config.toml"))
            controller.configure(configStore: configStore, paths: paths)
            let decided = expectation(description: "launch decision")
            controller.scheduleStartAfterLaunch { _ in decided.fulfill() }
            wait(for: [decided], timeout: 10)
            waitForStatus(controller, "state loaded", timeout: 10) { $0.isStateLoaded }
        }
        return Fixture(directoryURL: base, paths: paths, controller: controller, summary: summary)
    }

    private func waitForStatus(
        _ controller: AgentHistoryController,
        _ description: String,
        timeout: TimeInterval,
        where predicate: @escaping (AgentHistoryStatus) -> Bool
    ) {
        if predicate(controller.status) {
            return
        }
        let reached = expectation(description: description)
        var fulfilled = false
        let id = controller.addStatusObserver { status in
            if !fulfilled, predicate(status) {
                fulfilled = true
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: timeout)
        controller.removeObserver(id)
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func megabytes<T: BinaryInteger>(_ bytes: T) -> Double {
        Double(bytes) / 1_048_576
    }
}

// MARK: - Probes

/// The process's `phys_footprint` (what Activity Monitor calls Memory) via `proc_pid_rusage`.
private enum MemoryFootprint {
    static func current() -> (footprint: UInt64, lifetimePeak: UInt64) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            return (0, 0)
        }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }

    /// Samples the footprint every 10 ms on its own queue and keeps the maximum.
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "be.zenjoy.zentty.tests.footprint", qos: .userInitiated)
        )
        private var peak: UInt64 = 0
        private var samples = 0

        init() {
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                self?.sample()
            }
            timer.resume()
        }

        var sampleCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }

        /// Stops sampling and returns the peak.
        func stop() -> UInt64 {
            timer.cancel()
            sample()
            lock.lock()
            defer { lock.unlock() }
            return peak
        }

        private func sample() {
            let footprint = MemoryFootprint.current().footprint
            lock.lock()
            peak = max(peak, footprint)
            samples += 1
            lock.unlock()
        }
    }
}

/// Pings main every 5 ms from a background queue and records the longest wait for a ping to
/// run: how long main was busy with something else.
private final class MainThreadStallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "be.zenjoy.zentty.tests.main-stall", qos: .userInitiated)
    )
    private var maxStallNs: UInt64 = 0
    private var isPinging = false

    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.ping()
        }
        timer.resume()
    }

    /// Stops pinging and returns the longest stall in ms.
    func stop() -> Double {
        timer.cancel()
        lock.lock()
        defer { lock.unlock() }
        return Double(maxStallNs) / 1_000_000
    }

    private func ping() {
        lock.lock()
        guard !isPinging else {
            lock.unlock()
            return
        }
        isPinging = true
        lock.unlock()
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [self] in
            let stall = DispatchTime.now().uptimeNanoseconds - sent
            lock.lock()
            maxStallNs = max(maxStallNs, stall)
            isPinging = false
            lock.unlock()
        }
    }
}

/// Which thread each source call ran on.
private final class MainThreadProbe: @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let onMain: Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ name: String) {
        let call = Call(name: name, onMain: Thread.isMainThread)
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }
}

/// Forwards every source call to the real adapter and records the thread it ran on.
private final class ThreadRecordingSource: AgentHistorySource, @unchecked Sendable {
    private let inner: any AgentHistorySource
    private let probe: MainThreadProbe

    init(_ inner: any AgentHistorySource, probe: MainThreadProbe) {
        self.inner = inner
        self.probe = probe
    }

    var agent: AgentHistoryAgent { inner.agent }
    var root: AgentHistorySourceRoot { inner.root }
    var adapterVersion: Int { inner.adapterVersion }
    var watchPaths: [String] { inner.watchPaths }
    var holdsBackSessionsWithoutFolder: Bool { inner.holdsBackSessionsWithoutFolder }

    func discoverUnits() throws -> [AgentHistoryUnit] {
        probe.record("discoverUnits")
        return try inner.discoverUnits()
    }

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        probe.record("eventTarget")
        return inner.eventTarget(forCanonicalPath: path)
    }

    func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit {
        probe.record("refreshUnit")
        return inner.refreshUnit(unit)
    }

    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        probe.record("classifyChange")
        return inner.classifyChange(unit: unit, cursor: cursor)
    }

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        probe.record("ingest")
        return try inner.ingest(unit: unit, cursor: cursor, mode: mode, context: context)
    }

    func existingNativeIDs() throws -> Set<String>? {
        probe.record("existingNativeIDs")
        return try inner.existingNativeIDs()
    }

    func estimatedSessionCount() -> Int? {
        probe.record("estimatedSessionCount")
        return inner.estimatedSessionCount()
    }
}
