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
        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            forwardChunk(from: fileHandle, to: output, detect: detect, handleDetection: handleDetection)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            forwardChunk(from: fileHandle, to: errorOutput, detect: detect, handleDetection: handleDetection)
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
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

private func forwardChunk(
    from source: FileHandle,
    to destination: FileHandle,
    detect: (String) -> [ServerURLCandidate],
    handleDetection: (ServerURLCandidate) -> Void
) {
    let data = source.availableData
    guard !data.isEmpty else {
        return
    }

    destination.write(data)
    guard let text = String(data: data, encoding: .utf8) else {
        return
    }

    for candidate in detect(text) {
        handleDetection(candidate)
    }
}
