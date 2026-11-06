import XCTest
@testable import Zentty

/// Restore snapshots and tmux-compat state describe one Mac's live session.
/// They moved out of ~/.config/zentty so that folder can be synced between
/// Macs without dragging that state along. The move must stay safe while
/// older Zentty builds still run against the old files.
final class RuntimeStateRelocationTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var configDirectoryURL: URL!
    private var stateDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.RuntimeStateRelocation.\(UUID().uuidString)", isDirectory: true)
        configDirectoryURL = temporaryDirectoryURL.appendingPathComponent("config", isDirectory: true)
        stateDirectoryURL = temporaryDirectoryURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func test_state_directory_is_the_flavors_application_support_folder() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            ZenttyBuildFlavor.production.stateDirectoryURL(homeDirectoryURL: home).path,
            "/Users/tester/Library/Application Support/Zentty"
        )
        XCTAssertEqual(
            ZenttyBuildFlavor.dev.stateDirectoryURL(homeDirectoryURL: home).path,
            "/Users/tester/Library/Application Support/Zentty Dev"
        )
    }

    func test_copies_session_state_once_and_leaves_the_old_files_for_older_builds() throws {
        try write("config.toml", "[sidebar]\n", in: configDirectoryURL)
        for name in RuntimeStateRelocation.fileNames {
            try write(name, name, in: configDirectoryURL)
        }

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(Set(copied), Set(RuntimeStateRelocation.fileNames))
        for name in RuntimeStateRelocation.fileNames {
            XCTAssertEqual(try read(name, in: stateDirectoryURL), name)
            XCTAssertEqual(try read(name, in: configDirectoryURL), name, "an older build may still be using \(name)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("config.toml").path))
    }

    func test_later_writes_by_an_older_build_are_never_pulled_in() throws {
        try write("restore-snapshot.json", "first", in: configDirectoryURL)
        RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)
        try write("restore-snapshot.json", "own session", in: stateDirectoryURL)

        // Another worktree build on 0.3.7 keeps writing the old location.
        try write("restore-snapshot.json", "other instance", in: configDirectoryURL)
        try write("tmux-compat-store.json", "other instance", in: configDirectoryURL)
        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, [])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "own session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("tmux-compat-store.json").path))
    }

    func test_existing_state_is_never_replaced_and_restore_files_move_as_a_pair() throws {
        try write("restore-snapshot.json", "current", in: stateDirectoryURL)
        try write("restore-snapshot.json", "old", in: configDirectoryURL)
        try write("restore-lifecycle.json", "old", in: configDirectoryURL)

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, [])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "current")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("restore-lifecycle.json").path),
            "a lifecycle file without its own snapshot could fake a crash recovery"
        )
    }

    func test_a_failed_copy_is_retried_on_the_next_launch() throws {
        try write("restore-snapshot.json", "session", in: configDirectoryURL)
        // A regular file where the state directory should be makes every copy fail.
        try Data().write(to: stateDirectoryURL)

        XCTAssertEqual(RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL), [])

        try FileManager.default.removeItem(at: stateDirectoryURL)
        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, ["restore-snapshot.json"])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "session")
    }

    func test_failed_lifecycle_copy_rolls_back_snapshot_and_retries_the_pair() throws {
        try write("restore-snapshot.json", "session", in: configDirectoryURL)
        try write("restore-lifecycle.json", "lifecycle", in: configDirectoryURL)
        let failing = CopyFailingFileManager(failingFileName: "restore-lifecycle.json")

        XCTAssertEqual(
            RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL, fileManager: failing),
            []
        )
        XCTAssertEqual(try contents(of: stateDirectoryURL), [], "half a pair must not stay behind, and the marker waits for a retry")

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(Set(copied), Set(RuntimeStateRelocation.restoreFileNames))
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "session")
        XCTAssertEqual(try read("restore-lifecycle.json", in: stateDirectoryURL), "lifecycle")
    }

    func test_launch_after_failed_pair_copy_retries_once_the_source_is_repaired() throws {
        try write("restore-snapshot.json", "session", in: configDirectoryURL)
        try write("restore-lifecycle.json", "lifecycle", in: configDirectoryURL)

        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: "restore-lifecycle.json")
        )
        try launchBookkeeping()

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(Set(copied), Set(RuntimeStateRelocation.restoreFileNames))
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "session")
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL)
    }

    func test_launch_after_failed_snapshot_copy_retries_once_the_source_is_repaired() throws {
        try write("restore-snapshot.json", "session", in: configDirectoryURL)

        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: "restore-snapshot.json")
        )
        try launchBookkeeping()

        XCTAssertEqual(
            RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL).first,
            "restore-snapshot.json"
        )
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "session")
    }

    func test_restore_store_stays_in_the_state_directory_without_a_pending_pair() throws {
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL, "nothing to migrate")

        try write("restore-snapshot.json", "old", in: configDirectoryURL)
        try write("restore-lifecycle.json", "current", in: stateDirectoryURL)
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL, "existing state wins over the old pair")

        try FileManager.default.removeItem(at: stateDirectoryURL)
        RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL, "the pair moved")

        try FileManager.default.removeItem(at: stateDirectoryURL.appendingPathComponent("restore-snapshot.json"))
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL, "the marker ends the migration for good")
    }

    func test_existing_lifecycle_blocks_copying_old_snapshot() throws {
        try write("restore-lifecycle.json", "current", in: stateDirectoryURL)
        try write("restore-snapshot.json", "old", in: configDirectoryURL)
        try write("restore-lifecycle.json", "old", in: configDirectoryURL)

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, [])
        XCTAssertEqual(try read("restore-lifecycle.json", in: stateDirectoryURL), "current")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("restore-snapshot.json").path),
            "an old snapshot paired with a newer lifecycle could fake a crash recovery"
        )
    }

    func test_nothing_to_copy_only_marks_the_relocation_done() throws {
        XCTAssertEqual(RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL), [])
        XCTAssertEqual(try contents(of: stateDirectoryURL), [RuntimeStateRelocation.markerFileName])
    }

    // MARK: - Scrollback

    /// The launch that fell back to the config directory wrote its scrollback there too. The
    /// snapshot names those files bare, so they have to land beside the pair it moves with.
    @MainActor
    func test_retry_brings_across_the_scrollback_the_fallback_launch_saved() throws {
        try write("restore-snapshot.json", "legacy", in: configDirectoryURL)
        failMigrationOnce(on: "restore-snapshot.json")
        XCTAssertEqual(restoreStoreDirectory(), configDirectoryURL)
        try quitWithScrollback(screens: ["pn_1": "$ make\nok\n"])

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertTrue(copied.contains("pn_1-L1.txt"), "\(copied)")
        XCTAssertTrue(marker(in: stateDirectoryURL))
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL)
        XCTAssertEqual(try restoredScrollback(paneID: "pn_1"), "$ make\nok\n" + SessionScrollbackText.separatorLine)
        XCTAssertEqual(
            try permissions(of: scrollbackDirectory(in: stateDirectoryURL)), 0o700,
            "saved output can hold secrets"
        )
        XCTAssertEqual(try permissions(of: scrollbackFile("pn_1-L1.txt", in: stateDirectoryURL)), 0o600)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scrollbackFile("pn_1-L1.txt", in: configDirectoryURL).path),
            "an older build may still be using the config directory"
        )
    }

    @MainActor
    func test_failed_scrollback_copy_keeps_the_config_directory_authoritative_and_retries() throws {
        try quitWithScrollback(screens: ["pn_1": "one\n", "pn_2": "two\n"])

        let copied = RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: "pn_2-L1.txt")
        )

        XCTAssertEqual(copied, [])
        XCTAssertFalse(marker(in: stateDirectoryURL))
        for name in RuntimeStateRelocation.restoreFileNames {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent(name).path),
                "\(name) must wait for the scrollback it points at"
            )
        }
        XCTAssertEqual(try scrollbackFiles(in: stateDirectoryURL), [], "the attempt takes back what it copied")
        XCTAssertEqual(restoreStoreDirectory(), configDirectoryURL)

        RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertTrue(marker(in: stateDirectoryURL))
        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL)
        XCTAssertEqual(try restoredScrollback(paneID: "pn_2"), "two\n" + SessionScrollbackText.separatorLine)
    }

    @MainActor
    func test_rollback_removes_only_the_scrollback_this_attempt_created() throws {
        try quitWithScrollback(screens: ["pn_1": "one\n", "pn_2": "two\n"])
        try SessionRestoreStore(stateDirectoryURL: configDirectoryURL).markLaunchStarted()
        let existing = SessionScrollbackArchive(stateDirectoryURL: stateDirectoryURL)
        try existing.write("already here\n", fileName: "pn_1-L1.txt")

        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: "restore-lifecycle.json")
        )

        XCTAssertEqual(try scrollbackFiles(in: stateDirectoryURL), ["pn_1-L1.txt"])
        XCTAssertEqual(
            try String(contentsOf: scrollbackFile("pn_1-L1.txt", in: stateDirectoryURL), encoding: .utf8),
            "already here\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("restore-snapshot.json").path))
        XCTAssertFalse(marker(in: stateDirectoryURL))
    }

    /// Half a pair that can't be taken back reads as existing state and ends the migration, so
    /// the scrollback it points at has to stay with it.
    @MainActor
    func test_rollback_that_cannot_remove_the_snapshot_keeps_its_scrollback() throws {
        try quitWithScrollback(screens: ["pn_1": "one\n"])
        try SessionRestoreStore(stateDirectoryURL: configDirectoryURL).markLaunchStarted()

        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(
                failingFileName: "restore-lifecycle.json",
                refusedRemovalName: "restore-snapshot.json"
            )
        )

        XCTAssertEqual(restoreStoreDirectory(), stateDirectoryURL)
        XCTAssertEqual(try restoredScrollback(paneID: "pn_1"), "one\n" + SessionScrollbackText.separatorLine)
    }

    /// A full disk stops a copy halfway. What that leaves behind must not pass for a finished
    /// file: the retry skips any file that already exists.
    @MainActor
    func test_copy_interrupted_halfway_is_not_taken_for_a_finished_file_on_retry() throws {
        try quitWithScrollback(screens: ["pn_1": "one\n"])

        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: "pn_1-L1.txt", leavesPartialCopy: true)
        )

        XCTAssertEqual(try contents(of: scrollbackDirectory(in: stateDirectoryURL)), [])

        RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(try restoredScrollback(paneID: "pn_1"), "one\n" + SessionScrollbackText.separatorLine)
    }

    func test_interrupted_snapshot_copy_does_not_end_the_retry() throws {
        try write("restore-snapshot.json", "session", in: configDirectoryURL)

        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: "restore-snapshot.json", leavesPartialCopy: true)
        )

        XCTAssertEqual(try contents(of: stateDirectoryURL), [])
        XCTAssertEqual(restoreStoreDirectory(), configDirectoryURL)
    }

    /// A pane whose file is gone restores without it today, so it can't block the migration.
    func test_snapshot_reference_without_a_usable_file_does_not_hold_the_migration_back() throws {
        var recipe = SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_gone", "pn_escape"])
        recipe.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile = "pn_gone-L1.txt"
        recipe.windows[0].worklanes[0].columns[0].panes[1].scrollbackFile = "../restore-lifecycle.txt"
        try write("restore-lifecycle.txt", "outside the archive", in: configDirectoryURL)
        try SessionRestoreStore(stateDirectoryURL: configDirectoryURL)
            .saveSnapshot(SessionRestoreEnvelope(workspace: recipe))

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, ["restore-snapshot.json"])
        XCTAssertTrue(marker(in: stateDirectoryURL))
        XCTAssertEqual(try contents(of: stateDirectoryURL).filter { $0.contains("scrollback") }, [])
    }

    func test_tmux_compat_store_lives_in_the_state_directory() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            TmuxCompatStoreIO.defaultFileURL(home: home).path,
            "/Users/tester/Library/Application Support/Zentty/tmux-compat-store.json"
        )
    }

    // MARK: - Helpers

    private func restoreStoreDirectory() -> URL {
        RuntimeStateRelocation.restoreStoreDirectory(from: configDirectoryURL, to: stateDirectoryURL)
    }

    /// What a launch writes through its restore store before the user does anything.
    private func launchBookkeeping() throws {
        try SessionRestoreStore(stateDirectoryURL: restoreStoreDirectory()).markLaunchStarted()
    }

    private func failMigrationOnce(on fileName: String) {
        RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL,
            fileManager: CopyFailingFileManager(failingFileName: fileName)
        )
    }

    /// The quit path of a launch that fell back to the config directory: the coordinator writes
    /// each pane's output there, and the snapshot records the bare file names.
    @MainActor
    private func quitWithScrollback(screens: [String: String]) throws {
        let directory: URL = configDirectoryURL
        let coordinator = SessionScrollbackCoordinator(stateDirectoryURL: directory, launchID: "L1")
        coordinator.setEnabled(true, startsCheckpoints: false)
        coordinator.sourcesProvider = {
            [SessionScrollbackCoordinator.CaptureSource(
                paneIDs: screens.keys.sorted().map { PaneID($0) },
                read: { screens[$0.rawValue] }
            )]
        }
        let recipe = coordinator.prepareForSave(
            SessionScrollbackTestFixtures.recipe(paneIDs: screens.keys.sorted()),
            finalSave: true
        )
        try SessionRestoreStore(stateDirectoryURL: directory).saveSnapshot(SessionRestoreEnvelope(workspace: recipe))
    }

    /// What the next launch replays: restore through the chosen directory, then read the file
    /// the shell integration would be pointed at.
    @MainActor
    private func restoredScrollback(paneID: String) throws -> String? {
        let directory = restoreStoreDirectory()
        let decision = try XCTUnwrap(
            try SessionRestoreStore(stateDirectoryURL: directory).prepareForLaunch(restorePreferenceEnabled: true)
        )
        let window = decision.envelope.workspace.windows[0]
        var state = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID(window.id),
            layoutContext: .fallback,
            processEnvironment: ["HOME": directory.path]
        )
        let coordinator = SessionScrollbackCoordinator(stateDirectoryURL: directory, launchID: "L2")
        coordinator.setEnabled(true, startsCheckpoints: false)
        coordinator.prepareRestoredPanes(in: &state, from: window)
        let pane = state.worklanes[0].paneStripState.panes.first { $0.id == PaneID(paneID) }
        guard let path = pane?.sessionRequest.environmentVariables[SessionScrollbackCoordinator.environmentKey] else {
            return nil
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func marker(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(RuntimeStateRelocation.markerFileName).path)
    }

    private func scrollbackDirectory(in directory: URL) -> URL {
        SessionScrollbackArchive(stateDirectoryURL: directory).directoryURL
    }

    private func scrollbackFile(_ name: String, in directory: URL) -> URL {
        scrollbackDirectory(in: directory).appendingPathComponent(name)
    }

    private func scrollbackFiles(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: scrollbackDirectory(in: directory).path) else { return [] }
        return try contents(of: scrollbackDirectory(in: directory))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    private func write(_ name: String, _ contents: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

private final class CopyFailingFileManager: FileManager {
    private let failingFileName: String
    private let refusedRemovalName: String?
    private let leavesPartialCopy: Bool

    init(failingFileName: String, refusedRemovalName: String? = nil, leavesPartialCopy: Bool = false) {
        self.failingFileName = failingFileName
        self.refusedRemovalName = refusedRemovalName
        self.leavesPartialCopy = leavesPartialCopy
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard srcURL.lastPathComponent != failingFileName else {
            if leavesPartialCopy {
                try Data("par".utf8).write(to: dstURL)
            }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        guard URL.lastPathComponent != refusedRemovalName else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
