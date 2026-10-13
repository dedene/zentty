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

    private func writeBundle(names: [String]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bundle = WorkspaceTemplateBundle(
            templates: names.map { WorkspaceTemplate(name: $0, kind: .bookmark) }
        )
        try encoder.encode(bundle).write(to: fileURL, options: .atomic)
    }
}
