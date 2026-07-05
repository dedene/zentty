import Foundation

struct RemoteFileResourceValues: Equatable, Sendable {
    let isDirectory: Bool
    let fileSize: Int64?
}

protocol RemoteFileResourceResolving: Sendable {
    func values(for fileURL: URL) throws -> RemoteFileResourceValues
}

struct FileManagerRemoteFileResourceResolver: RemoteFileResourceResolving {
    func values(for fileURL: URL) throws -> RemoteFileResourceValues {
        let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return RemoteFileResourceValues(
            isDirectory: resourceValues.isDirectory == true,
            fileSize: resourceValues.fileSize.map(Int64.init)
        )
    }
}

struct RemoteFileUploadRequest: Equatable, Sendable {
    let localURL: URL
    let originalFilename: String
    let byteCount: Int64
}

enum RemoteFileUploadRequestResolution: Equatable, Sendable {
    case noFiles
    case files([RemoteFileUploadRequest])
    case foldersOnly
    case fileTooLarge
    case failedToResolve
}

enum RemoteFileUploadRequestResolver {
    static let maxFileByteCount: Int64 = 500 * 1024 * 1024

    static func resolve(
        fileURLs: [URL],
        resourceResolver: any RemoteFileResourceResolving = FileManagerRemoteFileResourceResolver()
    ) -> RemoteFileUploadRequestResolution {
        guard !fileURLs.isEmpty else {
            return .noFiles
        }

        var requests: [RemoteFileUploadRequest] = []
        var skippedDirectoryCount = 0
        var sawNonDirectory = false

        for fileURL in fileURLs {
            let values: RemoteFileResourceValues
            do {
                values = try resourceResolver.values(for: fileURL)
            } catch {
                return .failedToResolve
            }

            if values.isDirectory {
                skippedDirectoryCount += 1
                continue
            }

            sawNonDirectory = true
            guard let byteCount = values.fileSize else {
                return .failedToResolve
            }
            guard byteCount <= maxFileByteCount else {
                return .fileTooLarge
            }

            let filename = fileURL.lastPathComponent.isEmpty ? "file" : fileURL.lastPathComponent
            requests.append(
                RemoteFileUploadRequest(
                    localURL: fileURL,
                    originalFilename: filename,
                    byteCount: byteCount
                )
            )
        }

        if !requests.isEmpty {
            return .files(requests)
        }

        if skippedDirectoryCount > 0 && !sawNonDirectory {
            return .foldersOnly
        }

        return .failedToResolve
    }
}

struct RemoteFileUploadProgress: Equatable, Sendable {
    let filename: String
    let fileIndex: Int
    let fileCount: Int
    let fraction: Double
}

struct RemoteFileUploadBatchResult: Equatable, Sendable {
    let successfulRemotePaths: [String]
    let failedCount: Int
    let totalCount: Int
    let firstFailure: RemoteImageUploadError?

    var pasteText: String {
        successfulRemotePaths
            .map { ShellEscaping.escapePath($0) }
            .joined(separator: " ")
    }
}

struct RemoteFileUploadBatch: Sendable {
    let uploader: RemoteImageUploader

    func uploadFiles(
        _ requests: [RemoteFileUploadRequest],
        destination: SSHDestination,
        progress: @escaping @MainActor @Sendable (RemoteFileUploadProgress) -> Void
    ) async throws -> RemoteFileUploadBatchResult {
        var successfulRemotePaths: [String] = []
        var failedCount = 0
        var firstFailure: RemoteImageUploadError?
        let totalCount = requests.count

        for (index, request) in requests.enumerated() {
            do {
                let remotePath = try await uploader.upload(
                    fileURL: request.localURL,
                    originalFilename: request.originalFilename,
                    byteCount: request.byteCount,
                    destination: destination,
                    progress: { fraction in
                        progress(
                            RemoteFileUploadProgress(
                                filename: request.originalFilename,
                                fileIndex: index + 1,
                                fileCount: totalCount,
                                fraction: fraction
                            )
                        )
                    }
                )
                successfulRemotePaths.append(remotePath)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemoteImageUploadError {
                failedCount += 1
                if firstFailure == nil {
                    firstFailure = error
                }
            } catch {
                failedCount += 1
                if firstFailure == nil {
                    firstFailure = .transferFailed
                }
            }

            try Task.checkCancellation()
        }

        return RemoteFileUploadBatchResult(
            successfulRemotePaths: successfulRemotePaths,
            failedCount: failedCount,
            totalCount: totalCount,
            firstFailure: firstFailure
        )
    }
}
