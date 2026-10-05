import Darwin
import Foundation

struct ServerWatchRunner {
    typealias Detector = @Sendable (String) -> [ServerURLCandidate]
    typealias DetectionHandler = @Sendable (ServerURLCandidate) -> Void

    let detect: Detector
    let handleDetection: DetectionHandler
    let output: FileHandle
    let errorOutput: FileHandle

    init(
        detect: @escaping Detector = ServerOutputURLDetector.detect(in:),
        handleDetection: @escaping DetectionHandler,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) {
        self.detect = detect
        self.handleDetection = handleDetection
        self.output = output
        self.errorOutput = errorOutput
    }

    func run(command: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int32 {
        guard let executable = command.first else {
            throw ServerWatchRunnerError.missingCommand
        }

        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(command.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }
        process.environment = environment
        process.standardInput = FileHandle.standardInput

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output = output
        let errorOutput = errorOutput
        let detect = detect
        let handleDetection = handleDetection
        // Serializes the handlers with the final drain so chunks stay ordered
        // and each one is forwarded exactly once.
        let forwardLock = NSLock()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            forwardChunk(from: fileHandle, to: output, lock: forwardLock, detect: detect, handleDetection: handleDetection)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            forwardChunk(from: fileHandle, to: errorOutput, lock: forwardLock, detect: detect, handleDetection: handleDetection)
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Output the child wrote just before exiting may still sit in the pipe.
        // Only take what is already buffered, and only briefly: a grandchild
        // (e.g. a dev server left running) may hold the pipe open and keep writing.
        let drainDeadline = DispatchTime.now() + Self.finalDrainTimeout
        var stdoutHasData = true
        var stderrHasData = true
        while stdoutHasData || stderrHasData, DispatchTime.now() < drainDeadline {
            if stdoutHasData {
                stdoutHasData = forwardChunk(from: stdoutPipe.fileHandleForReading, to: output, lock: forwardLock, detect: detect, handleDetection: handleDetection)
            }
            if stderrHasData {
                stderrHasData = forwardChunk(from: stderrPipe.fileHandleForReading, to: errorOutput, lock: forwardLock, detect: detect, handleDetection: handleDetection)
            }
        }
        return process.terminationStatus
    }

    /// Upper bound on forwarding output that is still buffered after the
    /// watched command exited.
    static let finalDrainTimeout: TimeInterval = 0.25
}

enum ServerWatchRunnerError: LocalizedError, Equatable {
    case missingCommand

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            "Missing command after zentty server watch --."
        }
    }
}

/// Forwards one buffered chunk. Returns `false` when nothing was readable
/// (empty pipe or EOF). Polls first so it never blocks on a quiet pipe.
@discardableResult
private func forwardChunk(
    from source: FileHandle,
    to destination: FileHandle,
    lock: NSLock,
    detect: (String) -> [ServerURLCandidate],
    handleDetection: (ServerURLCandidate) -> Void
) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    var pollEntry = pollfd(fd: source.fileDescriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&pollEntry, 1, 0) > 0 else {
        return false
    }
    let data = source.availableData
    guard !data.isEmpty else {
        return false
    }

    destination.write(data)
    if let text = String(data: data, encoding: .utf8) {
        for candidate in detect(text) {
            handleDetection(candidate)
        }
    }
    return true
}
