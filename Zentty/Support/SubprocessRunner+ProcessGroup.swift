import Darwin
import Foundation

extension SubprocessRunner {
    /// Like `run`, but for commands that must get a chance to undo their own work when they time
    /// out. The child leads a new process group, and a timeout signals that whole group: `SIGTERM`
    /// first, so the child and the helpers it spawned run their signal cleanup, then `SIGKILL`
    /// for anything still alive after `terminationGracePeriod`.
    ///
    /// Example: `git worktree add` removes its half-made worktree and registration on `SIGTERM`.
    /// On `SIGKILL` it leaves both behind, locked as "initializing", while its checkout child keeps
    /// writing into the folder.
    ///
    /// The leader is detected as exited without being reaped (`WNOWAIT`), so its pid, and with it
    /// the process group id, cannot be reused while stragglers are signalled.
    static func runInProcessGroup(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval
    ) throws -> SubprocessResult {
        let child = try ProcessGroupChild.spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        defer {
            close(child.stdoutFD)
            close(child.stderrFD)
        }

        let deadline = DispatchTime.now() + timeout
        var drain = PipeDrain(stdoutFD: child.stdoutFD, stderrFD: child.stderrFD)
        var drainDeadline: DispatchTime?

        while true {
            if drainDeadline == nil, child.hasExited() {
                drainDeadline = .now() + drainGraceAfterExit
            }
            let now = DispatchTime.now()
            if let drainDeadline, now >= drainDeadline || !drain.isOpen {
                break
            }
            if drainDeadline == nil, now >= deadline {
                child.terminateGroup(gracePeriod: terminationGracePeriod, draining: &drain)
                throw SubprocessError.timedOut
            }
            if drain.isOpen {
                drain.readAvailable(waitingAtMost: 50)
            } else {
                // stdio closed early but the child still runs; the overall timeout still applies.
                usleep(20_000)
            }
        }

        return SubprocessResult(
            terminationStatus: child.reap(),
            stdout: drain.stdout,
            stderr: drain.stderr
        )
    }
}

/// A child spawned as the leader of its own process group, with stdout/stderr on pipes and
/// stdin on `/dev/null`. Only this type waits for its pid.
private struct ProcessGroupChild {
    /// How long stragglers in the group get after the leader exited from `SIGTERM`.
    private static let stragglerGrace: TimeInterval = 0.5
    private static let reapTimeout: TimeInterval = 2

    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32

    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> ProcessGroupChild {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            throw SubprocessError.launchFailed("pipe failed: \(errno)")
        }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            throw SubprocessError.launchFailed("pipe failed: \(errno)")
        }
        let allDescriptors = stdoutPipe + stderrPipe
        for descriptor in allDescriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let path = executableURL.path
        let argv = [path] + arguments
        let envp = environment.map { $0.map { "\($0.key)=\($0.value)" } }

        var pid: pid_t = 0
        let status = withCStringArray(argv) { argvPointer in
            if let envp {
                return withCStringArray(envp) { envpPointer in
                    posix_spawn(&pid, path, &fileActions, &attributes, argvPointer, envpPointer)
                }
            }
            return posix_spawn(&pid, path, &fileActions, &attributes, argvPointer, environ)
        }

        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard status == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw SubprocessError.launchFailed(String(cString: strerror(status)))
        }
        return ProcessGroupChild(pid: pid, stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }

    enum LeaderState {
        case running
        /// Exited but not reaped: the pid, and so the group id, can't be reused yet.
        case exited
        /// Reaped by someone else; the group id may now belong to an unrelated process.
        case gone
    }

    /// Checks the leader without reaping it (`WNOWAIT`).
    func leaderState() -> LeaderState {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return info.si_pid == pid ? .exited : .running
            }
            if errno != EINTR {
                return .gone
            }
        }
    }

    func hasExited() -> Bool {
        leaderState() != .running
    }

    /// `SIGTERM` to the group, wait up to `gracePeriod` for the leader (still draining output so
    /// nobody blocks on a full pipe), give stragglers a moment, then `SIGKILL` the group and reap.
    /// The group is only signalled while the leader is unreaped, so the id is still ours.
    func terminateGroup(gracePeriod: TimeInterval, draining drain: inout PipeDrain) {
        guard leaderState() != .gone else {
            return
        }
        kill(-pid, SIGTERM)
        let graceDeadline = DispatchTime.now() + gracePeriod
        var settleDeadline: DispatchTime?
        while true {
            let now = DispatchTime.now()
            if now >= graceDeadline || settleDeadline.map({ now >= $0 }) == true {
                break
            }
            if settleDeadline == nil, hasExited() {
                settleDeadline = min(graceDeadline, now + Self.stragglerGrace)
            }
            if drain.isOpen {
                drain.readAvailable(waitingAtMost: 20)
            } else {
                usleep(20_000)
            }
        }
        if leaderState() != .gone {
            kill(-pid, SIGKILL)
        }
        _ = reap(timeout: Self.reapTimeout)
    }

    /// Reaps the leader and maps its wait status like `Process.terminationStatus`: the exit code,
    /// or the signal number when a signal ended it. -1 when someone else already reaped it.
    func reap(timeout: TimeInterval? = nil) -> Int32 {
        let deadline = timeout.map { DispatchTime.now() + $0 }
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, deadline == nil ? 0 : WNOHANG)
            if result == pid {
                let signal = status & 0x7F
                return signal == 0 ? (status >> 8) & 0xFF : signal
            }
            if result == -1, errno != EINTR {
                return -1
            }
            if let deadline, DispatchTime.now() >= deadline {
                return -1
            }
            if result == 0 {
                usleep(10_000)
            }
        }
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    return pointers.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
