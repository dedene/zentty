import XCTest
@testable import Zentty

final class ClosedPaneCWDResolverTests: XCTestCase {
    func test_returns_original_when_directory_exists() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let resolution = ClosedPaneCWDResolver.resolve(
            original: temp.path,
            homeDirectory: "/Users/peter"
        )

        XCTAssertEqual(resolution.path, temp.path)
        XCTAssertFalse(resolution.originalMissing)
    }

    func test_walks_up_to_first_existing_ancestor() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let missing = parent.appendingPathComponent("does-not-exist/feature-x")

        let resolution = ClosedPaneCWDResolver.resolve(
            original: missing.path,
            homeDirectory: "/Users/peter"
        )

        XCTAssertEqual(resolution.path, parent.path)
        XCTAssertTrue(resolution.originalMissing)
    }

    func test_falls_back_to_home_when_nothing_exists() {
        let resolution = ClosedPaneCWDResolver.resolve(
            original: "/this/does/not/exist/anywhere/we/hope",
            homeDirectory: "/Users/peter"
        )

        XCTAssertTrue(resolution.originalMissing)
    }

    func test_returns_root_when_walk_up_lands_on_root() {
        // /this-must-not-exist-on-disk should walk up to "/" which always exists.
        let resolution = ClosedPaneCWDResolver.resolve(
            original: "/this-must-not-exist-on-disk-\(UUID().uuidString)",
            homeDirectory: "/Users/peter"
        )

        XCTAssertEqual(resolution.path, "/")
        XCTAssertTrue(resolution.originalMissing)
    }

    func test_falls_back_to_home_when_path_empty_or_nil() {
        let nilResolution = ClosedPaneCWDResolver.resolve(
            original: nil,
            homeDirectory: "/Users/peter"
        )
        XCTAssertEqual(nilResolution.path, "/Users/peter")
        XCTAssertTrue(nilResolution.originalMissing)

        let emptyResolution = ClosedPaneCWDResolver.resolve(
            original: "   ",
            homeDirectory: "/Users/peter"
        )
        XCTAssertEqual(emptyResolution.path, "/Users/peter")
        XCTAssertTrue(emptyResolution.originalMissing)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zentty-restore-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
