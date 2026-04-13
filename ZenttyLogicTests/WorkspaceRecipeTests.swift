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
}
