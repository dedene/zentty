import XCTest
@testable import Zentty

@MainActor
final class BookmarkStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.BookmarkStore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        fileURL = temporaryDirectoryURL.appendingPathComponent("bookmarks.json")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        fileURL = nil
    }

    func test_returns_empty_when_file_missing() {
        let store = BookmarkStore(fileURL: fileURL)
        XCTAssertTrue(store.templates.isEmpty)
    }

    func test_returns_empty_and_preserves_corrupt_file_aside() throws {
        try Data("not-json".utf8).write(to: fileURL)
        let store = BookmarkStore(fileURL: fileURL)
        XCTAssertTrue(store.templates.isEmpty, "Corrupt file should be tolerated and surface as empty list")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "Corrupt file should be moved aside, not left in place where the next persist would overwrite it"
        )

        let siblingFiles = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectoryURL.path)) ?? []
        XCTAssertTrue(
            siblingFiles.contains(where: { $0.contains(".corrupt-") }),
            "Expected a preserved .corrupt-<timestamp>.json sibling but found: \(siblingFiles)"
        )
    }

    func test_upsert_persists_atomically() throws {
        let store = BookmarkStore(fileURL: fileURL)
        let template = WorkspaceTemplate(name: "Demo", kind: .bookmark)
        store.upsert(template)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let reloaded = BookmarkStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.templates.map(\.name), ["Demo"])
    }

    func test_upsert_preserves_symlinked_file_on_save() throws {
        let repoDirURL = temporaryDirectoryURL.appendingPathComponent("dotfiles", isDirectory: true)
        let homeDirURL = temporaryDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDirURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirURL, withIntermediateDirectories: true)

        let targetURL = repoDirURL.appendingPathComponent("bookmarks.json")
        // Stow-style: ~/.config/zentty/bookmarks.json -> dotfiles/bookmarks.json
        let linkURL = homeDirURL.appendingPathComponent("bookmarks.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let store = BookmarkStore(fileURL: linkURL)
        store.upsert(WorkspaceTemplate(name: "Demo", kind: .bookmark))

        // The link must survive the save instead of becoming a regular file...
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            targetURL.path
        )
        // ...and the bookmarks land in the real target, readable through the link.
        let reloaded = BookmarkStore(fileURL: linkURL)
        XCTAssertEqual(reloaded.templates.map(\.name), ["Demo"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func test_upsert_updates_existing_template() {
        let store = BookmarkStore(fileURL: fileURL)
        let id = UUID()
        store.upsert(WorkspaceTemplate(id: id, name: "Initial", kind: .bookmark))
        store.upsert(WorkspaceTemplate(id: id, name: "Updated", kind: .bookmark))

        XCTAssertEqual(store.templates.count, 1)
        XCTAssertEqual(store.templates.first?.name, "Updated")
    }

    func test_set_pinned_toggles_state() {
        let store = BookmarkStore(fileURL: fileURL)
        let template = WorkspaceTemplate(name: "Demo", kind: .preset)
        store.upsert(template)

        store.setPinned(id: template.id, pinned: true)
        XCTAssertEqual(store.template(withID: template.id)?.pinned, true)

        store.setPinned(id: template.id, pinned: false)
        XCTAssertEqual(store.template(withID: template.id)?.pinned, false)
    }

    func test_record_use_updates_lastUsedAt() {
        let store = BookmarkStore(fileURL: fileURL)
        let template = WorkspaceTemplate(name: "Demo", kind: .preset)
        store.upsert(template)
        XCTAssertNil(store.template(withID: template.id)?.lastUsedAt)

        store.recordUse(id: template.id)
        XCTAssertNotNil(store.template(withID: template.id)?.lastUsedAt)
    }

    func test_delete_removes_template() {
        let store = BookmarkStore(fileURL: fileURL)
        let template = WorkspaceTemplate(name: "Demo", kind: .preset)
        store.upsert(template)
        store.delete(id: template.id)
        XCTAssertTrue(store.templates.isEmpty)
    }

    func test_duplicate_creates_distinct_entry_with_unique_name() {
        let store = BookmarkStore(fileURL: fileURL)
        let original = WorkspaceTemplate(name: "Demo", kind: .preset)
        store.upsert(original)

        let firstCopy = store.duplicate(id: original.id)
        XCTAssertEqual(firstCopy?.name, "Demo copy")
        XCTAssertNotEqual(firstCopy?.id, original.id)

        let secondCopy = store.duplicate(id: original.id)
        XCTAssertEqual(secondCopy?.name, "Demo copy 2")
    }

    func test_observers_called_on_mutation() {
        let store = BookmarkStore(fileURL: fileURL)
        var notifications = 0
        _ = store.addObserver { notifications += 1 }

        store.upsert(WorkspaceTemplate(name: "A", kind: .preset))
        store.rename(id: store.templates[0].id, to: "Renamed")
        XCTAssertEqual(notifications, 2)
    }

    func test_rename_ignores_blank_input() {
        let store = BookmarkStore(fileURL: fileURL)
        let template = WorkspaceTemplate(name: "Original", kind: .preset)
        store.upsert(template)

        store.rename(id: template.id, to: "   ")
        XCTAssertEqual(store.template(withID: template.id)?.name, "Original")
    }

    func test_save_sheet_kind_presentation_uses_plain_explanatory_copy() {
        let bookmark = BookmarkSaveSheetKindPresentation(kind: .bookmark)
        XCTAssertEqual(bookmark.title, "Bookmark")
        XCTAssertEqual(bookmark.subtitle, "Restore panes in these folders")

        let preset = BookmarkSaveSheetKindPresentation(kind: .preset)
        XCTAssertEqual(preset.title, "Preset")
        XCTAssertEqual(preset.subtitle, "Restore panes without folders")
    }

    func test_save_sheet_primary_action_title_tracks_mode_and_kind() {
        let newTemplate = BookmarkSaveSheetViewModel(
            initialTemplate: WorkspaceTemplate(name: "Demo", kind: .bookmark),
            isUpdatingExisting: false,
            onSave: { _ in },
            onCancel: {}
        )
        XCTAssertEqual(newTemplate.primaryActionTitle, "Save Bookmark")

        newTemplate.kind = .preset
        XCTAssertEqual(newTemplate.primaryActionTitle, "Save Preset")

        let existingTemplate = BookmarkSaveSheetViewModel(
            initialTemplate: WorkspaceTemplate(name: "Demo", kind: .preset),
            isUpdatingExisting: true,
            onSave: { _ in },
            onCancel: {}
        )
        XCTAssertEqual(existingTemplate.primaryActionTitle, "Update")
    }

    func test_save_sheet_command_summary_reports_default_shell_for_empty_commands() {
        let viewModel = BookmarkSaveSheetViewModel(
            initialTemplate: WorkspaceTemplate(
                name: "Demo",
                kind: .bookmark,
                columns: [
                    WorkspaceTemplate.Column(
                        id: "column-1",
                        width: 1,
                        focusedPaneID: nil,
                        lastFocusedPaneID: nil,
                        paneHeights: [0.5, 0.5],
                        panes: [
                            WorkspaceTemplate.Pane(id: "pane-1"),
                            WorkspaceTemplate.Pane(id: "pane-2")
                        ]
                    )
                ]
            ),
            isUpdatingExisting: false,
            onSave: { _ in },
            onCancel: {}
        )

        XCTAssertEqual(viewModel.commandSummary, "2 panes will reopen with the default shell")
    }

    func test_save_sheet_command_summary_reports_custom_command_count() {
        let viewModel = BookmarkSaveSheetViewModel(
            initialTemplate: WorkspaceTemplate(
                name: "Demo",
                kind: .preset,
                columns: [
                    WorkspaceTemplate.Column(
                        id: "column-1",
                        width: 1,
                        focusedPaneID: nil,
                        lastFocusedPaneID: nil,
                        paneHeights: [1],
                        panes: [
                            WorkspaceTemplate.Pane(id: "pane-1", command: "npm test"),
                            WorkspaceTemplate.Pane(id: "pane-2", command: "   "),
                            WorkspaceTemplate.Pane(id: "pane-3", command: nil)
                        ]
                    )
                ]
            ),
            isUpdatingExisting: false,
            onSave: { _ in },
            onCancel: {}
        )

        XCTAssertEqual(viewModel.commandSummary, "1 pane has a custom command")
    }

    func test_save_sheet_commands_disclosure_fades_content_in_place() {
        let presentation = BookmarkSaveSheetCommandsDisclosurePresentation.standard

        XCTAssertEqual(presentation.animationDuration, 0.16, accuracy: 0.001)
        XCTAssertEqual(presentation.expandedContentTransition, .fadeInPlace)
    }
}
