import Foundation

struct SSHDestination: Equatable, Sendable {
    let target: String
    let user: String?
    let host: String
    let port: Int?

    init(target: String, user: String? = nil, host: String? = nil, port: Int? = nil) {
        self.target = target
        self.user = user
        self.host = host ?? Self.host(from: target)
        self.port = port
    }

    private static func host(from target: String) -> String {
        target.split(separator: "@", maxSplits: 1).last.map(String.init) ?? target
    }
}

enum RemoteImageUploadError: Error, Equatable, Sendable {
    case authRequired
    case hostUnreachable
    case timeout
    case transferFailed
    case invalidRemotePath
}

struct RemoteImageUploadProcessResult: Equatable, Sendable {
    let exitStatus: Int32
    let stderr: String
    let timedOut: Bool
}

protocol RemoteImageUploadProcess: AnyObject, Sendable {
    func run() throws
    func write(_ data: Data) throws
    func closeStandardInput()
    func waitUntilExit(timeout: TimeInterval) -> RemoteImageUploadProcessResult
    func terminate()
}

protocol RemoteImageUploadProcessFactory: Sendable {
    func makeProcess(executableURL: URL, arguments: [String]) -> any RemoteImageUploadProcess
}

struct ProcessRemoteImageUploadProcessFactory: RemoteImageUploadProcessFactory {
    func makeProcess(executableURL: URL, arguments: [String]) -> any RemoteImageUploadProcess {
        ProcessRemoteImageUploadProcess(executableURL: executableURL, arguments: arguments)
    }
}

struct RemoteImageUploader: Sendable {
    private let processFactory: any RemoteImageUploadProcessFactory
    private let remotePathProvider: @Sendable (String) -> String
    private let chunkSize: Int
    private let timeout: TimeInterval

    init(
        processFactory: any RemoteImageUploadProcessFactory = ProcessRemoteImageUploadProcessFactory(),
        remotePathProvider: @escaping @Sendable (String) -> String = { fileExtension in
            RemoteImageUploadPath.generate(fileExtension: fileExtension)
        },
        chunkSize: Int = 64 * 1024,
        timeout: TimeInterval = 60
    ) {
        self.processFactory = processFactory
        self.remotePathProvider = remotePathProvider
        self.chunkSize = max(1, chunkSize)
        self.timeout = timeout
    }

    func upload(
        imageData: Data,
        fileExtension: String,
        destination: SSHDestination,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        let normalizedExtension = TerminalClipboardImagePolicy.normalizedFileExtension(fileExtension)
        let remotePath = remotePathProvider(normalizedExtension)
        guard RemoteImageUploadPath.isSafeRemotePath(remotePath) else {
            throw RemoteImageUploadError.invalidRemotePath
        }

        let arguments = Self.sshArguments(destination: destination, remotePath: remotePath)
        let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let processFactory = processFactory
        let chunkSize = chunkSize
        let timeout = timeout

        let uploadTask = Task<String, Error>.detached(priority: .utility) {
            let process = processFactory.makeProcess(
                executableURL: executableURL,
                arguments: arguments
            )
            let timeoutState = TimeoutState()
            let timeoutTask = Self.startTimeout(
                seconds: timeout,
                process: process,
                timeoutState: timeoutState
            )
            defer {
                timeoutTask.cancel()
            }

            return try await withTaskCancellationHandler(operation: {
                try await Self.writeAndValidateUpload(
                    imageData: imageData,
                    process: process,
                    chunkSize: chunkSize,
                    timeout: timeout,
                    timeoutState: timeoutState,
                    progress: progress
                )
                return remotePath
            }, onCancel: {
                process.terminate()
                process.closeStandardInput()
            })
        }

        return try await withTaskCancellationHandler(operation: {
            try await uploadTask.value
        }, onCancel: {
            uploadTask.cancel()
        })
    }

    private static func writeAndValidateUpload(
        imageData: Data,
        process: any RemoteImageUploadProcess,
        chunkSize: Int,
        timeout: TimeInterval,
        timeoutState: TimeoutState,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        var didRunProcess = false
        do {
            try process.run()
            didRunProcess = true
            try Task.checkCancellation()
            try await write(
                imageData,
                to: process,
                chunkSize: chunkSize,
                progress: progress
            )
            let result = process.waitUntilExit(timeout: timeout)
            if timeoutState.timedOut {
                throw RemoteImageUploadError.timeout
            }

            try validate(result)
        } catch let uploadError as RemoteImageUploadError {
            process.closeStandardInput()
            if timeoutState.timedOut {
                throw RemoteImageUploadError.timeout
            }
            throw uploadError
        } catch is CancellationError {
            process.terminate()
            process.closeStandardInput()
            throw CancellationError()
        } catch {
            process.closeStandardInput()
            if timeoutState.timedOut {
                throw RemoteImageUploadError.timeout
            }

            if didRunProcess {
                let result = process.waitUntilExit(timeout: timeout)
                if timeoutState.timedOut || result.timedOut {
                    throw RemoteImageUploadError.timeout
                }

                if result.exitStatus != 0 {
                    throw classifiedError(stderr: result.stderr)
                }
            }

            throw RemoteImageUploadError.transferFailed
        }
    }

    static func sshArguments(destination: SSHDestination, remotePath: String) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ]
        if let port = destination.port {
            arguments += ["-p", "\(port)"]
        }
        arguments += [
            "--",
            destination.target,
            "sh",
            "-c",
            "umask 077; cat > \(remotePath)",
        ]
        return arguments
    }

    private static func write(
        _ imageData: Data,
        to process: any RemoteImageUploadProcess,
        chunkSize: Int,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        var offset = 0
        let totalBytes = imageData.count
        while offset < totalBytes {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, totalBytes)
            try process.write(imageData.subdata(in: offset..<end))
            offset = end
            await MainActor.run {
                progress(Double(offset) / Double(totalBytes))
            }
        }
        try Task.checkCancellation()
        process.closeStandardInput()
    }

    private static func validate(_ result: RemoteImageUploadProcessResult) throws {
        if result.timedOut {
            throw RemoteImageUploadError.timeout
        }

        guard result.exitStatus == 0 else {
            throw classifiedError(stderr: result.stderr)
        }
    }

    private static func classifiedError(stderr: String) -> RemoteImageUploadError {
        let lowered = stderr.lowercased()
        if lowered.contains("permission denied")
            || lowered.contains("publickey")
            || lowered.contains("authentication")
        {
            return .authRequired
        }

        if lowered.contains("operation timed out")
            || lowered.contains("connection timed out")
            || lowered.contains("could not resolve hostname")
            || lowered.contains("no route to host")
            || lowered.contains("connection refused")
            || lowered.contains("host is down")
        {
            return .hostUnreachable
        }

        return .transferFailed
    }

    private static func startTimeout(
        seconds: TimeInterval,
        process: any RemoteImageUploadProcess,
        timeoutState: TimeoutState
    ) -> Task<Void, Never> {
        let nanoseconds = UInt64(max(0.001, seconds) * 1_000_000_000)
        return Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            timeoutState.markTimedOut()
            process.terminate()
            process.closeStandardInput()
        }
    }
}

enum RemoteImageUploadPath {
    static func generate(
        fileExtension: String,
        date: Date = Date(),
        uuid: UUID = UUID()
    ) -> String {
        let timestamp = Int(date.timeIntervalSince1970)
        let uuidPrefix = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        let ext = TerminalClipboardImagePolicy.normalizedFileExtension(fileExtension)
        return "/tmp/zentty-paste-\(timestamp)-\(uuidPrefix).\(ext)"
    }

    static func isSafeRemotePath(_ path: String) -> Bool {
        path.range(
            of: #"^/tmp/zentty-paste-[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
    }
}

private final class ProcessRemoteImageUploadProcess: RemoteImageUploadProcess, @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let stderrPipe = Pipe()

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardError = stderrPipe
    }

    func run() throws {
        try process.run()
    }

    func write(_ data: Data) throws {
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func closeStandardInput() {
        try? inputPipe.fileHandleForWriting.close()
    }

    func waitUntilExit(timeout: TimeInterval) -> RemoteImageUploadProcessResult {
        let timeoutState = TimeoutState()
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            timeoutState.markTimedOut()
            self?.process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        process.waitUntilExit()
        timeoutWorkItem.cancel()

        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        return RemoteImageUploadProcessResult(
            exitStatus: process.terminationStatus,
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timeoutState.timedOut
        )
    }

    func terminate() {
        process.terminate()
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
