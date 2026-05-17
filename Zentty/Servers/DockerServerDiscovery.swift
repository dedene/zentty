import Foundation

protocol DockerInspecting: Sendable {
    func isDockerResponsive() -> Bool
    func runningContainers() throws -> [DockerContainer]
}

struct DockerContainer: Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let command: String
    let labels: [String: String]
    let publishedPorts: [DockerPublishedPort]
}

struct DockerPublishedPort: Equatable, Sendable {
    let hostIP: String
    let hostPort: Int
    let containerPort: Int
    let protocolName: String
}

struct DockerDiscoveryContext: Equatable, Sendable {
    let worklaneID: WorklaneID
    let focusedPaneID: PaneID?
    let panes: [DockerPaneContext]
}

struct DockerPaneContext: Equatable, Sendable {
    let paneID: PaneID
    let workingDirectory: String
    let recentCommandLines: [String]
}

struct DockerServerDiscovery: Sendable {
    private let dockerInspector: any DockerInspecting
    private let currentDate: @Sendable () -> Date

    init(
        dockerInspector: any DockerInspecting = DockerCLIInspector(),
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dockerInspector = dockerInspector
        self.currentDate = currentDate
    }

    func discover(context: DockerDiscoveryContext) -> [DetectedServer] {
        guard dockerInspector.isDockerResponsive() else {
            return []
        }

        let containers: [DockerContainer]
        do {
            containers = try dockerInspector.runningContainers()
        } catch {
            return []
        }

        return containers.flatMap { container in
            detectedServers(from: container, context: context)
        }
    }

    private func detectedServers(
        from container: DockerContainer,
        context: DockerDiscoveryContext
    ) -> [DetectedServer] {
        guard isRelevantToWorklane(container, context: context), isWebLike(container) else {
            return []
        }

        return container.publishedPorts.compactMap { publishedPort in
            guard publishedPort.protocolName.lowercased() == "tcp",
                  isWebLikePublishedPort(publishedPort, container: container) else {
                return nil
            }

            let host = publishedPort.hostIP.isEmpty ? "localhost" : publishedPort.hostIP
            guard let candidate = try? ServerURLNormalizer.normalize("\(host):\(publishedPort.hostPort)") else {
                return nil
            }

            let paneID = assignedPaneID(for: container, context: context)
            return DetectedServer(
                id: "docker:\(container.id):\(candidate.origin)",
                origin: candidate.origin,
                url: candidate.url,
                display: candidate.display,
                worklaneID: context.worklaneID,
                paneID: paneID,
                source: .docker,
                ports: [candidate.port],
                confidence: paneID == nil ? .worklane : .cwd,
                updatedAt: currentDate()
            )
        }
    }

    private func isRelevantToWorklane(_ container: DockerContainer, context: DockerDiscoveryContext) -> Bool {
        let projectPaths = composeProjectPaths(for: container)
        let matchesPath = projectPaths.contains { projectPath in
            context.panes.contains { pane in pathsOverlap(projectPath, pane.workingDirectory) }
        }
        if !projectPaths.isEmpty {
            return matchesPath
        }

        return hasActivationEvidence(context)
    }

    private func assignedPaneID(for container: DockerContainer, context: DockerDiscoveryContext) -> PaneID? {
        let projectPaths = composeProjectPaths(for: container)
        let matchingPanes = context.panes.filter { pane in
            projectPaths.contains { projectPath in pathsOverlap(projectPath, pane.workingDirectory) }
        }

        if let focusedPaneID = context.focusedPaneID,
           matchingPanes.contains(where: { $0.paneID == focusedPaneID }) {
            return focusedPaneID
        }

        if let pane = matchingPanes.first(where: hasActivationEvidence) {
            return pane.paneID
        }

        return deepestUniquePane(from: matchingPanes)
    }

    private func composeProjectPaths(for container: DockerContainer) -> [String] {
        var paths: [String] = []

        if let workingDirectory = container.labels["com.docker.compose.project.working_dir"] {
            paths.append(workingDirectory)
        }

        if let configFiles = container.labels["com.docker.compose.project.config_files"] {
            for rawPath in configFiles.split(separator: ",").map(String.init) {
                let url = URL(fileURLWithPath: rawPath)
                paths.append(url.deletingLastPathComponent().path)
            }
        }

        return paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func isWebLike(_ container: DockerContainer) -> Bool {
        let text = searchText(for: container)
        let excludedTerms = [
            "postgres", "mysql", "mariadb", "redis", "memcached", "elasticsearch",
            "opensearch", "mongo", "rabbitmq", "kafka",
        ]
        guard !excludedTerms.contains(where: { text.contains($0) }) else {
            return false
        }

        let positiveTerms = [
            "web", "app", "frontend", "vite", "next", "nuxt", "rails", "django",
            "flask", "phoenix", "laravel", "node", "http", "nginx",
        ]
        return positiveTerms.contains(where: { text.contains($0) })
            || container.publishedPorts.contains { commonWebPorts.contains($0.containerPort) || commonWebPorts.contains($0.hostPort) }
    }

    private func isWebLikePublishedPort(_ port: DockerPublishedPort, container _: DockerContainer) -> Bool {
        commonWebPorts.contains(port.containerPort)
            || commonWebPorts.contains(port.hostPort)
    }

    private var commonWebPorts: Set<Int> {
        [80, 443, 3000, 3001, 4000, 4200, 5000, 5173, 8000, 8080, 8888]
    }

    private func hasActivationEvidence(_ context: DockerDiscoveryContext) -> Bool {
        context.panes.contains(where: hasActivationEvidence)
    }

    private func hasActivationEvidence(_ pane: DockerPaneContext) -> Bool {
        pane.recentCommandLines.contains { commandLine in
            let command = commandLine.lowercased()
            return command.contains("docker")
                || command.contains("docker compose")
                || command.contains("compose")
                || command.contains("dip")
        }
    }

    private func deepestUniquePane(from panes: [DockerPaneContext]) -> PaneID? {
        let ranked = panes.map { pane in (pane: pane, depth: pathDepth(pane.workingDirectory)) }
        guard let deepestDepth = ranked.map(\.depth).max() else {
            return nil
        }

        let deepest = ranked.filter { $0.depth == deepestDepth }
        return deepest.count == 1 ? deepest[0].pane.paneID : nil
    }

    private func pathDepth(_ path: String) -> Int {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .split(separator: "/", omittingEmptySubsequences: true)
            .count
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return path(left, isInsideOrEqualTo: right) || path(right, isInsideOrEqualTo: left)
    }

    private func path(_ childPath: String, isInsideOrEqualTo parentPath: String) -> Bool {
        guard !childPath.isEmpty, !parentPath.isEmpty else {
            return false
        }
        if childPath == parentPath {
            return true
        }

        let prefix = parentPath.hasSuffix("/") ? parentPath : "\(parentPath)/"
        return childPath.hasPrefix(prefix)
    }

    private func searchText(for container: DockerContainer) -> String {
        (
            [
                container.name,
                container.image,
                container.command,
            ] + container.labels.flatMap { [$0.key, $0.value] }
        )
        .joined(separator: " ")
        .lowercased()
    }
}

struct DockerCLIInspector: DockerInspecting {
    private let dockerExecutableURL: URL
    private let socketExists: @Sendable (String) -> Bool

    init(
        dockerExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        socketExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.dockerExecutableURL = dockerExecutableURL
        self.socketExists = socketExists
    }

    func isDockerResponsive() -> Bool {
        guard hasExistingDockerSocket() else {
            return false
        }

        return (try? runDocker(arguments: ["docker", "version", "--format", "{{.Server.Version}}"], timeout: 1)) != nil
    }

    func runningContainers() throws -> [DockerContainer] {
        let idsOutput = try runDocker(arguments: ["docker", "ps", "-q"], timeout: 2)
        let ids = idsOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            return []
        }

        let inspectOutput = try runDocker(arguments: ["docker", "inspect"] + ids, timeout: 2)
        guard let data = inspectOutput.data(using: .utf8),
              let rawContainers = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return rawContainers.map(Self.container(from:))
    }

    private func hasExistingDockerSocket() -> Bool {
        let fileManager = FileManager.default
        let socketPaths = [
            "/var/run/docker.sock",
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".docker", isDirectory: true)
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent("docker.sock")
                .path,
        ]

        return socketPaths.contains(where: socketExists)
    }

    private func runDocker(arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = dockerExecutableURL
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw CocoaError(.executableLoad)
        }

        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func container(from raw: [String: Any]) -> DockerContainer {
        let config = raw["Config"] as? [String: Any] ?? [:]
        let labels = config["Labels"] as? [String: String] ?? [:]
        let networkSettings = raw["NetworkSettings"] as? [String: Any] ?? [:]
        let ports = networkSettings["Ports"] as? [String: Any] ?? [:]

        return DockerContainer(
            id: raw["Id"] as? String ?? "",
            name: ((raw["Name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            image: config["Image"] as? String ?? "",
            command: command(config: config),
            labels: labels,
            publishedPorts: publishedPorts(from: ports)
        )
    }

    private static func command(config: [String: Any]) -> String {
        if let cmd = config["Cmd"] as? [String] {
            return cmd.joined(separator: " ")
        }

        return [config["Entrypoint"], config["Cmd"]]
            .compactMap { value -> String? in
                if let string = value as? String {
                    return string
                }
                if let strings = value as? [String] {
                    return strings.joined(separator: " ")
                }
                return nil
            }
            .joined(separator: " ")
    }

    private static func publishedPorts(from rawPorts: [String: Any]) -> [DockerPublishedPort] {
        rawPorts.flatMap { key, value -> [DockerPublishedPort] in
            let components = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2, let containerPort = Int(components[0]) else {
                return []
            }

            let protocolName = components[1]
            guard let bindings = value as? [[String: String]] else {
                return []
            }

            return bindings.compactMap { binding in
                guard let hostPortString = binding["HostPort"], let hostPort = Int(hostPortString) else {
                    return nil
                }

                return DockerPublishedPort(
                    hostIP: binding["HostIp"] ?? "",
                    hostPort: hostPort,
                    containerPort: containerPort,
                    protocolName: protocolName
                )
            }
        }
    }
}
