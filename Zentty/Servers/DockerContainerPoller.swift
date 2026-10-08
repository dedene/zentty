import Foundation
import os

enum DockerContainerPollOutcome: Equatable, Sendable {
    enum SkipReason: String, Sendable {
        /// Another poll is querying docker right now; its result lands in the
        /// cache shortly.
        case queryInFlight
        /// A timed-out query put polling in backoff; docker's state is unknown.
        case backingOff
    }

    /// Fresh or recently cached running containers.
    case containers([DockerContainer])
    /// There are no docker servers to show: no docker socket, or docker
    /// answered with an error (daemon not running, `docker` not on PATH).
    case unavailable
    /// The query timed out; keep what was detected before.
    case failed
    case skipped(SkipReason)

    var breadcrumbValue: String {
        switch self {
        case .containers:
            "containers"
        case .unavailable:
            "unavailable"
        case .failed:
            "failed"
        case .skipped(let reason):
            "skipped.\(reason.rawValue)"
        }
    }
}

/// Timing decisions behind `DockerContainerPoller`: a short-lived cache so a
/// reschedule filters the last result instead of re-querying, and exponential
/// backoff after a failed query. Elapsed times outside `0..<window` count as
/// expired, so a wall-clock jump cannot pin the cache or the backoff.
struct DockerContainerPollSchedule: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case useCache([DockerContainer])
        /// Within the backoff after a failed query. `dockerIsGone` is true when
        /// that failure was docker answering with an error rather than a timeout.
        case backingOff(dockerIsGone: Bool)
        case query
    }

    let minimumInterval: TimeInterval
    let initialBackoff: TimeInterval
    let maximumBackoff: TimeInterval
    private var cachedContainers: [DockerContainer]?
    private var cachedAt: Date?
    private(set) var consecutiveFailures = 0
    private var lastFailureAt: Date?
    private var lastFailureWasDefinitive = false

    init(minimumInterval: TimeInterval = 5, initialBackoff: TimeInterval = 10, maximumBackoff: TimeInterval = 120) {
        self.minimumInterval = minimumInterval
        self.initialBackoff = initialBackoff
        self.maximumBackoff = max(initialBackoff, maximumBackoff)
    }

    var currentBackoff: TimeInterval {
        guard consecutiveFailures > 0 else {
            return 0
        }
        let doublings = min(consecutiveFailures - 1, 16)
        return min(initialBackoff * pow(2, Double(doublings)), maximumBackoff)
    }

    func decision(at now: Date) -> Decision {
        if let lastFailureAt, Self.isWithin(now, since: lastFailureAt, window: currentBackoff) {
            return .backingOff(dockerIsGone: lastFailureWasDefinitive)
        }
        if let cachedContainers, let cachedAt, Self.isWithin(now, since: cachedAt, window: minimumInterval) {
            return .useCache(cachedContainers)
        }
        return .query
    }

    mutating func recordSuccess(_ containers: [DockerContainer], at now: Date) {
        cachedContainers = containers
        cachedAt = now
        resetFailures()
    }

    /// No docker socket. Checking for one spawns nothing, so this clears any
    /// backoff instead of extending it.
    mutating func recordUnavailable() {
        cachedContainers = nil
        cachedAt = nil
        resetFailures()
    }

    /// A query that timed out. Returns the backoff now in effect.
    @discardableResult
    mutating func recordFailure(at now: Date) -> TimeInterval {
        recordFailure(at: now, isDefinitive: false)
    }

    /// docker answered with an error (or could not be launched): there is
    /// nothing to show, but re-running it every scan would only repeat the
    /// error, so it backs off like a timeout. Returns the backoff now in effect.
    @discardableResult
    mutating func recordDockerGone(at now: Date) -> TimeInterval {
        recordFailure(at: now, isDefinitive: true)
    }

    private mutating func recordFailure(at now: Date, isDefinitive: Bool) -> TimeInterval {
        cachedContainers = nil
        cachedAt = nil
        consecutiveFailures += 1
        lastFailureAt = now
        lastFailureWasDefinitive = isDefinitive
        return currentBackoff
    }

    private mutating func resetFailures() {
        consecutiveFailures = 0
        lastFailureAt = nil
        lastFailureWasDefinitive = false
    }

    private static func isWithin(_ now: Date, since start: Date, window: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(start)
        return elapsed >= 0 && elapsed < window
    }
}

/// Process-wide gate in front of the docker CLI for passive server detection:
/// at most one docker query in flight, results reused for a few seconds, and
/// backoff after failures. It outlives individual detection loops, which are
/// cancelled and rescheduled on every worklane change.
final class DockerContainerPoller: @unchecked Sendable {
    static let shared = DockerContainerPoller()

    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "DockerDiscovery")

    private enum QueryResult {
        case containers([DockerContainer])
        case noSocket
        case dockerGone(any Error)
        case timedOut(any Error)
    }

    private let inspector: any DockerInspecting
    private let currentDate: @Sendable () -> Date
    private let lock = NSLock()
    private var schedule: DockerContainerPollSchedule
    private var isPolling = false

    init(
        inspector: any DockerInspecting = DockerCLIInspector(),
        schedule: DockerContainerPollSchedule = DockerContainerPollSchedule(),
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.inspector = inspector
        self.schedule = schedule
        self.currentDate = currentDate
    }

    /// Blocks while querying docker; call it off the main thread.
    func poll() -> DockerContainerPollOutcome {
        if let outcome = beginPoll() {
            return outcome
        }
        return finishPoll(query())
    }

    private func query() -> QueryResult {
        guard inspector.hasDockerSocket() else {
            return .noSocket
        }
        do {
            return .containers(try inspector.runningContainers())
        } catch let error as DockerCLIError where error.isDefinitive {
            return .dockerGone(error)
        } catch {
            return .timedOut(error)
        }
    }

    /// Returns an outcome when no query is needed; otherwise claims the
    /// in-flight slot and returns `nil`.
    private func beginPoll() -> DockerContainerPollOutcome? {
        lock.lock()
        defer { lock.unlock() }

        guard !isPolling else {
            return .skipped(.queryInFlight)
        }
        switch schedule.decision(at: currentDate()) {
        case .useCache(let containers):
            return .containers(containers)
        case .backingOff(let dockerIsGone):
            // Still the last known answer, so every window keeps clearing.
            return dockerIsGone ? .unavailable : .skipped(.backingOff)
        case .query:
            isPolling = true
            return nil
        }
    }

    private func finishPoll(_ result: QueryResult) -> DockerContainerPollOutcome {
        lock.lock()
        defer { lock.unlock() }

        isPolling = false
        let failuresBefore = schedule.consecutiveFailures
        switch result {
        case .containers(let containers):
            schedule.recordSuccess(containers, at: currentDate())
            if failuresBefore > 0 {
                Self.logger.info("Docker container query recovered after \(failuresBefore) failed attempts")
            }
            return .containers(containers)
        case .noSocket:
            schedule.recordUnavailable()
            return .unavailable
        case .dockerGone(let error):
            logFailure(error, backoff: schedule.recordDockerGone(at: currentDate()))
            return .unavailable
        case .timedOut(let error):
            logFailure(error, backoff: schedule.recordFailure(at: currentDate()))
            return .failed
        }
    }

    /// Loud once when a failure streak starts; repeats stay at debug so a
    /// machine without a working docker does not log every backoff period.
    private func logFailure(_ error: any Error, backoff: TimeInterval) {
        let reason = String(describing: error)
        let retry = Int(backoff)
        if schedule.consecutiveFailures == 1 {
            Self.logger.error("Docker container query failed: \(reason, privacy: .public); retrying in \(retry)s")
        } else {
            Self.logger.debug("Docker container query still failing: \(reason, privacy: .public); retrying in \(retry)s")
        }
    }
}
