import Foundation
import XCTest
@testable import Zentty

@MainActor
final class RemoteImageUploaderTests: XCTestCase {
    func test_upload_streams_chunks_reports_progress_and_returns_remote_path() async throws {
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(exitStatus: 0, stderr: "", timedOut: false)
        )
        let factory = FakeRemoteImageUploadProcessFactory(process: process)
        let uploader = RemoteImageUploader(
            processFactory: factory,
            remotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678.png" },
            chunkSize: 2,
            timeout: 60
        )
        var progressFractions: [Double] = []

        let path = try await uploader.upload(
            imageData: Data([1, 2, 3, 4, 5]),
            fileExtension: "png",
            destination: SSHDestination(target: "peter@example.test", port: 2222),
            progress: { progressFractions.append($0) }
        )

        XCTAssertEqual(path, "/tmp/zentty-paste-1700000000-12345678.png")
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/ssh")
        XCTAssertEqual(process.arguments, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-p", "2222",
            "--",
            "peter@example.test",
            "sh",
            "-c",
            "umask 077; cat > /tmp/zentty-paste-1700000000-12345678.png",
        ])
        let destinationIndex = try XCTUnwrap(process.arguments.firstIndex(of: "peter@example.test"))
        XCTAssertFalse(process.arguments[(destinationIndex + 1)...].contains { $0.hasPrefix("--") })
        XCTAssertEqual(process.writtenChunks, [Data([1, 2]), Data([3, 4]), Data([5])])
        XCTAssertTrue(process.didCloseStandardInput)
        XCTAssertEqual(progressFractions, [0.4, 0.8, 1.0])
    }

    func test_upload_maps_permission_denied_to_auth_required() async {
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(
                exitStatus: 255,
                stderr: "Permission denied (publickey).",
                timedOut: false
            )
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            remotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678.png" },
            chunkSize: 64,
            timeout: 60
        )

        await XCTAssertThrowsRemoteImageUploadError(.authRequired) {
            _ = try await uploader.upload(
                imageData: Data([1, 2, 3]),
                fileExtension: "png",
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }
    }

    func test_upload_maps_unreachable_stderr_to_host_unreachable() async {
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(
                exitStatus: 255,
                stderr: "ssh: connect to host example.test port 22: Operation timed out",
                timedOut: false
            )
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            remotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678.png" },
            chunkSize: 64,
            timeout: 60
        )

        await XCTAssertThrowsRemoteImageUploadError(.hostUnreachable) {
            _ = try await uploader.upload(
                imageData: Data([1, 2, 3]),
                fileExtension: "png",
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }
    }

    func test_upload_maps_permission_denied_to_auth_required_after_write_failure() async {
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(
                exitStatus: 255,
                stderr: "Permission denied (publickey).",
                timedOut: false
            ),
            throwOnWriteNumber: 2
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            remotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678.png" },
            chunkSize: 2,
            timeout: 60
        )

        await XCTAssertThrowsRemoteImageUploadError(.authRequired) {
            _ = try await uploader.upload(
                imageData: Data([1, 2, 3, 4, 5]),
                fileExtension: "png",
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }

        XCTAssertEqual(process.waitUntilExitCallCount, 1)
    }

    func test_upload_maps_connection_timeout_to_host_unreachable_after_write_failure() async {
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(
                exitStatus: 255,
                stderr: "ssh: connect to host example.test port 22: Connection timed out",
                timedOut: false
            ),
            throwOnWriteNumber: 2
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            remotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678.png" },
            chunkSize: 2,
            timeout: 60
        )

        await XCTAssertThrowsRemoteImageUploadError(.hostUnreachable) {
            _ = try await uploader.upload(
                imageData: Data([1, 2, 3, 4, 5]),
                fileExtension: "png",
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }

        XCTAssertEqual(process.waitUntilExitCallCount, 1)
    }

    func test_upload_maps_overall_timeout_to_timeout_error() async {
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(exitStatus: -1, stderr: "", timedOut: true)
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            remotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678.png" },
            chunkSize: 64,
            timeout: 60
        )

        await XCTAssertThrowsRemoteImageUploadError(.timeout) {
            _ = try await uploader.upload(
                imageData: Data([1, 2, 3]),
                fileExtension: "png",
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }
    }

    func test_remote_path_generation_uses_safe_filename_and_normalized_extension() throws {
        let path = RemoteImageUploadPath.generate(
            fileExtension: "jpeg",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
        )

        XCTAssertEqual(path, "/tmp/zentty-paste-1700000000-12345678.jpeg")
        XCTAssertTrue(RemoteImageUploadPath.isSafeRemotePath(path))
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "public.png"), "png")
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "public.jpeg"), "jpeg")
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "public.tiff"), "tiff")
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "com.compuserve.gif"), "gif")
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "org.webmproject.webp"), "webp")
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "public.heic"), "heic")
        XCTAssertEqual(TerminalClipboardImagePolicy.fileExtension(forUTIIdentifier: "com.example.unknown"), "png")
    }
}

private func XCTAssertThrowsRemoteImageUploadError(
    _ expected: RemoteImageUploadError,
    operation: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as RemoteImageUploadError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private final class FakeRemoteImageUploadProcessFactory: RemoteImageUploadProcessFactory, @unchecked Sendable {
    private let process: FakeRemoteImageUploadProcess

    init(process: FakeRemoteImageUploadProcess) {
        self.process = process
    }

    func makeProcess(executableURL: URL, arguments: [String]) -> any RemoteImageUploadProcess {
        process.executableURL = executableURL
        process.arguments = arguments
        return process
    }
}

private final class FakeRemoteImageUploadProcess: RemoteImageUploadProcess, @unchecked Sendable {
    private enum FakeWriteError: Error {
        case brokenPipe
    }

    var executableURL: URL?
    var arguments: [String] = []
    var writtenChunks: [Data] = []
    var didCloseStandardInput = false
    var waitUntilExitCallCount = 0

    private let result: RemoteImageUploadProcessResult
    private let throwOnWriteNumber: Int?

    init(
        result: RemoteImageUploadProcessResult,
        throwOnWriteNumber: Int? = nil
    ) {
        self.result = result
        self.throwOnWriteNumber = throwOnWriteNumber
    }

    func run() throws {}

    func write(_ data: Data) throws {
        if writtenChunks.count + 1 == throwOnWriteNumber {
            throw FakeWriteError.brokenPipe
        }

        writtenChunks.append(data)
    }

    func closeStandardInput() {
        didCloseStandardInput = true
    }

    func waitUntilExit(timeout: TimeInterval) -> RemoteImageUploadProcessResult {
        waitUntilExitCallCount += 1
        return result
    }

    func terminate() {}
}
