import Foundation

/// View-free owner of a window's server IPC surface: it registers/opens/kills
/// detected servers, answers `zentty server` IPC queries, and runs the passive
/// server-detection polling loop. It touches only the worklane store, config,
/// and the server services — no responder chain or view geometry.
@MainActor
final class WindowServerCommandService {
    private let worklaneStore: WorklaneStore
    private let configStore: AppConfigStore
    private let serverOpenService: ServerOpening
    private let serverListenerScanner: ServerListenerScanner
    private let dockerServerDiscovery: DockerServerDiscovery
    private let serverProcessTerminator: ServerProcessTerminator
    private var passiveServerDetectionTask: Task<Void, Never>?

    init(
        worklaneStore: WorklaneStore,
        configStore: AppConfigStore,
        serverOpenService: ServerOpening,
        serverListenerScanner: ServerListenerScanner,
        dockerServerDiscovery: DockerServerDiscovery,
        serverProcessTerminator: ServerProcessTerminator = ServerProcessTerminator()
    ) {
        self.worklaneStore = worklaneStore
        self.configStore = configStore
        self.serverOpenService = serverOpenService
        self.serverListenerScanner = serverListenerScanner
        self.dockerServerDiscovery = dockerServerDiscovery
        self.serverProcessTerminator = serverProcessTerminator
    }

    deinit {
        MainActorShim.assumeIsolated {
            passiveServerDetectionTask?.cancel()
        }
    }

    func handle(
        _ command: ServerIPCCommand,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        switch command {
        case .set(let rawURL, let pid, _):
            try registerServer(
                rawURL: rawURL,
                pid: pid,
                source: .manual,
                target: target
            )
            return serverResponse(for: target.worklaneID)

        case .watchSet(let rawURL, let pid, _):
            try registerServer(
                rawURL: rawURL,
                pid: pid,
                source: .watch,
                target: target
            )
            return serverResponse(for: target.worklaneID)

        case .clear:
            worklaneStore.clearServers(worklaneID: target.worklaneID, paneID: target.paneID)
            return serverResponse(for: target.worklaneID)

        case .list:
            return serverResponse(for: target.worklaneID)

        case .open(let rawURL, let browserID, _):
            let context = worklaneStore.serverContext(for: target.worklaneID)
            let server = rawURL.flatMap { worklaneStore.serverRegistry.server(matching: $0, in: target.worklaneID) }
                ?? context.primaryServer
            if let server {
                worklaneStore.rememberPrimaryServer(server)
                _ = serverOpenService.open(
                    server: server,
                    browserID: browserID,
                    config: configStore.current.serverDetection
                )
            }
            return serverResponse(for: target.worklaneID)

        case .watch:
            return serverResponse(for: target.worklaneID)

        case .watchClear:
            worklaneStore.clearServers(worklaneID: target.worklaneID, paneID: target.paneID, source: .watch)
            return serverResponse(for: target.worklaneID)
        }
    }

    private func registerServer(
        rawURL: String,
        pid: Int?,
        source: DetectedServerSource,
        target: AgentIPCTarget
    ) throws {
        let candidate = try ServerURLNormalizer.normalize(rawURL)
        let server = DetectedServer(
            id: serverRecordID(
                worklaneID: target.worklaneID,
                paneID: target.paneID,
                source: source,
                origin: candidate.origin
            ),
            origin: candidate.origin,
            url: candidate.url,
            display: candidate.display,
            worklaneID: target.worklaneID,
            paneID: target.paneID,
            source: source,
            ports: [candidate.port],
            confidence: pid == nil ? .explicit : .pid,
            updatedAt: Date()
        )
        worklaneStore.register(server: server)
    }

    func schedulePassiveServerDetectionRefresh() {
        passiveServerDetectionTask?.cancel()

        guard configStore.current.serverDetection.passiveDetectionEnabled else {
            worklaneStore.worklanes.forEach { worklane in
                worklaneStore.replacePassiveServers(worklaneID: worklane.id, source: .scanner, servers: [])
                worklaneStore.replacePassiveServers(worklaneID: worklane.id, source: .docker, servers: [])
            }
            return
        }

        let snapshot = PassiveServerDetectionSnapshot(worklanes: worklaneStore.worklanes)
        clearPassiveServersForWorklanesWithoutContexts(snapshot)
        guard !snapshot.contexts.isEmpty else {
            return
        }

        let scanner = serverListenerScanner
        let dockerDiscovery = dockerServerDiscovery
        passiveServerDetectionTask = Task { [weak self, snapshot, scanner, dockerDiscovery] in
            try? await Task.sleep(nanoseconds: PassiveServerDetectionTiming.initialDelayNanoseconds)
            guard !Task.isCancelled else {
                return
            }

            var contexts = snapshot.contexts
            var dockerCadence = PassiveServerDetectionDockerCadence()
            var resultTracker = PassiveServerDetectionResultTracker()

            while !Task.isCancelled {
                let shouldDiscoverDocker = dockerCadence.shouldDiscoverDocker()
                let scanStartedAt = Date()
                let results = await Task.detached(priority: .utility) { [contexts, scanner, dockerDiscovery, shouldDiscoverDocker] in
                    contexts.map { context in
                        PassiveServerDetectionResult(
                            worklaneID: context.worklaneID,
                            scannerServers: scanner.scan(context: context.scanner),
                            dockerServers: shouldDiscoverDocker ? dockerDiscovery.discover(context: context.docker) : []
                        )
                    }
                }.value

                guard !Task.isCancelled, let self else {
                    return
                }

                let scannerServerCount = results.reduce(0) { $0 + $1.scannerServers.count }
                let dockerServerCount = results.reduce(0) { $0 + $1.dockerServers.count }
                ZenttyBreadcrumbs.record(
                    category: "zentty.passive-server.scan",
                    data: [
                        "contextCount": contexts.count,
                        "worklaneCount": Set(contexts.map(\.worklaneID)).count,
                        "scannerServerCount": scannerServerCount,
                        "dockerServerCount": dockerServerCount,
                        "dockerEnabled": shouldDiscoverDocker,
                        "durationMs": Int(Date().timeIntervalSince(scanStartedAt) * 1000),
                    ]
                )

                var appliedScannerCount = 0
                var appliedDockerCount = 0
                results.forEach { result in
                    if resultTracker.shouldApplyScannerResult(
                        worklaneID: result.worklaneID,
                        servers: result.scannerServers
                    ) {
                        appliedScannerCount += 1
                        self.worklaneStore.replacePassiveServers(
                            worklaneID: result.worklaneID,
                            source: .scanner,
                            servers: result.scannerServers
                        )
                    }
                    if shouldDiscoverDocker,
                           resultTracker.shouldApplyDockerResult(
                               worklaneID: result.worklaneID,
                               servers: result.dockerServers
                           ) {
                        appliedDockerCount += 1
                        self.worklaneStore.replacePassiveServers(
                            worklaneID: result.worklaneID,
                            source: .docker,
                            servers: result.dockerServers
                        )
                    }
                }
                if appliedScannerCount > 0 || appliedDockerCount > 0 {
                    ZenttyBreadcrumbs.record(
                        category: "zentty.passive-server.apply",
                        data: [
                            "scannerChangedCount": appliedScannerCount,
                            "dockerChangedCount": appliedDockerCount,
                        ]
                    )
                }

                let nextSnapshot = PassiveServerDetectionSnapshot(worklanes: self.worklaneStore.worklanes)
                self.clearPassiveServersForWorklanesWithoutContexts(nextSnapshot)
                guard nextSnapshot.shouldContinuePolling, !nextSnapshot.contexts.isEmpty else {
                    return
                }

                contexts = nextSnapshot.contexts
                try? await Task.sleep(nanoseconds: PassiveServerDetectionTiming.runningPollIntervalNanoseconds)
            }
        }
    }

    func cancelPassiveDetection() {
        passiveServerDetectionTask?.cancel()
        passiveServerDetectionTask = nil
    }

    private func clearPassiveServersForWorklanesWithoutContexts(_ snapshot: PassiveServerDetectionSnapshot) {
        snapshot.worklaneIDsWithoutContexts.forEach { worklaneID in
            worklaneStore.clearPassiveServers(worklaneID: worklaneID)
        }
    }

    @discardableResult
    func openServer(_ server: DetectedServer, browserID: String? = nil) -> Bool {
        worklaneStore.rememberPrimaryServer(server)
        return serverOpenService.open(
            server: server,
            browserID: browserID,
            config: configStore.current.serverDetection
        )
    }

    /// Stops the process backing `server` — a graceful `SIGINT` that escalates to
    /// a force kill if it lingers — then refreshes detection so the server clears
    /// from the menu once it exits. Only servers we can prove we own (scanner +
    /// shell-PID ancestry) reach this path via `ServerMenuModel.stoppable`.
    func killServer(_ server: DetectedServer) {
        guard let paneID = server.paneID else {
            return
        }

        let shellPID = worklaneStore.worklanes
            .first { $0.id == server.worklaneID }?
            .auxiliaryStateByPaneID[paneID]?
            .raw.paneRootPID

        switch serverProcessTerminator.stop(server, shellPID: shellPID) {
        case .stopped, .notRunning:
            schedulePassiveServerDetectionRefresh()
        case .notOwned, .failed:
            break
        }
    }

    func rememberServerBrowser(_ stableID: String) {
        guard configStore.current.serverDetection.preferredBrowserID != stableID else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.preferredBrowserID = stableID
        }
    }

    private func serverResponse(for worklaneID: WorklaneID) -> AgentIPCResponseResult {
        let context = worklaneStore.serverContext(for: worklaneID)
        return AgentIPCResponseResult(serverState: ServerListResult(
            version: 2,
            primaryServerID: context.primaryServer?.id,
            servers: context.ranked.map(serverListEntry)
        ))
    }

    private func serverListEntry(_ ranked: RankedServer) -> ServerListEntry {
        let server = ranked.server
        return ServerListEntry(
            id: server.id,
            origin: server.origin,
            url: server.url.absoluteString,
            display: server.display,
            worklaneID: server.worklaneID.rawValue,
            paneID: server.paneID?.rawValue,
            source: server.source.rawValue,
            ports: server.ports,
            confidence: server.confidence.rawValue,
            updatedAt: Self.formatServerDate(server.updatedAt),
            tier: Self.tierString(ranked.tier),
            reasons: ranked.reasons.map(Self.reasonString).sorted()
        )
    }

    static func tierString(_ tier: ServerRelevanceTier) -> String {
        switch tier {
        case .primary: "primary"
        case .shown: "shown"
        case .hidden: "hidden"
        }
    }

    static func reasonString(_ reason: ServerRelevanceReason) -> String {
        switch reason {
        case .sessionSelected: "session_selected"
        case .ignoredPort(let port): "ignored_port:\(port)"
        case .manual: "manual"
        case .runningPane: "running_pane"
        case .focusedPane: "focused_pane"
        case .source(let source): "source:\(source.rawValue)"
        case .confidence(let confidence): "confidence:\(confidence.rawValue)"
        case .fresh: "fresh"
        }
    }

    static func formatServerDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func serverRecordID(
        worklaneID: WorklaneID,
        paneID: PaneID?,
        source: DetectedServerSource,
        origin: String
    ) -> String {
        [
            worklaneID.rawValue,
            paneID?.rawValue ?? "worklane",
            source.rawValue,
            origin,
        ].joined(separator: "|")
    }
}
