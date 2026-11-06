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
        try saveSnapshot()
        _ = try launch()
        _ = try launch()
        let blockedStore = SessionRestoreStore(
            snapshotURL: snapshotURL,
            lifecycleURL: lifecycleURL,
            fileManager: UnrenamableFileManager()
        )

        XCTAssertThrowsError(try blockedStore.beginLaunch(restorePreferenceEnabled: true))

        XCTAssertTrue(exists(snapshotURL))
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
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: lifecycleURL))
        return try XCTUnwrap(object as? [String: Any])["incompleteRestoreLaunches"] as? Int
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

private final class UnrenamableFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
