import Foundation

/// One pane that may have triggered a 1Password authorization prompt.
struct OnePasswordPromptPaneSource: Equatable, Sendable {
    let windowID: WindowID
    let worklaneID: WorklaneID
    let paneID: PaneID
    let rootPID: Int32?
}

/// A pane whose process tree contains a live 1Password request.
struct OnePasswordPromptCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The `op` CLI (talks to the 1Password app or its daemon).
        case cli
        /// An SSH-family process holding a connection to the 1Password SSH agent.
        case sshAgent
    }

    let source: OnePasswordPromptPaneSource
    let kind: Kind
    let pid: Int32
    let processName: String
    /// Unix epoch seconds when the requesting process started. Used to pick the
    /// most recent request when several panes qualify.
    let startedAt: TimeInterval?
}

protocol OnePasswordPromptProcessProviding: Sendable {
    func treePIDs(rootPID: Int32) -> [Int32]
    func processName(pid: Int32) -> String?
    func argv(pid: Int32) -> [String]?
    func startTime(pid: Int32) -> TimeInterval?
    /// Paths of Unix-domain sockets this process is connected to (peer side).
    func unixSocketPeerPaths(pid: Int32) -> [String]
}

/// Answers "which pane made 1Password prompt?" by inspecting pane process
/// trees. 1Password itself only knows the requesting PID, so this inference is
/// the only bridge back to a pane.
struct OnePasswordPromptAttributor: Sendable {
    static let onePasswordGroupContainerMarker = "2BUA8C4S2C.com.1password"
    static let sshAgentSocketName = "agent.sock"
    static let cliProcessName = "op"
    static let sshProcessNames: Set<String> = ["ssh", "scp", "sftp", "ssh-add", "git", "rsync"]

    private let processProvider: any OnePasswordPromptProcessProviding

    init(processProvider: any OnePasswordPromptProcessProviding) {
        self.processProvider = processProvider
    }

    /// Scans every source and returns the candidates, most recently started first.
    /// Each pane contributes at most one candidate (its newest request).
    func candidates(in sources: [OnePasswordPromptPaneSource]) -> [OnePasswordPromptCandidate] {
        var results: [OnePasswordPromptCandidate] = []
        for source in sources {
            guard let rootPID = source.rootPID, rootPID > 0 else {
                continue
            }
            let paneCandidates = processProvider.treePIDs(rootPID: rootPID)
                .compactMap { candidate(for: $0, in: source) }
            if let newest = Self.sortedByRecency(paneCandidates).first {
                results.append(newest)
            }
        }
        return Self.sortedByRecency(results)
    }

    /// The single pane to jump to, or nil when nothing qualifies.
    func bestCandidate(in sources: [OnePasswordPromptPaneSource]) -> OnePasswordPromptCandidate? {
        candidates(in: sources).first
    }

    private func candidate(for pid: Int32, in source: OnePasswordPromptPaneSource) -> OnePasswordPromptCandidate? {
        guard let name = processProvider.processName(pid: pid), !name.isEmpty else {
            return nil
        }

        if name == Self.cliProcessName {
            guard Self.isCLIClient(argv: processProvider.argv(pid: pid)) else {
                return nil
            }
            return OnePasswordPromptCandidate(
                source: source,
                kind: .cli,
                pid: pid,
                processName: name,
                startedAt: processProvider.startTime(pid: pid)
            )
        }

        if Self.sshProcessNames.contains(name),
           processProvider.unixSocketPeerPaths(pid: pid).contains(where: Self.isOnePasswordAgentSocket) {
            return OnePasswordPromptCandidate(
                source: source,
                kind: .sshAgent,
                pid: pid,
                processName: name,
                startedAt: processProvider.startTime(pid: pid)
            )
        }

        return nil
    }

    /// `op daemon` is a detached helper (parent PID 1) that never prompts on its
    /// own; only real client invocations count.
    static func isCLIClient(argv: [String]?) -> Bool {
        guard let argv, argv.count > 1 else {
            return true
        }
        return argv[1] != "daemon" && argv[1] != "cleanup"
    }

    static func isOnePasswordAgentSocket(_ path: String) -> Bool {
        path.contains(onePasswordGroupContainerMarker) && path.hasSuffix("/" + sshAgentSocketName)
    }

    private static func sortedByRecency(_ candidates: [OnePasswordPromptCandidate]) -> [OnePasswordPromptCandidate] {
        candidates.sorted { lhs, rhs in
            switch (lhs.startedAt, rhs.startedAt) {
            case let (l?, r?) where l != r:
                return l > r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs.pid > rhs.pid
            }
        }
    }
}
