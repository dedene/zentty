import XCTest
@testable import Zentty

final class WorkspaceRecipeTests: XCTestCase {
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
                title: "MAIN",
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
            title: "MAIN",
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

    func test_import_injects_restore_draft_prefill_for_supported_agent_pane() throws {
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
        XCTAssertEqual(pane.sessionRequest.prefillText, "claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c")
    }

    func test_import_injects_restore_draft_prefill_for_supported_codex_pane() throws {
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
        XCTAssertEqual(pane.sessionRequest.prefillText, "codex resume add-faq-section-landing")
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
        XCTAssertNil(pane.sessionRequest.prefillText)
    }

    func test_exporter_skips_agent_restore_draft_when_tracked_pid_is_not_alive() {
        let paneID = PaneID("pane-agent")
        let worklane = WorklaneState(
            id: WorklaneID("main"),
            title: "MAIN",
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
                            sessionID: "session-123"
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
            title: "MAIN",
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
                            sessionID: "session-123"
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
                    sessionID: "session-123",
                    workingDirectory: "/tmp/project",
                    trackedPID: 4242
                )
            ]
        )
    }
}
