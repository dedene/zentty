import XCTest
@testable import Zentty

final class FileManagerSymlinkWriteTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.SymlinkWrite.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? fileManager.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func test_regular_file_returns_same_url() throws {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("config.toml")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = fileManager.resolvingSymlinkTarget(at: fileURL)

        XCTAssertEqual(resolved.path, fileURL.path)
    }

    func test_missing_file_returns_same_url() {
        let fileURL = temporaryDirectoryURL.appendingPathComponent("does-not-exist.toml")

        let resolved = fileManager.resolvingSymlinkTarget(at: fileURL)

        XCTAssertEqual(resolved.path, fileURL.path)
    }

    func test_absolute_symlink_returns_target() throws {
        let targetURL = temporaryDirectoryURL.appendingPathComponent("target.toml")
        try "real".write(to: targetURL, atomically: true, encoding: .utf8)
        let linkURL = temporaryDirectoryURL.appendingPathComponent("link.toml")
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let resolved = fileManager.resolvingSymlinkTarget(at: linkURL)

        XCTAssertEqual(resolved.path, targetURL.path)
    }

    func test_relative_symlink_returns_resolved_target() throws {
        let repoDirURL = temporaryDirectoryURL.appendingPathComponent("repo", isDirectory: true)
        let homeDirURL = temporaryDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: repoDirURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDirURL, withIntermediateDirectories: true)

        let targetURL = repoDirURL.appendingPathComponent("config.toml")
        try "real".write(to: targetURL, atomically: true, encoding: .utf8)

        // home/config.toml -> ../repo/config.toml  (relative destination)
        let linkURL = homeDirURL.appendingPathComponent("config.toml")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "../repo/config.toml")

        let resolved = fileManager.resolvingSymlinkTarget(at: linkURL)

        XCTAssertEqual(resolved.standardizedFileURL.path, targetURL.standardizedFileURL.path)
    }

    func test_broken_symlink_returns_target_path() throws {
        let targetURL = temporaryDirectoryURL.appendingPathComponent("missing-target.toml")
        let linkURL = temporaryDirectoryURL.appendingPathComponent("link.toml")
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let resolved = fileManager.resolvingSymlinkTarget(at: linkURL)

        XCTAssertEqual(resolved.path, targetURL.path)
        XCTAssertFalse(fileManager.fileExists(atPath: resolved.path))
    }

    func test_chained_symlink_returns_final_target() throws {
        let targetURL = temporaryDirectoryURL.appendingPathComponent("target.toml")
        try "real".write(to: targetURL, atomically: true, encoding: .utf8)
        let middleURL = temporaryDirectoryURL.appendingPathComponent("middle.toml")
        try fileManager.createSymbolicLink(at: middleURL, withDestinationURL: targetURL)
        let linkURL = temporaryDirectoryURL.appendingPathComponent("link.toml")
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: middleURL)

        let resolved = fileManager.resolvingSymlinkTarget(at: linkURL)

        XCTAssertEqual(resolved.path, targetURL.path)
    }

    func test_cyclic_symlink_falls_back_to_original_url() throws {
        let aURL = temporaryDirectoryURL.appendingPathComponent("a.toml")
        let bURL = temporaryDirectoryURL.appendingPathComponent("b.toml")
        // a -> b and b -> a forms a cycle: there is no real target, so resolution must
        // terminate and fall back to the original path rather than loop or pick a link.
        try fileManager.createSymbolicLink(at: aURL, withDestinationURL: bURL)
        try fileManager.createSymbolicLink(at: bURL, withDestinationURL: aURL)

        let resolved = fileManager.resolvingSymlinkTarget(at: aURL)

        XCTAssertEqual(resolved.path, aURL.path)
    }
}
