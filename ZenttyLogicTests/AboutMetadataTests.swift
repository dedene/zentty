import XCTest
@testable import Zentty

final class AboutMetadataTests: XCTestCase {
    func test_metadata_parses_version_build_and_commit() throws {
        let metadata = try XCTUnwrap(AboutMetadata(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
            "ZenttyGitCommit": "abc1234",
        ]))

        XCTAssertEqual(metadata.version, "1.2.3")
        XCTAssertEqual(metadata.build, "456")
        XCTAssertEqual(metadata.commit, "abc1234")
    }

    func test_metadata_falls_back_when_values_are_missing() throws {
        let metadata = try XCTUnwrap(AboutMetadata(infoDictionary: [:]))

        XCTAssertEqual(metadata.version, "Unknown")
        XCTAssertEqual(metadata.build, "Unknown")
        XCTAssertEqual(metadata.commit, "unknown")
    }
}
