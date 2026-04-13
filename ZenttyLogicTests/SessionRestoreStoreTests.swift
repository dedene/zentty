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

    func test_save_snapshot_round_trips_restore_drafts() throws {
        let envelope = SessionRestoreEnvelope(
            workspace: WorkspaceRecipe(
                windows: [
                    WorkspaceRecipe.Window(
                        id: "window-main",
                        worklanes: [],
                        activeWorklaneID: nil
                    )
                ]
            ),
            restoreDraftWindows: [
                SessionRestoreDraftWindow(
                    windowID: "window-main",
                    paneDrafts: [
                        PaneRestoreDraft(
                            paneID: "pane-agent",
                            kind: .agentResume,
                            toolName: "Codex",
                            sessionID: "session-codex",
                            workingDirectory: "/tmp/project",
                            trackedPID: 4242
                        )
                    ]
                )
            ]
        )

        try store.saveSnapshot(envelope)
        try store.markLaunchStarted()
        try store.markCleanExit()

        let relaunchedStore = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )
        let decision = try XCTUnwrap(
            relaunchedStore.prepareForLaunch(restorePreferenceEnabled: true)
        )

        XCTAssertEqual(decision.envelope.restoreDraftWindows, envelope.restoreDraftWindows)
    }

    func test_clean_exit_save_preserves_existing_restore_drafts_for_matching_panes() throws {
        let workspace = WorkspaceRecipe(
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
                                    focusedPaneID: "pane-agent",
                                    lastFocusedPaneID: "pane-agent",
                                    paneHeights: [480],
                                    panes: [
                                        WorkspaceRecipe.Pane(
                                            id: "pane-agent",
                                            titleSeed: "Codex",
                                            workingDirectory: "/tmp/project"
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
        let liveEnvelope = SessionRestoreEnvelope(
            reason: .liveSnapshot,
            workspace: workspace,
            restoreDraftWindows: [
                SessionRestoreDraftWindow(
                    windowID: "window-main",
                    paneDrafts: [
                        PaneRestoreDraft(
                            paneID: "pane-agent",
                            kind: .agentResume,
                            toolName: "Codex",
                            sessionID: "session-codex",
                            workingDirectory: "/tmp/project",
                            trackedPID: 4242
                        )
                    ]
                )
            ]
        )
        let cleanExitEnvelope = SessionRestoreEnvelope(
            reason: .cleanExit,
            workspace: workspace,
            restoreDraftWindows: []
        )

        try store.saveSnapshot(liveEnvelope)
        try store.saveSnapshot(cleanExitEnvelope)
        try store.markLaunchStarted()
        try store.markCleanExit()

        let relaunchedStore = SessionRestoreStore(
            snapshotURL: directoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )
        let decision = try XCTUnwrap(
            relaunchedStore.prepareForLaunch(restorePreferenceEnabled: true)
        )

        XCTAssertEqual(decision.envelope.reason, .cleanExit)
        XCTAssertEqual(decision.envelope.restoreDraftWindows, liveEnvelope.restoreDraftWindows)
    }

    func test_prepare_for_launch_throws_when_snapshot_is_corrupt() throws {
        let snapshotURL = directoryURL.appendingPathComponent("restore-snapshot.json")
        try Data("not valid json".utf8).write(to: snapshotURL, options: .atomic)

        let relaunchedStore = SessionRestoreStore(
            snapshotURL: snapshotURL,
            lifecycleURL: directoryURL.appendingPathComponent("restore-lifecycle.json")
        )

        XCTAssertThrowsError(
            try relaunchedStore.prepareForLaunch(restorePreferenceEnabled: true)
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
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
