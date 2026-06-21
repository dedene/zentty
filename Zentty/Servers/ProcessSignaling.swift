import Darwin

/// Sends POSIX signals to processes and process groups. Injected so termination
/// logic can be exercised in tests without killing real processes.
protocol ProcessSignaling: Sendable {
    /// The process-group id of `pid`, or `nil` if it can't be determined.
    func processGroupID(of pid: pid_t) -> pid_t?
    /// Sends `signal` to a single process. Returns `0` on success, else `errno`.
    func signalProcess(_ pid: pid_t, signal: Int32) -> Int32
    /// Sends `signal` to a whole process group. Returns `0` on success, else `errno`.
    func signalProcessGroup(_ pgid: pid_t, signal: Int32) -> Int32
}

struct DarwinProcessSignaler: ProcessSignaling {
    func processGroupID(of pid: pid_t) -> pid_t? {
        let pgid = getpgid(pid)
        return pgid > 0 ? pgid : nil
    }

    func signalProcess(_ pid: pid_t, signal: Int32) -> Int32 {
        kill(pid, signal) == 0 ? 0 : errno
    }

    func signalProcessGroup(_ pgid: pid_t, signal: Int32) -> Int32 {
        killpg(pgid, signal) == 0 ? 0 : errno
    }
}
