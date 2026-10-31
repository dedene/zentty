import AppKit
import Foundation
import SQLite3
import XCTest
@testable import Zentty

/// Backfill pauses (low power, thermal pressure), the full-disk pause with its retry, recovery
/// from corruption found mid-run, and the production condition monitor.
final class AgentHistoryIndexerConditionsTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(_ value: Bool) {
            self.value = value
        }

        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }

        func set(_ next: Bool) {
            lock.lock()
            value = next
            lock.unlock()
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private final class ReadingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var readings = LiveAgentHistorySystemConditions.Readings(isLowPowerModeEnabled: false, thermalState: .nominal)

        var value: LiveAgentHistorySystemConditions.Readings { lock.lock(); defer { lock.unlock() }; return readings }

        func set(lowPower: Bool, thermal: ProcessInfo.ThermalState) {
            lock.lock()
            readings = .init(isLowPowerModeEnabled: lowPower, thermalState: thermal)
            lock.unlock()
        }
    }

    private static func databaseError(_ kind: AgentHistoryDatabaseError.Kind, _ code: Int32) -> AgentHistoryDatabaseError {
        AgentHistoryDatabaseError(kind: kind, code: code, extendedCode: code, message: "injected")
    }

    private func fileEvent(_ path: String) -> FileEvent {
        FileEvent(path: FileEventStream.canonicalPath(path), flags: [.itemModified, .itemIsFile], id: 1)
    }

    private func isPaused(_ state: AgentHistoryIndexerState, _ reason: AgentHistoryPauseReason) -> Bool {
        if case .paused(reason, _) = state {
            return true
        }
        return false
    }

    // MARK: - Low power and thermal pressure

    func test_low_power_pauses_backfill_but_processes_live_events() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let conditions = FakeSystemConditions()
        let first = FakeHistorySession(nativeID: "db-1", title: "First", cwd: "/work/project", messages: ["q", "a"])
        harness.source.setUnits([.single("a"), FakeHistoryUnit(key: "db", kind: .database, sessions: [first])])
        let indexer = harness.makeIndexer(conditions: conditions)
        indexer.start()
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 2)

        conditions.setPauseReason(.lowPower)
        let second = FakeHistorySession(nativeID: "db-2", title: "Second", cwd: "/work/project", messages: ["q", "a"])
        harness.source.setUnits([
            .single("live", mtimeNs: 5),
            .single("backfill", mtimeNs: 3),
            FakeHistoryUnit(key: "db", kind: .database, mtimeNs: 2, sessions: [first, second]),
        ])
        harness.source.setEventTarget(.unit("live"), forPath: harness.rootURL.path + "/live.jsonl")
        harness.source.setEventTarget(.database("db"), forPath: harness.rootURL.path + "/state.db")
        // The event for the unknown unit discovers the source: `backfill` lands in the paused lane.
        indexer.handleFileEventsForTesting([
            fileEvent(harness.rootURL.path + "/live.jsonl"),
            fileEvent(harness.rootURL.path + "/state.db"),
        ])
        indexer.drainSynchronouslyForTesting()

        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE native_id = 'live'"), 1,
                       "live events keep running while paused")
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE native_id = 'db-2'"), 1,
                       "database polls keep running while paused")
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE native_id = 'backfill'"), 0,
                       "backfill waits")
        guard case let .paused(.lowPower, progress) = indexer.currentStatus.state else {
            return XCTFail("expected a low-power pause, got \(indexer.currentStatus.state)")
        }
        XCTAssertEqual(progress, AgentHistoryBackfillProgress(indexedSessions: 4, totalSessions: 5))

        conditions.setPauseReason(nil)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions WHERE native_id = 'backfill'"), 1)
        XCTAssertEqual(indexer.currentStatus.state, .watching)
    }

    func test_thermal_serious_pauses_and_nominal_resumes() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let conditions = FakeSystemConditions()
        conditions.setPauseReason(.thermal)
        harness.source.setUnits([.single("a", mtimeNs: 2), .single("b", mtimeNs: 1)])
        let indexer = harness.makeIndexer(conditions: conditions)
        let paused = harness.recorder.expectStatus(self, "paused while hot") { status in
            status.state == .paused(.thermal, AgentHistoryBackfillProgress(indexedSessions: 0, totalSessions: 2))
        }

        indexer.start()
        wait(for: [paused], timeout: 10)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 0)
        XCTAssertTrue(harness.source.ingestedKeys.isEmpty, "nothing is read while paused")

        // Cooling down reports through the change handler; no drain drives the resume.
        let resumed = harness.recorder.expectStatus(self, "resumed when nominal") { status in
            status.state == .watching && status.indexedSessions == 2
        }
        conditions.setPauseReason(nil)
        wait(for: [resumed], timeout: 10)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 2)
    }

    // MARK: - Full disk

    func test_disk_full_pauses_and_retries() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        let conditions = FakeSystemConditions()
        harness.source.setUnits([
            .single("a", messages: ["q1", "a1"], mtimeNs: 3),
            .single("b", messages: ["q2", "a2"], mtimeNs: 2),
            .single("c", messages: ["q3", "a3"], mtimeNs: 1),
        ])
        harness.source.setEventTarget(.unit("c"), forPath: harness.rootURL.path + "/c.jsonl")
        let indexer = harness.makeIndexer(conditions: conditions)
        XCTAssertEqual(indexer.schedule.diskFullRetry, 60, "production retry cadence")
        indexer.schedule.diskFullRetry = 0.05
        let diskIsFull = Flag(true)
        let full = Self.databaseError(.full, SQLITE_FULL)
        indexer.beforeCursorSaveForTesting = { _ in
            if diskIsFull.isSet {
                throw full
            }
        }
        conditions.setAvailableBytes(100 << 20)

        indexer.start()
        indexer.drainSynchronouslyForTesting()

        XCTAssertTrue(isPaused(indexer.currentStatus.state, .diskFull), "got \(indexer.currentStatus.state)")
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 0, "the in-flight transaction rolled back")
        XCTAssertEqual(try harness.count("SELECT count(*) FROM cursors"), 0)
        XCTAssertEqual(harness.source.ingestedKeys, ["a"], "all work stops after the failed batch")

        // Live events wait too: nothing may write.
        indexer.handleFileEventsForTesting([fileEvent(harness.rootURL.path + "/c.jsonl")])
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(harness.source.ingestedKeys, ["a"])

        // Below the resume threshold the retry keeps waiting.
        wait(for: [conditions.expectCapacityChecks(self, reaching: 2)], timeout: 5)
        indexer.drainSynchronouslyForTesting()
        XCTAssertEqual(harness.source.ingestedKeys, ["a"])
        XCTAssertTrue(isPaused(indexer.currentStatus.state, .diskFull))

        let resumed = harness.recorder.expectStatus(self, "resumed after space was freed") { status in
            status.state == .watching && status.indexedSessions == 3
        }
        diskIsFull.set(false)
        conditions.setAvailableBytes(1 << 30)
        wait(for: [resumed], timeout: 10)

        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 3)
        XCTAssertEqual(try harness.messageTexts().sorted(), ["a1", "a2", "a3", "q1", "q2", "q3"],
                       "the failed batch is retried once, without duplicates")
    }

    // MARK: - Corruption

    func test_corruption_mid_run_recovers() throws {
        let harness = AgentHistoryIndexerHarness(testCase: self)
        harness.source.setUnits([
            .single("a", messages: ["q1", "a1"], mtimeNs: 2),
            .single("b", messages: ["q2", "a2"], mtimeNs: 1),
        ])
        let indexer = harness.makeIndexer()
        let saves = CallCounter()
        let corrupt = Self.databaseError(.corrupt, SQLITE_CORRUPT)
        indexer.beforeCursorSaveForTesting = { _ in
            // `a` commits; `b`'s transaction finds the index corrupt.
            if saves.next() == 2 {
                throw corrupt
            }
        }

        indexer.start()
        indexer.drainSynchronouslyForTesting()
        // The recovery runs on its own queue turn; this drain follows it.
        indexer.drainSynchronouslyForTesting()

        let names = try FileManager.default.contentsOfDirectory(atPath: harness.index.paths.directoryURL.path)
        XCTAssertEqual(names.filter(AgentHistoryPaths.isCorruptCopyName).count, 1, "the corrupt index was moved aside")
        XCTAssertTrue(indexer.isWriterOpenForTesting, "a fresh index was opened")
        XCTAssertEqual(indexer.currentStatus.state, .watching)
        XCTAssertEqual(try harness.count("SELECT count(*) FROM sessions"), 2, "a full reconcile re-read every unit")
        XCTAssertEqual(try harness.messageTexts().sorted(), ["a1", "a2", "q1", "q2"])
        XCTAssertEqual(Set(indexer.currentSnapshot.sessions.map(\.nativeID)), ["a", "b"])
        XCTAssertTrue(indexer.currentStatus.isBackfillComplete)
    }

    // MARK: - Production conditions

    func test_live_conditions_map_low_power_and_thermal_state() {
        let readings = ReadingsBox()
        let conditions = LiveAgentHistorySystemConditions(
            notificationCenter: NotificationCenter(),
            wakeNotificationCenter: NotificationCenter(),
            readings: { readings.value }
        )
        XCTAssertNil(conditions.pauseReason)
        readings.set(lowPower: false, thermal: .fair)
        XCTAssertNil(conditions.pauseReason)
        readings.set(lowPower: false, thermal: .serious)
        XCTAssertEqual(conditions.pauseReason, .thermal)
        readings.set(lowPower: false, thermal: .critical)
        XCTAssertEqual(conditions.pauseReason, .thermal)
        readings.set(lowPower: true, thermal: .nominal)
        XCTAssertEqual(conditions.pauseReason, .lowPower)
    }

    func test_live_conditions_report_changes_and_wake_until_stopped() {
        let center = NotificationCenter()
        let wakeCenter = NotificationCenter()
        let conditions = LiveAgentHistorySystemConditions(
            notificationCenter: center,
            wakeNotificationCenter: wakeCenter,
            readings: { .init(isLowPowerModeEnabled: false, thermalState: .nominal) }
        )
        let changed = expectation(description: "power and thermal changes reported")
        changed.expectedFulfillmentCount = 2
        let woke = expectation(description: "wake reported")
        conditions.startObserving { changed.fulfill() }
        conditions.startObservingWake { woke.fulfill() }

        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        wait(for: [changed, woke], timeout: 2)

        let silent = expectation(description: "nothing reported after stop")
        silent.isInverted = true
        conditions.startObserving { silent.fulfill() }
        conditions.startObservingWake { silent.fulfill() }
        conditions.stopObserving()
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        wait(for: [silent], timeout: 0.2)
    }

    func test_live_conditions_measure_free_space_of_nearest_existing_folder() throws {
        let conditions = LiveAgentHistorySystemConditions(
            notificationCenter: NotificationCenter(),
            wakeNotificationCenter: NotificationCenter()
        )
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)/AgentHistory", isDirectory: true)
        let available = try XCTUnwrap(conditions.availableCapacity(forVolumeAt: missing))
        XCTAssertGreaterThan(available, 0)
    }
}
