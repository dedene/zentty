import XCTest
@testable import Zentty

/// Recipe v5: floats, PiPs and pills survive export → JSON → import, and
/// every walker that decides what a save keeps (meaningfulness, agent drafts,
/// draft merge) sees them.
final class WorkspaceRecipeFloatTests: XCTestCase {
    private let tileID = PaneID("pane-tile")
    private let floatID = PaneID("pane-float")
    private let pipID = PaneID("pane-pip")
    private let pillID = PaneID("pane-pill")
    private let temporaryID = PaneID("pane-temp")
    private let floatSessionID = "237d8c32-2a27-4850-8da8-3a110f13682c"

    // MARK: - Round trip

    func test_export_import_round_trips_float_pip_minimized_and_hidden() throws {
        let directory = try makeDirectory()
        var worklane = makeWorklane(directory: directory, floats: [
            FloatingPaneState(
                pane: PaneState(id: floatID, title: "logs"),
                mode: .floating,
                floatFrame: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
                stackOrder: 2,
                origin: FloatOrigin(columnIndex: 1)
            ),
            FloatingPaneState(
                pane: PaneState(id: pipID, title: "build"),
                mode: .pip(corner: .topLeft, order: 0),
                floatFrame: NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.3),
                stackOrder: 0,
                origin: nil
            ),
            FloatingPaneState(
                pane: PaneState(id: pillID, title: "server"),
                mode: .minimized(order: 0),
                floatFrame: NormalizedRect(x: 0.25, y: 0.25, width: 0.6, height: 0.6),
                stackOrder: 1,
                origin: nil
            ),
        ])
        worklane.floatsHidden = true
        worklane.focusedFloatID = floatID

        let restored = try roundTrip([worklane], directory: directory).worklanes[0]

        XCTAssertEqual(restored.paneStripState.panes.map(\.id), [tileID])
        XCTAssertEqual(restored.floatingPanes.map(\.pane.id), [floatID, pipID, pillID])
        XCTAssertEqual(
            restored.floatingPanes.map(\.mode),
            [.floating, .pip(corner: .topLeft, order: 0), .minimized(order: 0)]
        )
        XCTAssertEqual(restored.floatingPanes.map(\.floatFrame), worklane.floatingPanes.map(\.floatFrame))
        XCTAssertEqual(restored.floatingPanes.map(\.stackOrder), [2, 0, 1])
        XCTAssertEqual(restored.floatingPanes.map(\.origin), [FloatOrigin(columnIndex: 1), nil, nil])
        XCTAssertTrue(restored.floatsHidden)
        // Hidden floats never own focus, as in the live store.
        XCTAssertNil(restored.focusedFloatID)
        for id in [floatID, pipID, pillID] {
            XCTAssertNotNil(restored.auxiliaryStateByPaneID[id], "float \(id.rawValue) needs its aux state")
            XCTAssertEqual(restored.pane(id: id)?.sessionRequest.workingDirectory, directory.path)
            XCTAssertEqual(restored.pane(id: id)?.sessionRequest.surfaceContext, .tab)
        }
    }

    func test_temporary_float_not_exported() throws {
        let directory = try makeDirectory()
        var worklane = makeWorklane(directory: directory, floats: [
            makeFloat(temporaryID, mode: .pip(corner: .bottomRight, order: 0), stackOrder: 0),
            makeFloat(pipID, mode: .pip(corner: .bottomRight, order: 1), stackOrder: 1),
        ])
        worklane.auxiliaryStateByPaneID[temporaryID]?.lifetime = .temporary(
            owner: tileID,
            placement: .worklane,
            waitAfterCommand: false
        )
        worklane.focusedFloatID = temporaryID

        let window = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: worklane.id
        )
        let exported = window.worklanes[0]

        XCTAssertEqual(exported.floatingPanes?.map(\.pane.id), [pipID.rawValue])
        XCTAssertNil(exported.focusedFloatID, "a focused temporary float is not saved, so neither is its focus")

        let restored = WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": directory.path]
        ).worklanes[0]
        XCTAssertEqual(
            restored.floatingPanes.map(\.mode),
            [.pip(corner: .bottomRight, order: 0)],
            "the surviving PiP closes the gap the temporary one left"
        )
    }

    func test_worklane_without_floats_exports_like_v4() {
        let worklane = makeWorklane(directory: URL(fileURLWithPath: "/tmp"), floats: [])

        let exported = WorkspaceRecipeExporter.makeWindow(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: worklane.id
        ).worklanes[0]

        XCTAssertNil(exported.floatingPanes)
        XCTAssertNil(exported.floatsHidden)
        XCTAssertNil(exported.focusedFloatID)
    }

    func test_float_only_worklane_round_trips_and_focuses_front_float() throws {
        let directory = try makeDirectory()
        var worklane = WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 3,
            floatingPanes: [
                makeFloat(floatID, mode: .floating, stackOrder: 0),
                makeFloat(pipID, mode: .floating, stackOrder: 1),
            ]
        )
        for id in [floatID, pipID] {
            worklane.auxiliaryStateByPaneID[id] = PaneAuxiliaryState(
                presentation: PanePresentationState(cwd: directory.path)
            )
        }

        let restored = try roundTrip([worklane], directory: directory).worklanes[0]

        XCTAssertTrue(restored.paneStripState.columns.isEmpty)
        XCTAssertEqual(restored.floatingPanes.map(\.pane.id), [floatID, pipID])
        XCTAssertTrue(restored.hasLivePanes)
        XCTAssertEqual(restored.focusedPaneID, pipID, "a float-only worklane comes back focused on its front float")
    }

    func test_export_import_round_trips_float_sequence() throws {
        let directory = try makeDirectory()
        var front = makeFloat(floatID, mode: .floating, stackOrder: 1)
        front.sequence = 7
        var back = makeFloat(pipID, mode: .floating, stackOrder: 0)
        back.sequence = 3
        let worklane = makeWorklane(directory: directory, floats: [front, back])

        let restored = try roundTrip([worklane], directory: directory).worklanes[0]

        XCTAssertEqual(restored.floatingPanes.map(\.sequence), [7, 3])
        XCTAssertEqual(restored.allPanes.map(\.id), [tileID, pipID, floatID])
    }

    func test_import_without_sequence_falls_back_to_stack_order() {
        var first = recipeFloat(id: floatID.rawValue)
        first.stackOrder = 4
        var second = recipeFloat(id: pipID.rawValue)
        second.stackOrder = 2
        XCTAssertNil(first.sequence)

        let restored = importWindow(recipeWindow(worklane: recipeWorklane(floats: [first, second]))).worklanes[0]

        XCTAssertEqual(restored.floatingPanes.map(\.sequence), [4, 2])
    }

    func test_float_sequence_is_optional_on_the_wire() throws {
        let legacy = #"{"pane":{"id":"pn_a","workingDirectory":"/tmp"},"mode":"floating","frame":[0.1,0.1,0.5,0.5],"stackOrder":3}"#
        let decoded = try JSONDecoder().decode(WorkspaceRecipe.FloatingPane.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.sequence)
        XCTAssertEqual(decoded.stackOrder, 3)
    }

    // MARK: - Lenient import

    func test_import_drops_float_whose_id_is_already_a_tile() {
        let window = recipeWindow(worklane: recipeWorklane(floats: [
            recipeFloat(id: tileID.rawValue),
            recipeFloat(id: floatID.rawValue),
            recipeFloat(id: floatID.rawValue),
        ]))

        let restored = importWindow(window).worklanes[0]

        XCTAssertEqual(restored.paneStripState.panes.map(\.id), [tileID])
        XCTAssertEqual(restored.floatingPanes.map(\.pane.id), [floatID])
    }

    func test_import_degrades_malformed_float_fields() {
        var unknownMode = recipeFloat(id: floatID.rawValue)
        unknownMode.mode = "hologram"
        unknownMode.frame = [0.1, .nan, 0.5]
        var badCorner = recipeFloat(id: pipID.rawValue)
        badCorner.mode = "pip"
        badCorner.corner = "middle"
        badCorner.order = 7
        var minimized = recipeFloat(id: pillID.rawValue)
        minimized.mode = "minimized"
        minimized.order = nil
        minimized.originColumnIndex = -3

        let restored = importWindow(recipeWindow(worklane: recipeWorklane(floats: [unknownMode, badCorner, minimized])))
            .worklanes[0]

        XCTAssertEqual(
            restored.floatingPanes.map(\.mode),
            [.floating, .pip(corner: .bottomRight, order: 0), .minimized(order: 0)]
        )
        XCTAssertEqual(restored.floatingPanes[0].floatFrame, WorkspaceRecipe.FloatingPane.defaultFrame)
        XCTAssertEqual(restored.floatingPanes[2].origin, FloatOrigin(columnIndex: 0))
    }

    func test_import_moves_pips_beyond_the_corner_cap_to_the_pill_bar() {
        var oldest = recipeFloat(id: "pane-pip-0")
        oldest.mode = "pip"
        oldest.corner = "bottomRight"
        oldest.order = 0
        var middle = recipeFloat(id: "pane-pip-1")
        middle.mode = "pip"
        middle.corner = "bottomRight"
        middle.order = 1
        var newest = recipeFloat(id: "pane-pip-2")
        newest.mode = "pip"
        newest.corner = "bottomRight"
        newest.order = 2
        var pill = recipeFloat(id: pillID.rawValue)
        pill.mode = "minimized"
        pill.order = 0

        let restored = importWindow(recipeWindow(worklane: recipeWorklane(floats: [newest, oldest, pill, middle])))
            .worklanes[0]

        let modes = Dictionary(uniqueKeysWithValues: restored.floatingPanes.map { ($0.pane.id.rawValue, $0.mode) })
        XCTAssertEqual(modes["pane-pip-1"], .pip(corner: .bottomRight, order: 0))
        XCTAssertEqual(modes["pane-pip-2"], .pip(corner: .bottomRight, order: 1))
        XCTAssertEqual(modes[pillID.rawValue], .minimized(order: 0))
        XCTAssertEqual(modes["pane-pip-0"], .minimized(order: 1), "the oldest PiP goes to the pill bar, like a live eviction")
        XCTAssertLessThanOrEqual(
            FloatLayout.pips(in: restored.floatingPanes, corner: .bottomRight).count,
            FloatLayout.maxPipsPerCorner
        )
    }

    func test_import_drops_saved_float_focus_while_floats_are_hidden() {
        var worklane = recipeWorklane(floats: [recipeFloat(id: floatID.rawValue)])
        worklane.floatsHidden = true
        worklane.focusedFloatID = floatID.rawValue

        let restored = importWindow(recipeWindow(worklane: worklane)).worklanes[0]

        XCTAssertTrue(restored.floatsHidden)
        XCTAssertNil(restored.focusedFloatID)
    }

    func test_import_keeps_saved_float_focus_while_floats_are_shown() {
        var worklane = recipeWorklane(floats: [recipeFloat(id: floatID.rawValue)])
        worklane.focusedFloatID = floatID.rawValue

        let restored = importWindow(recipeWindow(worklane: worklane)).worklanes[0]

        XCTAssertEqual(restored.focusedFloatID, floatID)
    }

    func test_import_clamps_float_frames_into_the_canvas() {
        var oversized = recipeFloat(id: floatID.rawValue)
        oversized.frame = [-0.2, 0.9, 1.4, 0.5]
        var offCanvas = recipeFloat(id: pipID.rawValue)
        offCanvas.frame = [0.8, 0.7, 0.5, 0.5]

        let restored = importWindow(recipeWindow(worklane: recipeWorklane(floats: [oversized, offCanvas])))
            .worklanes[0]

        XCTAssertEqual(restored.floatingPanes[0].floatFrame, NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5))
        XCTAssertEqual(restored.floatingPanes[1].floatFrame, NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    // MARK: - Meaningfulness

    func test_float_only_worklane_recipe_is_meaningful() {
        let floatOnly = recipe(worklane: WorkspaceRecipe.Worklane(
            id: "main",
            title: nil,
            nextPaneNumber: 2,
            focusedColumnID: nil,
            columns: [],
            floatingPanes: [recipeFloat(id: floatID.rawValue)]
        ))
        XCTAssertTrue(WorkspaceRecipeMeaningfulness.isMeaningful(floatOnly, defaultWorkingDirectory: "/Users/peter"))

        let defaultTileAndFloat = recipe(worklane: recipeWorklane(floats: [recipeFloat(id: floatID.rawValue)]))
        XCTAssertTrue(
            WorkspaceRecipeMeaningfulness.isMeaningful(defaultTileAndFloat, defaultWorkingDirectory: "/Users/peter"),
            "a default tile beside a float must not discard the float"
        )

        let defaultTileOnly = recipe(worklane: recipeWorklane(floats: nil))
        XCTAssertFalse(WorkspaceRecipeMeaningfulness.isMeaningful(defaultTileOnly, defaultWorkingDirectory: "/Users/peter"))
    }

    // MARK: - Agent drafts

    func test_draft_exporter_includes_float_panes() {
        var worklane = makeWorklane(directory: URL(fileURLWithPath: "/tmp/project"), floats: [
            makeFloat(floatID, mode: .minimized(order: 0), stackOrder: 0),
            makeFloat(temporaryID, mode: .floating, stackOrder: 1),
        ])
        worklane.auxiliaryStateByPaneID[floatID] = agentAuxiliary(pid: 4242, sessionID: floatSessionID)
        var temporary = agentAuxiliary(pid: 4343, sessionID: "8f0d6c1e-5b2a-4c3d-9e7f-1a2b3c4d5e6f")
        temporary.lifetime = .temporary(owner: nil, placement: .worklane, waitAfterCommand: true)
        worklane.auxiliaryStateByPaneID[temporaryID] = temporary

        let drafts = SessionRestoreDraftExporter.makeWindowDrafts(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(drafts?.paneDrafts.map(\.paneID), [floatID.rawValue])
        XCTAssertEqual(drafts?.paneDrafts.first?.sessionID, floatSessionID)
    }

    func test_paneIDsByWindowID_includes_floats() {
        let workspace = recipe(worklane: recipeWorklane(floats: [recipeFloat(id: floatID.rawValue)]))
        let floatDraft = PaneRestoreDraft(
            paneID: floatID.rawValue,
            kind: .agentResume,
            toolName: "Codex",
            sessionID: "session-float",
            workingDirectory: "/tmp/project",
            trackedPID: 4242
        )
        let previous = SessionRestoreEnvelope(
            reason: .liveSnapshot,
            workspace: workspace,
            restoreDraftWindows: [SessionRestoreDraftWindow(windowID: "window-main", paneDrafts: [floatDraft])]
        )
        let cleanExit = SessionRestoreEnvelope(reason: .cleanExit, workspace: workspace)

        let merged = cleanExit.mergingMissingRestoreDrafts(from: previous)

        XCTAssertEqual(merged.restoreDraftWindows.flatMap(\.paneDrafts), [floatDraft])
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.RecipeFloats.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeFloat(_ id: PaneID, mode: FloatingPaneMode, stackOrder: Int) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: id, title: "shell"),
            mode: mode,
            floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            stackOrder: stackOrder,
            origin: nil
        )
    }

    /// One tile plus `floats`, every pane rooted in `directory`.
    private func makeWorklane(directory: URL, floats: [FloatingPaneState]) -> WorklaneState {
        var auxiliary = [tileID: PaneAuxiliaryState(presentation: PanePresentationState(cwd: directory.path))]
        for float in floats {
            auxiliary[float.pane.id] = PaneAuxiliaryState(presentation: PanePresentationState(cwd: directory.path))
        }
        return WorklaneState(
            id: WorklaneID("main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: tileID, title: "shell", width: 640)],
                focusedPaneID: tileID
            ),
            nextPaneNumber: 5,
            auxiliaryStateByPaneID: auxiliary,
            floatingPanes: floats
        )
    }

    /// Export → JSON → decode → migrate → import, like a relaunch.
    private func roundTrip(_ worklanes: [WorklaneState], directory: URL) throws -> WindowWorkspaceState {
        let recipe = WorkspaceRecipe(
            windows: [
                WorkspaceRecipeExporter.makeWindow(
                    windowID: WindowID("window-main"),
                    worklanes: worklanes,
                    activeWorklaneID: worklanes.first?.id
                ),
            ]
        )
        XCTAssertEqual(recipe.schemaVersion, 5)
        let decoded = WorkspaceRecipeMigration.migrate(
            try JSONDecoder().decode(WorkspaceRecipe.self, from: try JSONEncoder().encode(recipe))
        )
        XCTAssertEqual(decoded, recipe)
        return WorkspaceRecipeImporter.makeWorklanes(
            from: decoded.windows[0],
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": directory.path]
        )
    }

    private func importWindow(_ window: WorkspaceRecipe.Window) -> WindowWorkspaceState {
        WorkspaceRecipeImporter.makeWorklanes(
            from: window,
            windowID: WindowID("window-main"),
            layoutContext: .fallback,
            processEnvironment: ["HOME": "/tmp"]
        )
    }

    private func recipeFloat(id: String) -> WorkspaceRecipe.FloatingPane {
        WorkspaceRecipe.FloatingPane(
            pane: WorkspaceRecipe.Pane(id: id, titleSeed: nil, workingDirectory: "/Users/peter"),
            mode: "floating",
            frame: [0.2, 0.2, 0.6, 0.6],
            stackOrder: 0
        )
    }

    /// A default single-tile worklane (meaningless on its own) plus `floats`.
    private func recipeWorklane(floats: [WorkspaceRecipe.FloatingPane]?) -> WorkspaceRecipe.Worklane {
        WorkspaceRecipe.Worklane(
            id: "main",
            title: nil,
            nextPaneNumber: 2,
            focusedColumnID: "column-main",
            columns: [
                WorkspaceRecipe.Column(
                    id: "column-main",
                    width: 640,
                    focusedPaneID: tileID.rawValue,
                    lastFocusedPaneID: tileID.rawValue,
                    paneHeights: [480],
                    panes: [WorkspaceRecipe.Pane(id: tileID.rawValue, titleSeed: nil, workingDirectory: "/Users/peter")]
                ),
            ],
            floatingPanes: floats
        )
    }

    private func recipeWindow(worklane: WorkspaceRecipe.Worklane) -> WorkspaceRecipe.Window {
        WorkspaceRecipe.Window(id: "window-main", worklanes: [worklane], activeWorklaneID: worklane.id)
    }

    private func recipe(worklane: WorkspaceRecipe.Worklane) -> WorkspaceRecipe {
        WorkspaceRecipe(windows: [recipeWindow(worklane: worklane)], activeWindowID: "window-main")
    }

    private func agentAuxiliary(pid: Int32, sessionID: String) -> PaneAuxiliaryState {
        PaneAuxiliaryState(
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
                    trackedPID: pid,
                    workingDirectory: "/tmp/project",
                    sessionID: sessionID
                )
            ),
            presentation: PanePresentationState(cwd: "/tmp/project")
        )
    }
}
