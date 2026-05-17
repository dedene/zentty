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
    private var scanCountSinceLastDiscovery = 0
    private var hasDiscovered = false

    init(pollEveryRunningScanCount: Int = 3) {
        self.pollEveryRunningScanCount = max(1, pollEveryRunningScanCount)
    }

    mutating func shouldDiscoverDocker() -> Bool {
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
}

enum PassiveServerDetectionTiming {
    static let initialDelayNanoseconds: UInt64 = 750_000_000
    static let runningPollIntervalNanoseconds: UInt64 = 2_000_000_000
}
