import XCTest
@testable import Zentty

final class WorkspaceTemplateImporterTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.WorkspaceTemplateImporter.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func test_imports_bookmark_with_runnable_command_as_command_field() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: "yes-this-runs"),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertTrue(result.fallbacks.isEmpty)
        let pane = result.worklane.paneStripState.panes.first!
        XCTAssertEqual(pane.sessionRequest.command, "yes-this-runs")
        XCTAssertNil(pane.sessionRequest.prefillText)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, temporaryDirectoryURL.path)
    }

    func test_imports_missing_command_as_prefillText_and_reports_fallback() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: "definitely-not-installed"),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in false }
        )

        XCTAssertEqual(result.fallbacks.count, 1)
        switch result.fallbacks.first?.kind {
        case .missingCommand(let command):
            XCTAssertEqual(command, "definitely-not-installed")
        default:
            XCTFail("Expected missingCommand fallback, got \(String(describing: result.fallbacks.first))")
        }

        let pane = result.worklane.paneStripState.panes.first!
        XCTAssertNil(pane.sessionRequest.command, "Missing command must NOT be set as auto-Enter command")
        XCTAssertEqual(pane.sessionRequest.prefillText, "definitely-not-installed", "Missing command should fall back to prefillText (no auto-Enter)")
    }

    func test_imports_bookmark_with_missing_cwd_falls_back_to_home_and_reports() {
        let bogusPath = "/this/path/does/not/exist/\(UUID().uuidString)"
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(id: "p1", workingDirectory: bogusPath, command: nil),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertEqual(result.fallbacks.count, 1)
        switch result.fallbacks.first?.kind {
        case .missingWorkingDirectory(let requested, _):
            XCTAssertEqual(requested, bogusPath)
        default:
            XCTFail("Expected missingWorkingDirectory fallback")
        }

        let pane = result.worklane.paneStripState.panes.first!
        XCTAssertNotEqual(pane.sessionRequest.workingDirectory, bogusPath)
    }

    func test_imports_preset_uses_fallback_working_directory() {
        let template = makeTemplate(
            kind: .preset,
            panes: [
                makePane(id: "p1", workingDirectory: nil, command: nil),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: temporaryDirectoryURL.path,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertTrue(result.fallbacks.isEmpty)
        XCTAssertEqual(result.worklane.paneStripState.panes.first?.sessionRequest.workingDirectory, temporaryDirectoryURL.path)
    }

    func test_imported_worklane_carries_template_id_as_origin() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: nil)]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertEqual(result.worklane.bookmarkOriginID, template.id)
    }

    func test_import_normalizes_single_column_width_to_current_single_pane_width() {
        let context = PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 1800,
            leadingVisibleInset: 0,
            sizing: .balanced
        )
        let template = makeTemplate(
            kind: .bookmark,
            panes: [makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: nil)]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: context,
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertEqual(result.worklane.paneStripState.columns.first?.width, context.singlePaneWidth)
    }

    func test_import_scales_multi_column_widths_from_captured_readable_width() {
        var template = WorkspaceTemplate(
            name: "Scaled",
            kind: .bookmark,
            capturedReadableWidth: 600,
            focusedColumnID: "left",
            columns: [
                WorkspaceTemplate.Column(
                    id: "left",
                    width: 200,
                    focusedPaneID: "p1",
                    lastFocusedPaneID: "p1",
                    paneHeights: [1],
                    panes: [makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: nil)]
                ),
                WorkspaceTemplate.Column(
                    id: "right",
                    width: 400,
                    focusedPaneID: "p2",
                    lastFocusedPaneID: "p2",
                    paneHeights: [1],
                    panes: [makePane(id: "p2", workingDirectory: temporaryDirectoryURL.path, command: nil)]
                ),
            ]
        )
        let context = PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 1200,
            leadingVisibleInset: 100,
            sizing: .balanced
        )
        template.capturedReadableWidth = Double(context.readableWidth / 2)

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: context,
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        let widths = result.worklane.paneStripState.columns.map(\.width)
        XCTAssertEqual(widths[0], 400, accuracy: 0.001)
        XCTAssertEqual(widths[1], 800, accuracy: 0.001)
    }

    func test_import_keeps_legacy_multi_column_widths_without_captured_readable_width() {
        let template = WorkspaceTemplate(
            name: "Legacy",
            kind: .bookmark,
            focusedColumnID: "left",
            columns: [
                WorkspaceTemplate.Column(
                    id: "left",
                    width: 250,
                    focusedPaneID: "p1",
                    lastFocusedPaneID: "p1",
                    paneHeights: [1],
                    panes: [makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: nil)]
                ),
                WorkspaceTemplate.Column(
                    id: "right",
                    width: 350,
                    focusedPaneID: "p2",
                    lastFocusedPaneID: "p2",
                    paneHeights: [1],
                    panes: [makePane(id: "p2", workingDirectory: temporaryDirectoryURL.path, command: nil)]
                ),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertEqual(result.worklane.paneStripState.columns.map(\.width), [250, 350])
    }

    func test_decodes_template_payload_without_captured_readable_width() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "id": "B99AAE70-EF4D-4739-AFB0-7C6FB5857001",
          "name": "Legacy",
          "kind": "bookmark",
          "title": null,
          "color": null,
          "projectRoot": null,
          "nextPaneNumber": 1,
          "focusedColumnID": "c0",
          "columns": [
            {
              "id": "c0",
              "width": 600,
              "focusedPaneID": "p1",
              "lastFocusedPaneID": "p1",
              "paneHeights": [1],
              "panes": [
                {
                  "id": "p1",
                  "titleSeed": null,
                  "workingDirectory": null,
                  "command": null,
                  "environment": {},
                  "wasUserEdited": false
                }
              ]
            }
          ],
          "pinned": false,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "lastUsedAt": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let template = try decoder.decode(WorkspaceTemplate.self, from: Data(payload.utf8))

        XCTAssertNil(template.capturedReadableWidth)
    }

    func test_import_allocates_fresh_ids_and_remaps_focus_references() {
        let template = WorkspaceTemplate(
            name: "Focused",
            kind: .bookmark,
            focusedColumnID: "c0",
            columns: [
                WorkspaceTemplate.Column(
                    id: "c0",
                    width: 600,
                    focusedPaneID: "p2",
                    lastFocusedPaneID: "p2",
                    paneHeights: [0.4, 0.6],
                    panes: [
                        makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: nil),
                        makePane(id: "p2", workingDirectory: temporaryDirectoryURL.path, command: nil),
                    ]
                ),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        let column = result.worklane.paneStripState.columns.first!
        let paneIDs = column.panes.map(\.id)
        XCTAssertNotEqual(column.id, PaneColumnID("c0"))
        XCTAssertFalse(paneIDs.contains(PaneID("p1")))
        XCTAssertFalse(paneIDs.contains(PaneID("p2")))
        XCTAssertEqual(Set(paneIDs).count, 2)
        XCTAssertEqual(result.worklane.paneStripState.focusedColumnID, column.id)
        XCTAssertEqual(column.focusedPaneID, paneIDs[1])
        XCTAssertEqual(column.lastFocusedPaneID, paneIDs[1])
    }

    func test_repeated_imports_of_same_template_allocate_distinct_pane_ids() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: nil),
                makePane(id: "p2", workingDirectory: temporaryDirectoryURL.path, command: nil),
            ]
        )

        let first = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )
        let second = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w2"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertTrue(
            Set(first.worklane.paneStripState.panes.map(\.id))
                .isDisjoint(with: Set(second.worklane.paneStripState.panes.map(\.id)))
        )
    }

    func test_duplicate_serialized_pane_ids_remap_focus_within_each_column() {
        let template = WorkspaceTemplate(
            name: "Duplicate IDs",
            kind: .bookmark,
            focusedColumnID: "right",
            columns: [
                WorkspaceTemplate.Column(
                    id: "left",
                    width: 500,
                    focusedPaneID: "duplicate",
                    lastFocusedPaneID: "duplicate",
                    paneHeights: [1.0],
                    panes: [
                        makePane(id: "duplicate", workingDirectory: temporaryDirectoryURL.path, command: nil),
                    ]
                ),
                WorkspaceTemplate.Column(
                    id: "right",
                    width: 500,
                    focusedPaneID: "duplicate",
                    lastFocusedPaneID: "duplicate",
                    paneHeights: [0.5, 0.5],
                    panes: [
                        makePane(id: "other", workingDirectory: temporaryDirectoryURL.path, command: nil),
                        makePane(id: "duplicate", workingDirectory: temporaryDirectoryURL.path, command: nil),
                    ]
                ),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        let columns = result.worklane.paneStripState.columns
        XCTAssertEqual(columns[0].focusedPaneID, columns[0].panes[0].id)
        XCTAssertEqual(columns[1].focusedPaneID, columns[1].panes[1].id)
        XCTAssertEqual(result.worklane.paneStripState.focusedColumnID, columns[1].id)
    }

    func test_environment_overrides_are_merged_into_session_environment() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(
                    id: "p1",
                    workingDirectory: temporaryDirectoryURL.path,
                    command: nil,
                    environment: ["NODE_ENV": "production"]
                ),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in true }
        )

        XCTAssertEqual(
            result.worklane.paneStripState.panes.first?.sessionRequest.environmentVariables["NODE_ENV"],
            "production"
        )
    }

    func test_reserved_environment_overrides_cannot_replace_fresh_session_identity() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(
                    id: "p1",
                    workingDirectory: temporaryDirectoryURL.path,
                    command: nil,
                    environment: [
                        "NODE_ENV": "production",
                        "ZENTTY_WINDOW_ID": "stale-window",
                        "ZENTTY_WORKLANE_ID": "stale-worklane",
                        "ZENTTY_PANE_ID": "stale-pane",
                        "ZENTTY_PANE_TOKEN": "stale-token",
                        "PATH": "/tmp/stale-bin",
                        "ZDOTDIR": "/tmp/stale-zdotdir",
                    ]
                ),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("fresh-worklane"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("fresh-window"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"],
            commandResolver: { _ in true }
        )

        let pane = result.worklane.paneStripState.panes.first!
        let environment = pane.sessionRequest.environmentVariables
        XCTAssertEqual(environment["NODE_ENV"], "production")
        XCTAssertEqual(environment["ZENTTY_WINDOW_ID"], "fresh-window")
        XCTAssertEqual(environment["ZENTTY_WORKLANE_ID"], "fresh-worklane")
        XCTAssertEqual(environment["ZENTTY_PANE_ID"], pane.id.rawValue)
        XCTAssertNotEqual(environment["ZENTTY_PANE_TOKEN"], "stale-token")
        XCTAssertNotEqual(environment["PATH"], "/tmp/stale-bin")
        XCTAssertNotEqual(environment["ZDOTDIR"], "/tmp/stale-zdotdir")
    }

    func test_missing_command_fallback_reports_fresh_pane_id() {
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: "missing-command"),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory()],
            commandResolver: { _ in false }
        )

        let paneID = result.worklane.paneStripState.panes.first!.id
        XCTAssertEqual(result.fallbacks.first?.paneID, paneID)
        XCTAssertNotEqual(result.fallbacks.first?.paneID, PaneID("p1"))
    }

    func test_default_command_resolver_uses_passed_process_environment_path() {
        let helperDir = temporaryDirectoryURL.appendingPathComponent("custom-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        let executableURL = helperDir.appendingPathComponent("zentty-template-test-cmd-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        let template = makeTemplate(
            kind: .bookmark,
            panes: [
                makePane(id: "p1", workingDirectory: temporaryDirectoryURL.path, command: executableURL.lastPathComponent),
            ]
        )

        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: WorklaneID("w1"),
            fallbackWorkingDirectory: nil,
            windowID: WindowID("win1"),
            layoutContext: layoutContext(),
            processEnvironment: ["HOME": NSHomeDirectory(), "PATH": helperDir.path]
        )

        let pane = result.worklane.paneStripState.panes.first!
        XCTAssertEqual(pane.sessionRequest.command, executableURL.lastPathComponent)
        XCTAssertNil(pane.sessionRequest.prefillText)
        XCTAssertTrue(result.fallbacks.isEmpty)
    }

    func test_isCommandOnPath_resolves_first_token_against_PATH() {
        let helperDir = temporaryDirectoryURL.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        let executableURL = helperDir.appendingPathComponent("zen-test-cmd")
        FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )

        XCTAssertTrue(
            WorkspaceTemplateImporter.isCommandOnPath(
                "zen-test-cmd --flag",
                processEnvironment: ["PATH": helperDir.path]
            )
        )

        XCTAssertFalse(
            WorkspaceTemplateImporter.isCommandOnPath(
                "definitely-not-an-installed-thing-xyz",
                processEnvironment: ["PATH": helperDir.path]
            )
        )
    }

    private func layoutContext() -> PaneLayoutContext {
        PaneLayoutContext(
            displayClass: .largeDisplay,
            preset: .balanced,
            viewportWidth: 1280,
            leadingVisibleInset: 0,
            sizing: .balanced
        )
    }

    private func makeTemplate(
        kind: WorkspaceTemplate.Kind,
        panes: [WorkspaceTemplate.Pane]
    ) -> WorkspaceTemplate {
        let column = WorkspaceTemplate.Column(
            id: "c0",
            width: 600,
            focusedPaneID: panes.first?.id,
            lastFocusedPaneID: panes.first?.id,
            paneHeights: panes.map { _ in 1.0 },
            panes: panes
        )
        return WorkspaceTemplate(
            name: "Test",
            kind: kind,
            focusedColumnID: "c0",
            columns: [column]
        )
    }

    private func makePane(
        id: String,
        workingDirectory: String?,
        command: String?,
        environment: [String: String] = [:]
    ) -> WorkspaceTemplate.Pane {
        WorkspaceTemplate.Pane(
            id: id,
            titleSeed: nil,
            workingDirectory: workingDirectory,
            command: command,
            environment: environment,
            wasUserEdited: false
        )
    }
}
