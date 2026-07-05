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

    func test_upload_file_url_streams_chunks_reports_progress_and_returns_remote_path() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([1, 2, 3, 4, 5]), filename: "Quarterly Report.pdf")
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(exitStatus: 0, stderr: "", timedOut: false)
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            fileRemotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678-Quarterly-Report.pdf" },
            chunkSize: 2,
            timeout: 60
        )
        var progressFractions: [Double] = []

        let path = try await uploader.upload(
            fileURL: fileURL,
            originalFilename: "Quarterly Report.pdf",
            byteCount: 5,
            destination: SSHDestination(target: "peter@example.test"),
            progress: { progressFractions.append($0) }
        )

        XCTAssertEqual(path, "/tmp/zentty-paste-1700000000-12345678-Quarterly-Report.pdf")
        XCTAssertEqual(process.writtenChunks, [Data([1, 2]), Data([3, 4]), Data([5])])
        XCTAssertTrue(process.didCloseStandardInput)
        XCTAssertEqual(progressFractions, [0.4, 0.8, 1.0])
    }

    func test_upload_file_url_maps_permission_denied_to_auth_required() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([1, 2, 3]), filename: "private.pdf")
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(
                exitStatus: 255,
                stderr: "Permission denied (publickey).",
                timedOut: false
            )
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            fileRemotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678-private.pdf" },
            chunkSize: 64,
            timeout: 60
        )

        await XCTAssertThrowsRemoteImageUploadError(.authRequired) {
            _ = try await uploader.upload(
                fileURL: fileURL,
                originalFilename: "private.pdf",
                byteCount: 3,
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }
    }

    func test_upload_file_url_cancellation_mid_file_terminates_process() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([1, 2, 3, 4, 5]), filename: "cancel.bin")
        let process = FakeRemoteImageUploadProcess(
            result: RemoteImageUploadProcessResult(exitStatus: 0, stderr: "", timedOut: false),
            blockOnWriteNumber: 2
        )
        let uploader = RemoteImageUploader(
            processFactory: FakeRemoteImageUploadProcessFactory(process: process),
            fileRemotePathProvider: { _ in "/tmp/zentty-paste-1700000000-12345678-cancel.bin" },
            chunkSize: 1,
            timeout: 60
        )

        let task = Task {
            try await uploader.upload(
                fileURL: fileURL,
                originalFilename: "cancel.bin",
                byteCount: 5,
                destination: SSHDestination(target: "example.test"),
                progress: { _ in }
            )
        }

        let didBlockOnWrite = await Task.detached {
            process.waitForBlockedWrite(timeout: 2)
        }.value
        XCTAssertTrue(didBlockOnWrite)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(process.didTerminate)
        XCTAssertTrue(process.didCloseStandardInput)
        XCTAssertLessThan(process.writtenChunks.count, 5)
    }

    func test_batch_upload_preserves_drop_order_and_omits_failed_files_from_paste_text() async throws {
        let firstURL = try makeTemporaryFile(contents: Data([1]), filename: "first.pdf")
        let secondURL = try makeTemporaryFile(contents: Data([2]), filename: "second.mov")
        let thirdURL = try makeTemporaryFile(contents: Data([3]), filename: "third.zip")
        let factory = SequencedFakeRemoteImageUploadProcessFactory(processes: [
            FakeRemoteImageUploadProcess(
                result: RemoteImageUploadProcessResult(exitStatus: 0, stderr: "", timedOut: false)
            ),
            FakeRemoteImageUploadProcess(
                result: RemoteImageUploadProcessResult(exitStatus: 1, stderr: "disk full", timedOut: false)
            ),
            FakeRemoteImageUploadProcess(
                result: RemoteImageUploadProcessResult(exitStatus: 0, stderr: "", timedOut: false)
            ),
        ])
        let uploader = RemoteImageUploader(
            processFactory: factory,
            fileRemotePathProvider: {
                RemoteImageUploadPath.path(
                    forOriginalFilename: $0,
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    uuid: UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
                )
            },
            chunkSize: 64,
            timeout: 60
        )
        let batch = RemoteFileUploadBatch(uploader: uploader)

        let result = try await batch.uploadFiles(
            [
                RemoteFileUploadRequest(localURL: firstURL, originalFilename: "first.pdf", byteCount: 1),
                RemoteFileUploadRequest(localURL: secondURL, originalFilename: "second.mov", byteCount: 1),
                RemoteFileUploadRequest(localURL: thirdURL, originalFilename: "third.zip", byteCount: 1),
            ],
            destination: SSHDestination(target: "example.test"),
            progress: { _ in }
        )

        XCTAssertEqual(result.successfulRemotePaths, [
            "/tmp/zentty-paste-1700000000-12345678-first.pdf",
            "/tmp/zentty-paste-1700000000-12345678-third.zip",
        ])
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertEqual(
            result.pasteText,
            "/tmp/zentty-paste-1700000000-12345678-first.pdf /tmp/zentty-paste-1700000000-12345678-third.zip"
        )
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

    func test_remote_path_generation_from_original_filename_sanitizes_names_and_preserves_extension() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let uuid = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!

        XCTAssertEqual(
            uploadedName(for: "Quarterly Report.pdf", date: date, uuid: uuid),
            "Quarterly-Report.pdf"
        )
        XCTAssertEqual(
            uploadedName(for: "résumé 🚀.png", date: date, uuid: uuid),
            "r-sum.png"
        )
        XCTAssertEqual(
            uploadedName(for: "???bad***name.zip", date: date, uuid: uuid),
            "bad-name.zip"
        )
        XCTAssertEqual(
            uploadedName(for: ".env", date: date, uuid: uuid),
            "env"
        )
        XCTAssertEqual(
            uploadedName(for: "README", date: date, uuid: uuid),
            "README"
        )

        let longName = uploadedName(
            for: "\(String(repeating: "a", count: 160)).tar.gz",
            date: date,
            uuid: uuid
        )
        XCTAssertLessThanOrEqual(longName.count, 128)
        XCTAssertTrue(longName.hasSuffix(".gz"))
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

private final class SequencedFakeRemoteImageUploadProcessFactory: RemoteImageUploadProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [FakeRemoteImageUploadProcess]

    init(processes: [FakeRemoteImageUploadProcess]) {
        self.processes = processes
    }

    func makeProcess(executableURL: URL, arguments: [String]) -> any RemoteImageUploadProcess {
        lock.lock()
        let process = processes.removeFirst()
        lock.unlock()

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
    var didTerminate = false
    var waitUntilExitCallCount = 0

    private let result: RemoteImageUploadProcessResult
    private let throwOnWriteNumber: Int?
    private let blockOnWriteNumber: Int?
    private let blockedWriteSemaphore = DispatchSemaphore(value: 0)
    private let unblockWriteSemaphore = DispatchSemaphore(value: 0)

    init(
        result: RemoteImageUploadProcessResult,
        throwOnWriteNumber: Int? = nil,
        blockOnWriteNumber: Int? = nil
    ) {
        self.result = result
        self.throwOnWriteNumber = throwOnWriteNumber
        self.blockOnWriteNumber = blockOnWriteNumber
    }

    func run() throws {}

    func write(_ data: Data) throws {
        if writtenChunks.count + 1 == throwOnWriteNumber {
            throw FakeWriteError.brokenPipe
        }

        if writtenChunks.count + 1 == blockOnWriteNumber {
            blockedWriteSemaphore.signal()
            _ = unblockWriteSemaphore.wait(timeout: .now() + 2)
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

    func terminate() {
        didTerminate = true
        unblockWriteSemaphore.signal()
    }

    func waitForBlockedWrite(timeout: TimeInterval) -> Bool {
        blockedWriteSemaphore.wait(timeout: .now() + timeout) == .success
    }
}

private func makeTemporaryFile(contents: Data, filename: String) throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Zentty.RemoteImageUploaderTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let fileURL = directoryURL.appendingPathComponent(filename)
    try contents.write(to: fileURL)
    return fileURL
}

private func uploadedName(for originalFilename: String, date: Date, uuid: UUID) -> String {
    let path = RemoteImageUploadPath.path(
        forOriginalFilename: originalFilename,
        date: date,
        uuid: uuid
    )
    XCTAssertTrue(RemoteImageUploadPath.isSafeRemotePath(path))
    let prefix = "/tmp/zentty-paste-1700000000-12345678-"
    XCTAssertTrue(path.hasPrefix(prefix))
    return String(path.dropFirst(prefix.count))
}
