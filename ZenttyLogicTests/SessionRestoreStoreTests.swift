import XCTest
@testable import Zentty

final class SessionRestoreStoreTests: XCTestCase {
    private var directoryURL: URL!
    private var store: SessionRestoreStore!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.SessionRestore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        store = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        store = nil
        directoryURL = nil
    }

    func test_prepare_for_launch_returns_clean_restore_when_snapshot_exists_and_restore_is_enabled() throws {
        try store.saveSnapshot(
            SessionRestoreEnvelope(
                workspace: WorkspaceRecipe(
                    windows: [
                        WorkspaceRecipe.Window(
                            id: "window-main",
                            worklanes: [],
                            activeWorklaneID: nil
                        )
                    ]
                )
            )
        )
        try store.markLaunchStarted()
        try store.markCleanExit()

        let relaunchedStore = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )

        let decision = try relaunchedStore.prepareForLaunch(restorePreferenceEnabled: true)

        XCTAssertEqual(decision?.reason, .normalRestore)
        XCTAssertEqual(decision?.envelope.workspace.windows.map(\.id), ["window-main"])
    }

    func test_prepare_for_launch_returns_crash_recovery_even_when_restore_preference_is_disabled() throws {
        try store.saveSnapshot(
            SessionRestoreEnvelope(
                workspace: WorkspaceRecipe(
                    windows: [
                        WorkspaceRecipe.Window(
                            id: "window-main",
                            worklanes: [],
                            activeWorklaneID: nil
                        )
                    ]
                )
            )
        )
        try store.markLaunchStarted()

        let relaunchedStore = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )

        let decision = try relaunchedStore.prepareForLaunch(restorePreferenceEnabled: false)

        XCTAssertEqual(decision?.reason, .crashRecovery)
        XCTAssertEqual(decision?.envelope.workspace.windows.first?.id, "window-main")
    }

    func test_delete_snapshot_removes_snapshot_file() throws {
        try store.saveSnapshot(
            SessionRestoreEnvelope(
                workspace: WorkspaceRecipe(
                    windows: [
                        WorkspaceRecipe.Window(
                            id: "window-main",
                            worklanes: [],
                            activeWorklaneID: nil
                        )
                    ]
                )
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("restore-snapshot.json").path
            )
        )

        try store.deleteSnapshot()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("restore-snapshot.json").path
            )
        )
    }

    func test_meaningfulness_classifier_rejects_trivial_default_workspace() {
        let recipe = WorkspaceRecipe(
            windows: [
                WorkspaceRecipe.Window(
                    id: "window-main",
                    worklanes: [
                        WorkspaceRecipe.Worklane(
                            id: "main",
                            title: "MAIN",
                            nextPaneNumber: 2,
                            focusedColumnID: "column-main",
                            columns: [
                                WorkspaceRecipe.Column(
                                    id: "column-main",
                                    width: 640,
                                    focusedPaneID: "pane-main",
                                    lastFocusedPaneID: "pane-main",
                                    paneHeights: [480],
                                    panes: [
                                        WorkspaceRecipe.Pane(
                                            id: "pane-main",
                                            titleSeed: "shell",
                                            workingDirectory: "/Users/peter"
                                        )
                                    ]
                                )
                            ]
                        )
                    ],
                    activeWorklaneID: "main"
                )
            ]
        )

        XCTAssertFalse(
            WorkspaceRecipeMeaningfulness.isMeaningful(
                recipe,
                defaultWorkingDirectory: "/Users/peter"
            )
        )
    }
}
