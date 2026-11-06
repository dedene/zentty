import XCTest
@testable import Zentty

/// bookmarks.json changes under a running app when it is synced from another
/// Mac or edited by hand. The store must pick that up instead of overwriting it
/// with its stale copy on the next save.
@MainActor
final class BookmarkStoreLiveReloadTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.BookmarkLiveReload.\(UUID().uuidString)", isDirectory: true)
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

    func test_external_write_reloads_templates_and_notifies_observers() throws {
        let store = BookmarkStore(fileURL: fileURL)
        let reloaded = expectation(description: "external bookmarks write picked up")
        _ = store.addObserver { [weak store] in
            if store?.templates.map(\.name) == ["From other Mac"] {
                reloaded.fulfill()
            }
        }

        try writeBundle(names: ["From other Mac"])

        wait(for: [reloaded], timeout: 5)
    }

    func test_save_after_external_write_keeps_both_bookmarks() throws {
        let store = BookmarkStore(fileURL: fileURL)
        // No reloadFromDisk(): the save must not wait for the debounced watcher.
        try writeBundle(names: ["From other Mac"])

        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))

        let names = BookmarkStore(fileURL: fileURL).templates.map(\.name)
        XCTAssertEqual(Set(names), ["From other Mac", "Local"])
    }

    func test_own_save_does_not_trigger_a_reload_notification() throws {
        let store = BookmarkStore(fileURL: fileURL)
        var notifications = 0
        _ = store.addObserver { notifications += 1 }

        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        XCTAssertEqual(notifications, 1)

        let settled = expectation(description: "watcher debounce elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(notifications, 1, "the store's own write must not read back as an external change")
    }

    func test_external_delete_clears_templates() throws {
        let store = BookmarkStore(fileURL: fileURL)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))

        try FileManager.default.removeItem(at: fileURL)
        store.reloadFromDisk()

        XCTAssertTrue(store.templates.isEmpty)
    }

    func test_unreadable_external_write_keeps_last_good_templates_in_place() throws {
        let store = BookmarkStore(fileURL: fileURL)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))

        try Data("{ half a sync".utf8).write(to: fileURL)
        store.reloadFromDisk()

        XCTAssertEqual(store.templates.map(\.name), ["Local"])
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "{ half a sync")
    }

    func test_save_over_an_unreadable_file_sets_the_broken_file_aside_first() throws {
        let store = BookmarkStore(fileURL: fileURL)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        try Data("{ broken hand edit".utf8).write(to: fileURL)

        store.upsert(WorkspaceTemplate(name: "Another", kind: .bookmark))

        XCTAssertEqual(Set(BookmarkStore(fileURL: fileURL).templates.map(\.name)), ["Local", "Another"])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectoryURL.path)
        let backup = try XCTUnwrap(siblings.first { $0.contains(".corrupt-") }, "\(siblings)")
        XCTAssertEqual(
            try String(contentsOf: temporaryDirectoryURL.appendingPathComponent(backup), encoding: .utf8),
            "{ broken hand edit"
        )
    }

    func test_repairing_file_to_last_good_bytes_clears_unreadable_flag() throws {
        let store = BookmarkStore(fileURL: fileURL)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        let goodBytes = try Data(contentsOf: fileURL)
        try Data("{ broken hand edit".utf8).write(to: fileURL)
        store.reloadFromDisk()

        try goodBytes.write(to: fileURL)
        store.reloadFromDisk()
        store.upsert(WorkspaceTemplate(name: "Another", kind: .bookmark))

        XCTAssertEqual(try corruptBackupNames(), [])
    }

    func test_save_over_file_that_cannot_be_read_preserves_it_first() throws {
        let store = BookmarkStore(fileURL: fileURL)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        try writeBundle(names: ["Synced"])
        let externalBytes = try Data(contentsOf: fileURL)
        try setPermissions(0o000, on: fileURL)

        store.upsert(WorkspaceTemplate(name: "Another", kind: .bookmark))

        let backup = try XCTUnwrap(try corruptBackupNames().first)
        let backupURL = temporaryDirectoryURL.appendingPathComponent(backup)
        try setPermissions(0o644, on: backupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), externalBytes)
    }

    func test_save_is_blocked_when_the_unreadable_file_cannot_be_preserved() throws {
        let fileManager = MoveRefusingFileManager()
        let store = BookmarkStore(fileURL: fileURL, fileManager: fileManager)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        var persistErrorCount = 0
        store.onPersistError = { _ in persistErrorCount += 1 }
        try Data("{ broken hand edit".utf8).write(to: fileURL)

        store.upsert(WorkspaceTemplate(name: "Another", kind: .bookmark))

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "{ broken hand edit")
        XCTAssertEqual(persistErrorCount, 1)

        fileManager.refusesMoves = false
        store.upsert(WorkspaceTemplate(name: "Retry", kind: .bookmark))

        XCTAssertEqual(try corruptBackupNames().count, 1)
        XCTAssertEqual(persistErrorCount, 1)
    }

    /// The file is out of the way, the replacement failed. The missing file is the store's own
    /// doing, not a deletion: only the in-memory list still holds these bookmarks.
    func test_failed_save_after_the_backup_keeps_the_list_and_a_later_save_retries_it() throws {
        let fileManager = DirectoryFreezingFileManager()
        let store = BookmarkStore(fileURL: fileURL, fileManager: fileManager)
        addTeardownBlock { [temporaryDirectoryURL] in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: try XCTUnwrap(temporaryDirectoryURL).path
            )
        }
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        var persistErrorCount = 0
        store.onPersistError = { _ in persistErrorCount += 1 }
        try Data("{ broken hand edit".utf8).write(to: fileURL)

        fileManager.freezesDirectoryAfterMove = true
        store.upsert(WorkspaceTemplate(name: "Added", kind: .bookmark))

        XCTAssertEqual(persistErrorCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        store.reloadFromDisk()

        XCTAssertEqual(Set(store.templates.map(\.name)), ["Local", "Added"])

        fileManager.freezesDirectoryAfterMove = false
        try setPermissions(0o755, on: temporaryDirectoryURL)
        store.upsert(WorkspaceTemplate(name: "Later", kind: .bookmark))

        XCTAssertEqual(persistErrorCount, 1)
        XCTAssertEqual(Set(BookmarkStore(fileURL: fileURL).templates.map(\.name)), ["Local", "Added", "Later"])
        XCTAssertEqual(try corruptBackupNames().count, 1)
    }

    func test_valid_file_landing_after_a_failed_save_is_adopted_and_deletion_counts_again() throws {
        let fileManager = DirectoryFreezingFileManager()
        let store = BookmarkStore(fileURL: fileURL, fileManager: fileManager)
        addTeardownBlock { [temporaryDirectoryURL] in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: try XCTUnwrap(temporaryDirectoryURL).path
            )
        }
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        try Data("{ broken hand edit".utf8).write(to: fileURL)
        fileManager.freezesDirectoryAfterMove = true
        store.upsert(WorkspaceTemplate(name: "Added", kind: .bookmark))
        fileManager.freezesDirectoryAfterMove = false
        try setPermissions(0o755, on: temporaryDirectoryURL)

        try writeBundle(names: ["Synced"])
        store.reloadFromDisk()

        XCTAssertEqual(store.templates.map(\.name), ["Synced"])

        try FileManager.default.removeItem(at: fileURL)
        store.reloadFromDisk()

        XCTAssertEqual(store.templates, [], "the store owns the missing file no longer")
    }

    /// The cached bytes describe the list from before the failed save. A file that matches them
    /// is still a valid file landing during recovery, not the store's own save read back.
    func test_good_backup_restored_after_a_failed_save_is_adopted_and_not_overwritten() throws {
        let fileManager = DirectoryFreezingFileManager()
        let store = BookmarkStore(fileURL: fileURL, fileManager: fileManager)
        addTeardownBlock { [temporaryDirectoryURL] in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: try XCTUnwrap(temporaryDirectoryURL).path
            )
        }
        let kept = WorkspaceTemplate(name: "Kept", kind: .bookmark)
        let removed = WorkspaceTemplate(name: "Removed", kind: .bookmark)
        store.upsert(kept)
        store.upsert(removed)
        let goodBytes = try Data(contentsOf: fileURL)
        try Data("{ broken hand edit".utf8).write(to: fileURL)

        fileManager.freezesDirectoryAfterMove = true
        store.delete(id: removed.id)
        fileManager.freezesDirectoryAfterMove = false
        try setPermissions(0o755, on: temporaryDirectoryURL)
        store.reloadFromDisk()
        XCTAssertEqual(store.templates.map(\.name), ["Kept"])

        try goodBytes.write(to: fileURL)
        store.reloadFromDisk()

        XCTAssertEqual(store.templates.map(\.name), ["Kept", "Removed"])

        store.rename(id: kept.id, to: "Renamed")

        XCTAssertEqual(BookmarkStore(fileURL: fileURL).templates.map(\.name), ["Renamed", "Removed"])
    }

    /// Same trap with the save blocked one step earlier: the broken file could not be moved, so
    /// the store never reached the replacement state but its list has still moved on.
    func test_good_backup_restored_after_a_blocked_save_is_adopted_and_not_overwritten() throws {
        let fileManager = MoveRefusingFileManager()
        let store = BookmarkStore(fileURL: fileURL, fileManager: fileManager)
        let kept = WorkspaceTemplate(name: "Kept", kind: .bookmark)
        let removed = WorkspaceTemplate(name: "Removed", kind: .bookmark)
        store.upsert(kept)
        store.upsert(removed)
        let goodBytes = try Data(contentsOf: fileURL)
        try Data("{ broken hand edit".utf8).write(to: fileURL)

        store.delete(id: removed.id)
        XCTAssertEqual(store.templates.map(\.name), ["Kept"])

        try goodBytes.write(to: fileURL)
        store.reloadFromDisk()

        XCTAssertEqual(store.templates.map(\.name), ["Kept", "Removed"])
    }

    /// The shortcut still has to hold for an intact file: a failed save over a healthy file must
    /// not be undone by the next reload seeing the same old bytes.
    func test_failed_save_over_an_intact_file_keeps_the_change_for_the_next_save() throws {
        let store = BookmarkStore(fileURL: fileURL)
        addTeardownBlock { [temporaryDirectoryURL] in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: try XCTUnwrap(temporaryDirectoryURL).path
            )
        }
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        try setPermissions(0o555, on: temporaryDirectoryURL)

        store.upsert(WorkspaceTemplate(name: "Unsaved", kind: .bookmark))
        store.reloadFromDisk()

        XCTAssertEqual(Set(store.templates.map(\.name)), ["Local", "Unsaved"])

        try setPermissions(0o755, on: temporaryDirectoryURL)
        store.upsert(WorkspaceTemplate(name: "Later", kind: .bookmark))

        XCTAssertEqual(Set(BookmarkStore(fileURL: fileURL).templates.map(\.name)), ["Local", "Unsaved", "Later"])
    }

    func test_backups_made_within_one_second_all_land() throws {
        let store = BookmarkStore(fileURL: fileURL)
        store.upsert(WorkspaceTemplate(name: "Local", kind: .bookmark))
        var persistErrorCount = 0
        store.onPersistError = { _ in persistErrorCount += 1 }

        for attempt in 0..<3 {
            try Data("{ broken hand edit \(attempt)".utf8).write(to: fileURL)
            store.upsert(WorkspaceTemplate(name: "Saved \(attempt)", kind: .bookmark))
        }

        XCTAssertEqual(persistErrorCount, 0)
        XCTAssertEqual(try corruptBackupNames().count, 3)
    }

    private func corruptBackupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temporaryDirectoryURL.path)
            .filter { $0.contains(".corrupt-") }
    }

    private func setPermissions(_ permissions: Int, on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func writeBundle(names: [String]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bundle = WorkspaceTemplateBundle(
            templates: names.map { WorkspaceTemplate(name: $0, kind: .bookmark) }
        )
        try encoder.encode(bundle).write(to: fileURL, options: .atomic)
    }
}

/// A move succeeds, then the folder stops taking writes: the failure a full disk gives the
/// replacement write, once renaming the old file aside has already worked.
private final class DirectoryFreezingFileManager: FileManager, @unchecked Sendable {
    var freezesDirectoryAfterMove = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        if freezesDirectoryAfterMove {
            try setAttributes([.posixPermissions: 0o555], ofItemAtPath: dstURL.deletingLastPathComponent().path)
        }
    }
}

private final class MoveRefusingFileManager: FileManager, @unchecked Sendable {
    var refusesMoves = true

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if refusesMoves {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
