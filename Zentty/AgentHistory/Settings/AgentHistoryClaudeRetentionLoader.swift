import Foundation

/// Reads and raises Claude Code's retention for Settings › Agent History. The settings.json
/// read and the backup + atomic write run off main (`runner`); results come back on main, and a
/// read that a newer one replaced is dropped.
@MainActor
final class AgentHistoryClaudeRetentionLoader {
    typealias StatusProvider = @Sendable (URL) -> ClaudeRetentionStatus
    typealias Writer = @Sendable (URL) throws -> ClaudeRetentionWriteOutcome

    private let statusProvider: StatusProvider
    private let writer: Writer
    private let runner: AgentHistoryOffMainRunner
    private var generation: UInt64 = 0
    private var writesInFlight: Set<String> = []
    /// Folders raised by "Keep 1 Year" in this window; their row says so.
    private(set) var raisedDirectories: Set<String> = []

    init(statusProvider: @escaping StatusProvider, writer: @escaping Writer, runner: AgentHistoryOffMainRunner) {
        self.statusProvider = statusProvider
        self.writer = writer
        self.runner = runner
    }

    /// Statuses for `roots` in order; only the newest call's completion runs.
    func load(roots: [String], completion: @escaping @MainActor ([ClaudeRetentionStatus]) -> Void) {
        generation &+= 1
        let requested = generation
        let directories = roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let provider = statusProvider
        runner.run({ directories.map(provider) }) { [weak self] statuses in
            guard let self, requested == self.generation else { return }
            completion(statuses)
        }
    }

    /// Raises one folder's retention; a second click while its write runs is ignored.
    func raise(directory: String, completion: @escaping @MainActor (Error?) -> Void) {
        guard writesInFlight.insert(directory).inserted else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let writer = writer
        runner.run({ Result { try writer(url) } }) { [weak self] result in
            guard let self else { return }
            self.writesInFlight.remove(directory)
            switch result {
            case .success:
                self.raisedDirectories.insert(directory)
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }
}
