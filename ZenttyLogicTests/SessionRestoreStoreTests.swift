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

    func test_snapshot_persistence_drops_stale_async_generation_after_newer_sync_write() throws {
        let persistence = SessionRestoreSnapshotPersistence(store: store)
        let staleEnvelope = envelope(windowID: "window-stale")
        let currentEnvelope = envelope(windowID: "window-current")

        persistence.persistSynchronously(.saveSnapshot(currentEnvelope), generation: 2)
        persistence.persistAsync(.saveSnapshot(staleEnvelope), generation: 1)
        persistence.waitForPendingOperationsForTesting()

        let decision = try XCTUnwrap(store.prepareForLaunch(restorePreferenceEnabled: true))
        XCTAssertEqual(decision.envelope.workspace.windows.map(\.id), ["window-current"])
    }

    func test_snapshot_persistence_serializes_clean_exit_after_pending_live_write() throws {
        let persistence = SessionRestoreSnapshotPersistence(store: store)

        persistence.persistAsync(.saveSnapshot(envelope(windowID: "window-live")), generation: 1)
        persistence.persistSynchronously(.saveSnapshot(envelope(windowID: "window-clean-exit")), generation: 2)

        let decision = try XCTUnwrap(store.prepareForLaunch(restorePreferenceEnabled: true))
        XCTAssertEqual(decision.envelope.workspace.windows.map(\.id), ["window-clean-exit"])
    }

    func test_compact_snapshot_encoder_remains_compatible_with_pretty_printed_snapshots() throws {
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshotURL = directoryURL.appendingPathComponent("restore-snapshot.json")
        let data = try prettyEncoder.encode(envelope(windowID: "window-pretty"))
        try data.write(to: snapshotURL)

        let decision = try XCTUnwrap(store.prepareForLaunch(restorePreferenceEnabled: true))

        XCTAssertEqual(decision.envelope.workspace.windows.map(\.id), ["window-pretty"])
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

    func test_exporter_creates_cursor_restore_draft_for_live_session() throws {
        let paneID = PaneID("pane-cursor")
        let worklaneID = WorklaneID("worklane-main")
        let sessionID = "237d8c32-2a27-4850-8da8-3a110f13682c"
        let livePID: Int32 = 4242

        var worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                columns: [
                    PaneColumnState(
                        id: PaneColumnID("column-main"),
                        panes: [
                            PaneState(
                                id: paneID,
                                title: "Cursor",
                                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project")
                            ),
                        ],
                        width: 640,
                        focusedPaneID: paneID
                    ),
                ],
                focusedColumnID: PaneColumnID("column-main")
            )
        )
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].agentStatus = PaneAgentStatus(
            tool: .cursor,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            source: .explicit,
            origin: .explicitHook,
            confidence: .explicit,
            trackedPID: livePID,
            hasObservedRunning: true,
            sessionID: sessionID
        )

        let windowDrafts = try XCTUnwrap(
            SessionRestoreDraftExporter.makeWindowDrafts(
                windowID: WindowID("window-main"),
                worklanes: [worklane],
                isProcessAlive: { $0 == livePID }
            )
        )

        XCTAssertEqual(
            windowDrafts.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: paneID.rawValue,
                    kind: .agentResume,
                    toolName: "Cursor",
                    sessionID: sessionID,
                    workingDirectory: "/tmp/project",
                    trackedPID: livePID
                ),
            ]
        )
    }

    private func envelope(windowID: String) -> SessionRestoreEnvelope {
        SessionRestoreEnvelope(
            workspace: WorkspaceRecipe(
                windows: [
                    WorkspaceRecipe.Window(
                        id: windowID,
                        worklanes: [],
                        activeWorklaneID: nil
                    ),
                ]
            )
        )
    }

    func test_clean_exit_save_preserves_existing_restore_drafts_for_matching_panes() throws {
        let workspace = WorkspaceRecipe(
            windows: [
                WorkspaceRecipe.Window(
                    id: "window-main",
                    worklanes: [
                        WorkspaceRecipe.Worklane(
                            id: "main",
                            title: nil,
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

    func test_draft_exporter_allows_agy_continue_restore_from_working_directory_without_session_id() throws {
        let paneID = PaneID("pane-agy")
        let pane = PaneState(
            id: paneID,
            title: "Antigravity",
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project")
        )
        let status = PaneAgentStatus(
            tool: .agy,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: Date(),
            trackedPID: 4242,
            workingDirectory: "/tmp/project",
            sessionID: nil
        )
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
            paneStripState: PaneStripState(
                columns: [
                    PaneColumnState(
                        id: PaneColumnID("column-main"),
                        panes: [pane],
                        width: 800,
                        focusedPaneID: paneID
                    )
                ],
                focusedColumnID: PaneColumnID("column-main")
            ),
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(agentStatus: status)
            ]
        )

        let draftWindow = try XCTUnwrap(
            SessionRestoreDraftExporter.makeWindowDrafts(
                windowID: WindowID("window-main"),
                worklanes: [worklane],
                isProcessAlive: { $0 == 4242 }
            )
        )
        let draft = try XCTUnwrap(draftWindow.paneDrafts.first)

        XCTAssertEqual(draft.toolName, "Antigravity")
        XCTAssertEqual(draft.sessionID, "")
        XCTAssertEqual(draft.workingDirectory, "/tmp/project")
        XCTAssertEqual(AgentResumeCommandBuilder.command(for: draft), "agy --continue")
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
        let recipe = makeDefaultWorkspaceRecipe(title: nil, schemaVersion: nil)

        XCTAssertFalse(
            WorkspaceRecipeMeaningfulness.isMeaningful(
                recipe,
                defaultWorkingDirectory: "/Users/peter"
            )
        )
    }

    func test_meaningfulness_classifier_treats_custom_pane_title_as_meaningful() {
        var recipe = makeDefaultWorkspaceRecipe(
            title: nil,
            schemaVersion: WorkspaceRecipe.currentSchemaVersion
        )
        recipe.windows[0].worklanes[0].columns[0].panes[0].customTitle = "Nimbu API"

        XCTAssertTrue(
            WorkspaceRecipeMeaningfulness.isMeaningful(
                recipe,
                defaultWorkingDirectory: "/Users/peter"
            )
        )
    }

    func test_meaningfulness_classifier_treats_titles_schema_aware() {
        // Legacy recipes carry auto-generated "MAIN"/"WS N" junk — not meaningful.
        let legacyJunk = makeDefaultWorkspaceRecipe(title: "MAIN", schemaVersion: nil)
        XCTAssertFalse(
            WorkspaceRecipeMeaningfulness.isMeaningful(
                legacyJunk,
                defaultWorkingDirectory: "/Users/peter"
            )
        )

        // Versioned recipes store titles verbatim — any title means the user
        // named the lane, so the snapshot must be kept.
        let versionedExotic = makeDefaultWorkspaceRecipe(
            title: "MAIN",
            schemaVersion: WorkspaceRecipe.currentSchemaVersion
        )
        XCTAssertTrue(
            WorkspaceRecipeMeaningfulness.isMeaningful(
                versionedExotic,
                defaultWorkingDirectory: "/Users/peter"
            )
        )

        // An untitled versioned default workspace is still disposable.
        let versionedDefault = makeDefaultWorkspaceRecipe(
            title: nil,
            schemaVersion: WorkspaceRecipe.currentSchemaVersion
        )
        XCTAssertFalse(
            WorkspaceRecipeMeaningfulness.isMeaningful(
                versionedDefault,
                defaultWorkingDirectory: "/Users/peter"
            )
        )
    }

    private func makeDefaultWorkspaceRecipe(
        title: String?,
        schemaVersion: Int?
    ) -> WorkspaceRecipe {
        WorkspaceRecipe(
            schemaVersion: schemaVersion,
            windows: [
                WorkspaceRecipe.Window(
                    id: "window-main",
                    worklanes: [
                        WorkspaceRecipe.Worklane(
                            id: "main",
                            title: title,
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
    }
}
