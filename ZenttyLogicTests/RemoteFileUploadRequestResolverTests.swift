import Foundation
import XCTest
@testable import Zentty

final class RemoteFileUploadRequestResolverTests: XCTestCase {
    func test_resolve_skips_directories_in_mixed_drop() {
        let directoryURL = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        let pdfURL = URL(fileURLWithPath: "/tmp/Quarterly Report.pdf")
        let archiveURL = URL(fileURLWithPath: "/tmp/archive.zip")
        let resourceResolver = FakeRemoteFileResourceResolver(valuesByURL: [
            directoryURL: RemoteFileResourceValues(isDirectory: true, fileSize: nil),
            pdfURL: RemoteFileResourceValues(isDirectory: false, fileSize: 123),
            archiveURL: RemoteFileResourceValues(isDirectory: false, fileSize: 456),
        ])

        let result = RemoteFileUploadRequestResolver.resolve(
            fileURLs: [directoryURL, pdfURL, archiveURL],
            resourceResolver: resourceResolver
        )

        XCTAssertEqual(
            result,
            .files([
                RemoteFileUploadRequest(localURL: pdfURL, originalFilename: "Quarterly Report.pdf", byteCount: 123),
                RemoteFileUploadRequest(localURL: archiveURL, originalFilename: "archive.zip", byteCount: 456),
            ])
        )
    }

    func test_resolve_reports_folders_only_when_all_entries_are_directories() {
        let firstDirectoryURL = URL(fileURLWithPath: "/tmp/folder-a", isDirectory: true)
        let secondDirectoryURL = URL(fileURLWithPath: "/tmp/folder-b", isDirectory: true)
        let resourceResolver = FakeRemoteFileResourceResolver(valuesByURL: [
            firstDirectoryURL: RemoteFileResourceValues(isDirectory: true, fileSize: nil),
            secondDirectoryURL: RemoteFileResourceValues(isDirectory: true, fileSize: nil),
        ])

        let result = RemoteFileUploadRequestResolver.resolve(
            fileURLs: [firstDirectoryURL, secondDirectoryURL],
            resourceResolver: resourceResolver
        )

        XCTAssertEqual(result, .foldersOnly)
    }

    func test_resolve_rejects_over_limit_file_before_upload_request() {
        let largeFileURL = URL(fileURLWithPath: "/tmp/movie.mov")
        let resourceResolver = FakeRemoteFileResourceResolver(valuesByURL: [
            largeFileURL: RemoteFileResourceValues(
                isDirectory: false,
                fileSize: RemoteFileUploadRequestResolver.maxFileByteCount + 1
            ),
        ])

        let result = RemoteFileUploadRequestResolver.resolve(
            fileURLs: [largeFileURL],
            resourceResolver: resourceResolver
        )

        XCTAssertEqual(result, .fileTooLarge)
        XCTAssertEqual(resourceResolver.requestedURLs, [largeFileURL])
    }
}

private final class FakeRemoteFileResourceResolver: RemoteFileResourceResolving, @unchecked Sendable {
    private let valuesByURL: [URL: RemoteFileResourceValues]
    private(set) var requestedURLs: [URL] = []

    init(valuesByURL: [URL: RemoteFileResourceValues]) {
        self.valuesByURL = valuesByURL
    }

    func values(for fileURL: URL) throws -> RemoteFileResourceValues {
        requestedURLs.append(fileURL)
        return valuesByURL[fileURL] ?? RemoteFileResourceValues(isDirectory: false, fileSize: 0)
    }
}
