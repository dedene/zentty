import XCTest
@testable import Zentty

/// Restore snapshots and tmux-compat state describe one Mac's live session.
/// They moved out of ~/.config/zentty so that folder can be synced between
/// Macs without dragging that state along.
final class RuntimeStateRelocationTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var configDirectoryURL: URL!
    private var stateDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.RuntimeStateRelocation.\(UUID().uuidString)", isDirectory: true)
        configDirectoryURL = temporaryDirectoryURL.appendingPathComponent("config", isDirectory: true)
        stateDirectoryURL = temporaryDirectoryURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func test_state_directory_is_the_flavors_application_support_folder() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            ZenttyBuildFlavor.production.stateDirectoryURL(homeDirectoryURL: home).path,
            "/Users/tester/Library/Application Support/Zentty"
        )
        XCTAssertEqual(
            ZenttyBuildFlavor.dev.stateDirectoryURL(homeDirectoryURL: home).path,
            "/Users/tester/Library/Application Support/Zentty Dev"
        )
    }

    func test_moves_runtime_state_and_leaves_settings_in_place() throws {
        try write("config.toml", "[sidebar]\n", in: configDirectoryURL)
        try write("bookmarks.json", "{}", in: configDirectoryURL)
        for name in RuntimeStateRelocation.fileNames {
            try write(name, name, in: configDirectoryURL)
        }

        let moved = RuntimeStateRelocation.migrateIfNeeded(
            from: configDirectoryURL,
            to: stateDirectoryURL
        )

        XCTAssertEqual(Set(moved), Set(RuntimeStateRelocation.fileNames))
        XCTAssertEqual(try contents(of: configDirectoryURL), ["bookmarks.json", "config.toml"])
        for name in RuntimeStateRelocation.fileNames {
            XCTAssertEqual(try read(name, in: stateDirectoryURL), name)
        }
    }

    func test_newer_file_in_old_location_replaces_older_state() throws {
        // An older build ran in between and wrote the old location again.
        try write("restore-snapshot.json", "stale", in: stateDirectoryURL)
        try setModificationDate(Date(timeIntervalSinceNow: -3600), of: "restore-snapshot.json", in: stateDirectoryURL)
        try write("restore-snapshot.json", "fresh", in: configDirectoryURL)

        RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configDirectoryURL.appendingPathComponent("restore-snapshot.json").path))
    }

    func test_older_file_in_old_location_is_dropped_without_touching_newer_state() throws {
        try write("restore-snapshot.json", "old", in: configDirectoryURL)
        try setModificationDate(Date(timeIntervalSinceNow: -3600), of: "restore-snapshot.json", in: configDirectoryURL)
        try write("restore-snapshot.json", "current", in: stateDirectoryURL)

        let moved = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(moved, [])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "current")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configDirectoryURL.appendingPathComponent("restore-snapshot.json").path))
    }

    func test_nothing_to_move_is_a_no_op() throws {
        XCTAssertEqual(RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectoryURL.path))
    }

    func test_tmux_compat_store_lives_in_the_state_directory() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            TmuxCompatStoreIO.defaultFileURL(home: home).path,
            "/Users/tester/Library/Application Support/Zentty/tmux-compat-store.json"
        )
    }

    // MARK: - Helpers

    private func write(_ name: String, _ contents: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func setModificationDate(_ date: Date, of name: String, in directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: directory.appendingPathComponent(name).path
        )
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
