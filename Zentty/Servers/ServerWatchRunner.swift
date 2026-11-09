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
        let stdoutLines = ServerWatchLineBufferBox()
        let stderrLines = ServerWatchLineBufferBox()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            forwardChunk(from: fileHandle, to: output, lines: stdoutLines, lock: forwardLock, detect: detect, handleDetection: handleDetection)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            forwardChunk(from: fileHandle, to: errorOutput, lines: stderrLines, lock: forwardLock, detect: detect, handleDetection: handleDetection)
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
                stdoutHasData = forwardChunk(from: stdoutPipe.fileHandleForReading, to: output, lines: stdoutLines, lock: forwardLock, detect: detect, handleDetection: handleDetection)
            }
            if stderrHasData {
                stderrHasData = forwardChunk(from: stderrPipe.fileHandleForReading, to: errorOutput, lines: stderrLines, lock: forwardLock, detect: detect, handleDetection: handleDetection)
            }
        }
        forwardLock.withLock {
            for lines in [stdoutLines, stderrLines] {
                if let text = lines.buffer.flush() {
                    detect(text).forEach(handleDetection)
                }
            }
        }
        return process.terminationStatus
    }

    /// Upper bound on forwarding output that is still buffered after the
    /// watched command exited.
    static let finalDrainTimeout: TimeInterval = 0.25
}

/// Reassembles one output stream for URL detection, since a pipe read can end
/// anywhere, including inside a URL or a UTF-8 sequence. Text is released up to
/// the last byte that ends a URL, so a server that prints one and keeps running
/// is detected without a newline. What follows waits in the tail, capped so an
/// endless token stays bounded; a URL inside a token longer than the cap can be lost.
struct ServerWatchLineBuffer {
    static let defaultCapacity = 64 * 1024

    private let capacity: Int
    private var tail = Data()

    init(capacity: Int = ServerWatchLineBuffer.defaultCapacity) {
        self.capacity = capacity
    }

    /// Returns the text `data` completed, or `nil` when nothing ended in it.
    mutating func append(_ data: Data) -> String? {
        tail.append(data)
        var completedText: String?
        if let lastDelimiter = tail.lastIndex(where: ServerOutputURLDetector.urlDelimiters.contains) {
            let tailStart = tail.index(after: lastDelimiter)
            completedText = String(decoding: tail[..<tailStart], as: UTF8.self)
            tail = Data(tail[tailStart...])
        }
        if tail.count > capacity {
            tail = Data(tail.suffix(capacity))
        }
        return completedText
    }

    /// Returns the unterminated tail once the stream is done.
    mutating func flush() -> String? {
        guard !tail.isEmpty else {
            return nil
        }
        defer { tail = Data() }
        return String(decoding: tail, as: UTF8.self)
    }
}

/// One stream's buffer, shared with its readability handler. `forwardLock`
/// guards every access.
private final class ServerWatchLineBufferBox: @unchecked Sendable {
    var buffer = ServerWatchLineBuffer()
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
    lines: ServerWatchLineBufferBox,
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
    if let text = lines.buffer.append(data) {
        detect(text).forEach(handleDetection)
    }
    return true
}
