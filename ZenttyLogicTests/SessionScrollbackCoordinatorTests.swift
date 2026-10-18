import XCTest
@testable import Zentty

@MainActor
final class SessionScrollbackCoordinatorTests: XCTestCase {
    private var stateDirectory: URL!
    private var coordinator: SessionScrollbackCoordinator!
    private var screens: [PaneID: String] = [:]

    override func setUp() async throws {
        try await super.setUp()
        stateDirectory = try makeScrollbackTemporaryDirectory()
        coordinator = SessionScrollbackCoordinator(stateDirectoryURL: stateDirectory, launchID: "L1")
        coordinator.setEnabled(true, startsCheckpoints: false)
        screens = [:]
        coordinator.sourcesProvider = { [unowned self] in
            [SessionScrollbackCoordinator.CaptureSource(
                paneIDs: self.screens.keys.sorted { $0.rawValue < $1.rawValue },
                read: { [unowned self] in self.screens[$0] }
            )]
        }
    }

    override func tearDown() async throws {
        coordinator.waitForPendingWritesForTesting()
        coordinator = nil
        try await super.tearDown()
    }

    func test_capture_on_quit_writes_each_pane_and_the_save_references_it() throws {
        screens = [PaneID("pn_1"): "$ make\nok\n", PaneID("pn_2"): "$ git status\nclean\n"]

        coordinator.captureAll(synchronously: true)
        let saved = coordinator.prepareForSave(SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1", "pn_2"]))

        let panes = saved.windows[0].worklanes[0].columns[0].panes
        XCTAssertEqual(panes.map(\.scrollbackFile), ["pn_1-L1.txt", "pn_2-L1.txt"])
        XCTAssertEqual(
            try String(contentsOf: fileURL("pn_1-L1.txt"), encoding: .utf8),
            "$ make\nok\n" + SessionScrollbackText.separatorLine
        )
    }

    func test_save_forgets_closed_panes_and_purges_their_files() throws {
        screens = [PaneID("pn_1"): "one\n", PaneID("pn_2"): "two\n"]
        coordinator.captureAll(synchronously: true)

        let saved = coordinator.prepareForSave(SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"]))
        coordinator.waitForPendingWritesForTesting()

        XCTAssertEqual(saved.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile, "pn_1-L1.txt")
        XCTAssertEqual(try archiveContents(), ["pn_1-L1.txt"])
        XCTAssertEqual(coordinator.trackedFileNamesForTesting, [PaneID("pn_1"): "pn_1-L1.txt"])
    }

    func test_purge_removes_files_no_recipe_references() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("left over\n", fileName: "pn_old.txt")
        screens = [PaneID("pn_1"): "current\n"]
        coordinator.captureAll(synchronously: true)

        _ = coordinator.prepareForSave(SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"]))
        coordinator.waitForPendingWritesForTesting()

        XCTAssertEqual(try archiveContents(), ["pn_1-L1.txt"])
    }

    func test_blank_or_unstarted_panes_keep_the_file_from_the_previous_session() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("previous run\n", fileName: "pn_1.txt")
        try archive.write("previous run\n", fileName: "pn_2.txt")
        _ = importedState(paneIDs: ["pn_1", "pn_2"], files: ["pn_1": "pn_1.txt", "pn_2": "pn_2.txt"])

        // pn_1 has no runtime yet (deferred start), pn_2 shows a blank screen.
        screens = [PaneID("pn_2"): "\n   \n"]
        coordinator.captureAll(synchronously: true)
        let saved = coordinator.prepareForSave(SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1", "pn_2"]))
        coordinator.waitForPendingWritesForTesting()

        XCTAssertEqual(saved.windows[0].worklanes[0].columns[0].panes.map(\.scrollbackFile), ["pn_1.txt", "pn_2.txt"])
        XCTAssertEqual(try String(contentsOf: fileURL("pn_2.txt"), encoding: .utf8), "previous run\n")
    }

    func test_checkpoint_reads_only_panes_with_activity() throws {
        var reads: [PaneID] = []
        screens = [PaneID("pn_1"): "one\n", PaneID("pn_2"): "two\n"]
        coordinator.sourcesProvider = { [unowned self] in
            [SessionScrollbackCoordinator.CaptureSource(
                paneIDs: [PaneID("pn_1"), PaneID("pn_2")],
                read: { paneID in
                    reads.append(paneID)
                    return self.screens[paneID]
                }
            )]
        }

        coordinator.checkpoint()
        XCTAssertEqual(reads, [], "nothing ran yet, nothing to read")

        coordinator.markDirty(PaneID("pn_2"))
        coordinator.checkpoint()
        coordinator.checkpoint()
        coordinator.waitForPendingWritesForTesting()

        XCTAssertEqual(reads, [PaneID("pn_2")], "a dirty pane is read once, then clean again")
        XCTAssertEqual(try archiveContents(), ["pn_2-L1.txt"])
    }

    func test_observing_a_store_marks_panes_with_activity_dirty() throws {
        let store = WorklaneStore(windowID: WindowID("wd_1"), worklanes: [])
        coordinator.observe(store)
        coordinator.observe(store)
        var reads = 0
        screens = [PaneID("pn_1"): "one\n"]
        coordinator.sourcesProvider = { [unowned self] in
            [SessionScrollbackCoordinator.CaptureSource(
                paneIDs: [PaneID("pn_1")],
                read: { paneID in
                    reads += 1
                    return self.screens[paneID]
                }
            )]
        }

        store.notify(.auxiliaryStateUpdated(WorklaneID("wl_1"), PaneID("pn_1"), [.sidebar]))
        coordinator.checkpoint()

        XCTAssertEqual(reads, 1)
    }

    func test_unchanged_content_is_not_rewritten() throws {
        screens = [PaneID("pn_1"): "same\n"]
        coordinator.captureAll(synchronously: true)
        // Overwrite the file behind the writer's back: a rewrite would undo it.
        try "sentinel".write(to: fileURL("pn_1-L1.txt"), atomically: true, encoding: .utf8)

        coordinator.captureAll(synchronously: true)
        XCTAssertEqual(try String(contentsOf: fileURL("pn_1-L1.txt"), encoding: .utf8), "sentinel")

        screens = [PaneID("pn_1"): "changed\n"]
        coordinator.captureAll(synchronously: true)
        XCTAssertEqual(
            try String(contentsOf: fileURL("pn_1-L1.txt"), encoding: .utf8),
            "changed\n" + SessionScrollbackText.separatorLine
        )
    }

    func test_new_reference_asks_for_a_snapshot_save_once() {
        var saves = 0
        coordinator.onReferencesChanged = { saves += 1 }
        screens = [PaneID("pn_1"): "one\n"]

        coordinator.markDirty(PaneID("pn_1"))
        coordinator.checkpoint()
        screens = [PaneID("pn_1"): "one\ntwo\n"]
        coordinator.markDirty(PaneID("pn_1"))
        coordinator.checkpoint()

        XCTAssertEqual(saves, 1, "the file name is stable, so only the first capture changes the recipe")
    }

    func test_turning_the_setting_off_deletes_saved_files_and_writes_nothing() throws {
        screens = [PaneID("pn_1"): "secret token\n"]
        coordinator.captureAll(synchronously: true)
        XCTAssertEqual(try archiveContents(), ["pn_1-L1.txt"])

        coordinator.setEnabled(false)
        coordinator.waitForPendingWritesForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory.path))

        coordinator.captureAll(synchronously: true)
        coordinator.markDirty(PaneID("pn_1"))
        coordinator.checkpoint()
        let saved = coordinator.prepareForSave(SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"]))
        coordinator.waitForPendingWritesForTesting()

        XCTAssertNil(saved.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory.path))
    }

    func test_discard_all_drops_references_and_files() throws {
        screens = [PaneID("pn_1"): "one\n"]
        coordinator.captureAll(synchronously: true)

        coordinator.discardAll()
        coordinator.waitForPendingWritesForTesting()

        XCTAssertTrue(coordinator.trackedFileNamesForTesting.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory.path))
    }

    func test_restored_panes_point_at_existing_files_only() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("previous\n", fileName: "pn_1.txt")

        let state = importedState(
            paneIDs: ["pn_1", "pn_2", "pn_3"],
            files: ["pn_1": "pn_1.txt", "pn_2": "pn_2.txt", "pn_3": "../../etc/passwd"]
        )

        let environments = state.worklanes[0].paneStripState.panes.map {
            $0.sessionRequest.environmentVariables[SessionScrollbackCoordinator.environmentKey]
        }
        XCTAssertEqual(environments, [try fileURL("pn_1.txt").path, nil, nil])
        XCTAssertEqual(coordinator.trackedFileNamesForTesting, [PaneID("pn_1"): "pn_1.txt"])
        XCTAssertNil(
            state.worklanes[0].paneStripState.panes[0].sessionRequest.command,
            "the saved output is printed by the shell, never typed as a command"
        )
        XCTAssertNil(state.worklanes[0].paneStripState.panes[0].sessionRequest.prefillText)
    }

    func test_agent_pane_keeps_its_resume_command_alongside_the_replay() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("agent transcript\n", fileName: "pn_1.txt")
        var recipe = SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"], workingDirectory: stateDirectory.path)
        recipe.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile = "pn_1.txt"
        let draftWindow = SessionRestoreDraftWindow(
            windowID: "wd_1",
            paneDrafts: [
                PaneRestoreDraft(
                    paneID: "pn_1",
                    kind: .agentResume,
                    toolName: "Claude Code",
                    sessionID: "123e4567-e89b-12d3-a456-426614174000",
                    workingDirectory: stateDirectory.path,
                    trackedPID: 0
                ),
            ]
        )
        let plainState = WorkspaceRecipeImporter.makeWorklanes(
            from: recipe.windows[0],
            restoreDraftWindow: draftWindow,
            windowID: WindowID("wd_1"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": stateDirectory.path]
        )
        var state = plainState

        coordinator.prepareRestoredPanes(in: &state, from: recipe.windows[0])

        let before = plainState.worklanes[0].paneStripState.panes[0].sessionRequest
        let after = state.worklanes[0].paneStripState.panes[0].sessionRequest
        XCTAssertNotNil(before.command)
        XCTAssertEqual(after.command, before.command, "the resume command runs exactly as without saved output")
        XCTAssertEqual(after.prefillText, before.prefillText)
        XCTAssertEqual(after.environmentVariables[SessionScrollbackCoordinator.environmentKey], try fileURL("pn_1.txt").path)
    }

    func test_disabled_coordinator_leaves_restored_panes_untouched() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("previous\n", fileName: "pn_1.txt")
        coordinator.setEnabled(false)
        coordinator.waitForPendingWritesForTesting()
        try archive.write("previous\n", fileName: "pn_1.txt")

        let state = importedState(paneIDs: ["pn_1"], files: ["pn_1": "pn_1.txt"])

        XCTAssertNil(
            state.worklanes[0].paneStripState.panes[0].sessionRequest
                .environmentVariables[SessionScrollbackCoordinator.environmentKey]
        )
    }

    func test_final_save_captures_every_pane_and_finishes_its_disk_work_before_returning() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("closed pane secret\n", fileName: "pn_gone.txt")
        screens = [PaneID("pn_1"): "$ make\nok\n"]

        // No captureAll first: the quit path captures inside the save, so the
        // recipe can never miss the files it writes.
        let saved = coordinator.prepareForSave(
            SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"]),
            finalSave: true
        )

        // No wait either: the app exits right after this returns.
        XCTAssertEqual(saved.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile, "pn_1-L1.txt")
        XCTAssertEqual(try archiveContents(), ["pn_1-L1.txt"])
    }

    func test_synchronous_discard_deletes_files_before_returning() throws {
        screens = [PaneID("pn_1"): "secret token\n"]
        coordinator.captureAll(synchronously: true)

        coordinator.discardAll(synchronously: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory.path))
    }

    func test_checkpoint_rereads_busy_panes_without_new_activity() throws {
        var reads: [PaneID] = []
        var output = "$ tail -f log\nline 1\n"
        coordinator.sourcesProvider = {
            [SessionScrollbackCoordinator.CaptureSource(
                paneIDs: [PaneID("pn_1"), PaneID("pn_2")],
                busyPaneIDs: [PaneID("pn_1")],
                read: { paneID in
                    reads.append(paneID)
                    return output
                }
            )]
        }

        coordinator.checkpoint()
        output += "line 2\n"
        coordinator.checkpoint()
        coordinator.waitForPendingWritesForTesting()

        XCTAssertEqual(reads, [PaneID("pn_1"), PaneID("pn_1")], "a running command keeps printing without metadata changes")
        XCTAssertEqual(
            try String(contentsOf: fileURL("pn_1-L1.txt"), encoding: .utf8),
            "$ tail -f log\nline 1\nline 2\n" + SessionScrollbackText.separatorLine
        )
    }

    func test_restored_file_is_never_rewritten_and_is_purged_once_the_pane_saves_newer_output() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: stateDirectory)
        try archive.write("previous launch\n", fileName: "pn_1-L0.txt")
        let state = importedState(paneIDs: ["pn_1"], files: ["pn_1": "pn_1-L0.txt"])
        let restoredPath = state.worklanes[0].paneStripState.panes[0].sessionRequest
            .environmentVariables[SessionScrollbackCoordinator.environmentKey]
        XCTAssertEqual(restoredPath, try fileURL("pn_1-L0.txt").path)
        var saves = 0
        coordinator.onReferencesChanged = { saves += 1 }

        screens = [PaneID("pn_1"): "previous launch\nnewer output\n"]
        coordinator.markDirty(PaneID("pn_1"))
        coordinator.checkpoint()
        coordinator.waitForPendingWritesForTesting()

        // A copy of the variable that leaked to a child process still names
        // the old file, which must not start showing the newer output.
        XCTAssertEqual(try String(contentsOf: fileURL("pn_1-L0.txt"), encoding: .utf8), "previous launch\n")
        XCTAssertEqual(saves, 1, "moving to this launch's file changes the recipe")

        let saved = coordinator.prepareForSave(SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"]))
        coordinator.waitForPendingWritesForTesting()

        XCTAssertEqual(saved.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile, "pn_1-L1.txt")
        XCTAssertEqual(try archiveContents(), ["pn_1-L1.txt"])
    }

    func test_launches_use_distinct_file_names() {
        XCTAssertNotEqual(SessionScrollbackCoordinator.makeLaunchID(), SessionScrollbackCoordinator.makeLaunchID())
        XCTAssertTrue(
            SessionScrollbackArchive.isValidFileName(
                SessionScrollbackArchive.fileName(forPaneID: "pn_1", launchID: SessionScrollbackCoordinator.makeLaunchID())
            )
        )
    }

    // MARK: - Helpers

    private var archiveDirectory: URL {
        SessionScrollbackArchive(stateDirectoryURL: stateDirectory).directoryURL
    }

    private func fileURL(_ name: String) throws -> URL {
        try XCTUnwrap(SessionScrollbackArchive(stateDirectoryURL: stateDirectory).url(forFileName: name))
    }

    private func archiveContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: archiveDirectory.path).sorted()
    }

    private func importedState(paneIDs: [String], files: [String: String]) -> WindowWorkspaceState {
        var recipe = SessionScrollbackTestFixtures.recipe(paneIDs: paneIDs, workingDirectory: stateDirectory.path)
        for index in recipe.windows[0].worklanes[0].columns[0].panes.indices {
            let id = recipe.windows[0].worklanes[0].columns[0].panes[index].id
            recipe.windows[0].worklanes[0].columns[0].panes[index].scrollbackFile = files[id]
        }
        var state = WorkspaceRecipeImporter.makeWorklanes(
            from: recipe.windows[0],
            windowID: WindowID("wd_1"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": stateDirectory.path]
        )
        coordinator.prepareRestoredPanes(in: &state, from: recipe.windows[0])
        return state
    }
}
