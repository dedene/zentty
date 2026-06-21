import Darwin
import Foundation
import os

/// The result of attempting to stop the process behind a detected server.
enum ServerTerminationOutcome: Equatable, Sendable {
    /// The graceful signal was delivered to a process we own (the listener
    /// resolved as a descendant of the pane's shell). A force-kill escalation
    /// is scheduled if it doesn't exit. Also covers the case where the process
    /// had already exited by the time we signalled.
    case stopped(pid: pid_t)
    /// No process is currently listening on the server's port — nothing to stop.
    case notRunning
    /// A listener exists but isn't ours to kill (not a descendant of the pane's
    /// shell, a non-scanner source like Docker, or a missing shell PID).
    case notOwned
    /// The signal could not be delivered (e.g. `EPERM`). Carries the `errno`.
    case failed(errno: Int32)
}

/// Stops the process backing a `DetectedServer` the way a user would: a graceful
/// `SIGINT` (like Ctrl-C, letting the server release its port and clean up
/// children), escalating to `SIGKILL` if it ignores the request.
///
/// Safety: only processes that demonstrably descend from the pane's shell PID
/// are ever signalled, and the pane's own shell process group is never targeted.
final class ServerProcessTerminator: Sendable {
    /// Schedules `work` to run after `delay`. Injected so tests drive escalation
    /// deterministically instead of waiting on a real timer.
    typealias Scheduler = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    struct Configuration: Sendable {
        var gracePeriod: TimeInterval
        var gracefulSignal: Int32
        var forceSignal: Int32

        init(gracePeriod: TimeInterval = 2.0, gracefulSignal: Int32 = SIGINT, forceSignal: Int32 = SIGKILL) {
            self.gracePeriod = gracePeriod
            self.gracefulSignal = gracefulSignal
            self.forceSignal = forceSignal
        }
    }

    private let inspector: any ProcessInspecting
    private let signaler: any ProcessSignaling
    private let configuration: Configuration
    private let scheduler: Scheduler
    private let logger = Logger(subsystem: "be.zenjoy.zentty", category: "ServerProcessTerminator")

    init(
        inspector: any ProcessInspecting = DarwinProcessInspector(),
        signaler: any ProcessSignaling = DarwinProcessSignaler(),
        configuration: Configuration = .init(),
        scheduler: @escaping Scheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.inspector = inspector
        self.signaler = signaler
        self.configuration = configuration
        self.scheduler = scheduler
    }

    /// Resolves the server's listening process and stops it.
    @discardableResult
    func stop(_ server: DetectedServer, shellPID: pid_t?) -> ServerTerminationOutcome {
        // Only scanner-detected servers map to a local process we can own. Docker
        // (and manual/watch) sources point at processes we don't control.
        guard server.source == .scanner else {
            return .notOwned
        }
        guard let shellPID, shellPID > 1 else {
            return .notOwned
        }

        let ports = Self.ports(of: server)
        guard !ports.isEmpty else {
            return .notRunning
        }

        // Re-scan at stop time so a stale PID can't cause us to signal the wrong
        // process; only the matching socket that descends from the pane's shell
        // is a valid target.
        let listeners = inspector.listeningTCPSockets().filter { ports.contains($0.port) }
        guard !listeners.isEmpty else {
            return .notRunning
        }
        guard let target = listeners.first(where: { inspector.isProcess($0.pid, descendantOf: shellPID) }),
              target.pid > 1
        else {
            return .notOwned
        }

        let pid = target.pid
        let groupTarget = groupTarget(for: pid, shellPID: shellPID)

        let result = deliver(configuration.gracefulSignal, pid: pid, group: groupTarget)
        if result != 0, result != ESRCH {
            logger.error("Graceful stop of server pid \(pid, privacy: .public) failed: errno \(result, privacy: .public)")
            return .failed(errno: result)
        }

        scheduleForceKill(pid: pid, group: groupTarget)
        return .stopped(pid: pid)
    }

    /// Returns the process group to signal, or `nil` to signal just `pid`.
    /// Never returns the pane shell's own group — killing that would take down
    /// the shell along with the server.
    private func groupTarget(for pid: pid_t, shellPID: pid_t) -> pid_t? {
        guard let pgid = signaler.processGroupID(of: pid), pgid > 1 else {
            return nil
        }
        if pgid == signaler.processGroupID(of: shellPID) {
            return nil
        }
        return pgid
    }

    private func scheduleForceKill(pid: pid_t, group: pid_t?) {
        scheduler(configuration.gracePeriod) { [weak self] in
            guard let self, self.inspector.isProcessAlive(pid) else {
                return
            }
            let result = self.deliver(self.configuration.forceSignal, pid: pid, group: group)
            if result != 0, result != ESRCH {
                self.logger.error("Force stop of server pid \(pid, privacy: .public) failed: errno \(result, privacy: .public)")
            }
        }
    }

    private func deliver(_ signal: Int32, pid: pid_t, group: pid_t?) -> Int32 {
        if let group {
            return signaler.signalProcessGroup(group, signal: signal)
        }
        return signaler.signalProcess(pid, signal: signal)
    }

    private static func ports(of server: DetectedServer) -> Set<Int> {
        var ports = Set(server.ports)
        if let urlPort = server.url.port {
            ports.insert(urlPort)
        }
        return ports
    }
}
