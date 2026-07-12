import XCTest
@testable import Zentty

final class WorkspaceRecipeTests: XCTestCase {
    func test_window_frame_round_trips_and_missing_frame_decodes_as_nil() throws {
        let frame = WorkspaceRecipe.WindowFrame(
            x: 1721,
            y: -1,
            width: 1720,
            height: 1410,
            screenX: 0,
            screenY: 0,
            screenWidth: 3440,
            screenHeight: 1410
        )
        let window = WorkspaceRecipe.Window(
            id: "window-main",
            frame: frame,
            worklanes: [],
            activeWorklaneID: nil
        )

        let data = try JSONEncoder().encode(window)
        let restored = try JSONDecoder().decode(WorkspaceRecipe.Window.self, from: data)

        XCTAssertEqual(restored.frame, frame)
        XCTAssertEqual(restored.frame?.rect, NSRect(x: 1721, y: -1, width: 1720, height: 1410))
        XCTAssertEqual(restored.frame?.screenX, 0)
        XCTAssertEqual(restored.frame?.screenY, 0)
        XCTAssertEqual(restored.frame?.screenWidth, 3440)
        XCTAssertEqual(restored.frame?.screenHeight, 1410)

        let legacyData = try XCTUnwrap(
            """
            {
              "id": "legacy-window",
              "worklanes": [],
              "activeWorklaneID": null
            }
            """.data(using: .utf8)
        )
        let legacy = try JSONDecoder().decode(WorkspaceRecipe.Window.self, from: legacyData)

        XCTAssertNil(legacy.frame)
    }

    func test_exporter_persists_window_frame_when_available() throws {
        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            frame: NSRect(x: 14, y: 0, width: 1720, height: 1410),
            worklanes: [],
            activeWorklaneID: nil
        )

        XCTAssertEqual(window.frame?.rect, NSRect(x: 14, y: 0, width: 1720, height: 1410))
        XCTAssertNil(window.frame?.screenX)
        XCTAssertNil(window.frame?.screenY)
        XCTAssertNil(window.frame?.screenWidth)
        XCTAssertNil(window.frame?.screenHeight)
    }

    func test_export_and_import_preserves_window_worklanes_layout_and_focus() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.\(UUID().uuidString)", isDirectory: true)
        let apiDirectory = baseDirectory.appendingPathComponent("project-api", isDirectory: true)
        let webDirectory = baseDirectory.appendingPathComponent("project-web", isDirectory: true)
        let reviewDirectory = baseDirectory.appendingPathComponent("project-review", isDirectory: true)
        try FileManager.default.createDirectory(at: apiDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reviewDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let leftPaneID = PaneID("pane-left")
        let bottomPaneID = PaneID("pane-bottom")
        let rightPaneID = PaneID("pane-right")
        let reviewPaneID = PaneID("pane-review")
        let mainWorklaneID = WorklaneID("main")
        let reviewWorklaneID = WorklaneID("review")

        let worklanes = [
            WorklaneState(
                id: mainWorklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    columns: [
                        PaneColumnState(
                            id: PaneColumnID("column-left"),
                            panes: [
                                PaneState(id: leftPaneID, title: "shell", width: 420),
                                PaneState(id: bottomPaneID, title: "tests", width: 420),
                            ],
                            width: 420,
                            paneHeights: [320, 180],
                            focusedPaneID: bottomPaneID,
                            lastFocusedPaneID: bottomPaneID
                        ),
                        PaneColumnState(
                            id: PaneColumnID("column-right"),
                            panes: [
                                PaneState(id: rightPaneID, title: "editor", width: 360),
                            ],
                            width: 360,
                            paneHeights: [500],
                            focusedPaneID: rightPaneID,
                            lastFocusedPaneID: rightPaneID
                        ),
                    ],
                    focusedColumnID: PaneColumnID("column-left")
                ),
                nextPaneNumber: 4,
                auxiliaryStateByPaneID: [
                    leftPaneID: PaneAuxiliaryState(
                        presentation: PanePresentationState(
                            cwd: apiDirectory.path,
                            rememberedTitle: "API shell"
                        )
                    ),
                    bottomPaneID: PaneAuxiliaryState(
                        presentation: PanePresentationState(
                            cwd: apiDirectory.path,
                            rememberedTitle: "Test runner"
                        )
                    ),
                    rightPaneID: PaneAuxiliaryState(
                        presentation: PanePresentationState(
                            cwd: webDirectory.path,
                            rememberedTitle: "Editor"
                        )
                    ),
                ]
            ),
            WorklaneState(
                id: reviewWorklaneID,
                title: "REVIEW",
                paneStripState: PaneStripState(
                    panes: [
                        PaneState(id: reviewPaneID, title: "review", width: 640),
                    ],
                    focusedPaneID: reviewPaneID
                ),
                nextPaneNumber: 2,
                auxiliaryStateByPaneID: [
                    reviewPaneID: PaneAuxiliaryState(
                        presentation: PanePresentationState(
                            cwd: reviewDirectory.path,
                            rememberedTitle: "Review shell"
                        )
                    )
                ]
            ),
        ]

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: worklanes,
            activeWorklaneID: mainWorklaneID
        )

        XCTAssertEqual(window.activeWorklaneID, "main")
        XCTAssertEqual(window.worklanes.count, 2)
        XCTAssertEqual(window.worklanes[0].columns.map(\.width), [420.0, 360.0])
        XCTAssertEqual(
            window.worklanes[0].columns[0].panes.map(\.workingDirectory),
            [apiDirectory.path, apiDirectory.path]
        )
        XCTAssertEqual(window.worklanes[0].columns[0].panes.map(\.titleSeed), ["API shell", "Test runner"])

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        XCTAssertEqual(restored.activeWorklaneID, mainWorklaneID)
        XCTAssertEqual(restored.worklanes.map(\.id), [mainWorklaneID, reviewWorklaneID])
        XCTAssertEqual(restored.worklanes[0].paneStripState.columns.map(\.width), [CGFloat(420), CGFloat(360)])
        XCTAssertEqual(restored.worklanes[0].paneStripState.columns[0].paneHeights, [CGFloat(320), CGFloat(180)])
        XCTAssertEqual(restored.worklanes[0].paneStripState.focusedPaneID, bottomPaneID)
        XCTAssertEqual(restored.worklanes[0].auxiliaryStateByPaneID[rightPaneID]?.presentation.rememberedTitle, "Editor")
        XCTAssertEqual(
            restored.worklanes[0].paneStripState.panes.first(where: { $0.id == rightPaneID })?.sessionRequest.workingDirectory,
            webDirectory.path
        )
        XCTAssertEqual(
            restored.worklanes[0].paneStripState.panes.first(where: { $0.id == rightPaneID })?.sessionRequest.environmentVariables["ZENTTY_WINDOW_ID"],
            "window-main"
        )
    }

    @MainActor
    func test_export_and_import_after_last_pane_transfer_preserves_identical_panes() throws {
        let layoutContext = PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 1280,
            leadingVisibleInset: 0,
            sizing: .balanced
        )
        let sourceWorklaneID = WorklaneID("source")
        let targetWorklaneID = WorklaneID("target")
        let sourcePaneID = PaneID("source-pane")
        let targetPaneID = PaneID("target-pane")
        let sharedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.Transfer.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sharedDirectory)
        }
        let sharedCWD = sharedDirectory.path
        let sharedRequest = TerminalSessionRequest(
            workingDirectory: sharedCWD,
            command: "codex",
            surfaceContext: .window
        )
        let sharedAuxiliary = PaneAuxiliaryState(
            presentation: PanePresentationState(
                cwd: sharedCWD,
                rememberedTitle: "codex"
            )
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: sourceWorklaneID,
                    title: "SOURCE",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: sourcePaneID, title: "codex", sessionRequest: sharedRequest)],
                        focusedPaneID: sourcePaneID
                    ),
                    auxiliaryStateByPaneID: [sourcePaneID: sharedAuxiliary]
                ),
                WorklaneState(
                    id: targetWorklaneID,
                    title: "TARGET",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: targetPaneID, title: "codex", sessionRequest: sharedRequest)],
                        focusedPaneID: targetPaneID
                    ),
                    auxiliaryStateByPaneID: [targetPaneID: sharedAuxiliary]
                ),
            ],
            layoutContext: layoutContext,
            activeWorklaneID: sourceWorklaneID
        )

        store.transferPaneToWorklane(
            paneID: sourcePaneID,
            targetWorklaneID: targetWorklaneID,
            singleColumnWidth: layoutContext.singlePaneWidth
        )
        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: store.worklanes,
            activeWorklaneID: store.activeWorklaneID
        )
        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: layoutContext,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        XCTAssertEqual(window.worklanes.flatMap { $0.columns.flatMap { $0.panes.map(\.id) } }, [
            targetPaneID.rawValue,
            sourcePaneID.rawValue,
        ])
        XCTAssertEqual(restored.activeWorklaneID, targetWorklaneID)
        XCTAssertEqual(restored.worklanes.map(\.id), [targetWorklaneID])

        let restoredWorklane = try XCTUnwrap(restored.worklanes.first)
        XCTAssertEqual(restoredWorklane.paneStripState.panes.map(\.id), [targetPaneID, sourcePaneID])
        XCTAssertEqual(
            restoredWorklane.paneStripState.panes.map(\.sessionRequest.workingDirectory),
            [sharedCWD, sharedCWD]
        )
        XCTAssertEqual(
            restoredWorklane.auxiliaryStateByPaneID.values.compactMap(\.presentation.rememberedTitle).sorted(),
            ["codex", "codex"]
        )
    }

    func test_import_falls_back_when_saved_working_directory_is_missing() throws {
        let missingPath = "/path/that/does/not/exist/\(UUID().uuidString)"
        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "Main shell",
                                    workingDirectory: missingPath
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let paneID = try XCTUnwrap(restored.worklanes[0].paneStripState.focusedPaneID)
        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first(where: { $0.id == paneID }))
        let auxiliary = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[paneID])

        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/Users/peter")
        XCTAssertEqual(auxiliary.presentation.statusText, "Original path unavailable")
        XCTAssertEqual(auxiliary.presentation.rememberedTitle, "Main shell")
    }

    func test_export_and_restore_drop_stale_local_ssh_command_title() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.ssh-title", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let paneID = PaneID("pane-main")
        let worklaneID = WorklaneID("main")
        let worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory.path,
                            surfaceContext: .window
                        ),
                        width: 640
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: workingDirectory.path,
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        )
                    ),
                    presentation: PanePresentationState(
                        cwd: workingDirectory.path,
                        rememberedTitle: "ssh root@203.0.113.10"
                    )
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: worklaneID
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let summary = WorklaneHeaderSummaryBuilder.summary(for: try XCTUnwrap(restored.worklanes.first))

        XCTAssertEqual(summary.focusedLabel, WorklaneContextFormatter.formattedWorkingDirectory(workingDirectory.path, branch: nil))
        XCTAssertNil(restored.worklanes[0].auxiliaryStateByPaneID[paneID]?.presentation.rememberedTitle)
    }

    func test_export_moves_local_live_process_title_to_last_activity() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.last-activity", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let paneID = PaneID("pane-main")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory.path,
                            surfaceContext: .window
                        ),
                        width: 640
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    metadata: TerminalMetadata(
                        title: "cmatrix -C cyan",
                        currentWorkingDirectory: workingDirectory.path,
                        processName: "cmatrix",
                        gitBranch: nil
                    ),
                    presentation: PanePresentationState(
                        cwd: workingDirectory.path,
                        rememberedTitle: "cmatrix -C cyan"
                    )
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: WorklaneID("main")
        )

        let pane = try XCTUnwrap(window.worklanes.first?.columns.first?.panes.first)
        XCTAssertNil(pane.titleSeed)
        XCTAssertEqual(pane.lastActivityTitle, "cmatrix -C cyan")
    }

    func test_export_preserves_restored_last_activity_when_no_new_command_started() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.restored-last-activity", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let paneID = PaneID("pane-main")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory.path,
                            surfaceContext: .window
                        ),
                        width: 640
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    metadata: TerminalMetadata(
                        title: workingDirectory.path,
                        currentWorkingDirectory: workingDirectory.path,
                        processName: "zsh",
                        gitBranch: nil
                    ),
                    presentation: PanePresentationState(
                        cwd: workingDirectory.path,
                        lastActivityTitle: "cmatrix -C cyan"
                    )
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: WorklaneID("main")
        )

        let pane = try XCTUnwrap(window.worklanes.first?.columns.first?.panes.first)
        XCTAssertNil(pane.titleSeed)
        XCTAssertEqual(pane.lastActivityTitle, "cmatrix -C cyan")
    }

    func test_export_persists_last_run_command() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.last-run-command", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let paneID = PaneID("pane-main")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory.path,
                            surfaceContext: .window
                        ),
                        width: 640
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        metadata: TerminalMetadata(
                            title: workingDirectory.path,
                            currentWorkingDirectory: workingDirectory.path,
                            processName: "zsh",
                            gitBranch: nil
                        ),
                        lastRunCommand: "pnpm start:staging\nnpm run smoke"
                    ),
                    presentation: PanePresentationState(
                        cwd: workingDirectory.path,
                        lastActivityTitle: "pnpm start:staging"
                    )
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: WorklaneID("main")
        )

        let pane = try XCTUnwrap(window.worklanes.first?.columns.first?.panes.first)
        XCTAssertEqual(pane.lastRunCommand, "pnpm start:staging\nnpm run smoke")
    }

    func test_export_drops_last_run_command_for_remote_shell() throws {
        let paneID = PaneID("pane-main")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: "/Users/peter",
                            surfaceContext: .window
                        ),
                        width: 640
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .remote,
                            path: "/srv/app",
                            home: "/home/peter",
                            user: "peter",
                            host: "example.com"
                        ),
                        lastRunCommand: "pnpm start:staging"
                    ),
                    presentation: PanePresentationState(cwd: "/srv/app")
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: WorklaneID("main")
        )

        let pane = try XCTUnwrap(window.worklanes.first?.columns.first?.panes.first)
        XCTAssertNil(pane.workingDirectory)
        XCTAssertNil(pane.lastRunCommand)
    }

    func test_import_restores_last_run_command_as_one_shot() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.import-last-run-command", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "shell",
                                    workingDirectory: workingDirectory.path,
                                    lastActivityTitle: "pnpm start:staging",
                                    lastRunCommand: "pnpm start:staging\nnpm run smoke"
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first)
        let auxiliary = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[pane.id])
        XCTAssertEqual(auxiliary.raw.lastRunCommand, "pnpm start:staging\nnpm run smoke")
        XCTAssertEqual(auxiliary.raw.restoredRerunnableCommand, "pnpm start:staging\nnpm run smoke")
    }

    func test_import_drops_rerunnable_command_when_working_directory_is_missing() throws {
        let missingPath = "/path/that/does/not/exist/\(UUID().uuidString)"
        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "shell",
                                    workingDirectory: missingPath,
                                    lastActivityTitle: "pnpm start:staging",
                                    lastRunCommand: "pnpm start:staging"
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first)
        let auxiliary = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[pane.id])
        XCTAssertEqual(auxiliary.presentation.statusText, "Original path unavailable")
        XCTAssertNil(auxiliary.raw.lastRunCommand)
        XCTAssertNil(auxiliary.raw.restoredRerunnableCommand)
    }

    func test_import_legacy_last_activity_status_is_not_rerunnable() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.legacy-status-rerun", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "shell",
                                    workingDirectory: workingDirectory.path,
                                    lastActivityTitle: "\u{273b} we need to...me ago, somehow (Branch)"
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first)
        let auxiliary = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[pane.id])
        XCTAssertEqual(auxiliary.presentation.lastActivityTitle, "\u{273b} we need to...me ago, somehow (Branch)")
        XCTAssertNil(auxiliary.raw.restoredRerunnableCommand)
    }

    func test_export_drops_restored_generated_pane_title_as_last_activity() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.generated-pane-last-activity", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let paneID = PaneID("pane-main")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory.path,
                            surfaceContext: .window
                        ),
                        width: 640
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    metadata: TerminalMetadata(
                        title: workingDirectory.path,
                        currentWorkingDirectory: workingDirectory.path,
                        processName: "zsh",
                        gitBranch: nil
                    ),
                    presentation: PanePresentationState(
                        cwd: workingDirectory.path,
                        lastActivityTitle: "pane 13"
                    )
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: WorklaneID("main")
        )

        let pane = try XCTUnwrap(window.worklanes.first?.columns.first?.panes.first)
        XCTAssertNil(pane.titleSeed)
        XCTAssertNil(pane.lastActivityTitle)
    }

    func test_import_shows_legacy_local_process_title_as_last_activity() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.legacy-last-activity", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "cmatrix -C cyan",
                                    workingDirectory: workingDirectory.path
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let paneID = try XCTUnwrap(restored.worklanes[0].paneStripState.focusedPaneID)
        let presentation = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[paneID]?.presentation)

        XCTAssertNil(presentation.rememberedTitle)
        XCTAssertEqual(presentation.lastActivityTitle, "cmatrix -C cyan")
    }

    func test_import_keeps_legacy_single_token_hyphenated_title_as_title_seed() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.legacy-title-seed", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "api-server",
                                    workingDirectory: workingDirectory.path
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let paneID = try XCTUnwrap(restored.worklanes[0].paneStripState.focusedPaneID)
        let presentation = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[paneID]?.presentation)

        XCTAssertEqual(presentation.rememberedTitle, "api-server")
        XCTAssertNil(presentation.lastActivityTitle)
    }

    func test_exporter_does_not_persist_volatile_agent_status_title_seed() {
        let paneID = PaneID("pane-main")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "Ready | zentty")],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    presentation: PanePresentationState(
                        cwd: "/tmp/project",
                        rememberedTitle: "Ready | zentty",
                        recognizedTool: .codex
                    )
                )
            ]
        )

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: worklane.id
        )

        XCTAssertNil(window.worklanes[0].columns[0].panes[0].titleSeed)
    }

    func test_import_auto_runs_restore_draft_command_for_supported_agent_pane() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.resume", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "Claude",
                                    workingDirectory: workingDirectory.path
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )
        let restoreDraftWindow = SessionRestoreDraftWindow(
            windowID: "window-main",
            paneDrafts: [
                PaneRestoreDraft(
                    paneID: "pane-main",
                    kind: .agentResume,
                    toolName: "Claude Code",
                    sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c",
                    workingDirectory: workingDirectory.path,
                    trackedPID: 4242
                )
            ]
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            restoreDraftWindow: restoreDraftWindow,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first)
        let auxiliary = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[pane.id])
        XCTAssertEqual(pane.sessionRequest.command, "claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c")
        XCTAssertNil(pane.sessionRequest.prefillText)
        XCTAssertEqual(auxiliary.raw.restoredAgentRestoreDraft, restoreDraftWindow.paneDrafts[0])
        XCTAssertTrue(auxiliary.raw.restoredAgentAutoResumePending)
    }

    func test_import_auto_runs_restore_draft_command_for_supported_codex_pane() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.codex-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "Codex",
                                    workingDirectory: workingDirectory.path
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )
        let restoreDraftWindow = SessionRestoreDraftWindow(
            windowID: "window-main",
            paneDrafts: [
                PaneRestoreDraft(
                    paneID: "pane-main",
                    kind: .agentResume,
                    toolName: "Codex",
                    sessionID: "add-faq-section-landing",
                    workingDirectory: workingDirectory.path,
                    trackedPID: 4242
                )
            ]
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            restoreDraftWindow: restoreDraftWindow,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first)
        let auxiliary = try XCTUnwrap(restored.worklanes[0].auxiliaryStateByPaneID[pane.id])
        XCTAssertEqual(pane.sessionRequest.command, "codex resume add-faq-section-landing")
        XCTAssertNil(pane.sessionRequest.prefillText)
        XCTAssertEqual(auxiliary.raw.restoredAgentRestoreDraft, restoreDraftWindow.paneDrafts[0])
        XCTAssertTrue(auxiliary.raw.restoredAgentAutoResumePending)
    }

    func test_import_skips_restore_draft_prefill_for_invalid_claude_session_id() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceRecipe.claude-invalid-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let window = WorkspaceRecipe.Window(
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
                            focusedPaneID: "pane-main",
                            lastFocusedPaneID: "pane-main",
                            paneHeights: [480],
                            panes: [
                                WorkspaceRecipe.Pane(
                                    id: "pane-main",
                                    titleSeed: "Claude",
                                    workingDirectory: workingDirectory.path
                                )
                            ]
                        )
                    ]
                )
            ],
            activeWorklaneID: "main"
        )
        let restoreDraftWindow = SessionRestoreDraftWindow(
            windowID: "window-main",
            paneDrafts: [
                PaneRestoreDraft(
                    paneID: "pane-main",
                    kind: .agentResume,
                    toolName: "Claude Code",
                    sessionID: "cli-pane-management",
                    workingDirectory: workingDirectory.path,
                    trackedPID: 4242
                )
            ]
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            restoreDraftWindow: restoreDraftWindow,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        let pane = try XCTUnwrap(restored.worklanes[0].paneStripState.panes.first)
        XCTAssertNil(pane.sessionRequest.command)
        XCTAssertNil(pane.sessionRequest.prefillText)
    }

    func test_exporter_skips_agent_restore_draft_when_tracked_pid_is_not_alive() {
        let paneID = PaneID("pane-agent")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Claude")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: PaneAgentStatus(
                            tool: .claudeCode,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: "/tmp/project",
                            sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c"
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { _ in false }
        )

        XCTAssertNil(drafts)
    }

    func test_exporter_persists_agent_restore_draft_when_tracked_pid_is_alive_even_if_idle() {
        let paneID = PaneID("pane-agent")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Claude")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: PaneAgentStatus(
                            tool: .claudeCode,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: "/tmp/project",
                            sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c"
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: "pane-agent",
                    kind: .agentResume,
                    toolName: "Claude Code",
                    sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }

    func test_exporter_persists_hermes_restore_draft_when_tracked_pid_and_session_id_exist() throws {
        let paneID = PaneID("pane-hermes")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Hermes")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: PaneAgentStatus(
                            tool: .hermes,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: "/tmp/project",
                            sessionID: "20260525_154137_ca1d63"
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 4242 }
        )

        let draft = drafts?.paneDrafts.first
        XCTAssertEqual(draft?.toolName, "Hermes Agent")
        XCTAssertEqual(draft?.sessionID, "20260525_154137_ca1d63")
        XCTAssertEqual(draft?.trackedPID, 4242)
        XCTAssertEqual(AgentResumeCommandBuilder.command(for: try XCTUnwrap(draft)), "hermes --resume 20260525_154137_ca1d63")
    }

    func test_exporter_recovers_hermes_restore_draft_from_live_descendant_when_tracked_pid_is_missing() throws {
        let paneID = PaneID("pane-hermes")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Hermes")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        paneRootPID: 61825,
                        agentStatus: PaneAgentStatus(
                            tool: .hermes,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: nil,
                            workingDirectory: "/tmp/project",
                            sessionID: "20260525_163202_f0218c"
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 62132 },
            resolveLiveAgentPID: { tool, rootPID in
                XCTAssertEqual(tool, .hermes)
                XCTAssertEqual(rootPID, 61825)
                return 62132
            }
        )

        let draft = drafts?.paneDrafts.first
        XCTAssertEqual(draft?.toolName, "Hermes Agent")
        XCTAssertEqual(draft?.sessionID, "20260525_163202_f0218c")
        XCTAssertEqual(draft?.trackedPID, 62132)
        XCTAssertEqual(AgentResumeCommandBuilder.command(for: try XCTUnwrap(draft)), "hermes --resume 20260525_163202_f0218c")
    }

    func test_exporter_skips_hermes_restore_draft_when_missing_tracked_pid_has_no_live_descendant() {
        let paneID = PaneID("pane-hermes")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Hermes")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        paneRootPID: 61825,
                        agentStatus: PaneAgentStatus(
                            tool: .hermes,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: nil,
                            workingDirectory: "/tmp/project",
                            sessionID: "20260525_163202_f0218c"
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { _ in false },
            resolveLiveAgentPID: { _, _ in nil }
        )

        XCTAssertNil(drafts)
    }

    func test_exporter_recovers_hidden_hermes_restore_draft_from_live_descendant_when_tracked_pid_is_missing() throws {
        let paneID = PaneID("pane-hermes")
        var reducerState = PaneAgentReducerState()
        let baseTime = Date(timeIntervalSince1970: 1_778_000_000)
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: AgentTool.hermes.displayName,
                text: nil,
                lifecycleEvent: .update,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                sessionID: "20260525_163202_f0218c",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: "/tmp/project"
            ),
            now: baseTime
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: AgentTool.hermes.displayName,
                text: nil,
                lifecycleEvent: .update,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                sessionID: "20260525_163202_f0218c",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: "/tmp/project"
            ),
            now: baseTime.addingTimeInterval(5)
        )

        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Hermes")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        paneRootPID: 61825,
                        agentStatus: nil,
                        agentReducerState: reducerState
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 62132 },
            resolveLiveAgentPID: { tool, rootPID in
                XCTAssertEqual(tool, .hermes)
                XCTAssertEqual(rootPID, 61825)
                return 62132
            }
        )

        let draft = drafts?.paneDrafts.first
        XCTAssertEqual(draft?.toolName, "Hermes Agent")
        XCTAssertEqual(draft?.sessionID, "20260525_163202_f0218c")
        XCTAssertEqual(draft?.trackedPID, 62132)
        XCTAssertEqual(AgentResumeCommandBuilder.command(for: try XCTUnwrap(draft)), "hermes --resume 20260525_163202_f0218c")
    }

    func test_exporter_persists_pi_restore_draft_without_session_id_when_cwd_and_pid_exist() {
        let paneID = PaneID("pane-pi")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Pi")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: PaneAgentStatus(
                            tool: .pi,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: "/tmp/project",
                            sessionID: nil
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 4242 }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: "pane-pi",
                    kind: .agentResume,
                    toolName: "Pi",
                    sessionID: "",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }

    func test_exporter_skips_pi_restore_draft_without_session_id_when_cwd_is_missing() {
        let paneID = PaneID("pane-pi")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Pi")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        agentStatus: PaneAgentStatus(
                            tool: .pi,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: nil,
                            sessionID: nil
                        )
                    )
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 4242 }
        )

        XCTAssertNil(drafts)
    }

    func test_exporter_persists_gemini_restore_draft_without_session_id_when_cwd_and_pid_exist() {
        let paneID = PaneID("pane-gemini")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Gemini")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: PaneAgentStatus(
                            tool: .gemini,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: "/tmp/project",
                            sessionID: nil
                        )
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 4242 }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: "pane-gemini",
                    kind: .agentResume,
                    toolName: "Gemini",
                    sessionID: "",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }

    func test_exporter_prefers_live_agent_status_over_restored_agent_restore_draft() {
        let paneID = PaneID("pane-agent")
        let restoredDraft = PaneRestoreDraft(
            paneID: "pane-agent",
            kind: .agentResume,
            toolName: "Claude Code",
            sessionID: "old-session",
            workingDirectory: "/tmp/old-project",
            trackedPID: 1111
        )
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Claude")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: PaneAgentStatus(
                            tool: .codex,
                            state: .idle,
                            text: nil,
                            artifactLink: nil,
                            updatedAt: Date(),
                            trackedPID: 4242,
                            workingDirectory: "/tmp/project",
                            sessionID: "new-session"
                        ),
                        restoredAgentRestoreDraft: restoredDraft
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 4242 }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: "pane-agent",
                    kind: .agentResume,
                    toolName: "Codex",
                    sessionID: "new-session",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }

    func test_exporter_keeps_restored_agent_restore_draft_when_original_pid_is_dead() {
        let paneID = PaneID("pane-agent")
        let restoredDraft = PaneRestoreDraft(
            paneID: "pane-agent",
            kind: .agentResume,
            toolName: "Claude Code",
            sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c",
            workingDirectory: "/tmp/old-project",
            trackedPID: 4242
        )
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "Claude",
                        sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project")
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        restoredAgentRestoreDraft: restoredDraft
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: "pane-agent",
                    kind: .agentResume,
                    toolName: "Claude Code",
                    sessionID: "237d8c32-2a27-4850-8da8-3a110f13682c",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }

    func test_exporter_keeps_restored_codex_restore_draft_without_live_identity_after_resume_command() {
        let paneID = PaneID("pane-agent")
        let restoredDraft = PaneRestoreDraft(
            paneID: "pane-agent",
            kind: .agentResume,
            toolName: "Codex",
            sessionID: "019e4548-2fab-7542-9d5b-378a5da96fa5",
            workingDirectory: "/tmp/old-project",
            trackedPID: 4242
        )
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "Codex",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: "/tmp/project",
                            command: "codex resume 019e4548-2fab-7542-9d5b-378a5da96fa5"
                        )
                    )
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        shellActivityState: .commandRunning,
                        lastRunCommand: "codex resume 019e4548-2fab-7542-9d5b-378a5da96fa5",
                        restoredAgentRestoreDraft: restoredDraft
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
                PaneRestoreDraft(
                    paneID: "pane-agent",
                    kind: .agentResume,
                    toolName: "Codex",
                    sessionID: "019e4548-2fab-7542-9d5b-378a5da96fa5",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }

    func test_exporter_persists_idle_codex_restore_draft_after_visible_status_expires() {
        let paneID = PaneID("pane-agent")
        let startedAt = Date(timeIntervalSince1970: 100)
        let expiredAt = startedAt.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow + 10)
        var reducerState = PaneAgentReducerState()

        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("main"),
                paneID: paneID,
                signalKind: .pid,
                state: nil,
                pid: 4242,
                pidEvent: .attach,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                sessionID: "session-codex",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("main"),
                paneID: paneID,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-codex",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(1)
        )
        reducerState.apply(
            AgentStatusPayload(
                worklaneID: WorklaneID("main"),
                paneID: paneID,
                state: .idle,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-codex",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
            now: startedAt.addingTimeInterval(2)
        )
        reducerState.sweep(now: expiredAt, isProcessAlive: { $0 == 4242 })

        XCTAssertNil(reducerState.reducedStatus(now: expiredAt))
        XCTAssertEqual(reducerState.sessionsByID["session-codex"]?.trackedPID, 4242)

        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "Codex")
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/tmp/project",
                            home: "/Users/peter",
                            user: "peter",
                            host: nil
                        ),
                        agentStatus: reducerState.reducedStatus(now: expiredAt),
                        agentReducerState: reducerState
                    ),
                    presentation: PanePresentationState(cwd: "/tmp/project")
                )
            ]
        )

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { $0 == 4242 }
        )

        XCTAssertEqual(
            drafts?.paneDrafts,
            [
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
    }

    func test_fresh_recipe_carries_current_schema_version_and_legacy_decodes_nil() throws {
        let fresh = WorkspaceRecipe(windows: [])
        XCTAssertEqual(fresh.schemaVersion, WorkspaceRecipe.currentSchemaVersion)

        let roundTripped = try JSONDecoder().decode(
            WorkspaceRecipe.self,
            from: JSONEncoder().encode(fresh)
        )
        XCTAssertEqual(roundTripped.schemaVersion, WorkspaceRecipe.currentSchemaVersion)

        let legacyData = try XCTUnwrap(
            """
            {
              "windows": [],
              "activeWindowID": null
            }
            """.data(using: .utf8)
        )
        let legacy = try JSONDecoder().decode(WorkspaceRecipe.self, from: legacyData)
        XCTAssertNil(legacy.schemaVersion)
    }

    func test_versioned_import_keeps_exotic_titles_verbatim() {
        let window = makeTitleFixtureWindow(titles: ["MAIN", "WS 3", "Nimbu support", nil])
        let migrated = WorkspaceRecipeMigration.migrate(
            WorkspaceRecipe(schemaVersion: WorkspaceRecipe.currentSchemaVersion, windows: [window])
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: migrated.windows[0],
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        XCTAssertEqual(restored.worklanes.map(\.title), ["MAIN", "WS 3", "Nimbu support", nil])
    }

    func test_unversioned_import_sanitizes_legacy_generated_titles() {
        let window = makeTitleFixtureWindow(titles: ["MAIN", "WS 3", "   ", "Nimbu support"])
        let migrated = WorkspaceRecipeMigration.migrate(
            WorkspaceRecipe(schemaVersion: nil, windows: [window])
        )

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: migrated.windows[0],
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/Users/peter", "USER": "peter"]
        )

        XCTAssertEqual(restored.worklanes.map(\.title), [nil, nil, nil, "Nimbu support"])
    }

    func test_export_writes_worklane_title_verbatim() {
        let titles: [String?] = ["MAIN", "Nimbu support", nil]
        let worklanes = titles.enumerated().map { index, title in
            WorklaneState(
                id: WorklaneID("worklane-\(index)"),
                title: title,
                paneStripState: PaneStripState(columns: [], focusedColumnID: nil)
            )
        }

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: worklanes,
            activeWorklaneID: worklanes.first?.id
        )

        XCTAssertEqual(window.worklanes.map(\.title), ["MAIN", "Nimbu support", nil])
    }

    func test_worklane_state_normalizes_title_at_init() {
        let strip = PaneStripState(columns: [], focusedColumnID: nil)

        XCTAssertEqual(
            WorklaneState(id: WorklaneID("a"), title: "  padded  ", paneStripState: strip).title,
            "padded"
        )
        XCTAssertNil(WorklaneState(id: WorklaneID("b"), title: "   ", paneStripState: strip).title)
        XCTAssertNil(WorklaneState(id: WorklaneID("c"), title: "", paneStripState: strip).title)
        XCTAssertNil(WorklaneState(id: WorklaneID("d"), title: nil, paneStripState: strip).title)
    }

    private func makeTitleFixtureWindow(titles: [String?]) -> WorkspaceRecipe.Window {
        WorkspaceRecipe.Window(
            id: "window-main",
            worklanes: titles.enumerated().map { index, title in
                WorkspaceRecipe.Worklane(
                    id: "worklane-\(index)",
                    title: title,
                    nextPaneNumber: 1,
                    focusedColumnID: nil,
                    columns: []
                )
            },
            activeWorklaneID: "worklane-0"
        )
    }
}
