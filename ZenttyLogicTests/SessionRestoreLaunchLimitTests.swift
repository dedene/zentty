import XCTest
@testable import Zentty

/// A snapshot that crashes the app on every launch used to be retried forever.
/// These drive the store the way launches do: `beginLaunch` with no save after
/// it is a launch that died while reopening the workspace.
final class SessionRestoreLaunchLimitTests: XCTestCase {
    private var directoryURL: URL!
    private var store: SessionRestoreStore!

    private var snapshotURL: URL { directoryURL.appendingPathComponent("restore-snapshot.json") }
    private var lifecycleURL: URL { directoryURL.appendingPathComponent("restore-lifecycle.json") }
    private var firstSetAsideURL: URL { directoryURL.appendingPathComponent("restore-snapshot.set-aside-1.json") }
    private var secondSetAsideURL: URL { directoryURL.appendingPathComponent("restore-snapshot.set-aside-2.json") }

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.SessionRestoreLimit.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        store = SessionRestoreStore(stateDirectoryURL: directoryURL)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        store = nil
        directoryURL = nil
    }

    // MARK: - The limit

    func test_two_incomplete_launches_then_the_third_sets_the_snapshot_aside() throws {
        try saveSnapshot()
        let snapshotBytes = try Data(contentsOf: snapshotURL)

        XCTAssertTrue(try launch().isRestore)
        XCTAssertTrue(try launch().isRestore)

        XCTAssertEqual(try launch(), .setAside(firstSetAsideURL))

        XCTAssertFalse(exists(snapshotURL))
        XCTAssertEqual(try Data(contentsOf: firstSetAsideURL), snapshotBytes)
    }

    func test_the_launch_after_setting_aside_starts_fresh() throws {
        try saveSnapshot()
        _ = try launch()
        _ = try launch()
        _ = try launch()

        XCTAssertEqual(try launch(), .startFresh)
        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
    }

    func test_the_attempt_is_on_disk_before_the_snapshot_is_read() throws {
        try Data("not valid json".utf8).write(to: snapshotURL, options: .atomic)

        XCTAssertThrowsError(try launch()) { XCTAssertTrue($0 is DecodingError) }

        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    func test_a_snapshot_that_cannot_be_decoded_is_still_set_aside_at_the_limit() throws {
        try Data("not valid json".utf8).write(to: snapshotURL, options: .atomic)
        XCTAssertThrowsError(try launch())
        XCTAssertThrowsError(try launch())

        XCTAssertEqual(try launch(), .setAside(firstSetAsideURL))
    }

    func test_a_new_snapshot_after_setting_aside_gets_its_own_two_attempts() throws {
        try saveSnapshot()
        _ = try launch()
        _ = try launch()
        _ = try launch()

        try saveSnapshot()

        XCTAssertTrue(try launch().isRestore)
        XCTAssertTrue(try launch().isRestore)
        XCTAssertEqual(try launch(), .setAside(secondSetAsideURL))
    }

    // MARK: - What resets the count

    func test_a_crash_after_the_first_save_does_not_count() throws {
        try saveSnapshot()

        for _ in 1...5 {
            XCTAssertTrue(try launch().isRestore)
            try saveSnapshot()
        }

        XCTAssertTrue(exists(snapshotURL))
        XCTAssertFalse(exists(firstSetAsideURL))
    }

    func test_the_first_save_keeps_the_launch_marked_as_running() throws {
        try saveSnapshot()
        _ = try launch()

        try saveSnapshot()

        guard case .restore(let decision) = try launch() else {
            return XCTFail("Expected a restore")
        }
        XCTAssertEqual(decision.reason, .crashRecovery)
    }

    func test_deleting_the_snapshot_counts_as_the_first_save() throws {
        try saveSnapshot()
        _ = try launch()

        try store.deleteSnapshot()

        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
    }

    func test_the_persistence_queue_resets_the_count_when_a_save_lands() throws {
        let persistence = SessionRestoreSnapshotPersistence(store: store)
        try saveSnapshot()
        _ = try launch()

        persistence.persistAsync(.saveSnapshot(envelope()), generation: 1)
        persistence.waitForPendingOperationsForTesting()

        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
    }

    func test_a_save_with_nothing_to_write_leaves_the_count_alone() throws {
        let persistence = SessionRestoreSnapshotPersistence(store: store)
        try saveSnapshot()
        _ = try launch()

        persistence.persistAsync(.none, generation: 1)
        persistence.waitForPendingOperationsForTesting()

        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    func test_a_clean_exit_resets_the_count() throws {
        try saveSnapshot()
        _ = try launch()
        _ = try launch()

        try store.markCleanExit()

        guard case .restore(let decision) = try launch() else {
            return XCTFail("Expected a restore")
        }
        XCTAssertEqual(decision.reason, .normalRestore)
        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    // MARK: - Launches that restore nothing

    func test_a_launch_with_no_snapshot_does_nothing() throws {
        try writeLifecycle(#"{"cleanExit":false,"updatedAt":0,"incompleteRestoreLaunches":2}"#)

        XCTAssertEqual(try launch(), .startFresh)

        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
        XCTAssertFalse(exists(firstSetAsideURL))
    }

    func test_a_launch_with_restore_disabled_does_nothing() throws {
        try saveSnapshot()
        try writeLifecycle(#"{"cleanExit":true,"updatedAt":0,"incompleteRestoreLaunches":2}"#)

        XCTAssertEqual(try store.beginLaunch(restorePreferenceEnabled: false), .startFresh)

        XCTAssertTrue(exists(snapshotURL))
        XCTAssertFalse(exists(firstSetAsideURL))
        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
    }

    /// Crash recovery reopens the workspace even with the preference off, so
    /// turning it off must not take a crash loop out of the limit.
    func test_crash_recovery_with_the_preference_off_is_still_limited() throws {
        try saveSnapshot()

        XCTAssertEqual(try store.beginLaunch(restorePreferenceEnabled: true).isRestore, true)
        XCTAssertEqual(try store.beginLaunch(restorePreferenceEnabled: false).isRestore, true)
        XCTAssertEqual(try store.beginLaunch(restorePreferenceEnabled: false), .setAside(firstSetAsideURL))
    }

    // MARK: - Set-aside files

    func test_setting_aside_never_overwrites_an_earlier_file() throws {
        try Data("earlier".utf8).write(to: firstSetAsideURL)
        try saveSnapshot()
        _ = try launch()
        _ = try launch()

        XCTAssertEqual(try launch(), .setAside(secondSetAsideURL))

        XCTAssertEqual(try String(contentsOf: firstSetAsideURL, encoding: .utf8), "earlier")
        XCTAssertTrue(exists(secondSetAsideURL))
    }

    func test_a_snapshot_that_cannot_be_renamed_is_not_restored_and_keeps_its_count() throws {
        _ = try launchWithFailedRename()

        XCTAssertTrue(exists(snapshotURL))
        XCTAssertFalse(exists(firstSetAsideURL))
        XCTAssertEqual(try recordedIncompleteLaunches(), 2)
    }

    func test_a_set_aside_snapshot_is_never_restored() throws {
        try saveSnapshot()
        _ = try launch()
        _ = try launch()
        _ = try launch()

        XCTAssertNil(try store.prepareForLaunch(restorePreferenceEnabled: true))
        XCTAssertEqual(try store.referencedScrollbackFileNames(), [])
    }

    func test_scrollback_named_by_set_aside_snapshots_is_listed() throws {
        try saveSnapshot(scrollbackFile: "pn_1-first.txt")
        _ = try launch()
        _ = try launch()
        _ = try launch()
        try saveSnapshot(scrollbackFile: "pn_1-second.txt")
        _ = try launch()
        _ = try launch()
        _ = try launch()
        try saveSnapshot(scrollbackFile: "pn_1-live.txt")

        XCTAssertEqual(store.setAsideScrollbackFileNames(), ["pn_1-first.txt", "pn_1-second.txt"])
    }

    /// Listing runs on every launch, on the files that are set aside because
    /// reopening them failed, so it must not depend on them decoding.
    func test_scrollback_is_listed_for_a_snapshot_that_no_longer_decodes() throws {
        try Data(#"{"workspace":{"windows":[{"panes":[{"scrollbackFile":"pn_1.txt"}]}]}}"#.utf8)
            .write(to: firstSetAsideURL)
        try Data("not valid json".utf8).write(to: secondSetAsideURL)

        XCTAssertEqual(store.setAsideScrollbackFileNames(), ["pn_1.txt"])
    }

    func test_no_scrollback_is_listed_in_a_directory_that_does_not_exist() {
        let store = SessionRestoreStore(
            stateDirectoryURL: directoryURL.appendingPathComponent("missing", isDirectory: true)
        )

        XCTAssertEqual(store.setAsideScrollbackFileNames(), [])
    }

    // MARK: - A rename that failed

    func test_a_debounced_save_cannot_replace_a_snapshot_waiting_to_be_renamed() throws {
        let (blockedStore, _) = try launchWithFailedRename()
        let original = try Data(contentsOf: snapshotURL)
        let persistence = SessionRestoreSnapshotPersistence(store: blockedStore)

        persistence.persistAsync(.saveSnapshot(envelope(scrollbackFile: "pn_1-new.txt")), generation: 1)
        persistence.waitForPendingOperationsForTesting()

        XCTAssertEqual(try Data(contentsOf: snapshotURL), original)
        XCTAssertEqual(try recordedIncompleteLaunches(), 2)
    }

    func test_a_delete_cannot_remove_a_snapshot_waiting_to_be_renamed() throws {
        let (blockedStore, _) = try launchWithFailedRename()
        let persistence = SessionRestoreSnapshotPersistence(store: blockedStore)

        persistence.persistAsync(.deleteSnapshot, generation: 1)
        persistence.waitForPendingOperationsForTesting()

        XCTAssertThrowsError(try blockedStore.deleteSnapshot())
        XCTAssertTrue(exists(snapshotURL))
        XCTAssertEqual(try recordedIncompleteLaunches(), 2)
    }

    /// The quit path is the same save, and the launch after it must still
    /// owe the rename instead of reading the snapshot as a clean one.
    func test_a_clean_exit_leaves_a_snapshot_waiting_to_be_renamed_for_the_next_launch() throws {
        let (blockedStore, _) = try launchWithFailedRename()
        let original = try Data(contentsOf: snapshotURL)
        let persistence = SessionRestoreSnapshotPersistence(store: blockedStore)
        var cleanExit = envelope(scrollbackFile: "pn_1-new.txt")
        cleanExit.reason = .cleanExit

        persistence.persistSynchronously(.saveSnapshot(cleanExit), generation: 1)
        try blockedStore.markCleanExit()

        XCTAssertEqual(try Data(contentsOf: snapshotURL), original)
        XCTAssertEqual(try recordedIncompleteLaunches(), 2)
        XCTAssertEqual(try launch(), .setAside(firstSetAsideURL))
        XCTAssertEqual(try Data(contentsOf: firstSetAsideURL), original)
    }

    func test_a_save_renames_the_snapshot_first_once_the_rename_works() throws {
        let (blockedStore, fileManager) = try launchWithFailedRename()
        let original = try Data(contentsOf: snapshotURL)
        let persistence = SessionRestoreSnapshotPersistence(store: blockedStore)
        let announced = URLRecorder()
        blockedStore.observeDeferredSetAside { announced.record($0) }

        persistence.persistAsync(.saveSnapshot(envelope(scrollbackFile: "pn_1-refused.txt")), generation: 1)
        fileManager.setFailsRenames(false)
        persistence.persistAsync(.saveSnapshot(envelope(scrollbackFile: "pn_1-new.txt")), generation: 2)
        persistence.waitForPendingOperationsForTesting()

        XCTAssertEqual(try Data(contentsOf: firstSetAsideURL), original)
        XCTAssertEqual(try store.referencedScrollbackFileNames(), ["pn_1-new.txt"])
        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
        XCTAssertEqual(announced.urls, [firstSetAsideURL])
    }

    func test_a_delete_renames_the_snapshot_instead_once_the_rename_works() throws {
        let (blockedStore, fileManager) = try launchWithFailedRename()
        let original = try Data(contentsOf: snapshotURL)
        let announced = URLRecorder()
        blockedStore.observeDeferredSetAside { announced.record($0) }

        fileManager.setFailsRenames(false)
        try blockedStore.deleteSnapshot()

        XCTAssertFalse(exists(snapshotURL))
        XCTAssertEqual(try Data(contentsOf: firstSetAsideURL), original)
        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
        XCTAssertEqual(announced.urls, [firstSetAsideURL])
    }

    /// Another instance got there first. There is nothing left to protect,
    /// and nothing of this launch's was set aside to announce.
    func test_a_snapshot_another_instance_moved_stops_the_wait() throws {
        let (blockedStore, fileManager) = try launchWithFailedRename()
        let announced = URLRecorder()
        blockedStore.observeDeferredSetAside { announced.record($0) }
        try FileManager.default.moveItem(at: snapshotURL, to: firstSetAsideURL)
        fileManager.setFailsRenames(false)

        try blockedStore.saveSnapshot(envelope(scrollbackFile: "pn_1-new.txt"))

        XCTAssertEqual(try store.referencedScrollbackFileNames(), ["pn_1-new.txt"])
        XCTAssertFalse(exists(secondSetAsideURL))
        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
        XCTAssertEqual(announced.urls, [])
    }

    func test_scrollback_of_a_snapshot_waiting_to_be_renamed_is_listed_on_both_sides_of_the_rename() throws {
        let (blockedStore, fileManager) = try launchWithFailedRename()

        XCTAssertEqual(blockedStore.setAsideScrollbackFileNames(), ["pn_1-original.txt"])

        fileManager.setFailsRenames(false)
        try blockedStore.saveSnapshot(envelope(scrollbackFile: "pn_1-new.txt"))

        XCTAssertEqual(blockedStore.setAsideScrollbackFileNames(), ["pn_1-original.txt"])
    }

    func test_a_live_snapshot_is_not_listed_as_set_aside() throws {
        try saveSnapshot(scrollbackFile: "pn_1-live.txt")

        XCTAssertEqual(store.setAsideScrollbackFileNames(), [])
    }

    // MARK: - Overlapping instances

    func test_a_live_instance_still_restoring_is_not_counted_as_a_crash() throws {
        try saveSnapshot()
        let instances = RunningInstances()
        _ = try instances.launch(in: self, running: false)
        _ = try instances.launch(in: self, running: true)
        XCTAssertEqual(try recordedIncompleteLaunches(), 2)

        let second = try instances.launch(in: self, running: true)

        XCTAssertTrue(second.isRestore)
        XCTAssertEqual(try recordedIncompleteLaunches(), 2)
        XCTAssertTrue(exists(snapshotURL))
        XCTAssertFalse(exists(firstSetAsideURL))
    }

    func test_an_attempt_whose_owner_died_counts() throws {
        try saveSnapshot()
        let instances = RunningInstances()
        _ = try instances.launch(in: self, running: false)
        _ = try instances.launch(in: self, running: false)

        XCTAssertEqual(try instances.launch(in: self, running: true), .setAside(firstSetAsideURL))
    }

    func test_a_launch_with_nothing_to_restore_leaves_another_instances_attempt_alone() throws {
        try saveSnapshot()
        let instances = RunningInstances()
        _ = try instances.launch(in: self, running: true)
        try FileManager.default.removeItem(at: snapshotURL)

        XCTAssertEqual(try instances.launch(in: self, running: true), .startFresh)

        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    func test_another_instances_save_does_not_clear_an_attempt_it_does_not_own() throws {
        try saveSnapshot()
        let instances = RunningInstances()
        let owner = instances.store(in: self, running: true)
        let other = instances.store(in: self, running: true)
        _ = try owner.beginLaunch(restorePreferenceEnabled: true)

        try other.saveSnapshot(envelope())
        XCTAssertEqual(try recordedIncompleteLaunches(), 1)

        try owner.saveSnapshot(envelope())
        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
    }

    func test_another_instances_clean_exit_does_not_clear_an_attempt_it_does_not_own() throws {
        try saveSnapshot()
        let instances = RunningInstances()
        let owner = instances.store(in: self, running: true)
        let other = instances.store(in: self, running: true)
        _ = try owner.beginLaunch(restorePreferenceEnabled: true)

        try other.markCleanExit()

        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
        XCTAssertEqual(try recordedCleanExit(), false)
    }

    func test_any_save_clears_an_attempt_whose_owner_died() throws {
        try saveSnapshot()
        let instances = RunningInstances()
        _ = try instances.launch(in: self, running: false)

        try instances.store(in: self, running: true).saveSnapshot(envelope())

        XCTAssertEqual(try recordedIncompleteLaunches(), 0)
    }

    func test_the_owner_is_on_disk_only_while_an_attempt_is_open() throws {
        try saveSnapshot()
        _ = try launch()
        XCTAssertNotNil(try recordedOwner())

        try saveSnapshot()

        XCTAssertNil(try recordedOwner())
    }

    func test_a_lifecycle_file_with_no_owner_counts_as_before() throws {
        try saveSnapshot()
        try writeLifecycle(#"{"cleanExit":false,"updatedAt":0,"incompleteRestoreLaunches":2}"#)

        XCTAssertEqual(try launch(), .setAside(firstSetAsideURL))
    }

    func test_a_reused_pid_does_not_keep_an_attempt_alive() throws {
        try saveSnapshot()
        let otherProcess = Process()
        otherProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        otherProcess.arguments = ["30"]
        try otherProcess.run()
        addTeardownBlock { otherProcess.terminate() }
        let pid = otherProcess.processIdentifier
        try writeLifecycle(
            #"{"cleanExit":false,"updatedAt":0,"incompleteRestoreLaunches":2,"restoreOwner":{"pid":\#(pid),"startTime":1}}"#
        )

        XCTAssertEqual(try launch(), .setAside(firstSetAsideURL))
    }

    func test_a_process_reads_as_running_until_it_exits() throws {
        let otherProcess = Process()
        otherProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        otherProcess.arguments = ["30"]
        try otherProcess.run()
        let identity = try XCTUnwrap(SessionRestoreProcess.running(pid: otherProcess.processIdentifier))
        XCTAssertTrue(identity.isRunning)
        XCTAssertFalse(SessionRestoreProcess(pid: identity.pid, startTime: identity.startTime + 1).isRunning)

        otherProcess.terminate()
        otherProcess.waitUntilExit()

        XCTAssertFalse(identity.isRunning)
    }

    func test_the_current_process_is_known_and_running() throws {
        XCTAssertEqual(try XCTUnwrap(SessionRestoreProcess.current).isRunning, true)
    }

    // MARK: - Lifecycle file compatibility

    func test_an_old_lifecycle_file_with_no_count_reads_as_zero() throws {
        try saveSnapshot()
        try writeLifecycle(#"{"cleanExit":false,"updatedAt":0}"#)

        guard case .restore(let decision) = try launch() else {
            return XCTFail("Expected a restore")
        }

        XCTAssertEqual(decision.reason, .crashRecovery)
        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    func test_an_older_build_can_read_the_lifecycle_file() throws {
        struct OlderLifecycleState: Decodable {
            var cleanExit: Bool
            var updatedAt: Date
        }
        try saveSnapshot()
        _ = try launch()

        let state = try JSONDecoder().decode(OlderLifecycleState.self, from: Data(contentsOf: lifecycleURL))

        XCTAssertFalse(state.cleanExit)
    }

    func test_an_older_build_rewriting_the_file_resets_the_count() throws {
        try saveSnapshot()
        _ = try launch()
        _ = try launch()
        try writeLifecycle(#"{"cleanExit":false,"updatedAt":0}"#)

        XCTAssertTrue(try launch().isRestore)
        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    func test_an_unreadable_lifecycle_file_starts_the_count_over() throws {
        try saveSnapshot()
        try writeLifecycle("not valid json")

        XCTAssertTrue(try launch().isRestore)
        XCTAssertEqual(try recordedIncompleteLaunches(), 1)
    }

    // MARK: - Helpers

    private func launch() throws -> SessionRestoreStore.LaunchAction {
        try store.beginLaunch(restorePreferenceEnabled: true)
    }

    /// Brings a snapshot to the limit, then has the rename fail. `store` plays
    /// the next launch, whose renames work.
    private func launchWithFailedRename() throws -> (
        store: SessionRestoreStore,
        fileManager: RenameFailingFileManager
    ) {
        try saveSnapshot(scrollbackFile: "pn_1-original.txt")
        _ = try launch()
        _ = try launch()
        let fileManager = RenameFailingFileManager()
        let blockedStore = SessionRestoreStore(
            snapshotURL: snapshotURL,
            lifecycleURL: lifecycleURL,
            fileManager: fileManager
        )
        XCTAssertEqual(try blockedStore.beginLaunch(restorePreferenceEnabled: true), .setAsideFailed)
        return (blockedStore, fileManager)
    }

    fileprivate func makeStore(
        as process: SessionRestoreProcess,
        isProcessRunning: @escaping @Sendable (SessionRestoreProcess) -> Bool
    ) -> SessionRestoreStore {
        SessionRestoreStore(
            snapshotURL: snapshotURL,
            lifecycleURL: lifecycleURL,
            process: process,
            isProcessRunning: isProcessRunning
        )
    }

    private func envelope(scrollbackFile: String? = nil) -> SessionRestoreEnvelope {
        var recipe = SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"])
        recipe.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile = scrollbackFile
        return SessionRestoreEnvelope(workspace: recipe)
    }

    private func saveSnapshot(scrollbackFile: String? = nil) throws {
        try store.saveSnapshot(envelope(scrollbackFile: scrollbackFile))
    }

    private func writeLifecycle(_ json: String) throws {
        try Data(json.utf8).write(to: lifecycleURL, options: .atomic)
    }

    private func recordedIncompleteLaunches() throws -> Int? {
        try recordedLifecycle()["incompleteRestoreLaunches"] as? Int
    }

    private func recordedCleanExit() throws -> Bool? {
        try recordedLifecycle()["cleanExit"] as? Bool
    }

    private func recordedOwner() throws -> [String: Any]? {
        try recordedLifecycle()["restoreOwner"] as? [String: Any]
    }

    private func recordedLifecycle() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: lifecycleURL))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

private extension SessionRestoreStore.LaunchAction {
    var isRestore: Bool {
        if case .restore = self { return true }
        return false
    }
}

/// Plays other Zentty processes sharing one state directory.
private final class RunningInstances: @unchecked Sendable {
    private let lock = NSLock()
    private var nextPID: Int32 = 1000
    private var running = Set<Int32>()

    func store(in testCase: SessionRestoreLaunchLimitTests, running isRunning: Bool) -> SessionRestoreStore {
        let process = lock.withLock {
            nextPID += 1
            if isRunning { running.insert(nextPID) }
            return SessionRestoreProcess(pid: nextPID, startTime: Int64(nextPID))
        }
        return testCase.makeStore(as: process) { [self] in
            let pid = $0.pid
            return lock.withLock { running.contains(pid) }
        }
    }

    func launch(
        in testCase: SessionRestoreLaunchLimitTests,
        running isRunning: Bool
    ) throws -> SessionRestoreStore.LaunchAction {
        try store(in: testCase, running: isRunning).beginLaunch(restorePreferenceEnabled: true)
    }
}

private final class RenameFailingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var failsRenames = true

    func setFailsRenames(_ fails: Bool) {
        lock.withLock { failsRenames = fails }
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if lock.withLock({ failsRenames }) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] {
        lock.withLock { recorded }
    }

    func record(_ url: URL) {
        lock.withLock { recorded.append(url) }
    }
}
