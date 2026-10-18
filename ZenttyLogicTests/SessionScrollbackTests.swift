import XCTest
@testable import Zentty

final class SessionScrollbackTextTests: XCTestCase {
    func test_prepared_text_strips_control_characters_but_keeps_tabs_and_newlines() {
        let raw = "red \u{1B}[31mtext\u{1B}[0m\r\n\tindented\u{07}\nosc \u{1B}]52;c;ZXZpbA==\u{07}end\u{9B}31m"

        let prepared = SessionScrollbackText.preparedText(from: raw)

        XCTAssertEqual(prepared, "red [31mtext[0m\n\tindented\nosc ]52;c;ZXZpbA==end31m")
        XCTAssertFalse(prepared?.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 || $0.value == 0x9B } ?? true)
    }

    func test_prepared_text_drops_trailing_blank_lines_and_ignores_blank_screens() {
        XCTAssertEqual(SessionScrollbackText.preparedText(from: "$ ls\nREADME.md\n\n   \n\n"), "$ ls\nREADME.md")
        XCTAssertNil(SessionScrollbackText.preparedText(from: "\n \n\t\n"))
        XCTAssertNil(SessionScrollbackText.preparedText(from: "\u{1B}\u{07}\r\n\u{1B}"))
        XCTAssertNil(SessionScrollbackText.replayPayload(from: ""))
    }

    func test_prepared_text_keeps_the_newest_lines_within_the_line_cap() {
        let raw = (1...10).map { "line \($0)" }.joined(separator: "\n")

        let prepared = SessionScrollbackText.preparedText(
            from: raw,
            limits: .init(maxLines: 3, maxBytes: 1_000)
        )

        XCTAssertEqual(prepared, "line 8\nline 9\nline 10")
    }

    func test_prepared_text_trims_from_the_top_on_a_line_boundary_to_fit_the_byte_cap() {
        let raw = "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc"

        // 11 bytes per line including its newline: 25 bytes fits two lines.
        let prepared = SessionScrollbackText.preparedText(
            from: raw,
            limits: .init(maxLines: 100, maxBytes: 25)
        )

        XCTAssertEqual(prepared, "bbbbbbbbbb\ncccccccccc")
    }

    func test_byte_cap_counts_utf8_bytes_not_characters() {
        let raw = "ééééé\nabc"

        let prepared = SessionScrollbackText.preparedText(
            from: raw,
            limits: .init(maxLines: 100, maxBytes: 8)
        )

        XCTAssertEqual(prepared, "abc")
    }

    func test_default_limits_are_four_thousand_lines_or_one_megabyte() {
        XCTAssertEqual(SessionScrollbackText.Limits.perPane.maxLines, 4_000)
        XCTAssertEqual(SessionScrollbackText.Limits.perPane.maxBytes, 1_048_576)

        let raw = (1...5_000).map { "row \($0)" }.joined(separator: "\n")
        let lines = SessionScrollbackText.preparedText(from: raw)?.components(separatedBy: "\n")
        XCTAssertEqual(lines?.count, 4_000)
        XCTAssertEqual(lines?.first, "row 1001")
        XCTAssertEqual(lines?.last, "row 5000")
    }

    func test_limits_share_the_total_budget_once_there_are_many_panes() {
        XCTAssertEqual(SessionScrollbackText.limits(forPaneCount: 4).maxBytes, 1_048_576)
        XCTAssertEqual(
            SessionScrollbackText.limits(forPaneCount: 64).maxBytes,
            SessionScrollbackText.totalByteBudget / 64
        )
        XCTAssertEqual(SessionScrollbackText.limits(forPaneCount: 64).maxLines, 4_000)
    }

    func test_replay_payload_ends_with_a_faint_separator_that_resets_attributes() throws {
        let payload = try XCTUnwrap(SessionScrollbackText.replayPayload(from: "$ make\nok\n"))

        XCTAssertEqual(payload, "$ make\nok\n\u{1B}[2m── restored from previous session ──\u{1B}[0m\n")
        XCTAssertTrue(payload.hasSuffix("\u{1B}[0m\n"), "the separator must reset SGR before the prompt")
    }

    func test_replay_payload_never_carries_control_sequences_from_the_capture() throws {
        let payload = try XCTUnwrap(SessionScrollbackText.replayPayload(from: "rm -rf /tmp/x\u{1B}]0;title\u{07}\n"))
        let separatorStart = try XCTUnwrap(payload.range(of: SessionScrollbackText.separatorLine))
        let captured = payload[..<separatorStart.lowerBound]

        XCTAssertFalse(captured.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x0A && $0.value != 0x09 })
    }

    func test_restoring_again_keeps_only_the_newest_separator() throws {
        let first = try XCTUnwrap(SessionScrollbackText.replayPayload(from: "$ make\nok\n"))
        // What the terminal shows after the replay, read back as plain text,
        // with some new output below it.
        let shown = first.replacingOccurrences(of: "\u{1B}[2m", with: "")
            .replacingOccurrences(of: "\u{1B}[0m", with: "") + "$ ls\nREADME.md  \n"

        let second = try XCTUnwrap(SessionScrollbackText.replayPayload(from: shown))
        let third = try XCTUnwrap(SessionScrollbackText.replayPayload(from: second))

        XCTAssertEqual(second, "$ make\nok\n$ ls\nREADME.md  \n" + SessionScrollbackText.separatorLine)
        XCTAssertEqual(third.components(separatedBy: SessionScrollbackText.separatorTitle).count, 2)
    }
}

final class SessionScrollbackArchiveTests: XCTestCase {
    func test_file_name_uses_the_pane_id_and_hashes_unsafe_ids() {
        XCTAssertEqual(SessionScrollbackArchive.fileName(forPaneID: "pn_abc123"), "pn_abc123.txt")

        let unsafe = SessionScrollbackArchive.fileName(forPaneID: "../../etc/passwd")
        XCTAssertTrue(unsafe.hasPrefix("pane-"))
        XCTAssertTrue(unsafe.hasSuffix(".txt"))
        XCTAssertFalse(unsafe.contains("/"))
        XCTAssertEqual(unsafe, SessionScrollbackArchive.fileName(forPaneID: "../../etc/passwd"), "names must be stable")
        XCTAssertTrue(SessionScrollbackArchive.isValidFileName(unsafe))
    }

    func test_file_name_can_be_scoped_to_a_launch() {
        XCTAssertEqual(SessionScrollbackArchive.fileName(forPaneID: "pn_1", launchID: "a1b2"), "pn_1-a1b2.txt")
        XCTAssertTrue(SessionScrollbackArchive.isValidFileName("pn_1-a1b2.txt"))
        XCTAssertEqual(
            SessionScrollbackArchive.fileName(forPaneID: "pn_1", launchID: "../x"),
            "pn_1.txt",
            "an unsafe launch id is ignored"
        )
    }

    func test_only_bare_archive_names_resolve_to_urls() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: try makeScrollbackTemporaryDirectory())

        XCTAssertNotNil(archive.url(forFileName: "pn_1.txt"))
        XCTAssertNil(archive.url(forFileName: "../pn_1.txt"))
        XCTAssertNil(archive.url(forFileName: "nested/pn_1.txt"))
        XCTAssertNil(archive.url(forFileName: "pn_1.json"))
        XCTAssertNil(archive.url(forFileName: ".txt"))
        XCTAssertNil(archive.url(forFileName: "/etc/passwd"))
    }

    func test_archive_lives_in_session_scrollback_next_to_the_state() throws {
        let state = try makeScrollbackTemporaryDirectory()
        let archive = SessionScrollbackArchive(stateDirectoryURL: state)

        XCTAssertEqual(archive.directoryURL, state.appendingPathComponent("session-scrollback", isDirectory: true))
    }

    func test_write_creates_a_private_directory_and_private_files() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: try makeScrollbackTemporaryDirectory())

        try archive.write("first\n", fileName: "pn_1.txt")
        try archive.write("second\n", fileName: "pn_1.txt")

        let fileURL = try XCTUnwrap(archive.url(forFileName: "pn_1.txt"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "second\n")
        XCTAssertEqual(try permissions(of: archive.directoryURL), 0o700)
        XCTAssertEqual(try permissions(of: fileURL), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: archive.directoryURL.path)
        XCTAssertEqual(leftovers, ["pn_1.txt"], "no temp files may linger")
    }

    func test_directory_is_excluded_from_backups() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: try makeScrollbackTemporaryDirectory())

        try archive.write("secret\n", fileName: "pn_1.txt")

        let values = try archive.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func test_write_tightens_an_existing_directory() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: try makeScrollbackTemporaryDirectory())
        try FileManager.default.createDirectory(
            at: archive.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        try archive.write("x\n", fileName: "pn_1.txt")

        XCTAssertEqual(try permissions(of: archive.directoryURL), 0o700)
    }

    func test_purge_removes_every_file_not_kept() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: try makeScrollbackTemporaryDirectory())
        try archive.write("a\n", fileName: "pn_a.txt")
        try archive.write("b\n", fileName: "pn_b.txt")
        try "stray".write(
            to: archive.directoryURL.appendingPathComponent("stray.log"),
            atomically: true,
            encoding: .utf8
        )

        archive.purge(keeping: ["pn_a.txt"])

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.directoryURL.path), ["pn_a.txt"])
    }

    func test_existing_file_path_requires_a_valid_name_and_a_file() throws {
        let archive = SessionScrollbackArchive(stateDirectoryURL: try makeScrollbackTemporaryDirectory())
        try archive.write("a\n", fileName: "pn_a.txt")

        XCTAssertEqual(archive.existingFilePath(forFileName: "pn_a.txt"), archive.url(forFileName: "pn_a.txt")?.path)
        XCTAssertNil(archive.existingFilePath(forFileName: "pn_missing.txt"))
        XCTAssertNil(archive.existingFilePath(forFileName: nil))
        XCTAssertNil(archive.existingFilePath(forFileName: "../pn_a.txt"))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

final class SessionScrollbackRecipeTests: XCTestCase {
    func test_pane_round_trips_the_scrollback_file_reference() throws {
        let pane = WorkspaceRecipe.Pane(
            id: "pn_1",
            titleSeed: nil,
            workingDirectory: "/tmp",
            scrollbackFile: "pn_1.txt"
        )

        let restored = try JSONDecoder().decode(
            WorkspaceRecipe.Pane.self,
            from: try JSONEncoder().encode(pane)
        )

        XCTAssertEqual(restored, pane)
        XCTAssertEqual(restored.scrollbackFile, "pn_1.txt")
    }

    func test_v4_recipe_without_the_field_still_decodes() throws {
        let legacyData = try XCTUnwrap(
            """
            {
              "schemaVersion": 4,
              "windows": [{
                "id": "wd_1",
                "activeWorklaneID": "wl_1",
                "worklanes": [{
                  "id": "wl_1",
                  "nextPaneNumber": 2,
                  "columns": [{
                    "id": "col_1",
                    "width": 600,
                    "paneHeights": [400],
                    "panes": [{ "id": "pn_1", "workingDirectory": "/tmp" }]
                  }]
                }]
              }]
            }
            """.data(using: .utf8)
        )

        let recipe = WorkspaceRecipeMigration.migrate(
            try JSONDecoder().decode(WorkspaceRecipe.self, from: legacyData)
        )

        XCTAssertNil(recipe.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile)
        XCTAssertEqual(recipe.schemaVersion, WorkspaceRecipe.currentSchemaVersion)
        XCTAssertEqual(WorkspaceRecipe.currentSchemaVersion, 4, "the field is additive; no schema bump")
    }

    func test_scrollback_reference_alone_does_not_make_a_default_workspace_meaningful() {
        var recipe = SessionScrollbackTestFixtures.recipe(paneIDs: ["pn_1"], workingDirectory: "/Users/peter")
        recipe.windows[0].worklanes[0].columns[0].panes[0].scrollbackFile = "pn_1.txt"

        XCTAssertFalse(WorkspaceRecipeMeaningfulness.isMeaningful(recipe, defaultWorkingDirectory: "/Users/peter"))
    }
}

enum SessionScrollbackTestFixtures {
    static func recipe(paneIDs: [String], workingDirectory: String = "/tmp") -> WorkspaceRecipe {
        WorkspaceRecipe(
            windows: [
                WorkspaceRecipe.Window(
                    id: "wd_1",
                    worklanes: [
                        WorkspaceRecipe.Worklane(
                            id: "wl_1",
                            title: nil,
                            nextPaneNumber: paneIDs.count + 1,
                            focusedColumnID: "col_1",
                            columns: [
                                WorkspaceRecipe.Column(
                                    id: "col_1",
                                    width: 600,
                                    focusedPaneID: paneIDs.first,
                                    lastFocusedPaneID: paneIDs.first,
                                    paneHeights: paneIDs.map { _ in 400 },
                                    panes: paneIDs.map {
                                        WorkspaceRecipe.Pane(id: $0, titleSeed: nil, workingDirectory: workingDirectory)
                                    }
                                ),
                            ],
                            color: nil,
                            bookmarkOriginID: nil
                        ),
                    ],
                    activeWorklaneID: "wl_1"
                ),
            ],
            activeWindowID: "wd_1"
        )
    }
}

extension XCTestCase {
    func makeScrollbackTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-scrollback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
