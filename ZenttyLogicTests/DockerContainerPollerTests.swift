import XCTest
@testable import Zentty

final class DockerContainerPollerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)
    private let timedOut = DockerCLIError.timedOut(subcommand: "ps")
    private let daemonDown = DockerCLIError.commandFailed(
        subcommand: "ps",
        status: 1,
        message: "Cannot connect to the Docker daemon"
    )

    // MARK: - Schedule

    func test_schedule_queries_first_then_uses_cache_within_minimum_interval() {
        var schedule = DockerContainerPollSchedule(minimumInterval: 5)
        XCTAssertEqual(schedule.decision(at: start), .query)

        schedule.recordSuccess([container("a")], at: start)

        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(4.9)), .useCache([container("a")]))
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(5)), .query)
        // A wall clock that jumped backwards must not pin the cache.
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(-60)), .query)
    }

    func test_schedule_backs_off_exponentially_up_to_the_cap_and_resets_on_success() {
        var schedule = DockerContainerPollSchedule(minimumInterval: 5, initialBackoff: 10, maximumBackoff: 30)

        XCTAssertEqual(schedule.recordFailure(at: start), 10)
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(9.9)), .backingOff(dockerIsGone: false))
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(10)), .query)

        XCTAssertEqual(schedule.recordFailure(at: start.addingTimeInterval(10)), 20)
        XCTAssertEqual(schedule.recordFailure(at: start.addingTimeInterval(30)), 30)
        XCTAssertEqual(schedule.recordFailure(at: start.addingTimeInterval(60)), 30)
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(89)), .backingOff(dockerIsGone: false))

        schedule.recordSuccess([], at: start.addingTimeInterval(90))
        XCTAssertEqual(schedule.currentBackoff, 0)
        XCTAssertEqual(schedule.recordFailure(at: start.addingTimeInterval(100)), 10)
    }

    func test_schedule_backs_off_after_docker_is_gone_and_remembers_why() {
        var schedule = DockerContainerPollSchedule(minimumInterval: 5, initialBackoff: 10, maximumBackoff: 30)

        XCTAssertEqual(schedule.recordDockerGone(at: start), 10)
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(9.9)), .backingOff(dockerIsGone: true))
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(10)), .query)

        // Both kinds of failure extend one streak; the latest decides the kind.
        XCTAssertEqual(schedule.recordFailure(at: start.addingTimeInterval(10)), 20)
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(11)), .backingOff(dockerIsGone: false))
        XCTAssertEqual(schedule.recordDockerGone(at: start.addingTimeInterval(30)), 30)
        XCTAssertEqual(schedule.consecutiveFailures, 3)
    }

    func test_schedule_no_socket_clears_backoff() {
        var schedule = DockerContainerPollSchedule(minimumInterval: 5, initialBackoff: 10)
        schedule.recordDockerGone(at: start)

        schedule.recordUnavailable()

        XCTAssertEqual(schedule.currentBackoff, 0)
        XCTAssertEqual(schedule.decision(at: start.addingTimeInterval(1)), .query)
    }

    // MARK: - Poller

    func test_poller_reuses_cached_containers_within_minimum_interval() {
        let clock = TestClock(start)
        let inspector = CountingDockerInspector(containers: [container("a")])
        let poller = DockerContainerPoller(inspector: inspector, currentDate: clock.now)

        XCTAssertEqual(poller.poll(), .containers([container("a")]))
        clock.advance(by: 4)
        XCTAssertEqual(poller.poll(), .containers([container("a")]))
        XCTAssertEqual(inspector.queryCount, 1)

        clock.advance(by: 2)
        XCTAssertEqual(poller.poll(), .containers([container("a")]))
        XCTAssertEqual(inspector.queryCount, 2)
    }

    func test_poller_without_socket_reports_unavailable_without_querying_or_backing_off() {
        let inspector = CountingDockerInspector(hasSocket: false, containers: [container("a")])
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)

        XCTAssertEqual(poller.poll(), .unavailable)
        // Checked again right away: a socket check spawns nothing, so no backoff.
        XCTAssertEqual(poller.poll(), .unavailable)
        XCTAssertEqual(inspector.socketCheckCount, 2)
        XCTAssertEqual(inspector.queryCount, 0)
    }

    func test_poller_backs_off_after_timeout_and_resets_after_success() {
        let clock = TestClock(start)
        let inspector = CountingDockerInspector(containers: [container("a")])
        inspector.failsWith = timedOut
        let poller = DockerContainerPoller(inspector: inspector, currentDate: clock.now)

        XCTAssertEqual(poller.poll(), .failed)
        clock.advance(by: 9)
        XCTAssertEqual(poller.poll(), .skipped(.backingOff))
        XCTAssertEqual(inspector.queryCount, 1)

        clock.advance(by: 1)
        XCTAssertEqual(poller.poll(), .failed)
        clock.advance(by: 19)
        XCTAssertEqual(poller.poll(), .skipped(.backingOff))
        XCTAssertEqual(inspector.queryCount, 2)

        inspector.failsWith = nil
        clock.advance(by: 1)
        XCTAssertEqual(poller.poll(), .containers([container("a")]))
        XCTAssertEqual(inspector.queryCount, 3)

        // Backoff starts over from the initial interval after a success.
        inspector.failsWith = timedOut
        clock.advance(by: 5)
        XCTAssertEqual(poller.poll(), .failed)
        clock.advance(by: 10)
        XCTAssertEqual(poller.poll(), .failed)
        XCTAssertEqual(inspector.queryCount, 5)
    }

    func test_poller_reports_docker_gone_as_unavailable_and_backs_off() {
        let clock = TestClock(start)
        let inspector = CountingDockerInspector(containers: [container("a")])
        inspector.failsWith = daemonDown
        let poller = DockerContainerPoller(inspector: inspector, currentDate: clock.now)

        XCTAssertEqual(poller.poll(), .unavailable)
        // Within the backoff docker is not run again, and the answer stays
        // "nothing to show" rather than "unknown".
        clock.advance(by: 9)
        XCTAssertEqual(poller.poll(), .unavailable)
        XCTAssertEqual(inspector.queryCount, 1)

        clock.advance(by: 1)
        XCTAssertEqual(poller.poll(), .unavailable)
        clock.advance(by: 19)
        XCTAssertEqual(poller.poll(), .unavailable)
        XCTAssertEqual(inspector.queryCount, 2)

        inspector.failsWith = nil
        clock.advance(by: 1)
        XCTAssertEqual(poller.poll(), .containers([container("a")]))
        XCTAssertEqual(inspector.queryCount, 3)
    }

    func test_poller_treats_unclassified_errors_like_a_timeout() {
        let inspector = CountingDockerInspector(containers: [])
        inspector.failsWith = CocoaError(.fileReadUnknown)
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)

        XCTAssertEqual(poller.poll(), .failed)
        XCTAssertEqual(poller.poll(), .skipped(.backingOff))
    }

    func test_concurrent_poll_is_skipped_while_one_is_in_flight() {
        let inspector = CountingDockerInspector(containers: [container("a")])
        let entered = expectation(description: "first poll is querying docker")
        let release = DispatchSemaphore(value: 0)
        inspector.onQuery = {
            entered.fulfill()
            release.wait()
        }
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)

        let firstFinished = expectation(description: "first poll finished")
        let firstOutcome = OutcomeBox()
        DispatchQueue.global().async {
            firstOutcome.value = poller.poll()
            firstFinished.fulfill()
        }
        wait(for: [entered], timeout: 5)

        XCTAssertEqual(poller.poll(), .skipped(.queryInFlight))

        inspector.onQuery = nil
        release.signal()
        wait(for: [firstFinished], timeout: 5)
        XCTAssertEqual(firstOutcome.value, .containers([container("a")]))
        // The in-flight result is cached, so a retry right after gets it.
        XCTAssertEqual(poller.poll(), .containers([container("a")]))
        XCTAssertEqual(inspector.queryCount, 1)
    }

    // MARK: - Detection round

    func test_round_queries_docker_once_for_all_contexts() {
        let inspector = CountingDockerInspector(containers: [webContainer(projectPath: "/tmp/one")])
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)

        let round = scanRound(
            contexts: ["/tmp/one", "/tmp/two", "/tmp/three"].enumerated().map { index, path in
                detectionContext(worklane: "worklane-\(index)", path: path)
            },
            poller: poller
        )

        XCTAssertEqual(inspector.queryCount, 1)
        XCTAssertTrue(round.appliesDockerResults)
        XCTAssertEqual(round.dockerOutcome?.breadcrumbValue, "containers")
        XCTAssertEqual(round.results.map(\.dockerServers.count), [1, 0, 0])
        XCTAssertEqual(round.results.first?.dockerServers.first?.origin, "http://localhost:5173")
    }

    func test_round_keeps_docker_servers_when_poll_times_out_and_while_backing_off() {
        let inspector = CountingDockerInspector(containers: [webContainer(projectPath: "/tmp/one")])
        inspector.failsWith = timedOut
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)
        let contexts = [detectionContext(worklane: "worklane", path: "/tmp/one")]

        let timedOutRound = scanRound(contexts: contexts, poller: poller)
        XCTAssertEqual(timedOutRound.dockerOutcome, .failed)
        XCTAssertFalse(timedOutRound.appliesDockerResults)

        let backingOffRound = scanRound(contexts: contexts, poller: poller)
        XCTAssertEqual(backingOffRound.dockerOutcome, .skipped(.backingOff))
        XCTAssertEqual(backingOffRound.dockerOutcome?.breadcrumbValue, "skipped.backingOff")
        XCTAssertFalse(backingOffRound.appliesDockerResults)
        XCTAssertEqual(inspector.queryCount, 1)
    }

    func test_round_clears_docker_servers_when_docker_is_gone_and_while_backing_off() {
        let inspector = CountingDockerInspector(containers: [webContainer(projectPath: "/tmp/one")])
        inspector.failsWith = daemonDown
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)
        let contexts = [detectionContext(worklane: "worklane", path: "/tmp/one")]

        for _ in 0..<2 {
            let round = scanRound(contexts: contexts, poller: poller)
            XCTAssertEqual(round.dockerOutcome, .unavailable)
            XCTAssertTrue(round.appliesDockerResults)
            XCTAssertEqual(round.results.map(\.dockerServers), [[]])
        }
        XCTAssertEqual(inspector.queryCount, 1)
    }

    func test_round_clears_docker_servers_without_docker_socket() {
        let inspector = CountingDockerInspector(hasSocket: false, containers: [webContainer(projectPath: "/tmp/one")])
        let poller = DockerContainerPoller(inspector: inspector, currentDate: TestClock(start).now)

        let round = scanRound(contexts: [detectionContext(worklane: "worklane", path: "/tmp/one")], poller: poller)

        XCTAssertTrue(round.appliesDockerResults)
        XCTAssertEqual(round.results.map(\.dockerServers), [[]])
        XCTAssertEqual(inspector.queryCount, 0)
    }

    func test_round_without_docker_does_not_poll() {
        let inspector = CountingDockerInspector(containers: [webContainer(projectPath: "/tmp/one")])

        let round = scanRound(contexts: [detectionContext(worklane: "worklane", path: "/tmp/one")], poller: nil)

        XCTAssertNil(round.dockerOutcome)
        XCTAssertFalse(round.appliesDockerResults)
        XCTAssertEqual(inspector.queryCount, 0)
    }

    // MARK: - Helpers

    private func scanRound(
        contexts: [PassiveServerDetectionContext],
        poller: DockerContainerPoller?
    ) -> PassiveServerDetectionRound {
        let date = start
        return PassiveServerDetectionRound.scan(
            contexts: contexts,
            scanner: ServerListenerScanner(processInspector: NoSocketsProcessInspector(), currentDate: { date }),
            dockerDiscovery: DockerServerDiscovery(currentDate: { date }),
            dockerPoller: poller
        )
    }

    private func detectionContext(worklane: String, path: String) -> PassiveServerDetectionContext {
        let worklaneID = WorklaneID(worklane)
        let paneID = PaneID("\(worklane)-pane")
        return PassiveServerDetectionContext(
            worklaneID: worklaneID,
            scanner: ServerScanContext(
                worklaneID: worklaneID,
                panes: [PaneScanContext(paneID: paneID, workingDirectory: path, shellPID: nil)]
            ),
            docker: DockerDiscoveryContext(
                worklaneID: worklaneID,
                focusedPaneID: paneID,
                panes: [DockerPaneContext(paneID: paneID, workingDirectory: path, recentCommandLines: [])]
            )
        )
    }

    private func container(_ id: String) -> DockerContainer {
        DockerContainer(id: id, name: id, image: "node", command: "", labels: [:], publishedPorts: [])
    }

    private func webContainer(projectPath: String) -> DockerContainer {
        DockerContainer(
            id: "web",
            name: "project-web-1",
            image: "node:22",
            command: "npm run vite",
            labels: ["com.docker.compose.project.working_dir": projectPath],
            publishedPorts: [
                DockerPublishedPort(hostIP: "0.0.0.0", hostPort: 5173, containerPort: 5173, protocolName: "tcp")
            ]
        )
    }
}

private final class CountingDockerInspector: DockerInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let hasSocket: Bool
    private let containers: [DockerContainer]
    private var _socketCheckCount = 0
    private var _queryCount = 0
    private var _failsWith: (any Error)?
    private var _onQuery: (@Sendable () -> Void)?

    init(hasSocket: Bool = true, containers: [DockerContainer]) {
        self.hasSocket = hasSocket
        self.containers = containers
    }

    var socketCheckCount: Int { locked { _socketCheckCount } }
    var queryCount: Int { locked { _queryCount } }
    var failsWith: (any Error)? {
        get { locked { _failsWith } }
        set { locked { _failsWith = newValue } }
    }
    var onQuery: (@Sendable () -> Void)? {
        get { locked { _onQuery } }
        set { locked { _onQuery = newValue } }
    }

    func hasDockerSocket() -> Bool {
        locked {
            _socketCheckCount += 1
            return hasSocket
        }
    }

    func runningContainers() throws -> [DockerContainer] {
        let (hook, failure) = locked {
            _queryCount += 1
            return (_onQuery, _failsWith)
        }
        hook?()
        if let failure {
            throw failure
        }
        return containers
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private struct NoSocketsProcessInspector: ProcessInspecting {
    func listeningTCPSockets() -> [ListeningSocket] { [] }
    func parentPID(of _: pid_t) -> pid_t? { nil }
    func workingDirectory(of _: pid_t) -> String? { nil }
    func isProcessAlive(_: pid_t) -> Bool { false }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: DockerContainerPollOutcome?

    var value: DockerContainerPollOutcome? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
