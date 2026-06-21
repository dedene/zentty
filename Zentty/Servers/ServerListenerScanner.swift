import Darwin
import Foundation

struct ServerScanContext: Equatable, Sendable {
    let worklaneID: WorklaneID
    let panes: [PaneScanContext]
}

struct PaneScanContext: Equatable, Sendable {
    let paneID: PaneID
    let workingDirectory: String
    let repositoryRoot: String?
    let shellPID: pid_t?

    init(
        paneID: PaneID,
        workingDirectory: String,
        repositoryRoot: String? = nil,
        shellPID: pid_t?
    ) {
        self.paneID = paneID
        self.workingDirectory = workingDirectory
        self.repositoryRoot = repositoryRoot
        self.shellPID = shellPID
    }
}

struct ServerListenerScanner: Sendable {
    private let processInspector: any ProcessInspecting
    private let currentDate: @Sendable () -> Date

    init(
        processInspector: any ProcessInspecting = DarwinProcessInspector(),
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processInspector = processInspector
        self.currentDate = currentDate
    }

    func scan(context: ServerScanContext) -> [DetectedServer] {
        processInspector.listeningTCPSockets().enumerated().compactMap { index, socket in
            detectedServer(
                from: socket,
                context: context,
                updatedAt: currentDate().addingTimeInterval(Double(index) / 1_000_000)
            )
        }
    }

    private func detectedServer(
        from socket: ListeningSocket,
        context: ServerScanContext,
        updatedAt: Date
    ) -> DetectedServer? {
        guard let candidate = try? ServerURLNormalizer.normalize("\(formattedHost(socket.localHost)):\(socket.port)") else {
            return nil
        }

        guard let attribution = attribution(for: socket, context: context) else {
            return nil
        }

        return DetectedServer(
            id: id(for: candidate, context: context, paneID: attribution.paneID),
            origin: candidate.origin,
            url: candidate.url,
            display: candidate.display,
            worklaneID: context.worklaneID,
            paneID: attribution.paneID,
            source: .scanner,
            ports: [candidate.port],
            confidence: attribution.confidence,
            updatedAt: updatedAt
        )
    }

    private func attribution(
        for socket: ListeningSocket,
        context: ServerScanContext
    ) -> (paneID: PaneID?, confidence: DetectedServerConfidence)? {
        if let pane = context.panes.first(where: { pane in
            guard let shellPID = pane.shellPID else {
                return false
            }

            return processInspector.isProcess(socket.pid, descendantOf: shellPID)
        }) {
            return (pane.paneID, .pid)
        }

        guard let processWorkingDirectory = processInspector.workingDirectory(of: socket.pid) else {
            return nil
        }

        let matchingPanes = context.panes
            .filter { cwdFallbackMatches(processWorkingDirectory: processWorkingDirectory, pane: $0) }
            .map { pane in (pane: pane, depth: pathDepth(pane.workingDirectory)) }
        if let deepestDepth = matchingPanes.map(\.depth).max() {
            let deepestMatches = matchingPanes.filter { $0.depth == deepestDepth }
            if deepestMatches.count == 1, let pane = deepestMatches.first?.pane {
                return (pane.paneID, .cwd)
            }

            return (nil, .worklane)
        }

        return nil
    }

    private func cwdFallbackMatches(processWorkingDirectory: String, pane: PaneScanContext) -> Bool {
        guard let repositoryRoot = pane.repositoryRoot,
              !isBroadRoot(pane.workingDirectory) else {
            return false
        }

        return path(processWorkingDirectory, isInsideOrEqualTo: pane.workingDirectory)
            && path(processWorkingDirectory, isInsideOrEqualTo: repositoryRoot)
    }

    private func isBroadRoot(_ path: String) -> Bool {
        Self.broadRootPaths.contains(Self.canonicalPath(path))
    }

    private static let broadRootPaths: Set<String> = {
        let home = NSHomeDirectory()
        return Set([
            "/",
            "/tmp",
            "/private/tmp",
            "/var/tmp",
            "/Users",
            home,
            canonicalPath(home),
        ].map(canonicalPath))
    }()

    private func path(_ childPath: String, isInsideOrEqualTo parentPath: String) -> Bool {
        let child = Self.canonicalPath(childPath)
        let parent = Self.canonicalPath(parentPath)
        guard !child.isEmpty, !parent.isEmpty else {
            return false
        }

        if child == parent {
            return true
        }

        let prefix = parent.hasSuffix("/") ? parent : "\(parent)/"
        return child.hasPrefix(prefix)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func pathDepth(_ path: String) -> Int {
        Self.canonicalPath(path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .count
    }

    private func formattedHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    private func id(
        for candidate: ServerURLCandidate,
        context: ServerScanContext,
        paneID: PaneID?
    ) -> String {
        let owner = paneID?.rawValue ?? "worklane"
        return "scanner:\(context.worklaneID.rawValue):\(owner):\(candidate.origin)"
    }
}
