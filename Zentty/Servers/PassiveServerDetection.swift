import Foundation

struct PassiveServerDetectionContext: Equatable, Sendable {
    let worklaneID: WorklaneID
    let scanner: ServerScanContext
    let docker: DockerDiscoveryContext
}

struct PassiveServerDetectionResult: Equatable, Sendable {
    let worklaneID: WorklaneID
    let scannerServers: [DetectedServer]
    let dockerServers: [DetectedServer]
}

/// One passive-detection scan across every worklane context. Docker is
/// queried at most once per round (through the shared poller) and the
/// container list is then filtered per context.
struct PassiveServerDetectionRound: Sendable {
    let results: [PassiveServerDetectionResult]
    /// `nil` when docker was not polled this round.
    let dockerOutcome: DockerContainerPollOutcome?

    /// `false` when docker was not polled this round, the poll timed out or was
    /// skipped: previously detected docker servers stay as they are.
    var appliesDockerResults: Bool {
        switch dockerOutcome {
        case .containers, .unavailable:
            true
        case .failed, .skipped, nil:
            false
        }
    }

    /// Blocks on the listener scan and docker; call it off the main thread.
    /// Pass `dockerPoller: nil` for a round without docker discovery.
    static func scan(
        contexts: [PassiveServerDetectionContext],
        scanner: ServerListenerScanner,
        dockerDiscovery: DockerServerDiscovery,
        dockerPoller: DockerContainerPoller?
    ) -> PassiveServerDetectionRound {
        let outcome = dockerPoller?.poll()
        let containers: [DockerContainer]
        switch outcome {
        case .containers(let polled):
            containers = polled
        case .unavailable, .failed, .skipped, nil:
            containers = []
        }

        let results = contexts.map { context in
            PassiveServerDetectionResult(
                worklaneID: context.worklaneID,
                scannerServers: scanner.scan(context: context.scanner),
                dockerServers: dockerDiscovery.servers(from: containers, context: context.docker)
            )
        }
        return PassiveServerDetectionRound(results: results, dockerOutcome: outcome)
    }
}

struct PassiveServerDetectionResultTracker: Sendable {
    private var scannerSignaturesByWorklane: [WorklaneID: [PassiveServerDetectionServerSignature]] = [:]
    private var dockerSignaturesByWorklane: [WorklaneID: [PassiveServerDetectionServerSignature]] = [:]

    mutating func shouldApplyScannerResult(worklaneID: WorklaneID, servers: [DetectedServer]) -> Bool {
        Self.shouldApply(
            worklaneID: worklaneID,
            servers: servers,
            signaturesByWorklane: &scannerSignaturesByWorklane
        )
    }

    mutating func shouldApplyDockerResult(worklaneID: WorklaneID, servers: [DetectedServer]) -> Bool {
        Self.shouldApply(
            worklaneID: worklaneID,
            servers: servers,
            signaturesByWorklane: &dockerSignaturesByWorklane
        )
    }

    private static func shouldApply(
        worklaneID: WorklaneID,
        servers: [DetectedServer],
        signaturesByWorklane: inout [WorklaneID: [PassiveServerDetectionServerSignature]]
    ) -> Bool {
        let signature = servers
            .map(PassiveServerDetectionServerSignature.init)
            .sorted()
        guard signaturesByWorklane[worklaneID] != signature else {
            return false
        }

        signaturesByWorklane[worklaneID] = signature
        return true
    }
}

private struct PassiveServerDetectionServerSignature: Comparable, Sendable {
    let origin: String
    let url: String
    let display: String
    let paneID: PaneID?
    let source: DetectedServerSource
    let ports: [Int]
    let confidence: DetectedServerConfidence

    init(server: DetectedServer) {
        self.origin = server.origin
        self.url = server.url.absoluteString
        self.display = server.display
        self.paneID = server.paneID
        self.source = server.source
        self.ports = server.ports.sorted()
        self.confidence = server.confidence
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortComponents.lexicographicallyPrecedes(rhs.sortComponents)
    }

    private var sortComponents: [String] {
        [
            origin,
            url,
            display,
            paneID?.rawValue ?? "",
            source.rawValue,
            ports.map(String.init).joined(separator: ","),
            confidence.rawValue,
        ]
    }
}

struct PassiveServerDetectionSnapshot: Equatable, Sendable {
    let contexts: [PassiveServerDetectionContext]
    let worklaneIDsWithoutContexts: [WorklaneID]
    let shouldContinuePolling: Bool

    init(worklanes: [WorklaneState]) {
        var shouldContinuePolling = false
        var worklaneIDsWithoutContexts: [WorklaneID] = []
        let contexts = worklanes.compactMap { worklane -> PassiveServerDetectionContext? in
            let panes = worklane.paneStripState.panes.compactMap { pane -> (scanner: PaneScanContext, docker: DockerPaneContext, isRunning: Bool)? in
                guard let auxiliary = worklane.auxiliaryStateByPaneID[pane.id],
                      let shellContext = auxiliary.shellContext,
                      shellContext.scope == .local,
                      let workingDirectory = shellContext.path else {
                    return nil
                }

                let isRunning = auxiliary.shellActivityState == .commandRunning
                return (
                    PaneScanContext(
                        paneID: pane.id,
                        workingDirectory: workingDirectory,
                        repositoryRoot: auxiliary.gitContext?.repositoryRoot,
                        shellPID: auxiliary.raw.paneRootPID
                    ),
                    DockerPaneContext(
                        paneID: pane.id,
                        workingDirectory: workingDirectory,
                        recentCommandLines: []
                    ),
                    isRunning
                )
            }

            guard !panes.isEmpty else {
                worklaneIDsWithoutContexts.append(worklane.id)
                return nil
            }

            if panes.contains(where: \.isRunning) {
                shouldContinuePolling = true
            }

            return PassiveServerDetectionContext(
                worklaneID: worklane.id,
                scanner: ServerScanContext(
                    worklaneID: worklane.id,
                    panes: panes.map(\.scanner)
                ),
                docker: DockerDiscoveryContext(
                    worklaneID: worklane.id,
                    focusedPaneID: worklane.paneStripState.focusedPaneID,
                    panes: panes.map(\.docker)
                )
            )
        }

        self.contexts = contexts
        self.worklaneIDsWithoutContexts = worklaneIDsWithoutContexts
        self.shouldContinuePolling = shouldContinuePolling
    }
}

struct PassiveServerDetectionDockerCadence: Equatable, Sendable {
    private let pollEveryRunningScanCount: Int
    private let maximumInFlightRetries: Int
    private var scanCountSinceLastDiscovery = 0
    private var hasDiscovered = false
    private var inFlightRetryCount = 0
    /// A docker poll lost to another round's in-flight query. That round may
    /// belong to a cancelled loop that never applies its result, so this loop
    /// asks again on its next scan instead of waiting for the regular cadence.
    private(set) var needsDockerRetry = false

    init(pollEveryRunningScanCount: Int = 3, maximumInFlightRetries: Int = 3) {
        self.pollEveryRunningScanCount = max(1, pollEveryRunningScanCount)
        self.maximumInFlightRetries = max(0, maximumInFlightRetries)
    }

    mutating func shouldDiscoverDocker() -> Bool {
        if needsDockerRetry {
            needsDockerRetry = false
            scanCountSinceLastDiscovery = 0
            return true
        }

        guard hasDiscovered else {
            hasDiscovered = true
            scanCountSinceLastDiscovery = 0
            return true
        }

        scanCountSinceLastDiscovery += 1
        guard scanCountSinceLastDiscovery >= pollEveryRunningScanCount else {
            return false
        }

        scanCountSinceLastDiscovery = 0
        return true
    }

    /// Records a round's docker outcome (`nil` when docker was not polled).
    /// Consecutive in-flight skips are retried at most `maximumInFlightRetries`
    /// times, so a loop kept alive for a retry can never spin forever.
    mutating func recordDockerOutcome(_ outcome: DockerContainerPollOutcome?) {
        switch outcome {
        case .skipped(.queryInFlight):
            needsDockerRetry = inFlightRetryCount < maximumInFlightRetries
            if needsDockerRetry {
                inFlightRetryCount += 1
            }
        case .some:
            inFlightRetryCount = 0
            needsDockerRetry = false
        case nil:
            break
        }
    }
}

enum PassiveServerDetectionTiming {
    static let initialDelayNanoseconds: UInt64 = 750_000_000
    static let runningPollIntervalNanoseconds: UInt64 = 2_000_000_000
}
