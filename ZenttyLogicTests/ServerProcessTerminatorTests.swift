import Darwin
import XCTest
@testable import Zentty

@MainActor
final class ServerProcessTerminatorTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-1")
    private let paneID = PaneID("pane-a")
    private let shellPID: pid_t = 100

    // MARK: - Resolution + graceful stop

    func test_stops_descendant_listener_by_sending_SIGINT_to_its_process_group() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 200, 200: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333, 100: 100])
        let scheduler = RecordingScheduler()
        let terminator = makeTerminator(inspector: inspector, signaler: signaler, scheduler: scheduler)

        let outcome = terminator.stop(server(ports: [5173]), shellPID: shellPID)

        XCTAssertEqual(outcome, .stopped(pid: 300))
        XCTAssertEqual(signaler.sent, [.init(target: .group(333), signal: SIGINT)])
    }

    func test_returns_notRunning_when_no_listener_matches_the_port() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 9999)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [:])
        let terminator = makeTerminator(inspector: inspector, signaler: signaler)

        XCTAssertEqual(terminator.stop(server(ports: [5173]), shellPID: shellPID), .notRunning)
        XCTAssertTrue(signaler.sent.isEmpty)
    }

    func test_returns_notOwned_when_listener_is_not_a_descendant_of_the_pane_shell() {
        // PID 300 belongs to an unrelated tree (parent 999), not the pane shell (100).
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 999, 999: 1],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333])
        let terminator = makeTerminator(inspector: inspector, signaler: signaler)

        XCTAssertEqual(terminator.stop(server(ports: [5173]), shellPID: shellPID), .notOwned)
        XCTAssertTrue(signaler.sent.isEmpty)
    }

    func test_refuses_docker_sourced_servers() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333])
        let terminator = makeTerminator(inspector: inspector, signaler: signaler)

        let dockerServer = server(ports: [5173], source: .docker)
        XCTAssertEqual(terminator.stop(dockerServer, shellPID: shellPID), .notOwned)
        XCTAssertTrue(signaler.sent.isEmpty)
    }

    func test_refuses_when_shellPID_is_missing() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333])
        let terminator = makeTerminator(inspector: inspector, signaler: signaler)

        XCTAssertEqual(terminator.stop(server(ports: [5173]), shellPID: nil), .notOwned)
        XCTAssertTrue(signaler.sent.isEmpty)
    }

    // MARK: - Process-group safety guard

    func test_signals_single_pid_when_job_shares_the_shell_process_group() {
        // Listener's pgid equals the shell's pgid — killpg would kill the shell, so
        // the terminator must target the single PID instead.
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 100, 100: 100])
        let terminator = makeTerminator(inspector: inspector, signaler: signaler)

        let outcome = terminator.stop(server(ports: [5173]), shellPID: shellPID)

        XCTAssertEqual(outcome, .stopped(pid: 300))
        XCTAssertEqual(signaler.sent, [.init(target: .process(300), signal: SIGINT)])
    }

    // MARK: - Escalation

    func test_escalates_to_SIGKILL_when_process_survives_the_grace_period() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333, 100: 100])
        let scheduler = RecordingScheduler()
        let terminator = makeTerminator(inspector: inspector, signaler: signaler, scheduler: scheduler)

        _ = terminator.stop(server(ports: [5173]), shellPID: shellPID)
        XCTAssertEqual(scheduler.scheduledDelays, [2.0])

        // Still alive when the timer fires → escalate.
        scheduler.fireAll()

        XCTAssertEqual(signaler.sent, [
            .init(target: .group(333), signal: SIGINT),
            .init(target: .group(333), signal: SIGKILL),
        ])
    }

    func test_does_not_escalate_when_process_already_exited() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333, 100: 100])
        let scheduler = RecordingScheduler()
        let terminator = makeTerminator(inspector: inspector, signaler: signaler, scheduler: scheduler)

        _ = terminator.stop(server(ports: [5173]), shellPID: shellPID)
        // The SIGINT worked: process is gone by the time the timer fires.
        inspector.aliveByPID[300] = false
        scheduler.fireAll()

        XCTAssertEqual(signaler.sent, [.init(target: .group(333), signal: SIGINT)])
    }

    // MARK: - Signal failures

    func test_reports_failure_and_skips_escalation_when_SIGINT_is_rejected() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        let signaler = FakeSignaler(pgidByPID: [300: 333, 100: 100], failWith: EPERM)
        let scheduler = RecordingScheduler()
        let terminator = makeTerminator(inspector: inspector, signaler: signaler, scheduler: scheduler)

        XCTAssertEqual(terminator.stop(server(ports: [5173]), shellPID: shellPID), .failed(errno: EPERM))
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
    }

    func test_treats_already_gone_process_as_stopped() {
        let inspector = FakeInspector(
            sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
            parentByPID: [300: 100],
            aliveByPID: [300: true]
        )
        // ESRCH: the process vanished between scan and signal — goal achieved.
        let signaler = FakeSignaler(pgidByPID: [300: 333, 100: 100], failWith: ESRCH)
        let terminator = makeTerminator(inspector: inspector, signaler: signaler)

        XCTAssertEqual(terminator.stop(server(ports: [5173]), shellPID: shellPID), .stopped(pid: 300))
    }

    // MARK: - Helpers

    private func makeTerminator(
        inspector: FakeInspector,
        signaler: FakeSignaler,
        scheduler: RecordingScheduler = RecordingScheduler()
    ) -> ServerProcessTerminator {
        ServerProcessTerminator(
            inspector: inspector,
            signaler: signaler,
            configuration: .init(gracePeriod: 2.0),
            scheduler: scheduler.schedule
        )
    }

    private func server(
        ports: [Int],
        source: DetectedServerSource = .scanner,
        confidence: DetectedServerConfidence = .pid
    ) -> DetectedServer {
        let port = ports.first ?? 0
        return DetectedServer(
            id: "scanner:\(worklaneID.rawValue):\(paneID.rawValue):http://localhost:\(port)",
            origin: "http://localhost:\(port)",
            url: URL(string: "http://localhost:\(port)")!,
            display: "localhost:\(port)",
            worklaneID: worklaneID,
            paneID: paneID,
            source: source,
            ports: ports,
            confidence: confidence,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

// MARK: - Test doubles

private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    let sockets: [ListeningSocket]
    let parentByPID: [pid_t: pid_t]
    var aliveByPID: [pid_t: Bool]

    init(sockets: [ListeningSocket], parentByPID: [pid_t: pid_t], aliveByPID: [pid_t: Bool]) {
        self.sockets = sockets
        self.parentByPID = parentByPID
        self.aliveByPID = aliveByPID
    }

    func listeningTCPSockets() -> [ListeningSocket] { sockets }
    func parentPID(of pid: pid_t) -> pid_t? { parentByPID[pid] }
    func workingDirectory(of pid: pid_t) -> String? { nil }
    func isProcessAlive(_ pid: pid_t) -> Bool { aliveByPID[pid] ?? false }
}

private final class FakeSignaler: ProcessSignaling, @unchecked Sendable {
    struct Sent: Equatable {
        enum Target: Equatable { case process(pid_t); case group(pid_t) }
        let target: Target
        let signal: Int32
    }

    let pgidByPID: [pid_t: pid_t]
    let failWith: Int32
    private(set) var sent: [Sent] = []

    init(pgidByPID: [pid_t: pid_t], failWith: Int32 = 0) {
        self.pgidByPID = pgidByPID
        self.failWith = failWith
    }

    func processGroupID(of pid: pid_t) -> pid_t? { pgidByPID[pid] }

    func signalProcess(_ pid: pid_t, signal: Int32) -> Int32 {
        sent.append(.init(target: .process(pid), signal: signal))
        return failWith
    }

    func signalProcessGroup(_ pgid: pid_t, signal: Int32) -> Int32 {
        sent.append(.init(target: .group(pgid), signal: signal))
        return failWith
    }
}

private final class RecordingScheduler: @unchecked Sendable {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var work: [@Sendable () -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        scheduledDelays.append(delay)
        self.work.append(work)
    }

    func fireAll() {
        let pending = work
        work.removeAll()
        pending.forEach { $0() }
    }
}
