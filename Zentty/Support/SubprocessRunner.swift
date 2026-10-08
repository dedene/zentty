import Darwin
import Foundation

struct SubprocessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

enum SubprocessError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
}

/// Runs a short-lived child process to completion without leaking it.
///
/// stdout and stderr are drained while the child runs, so a chatty child can
/// never block on a full pipe. On timeout the child gets `SIGKILL` (CLIs such
/// as docker ignore the first `SIGTERM`) and is waited for before returning.
/// A non-zero exit is reported in the result, not thrown.
///
/// Limits: only the direct child is killed on timeout; helper processes it
/// spawned are not (no process group). Output a grandchild still writes more
/// than `drainGraceAfterExit` after the child exited is dropped. Output is
/// buffered in memory, unbounded, until the child exits or the timeout fires.
enum SubprocessRunner {
    /// How long to keep reading after the child exited while a grandchild that
    /// inherited stdout/stderr still holds the pipe open.
    static let drainGraceAfterExit: TimeInterval = 0.25
    /// Upper bound on waiting for a `SIGKILL`ed child to be reported as exited.
    private static let reapTimeout: TimeInterval = 2
    private static let pollSliceMilliseconds: Int32 = 50

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval?
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            closeAll(stdoutPipe, stderrPipe)
            throw SubprocessError.launchFailed(String(describing: error))
        }
        // Foundation already closes the parent's write ends after launch (this
        // is then a no-op); an open copy here would keep EOF from ever arriving.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        let deadline = timeout.map { DispatchTime.now() + $0 }
        var drain = PipeDrain(
            stdoutFD: stdoutPipe.fileHandleForReading.fileDescriptor,
            stderrFD: stderrPipe.fileHandleForReading.fileDescriptor
        )
        var hasExited = false
        var drainDeadline: DispatchTime?

        while drain.isOpen {
            if !hasExited, exited.wait(timeout: .now()) == .success {
                hasExited = true
                drainDeadline = .now() + drainGraceAfterExit
            }
            let now = DispatchTime.now()
            if let drainDeadline, now >= drainDeadline {
                break
            }
            if !hasExited, let deadline, now >= deadline {
                killAndReap(process, exited: exited)
                throw SubprocessError.timedOut
            }
            drain.readAvailable(waitingAtMost: pollSliceMilliseconds)
        }

        // Output is closed; the child may still be running (it closed its
        // stdio early), so the overall timeout still applies.
        if !hasExited {
            if let deadline {
                if exited.wait(timeout: deadline) == .timedOut {
                    killAndReap(process, exited: exited)
                    throw SubprocessError.timedOut
                }
            } else {
                exited.wait()
            }
        }

        return SubprocessResult(
            terminationStatus: process.terminationStatus,
            stdout: drain.stdout,
            stderr: drain.stderr
        )
    }

    private static func killAndReap(_ process: Process, exited: DispatchSemaphore) {
        // Only signal a pid Foundation has not reaped yet; a reaped pid may
        // already belong to an unrelated process.
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // Foundation reaps the child; the termination handler fires afterwards.
        _ = exited.wait(timeout: .now() + reapTimeout)
    }

    private static func closeAll(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}

/// Reads stdout and stderr together with `poll(2)` so neither pipe can fill
/// up while the other is being waited on.
private struct PipeDrain {
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private var stdoutFD: Int32?
    private var stderrFD: Int32?
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(stdoutFD: Int32, stderrFD: Int32) {
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
    }

    var isOpen: Bool {
        stdoutFD != nil || stderrFD != nil
    }

    mutating func readAvailable(waitingAtMost milliseconds: Int32) {
        var fds = [stdoutFD, stderrFD].compactMap { $0 }.map {
            pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
        }
        let ready = poll(&fds, nfds_t(fds.count), milliseconds)
        guard ready > 0 else {
            return
        }

        for entry in fds where entry.revents != 0 {
            let isOpen = readOnce(from: entry.fd)
            if !isOpen {
                if entry.fd == stdoutFD {
                    stdoutFD = nil
                } else if entry.fd == stderrFD {
                    stderrFD = nil
                }
            }
        }
    }

    /// Returns `false` once the descriptor reached EOF or failed.
    private mutating func readOnce(from fd: Int32) -> Bool {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            if fd == stdoutFD {
                stdout.append(contentsOf: buffer[0..<count])
            } else {
                stderr.append(contentsOf: buffer[0..<count])
            }
            return true
        }
        if count < 0, errno == EINTR || errno == EAGAIN {
            return true
        }
        return false
    }
}
