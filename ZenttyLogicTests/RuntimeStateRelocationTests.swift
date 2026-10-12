import XCTest
@testable import Zentty

/// Restore snapshots and tmux-compat state describe one Mac's live session.
/// They moved out of ~/.config/zentty so that folder can be synced between
/// Macs without dragging that state along. The move must stay safe while
/// older Zentty builds still run against the old files.
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

    func test_copies_session_state_once_and_leaves_the_old_files_for_older_builds() throws {
        try write("config.toml", "[sidebar]\n", in: configDirectoryURL)
        for name in RuntimeStateRelocation.fileNames {
            try write(name, name, in: configDirectoryURL)
        }

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(Set(copied), Set(RuntimeStateRelocation.fileNames))
        for name in RuntimeStateRelocation.fileNames {
            XCTAssertEqual(try read(name, in: stateDirectoryURL), name)
            XCTAssertEqual(try read(name, in: configDirectoryURL), name, "an older build may still be using \(name)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("config.toml").path))
    }

    func test_later_writes_by_an_older_build_are_never_pulled_in() throws {
        try write("restore-snapshot.json", "first", in: configDirectoryURL)
        RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)
        try write("restore-snapshot.json", "own session", in: stateDirectoryURL)

        // Another worktree build on 0.3.7 keeps writing the old location.
        try write("restore-snapshot.json", "other instance", in: configDirectoryURL)
        try write("tmux-compat-store.json", "other instance", in: configDirectoryURL)
        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, [])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "own session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("tmux-compat-store.json").path))
    }

    func test_existing_state_is_never_replaced_and_restore_files_move_as_a_pair() throws {
        try write("restore-snapshot.json", "current", in: stateDirectoryURL)
        try write("restore-snapshot.json", "old", in: configDirectoryURL)
        try write("restore-lifecycle.json", "old", in: configDirectoryURL)

        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, [])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "current")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent("restore-lifecycle.json").path),
            "a lifecycle file without its own snapshot could fake a crash recovery"
        )
    }

    func test_a_failed_copy_is_retried_on_the_next_launch() throws {
        try write("restore-snapshot.json", "session", in: configDirectoryURL)
        // A regular file where the state directory should be makes every copy fail.
        try Data().write(to: stateDirectoryURL)

        XCTAssertEqual(RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL), [])

        try FileManager.default.removeItem(at: stateDirectoryURL)
        let copied = RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL)

        XCTAssertEqual(copied, ["restore-snapshot.json"])
        XCTAssertEqual(try read("restore-snapshot.json", in: stateDirectoryURL), "session")
    }

    func test_nothing_to_copy_only_marks_the_relocation_done() throws {
        XCTAssertEqual(RuntimeStateRelocation.migrateIfNeeded(from: configDirectoryURL, to: stateDirectoryURL), [])
        XCTAssertEqual(try contents(of: stateDirectoryURL), [RuntimeStateRelocation.markerFileName])
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

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
