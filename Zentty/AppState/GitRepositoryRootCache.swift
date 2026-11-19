import Foundation

/// Short-lived memo of "which repository does this directory belong to".
///
/// Sidebar and menu-bar summaries ask this for every pane on every metadata
/// update. Answering from disk means a `stat` per ancestor directory, which
/// adds up to thousands of calls per second on the main thread once many panes
/// are open. A repository root rarely changes, so a few seconds of staleness
/// (after `git init`, or after a repository is removed) is an acceptable trade.
final class GitRepositoryRootCache: @unchecked Sendable {
    static let shared = GitRepositoryRootCache()

    private struct Entry {
        let root: String?
        let expiresAt: TimeInterval
    }

    private let timeToLive: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entriesByPath: [String: Entry] = [:]

    init(
        timeToLive: TimeInterval = 2,
        maximumEntryCount: Int = 512,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.timeToLive = timeToLive
        self.maximumEntryCount = maximumEntryCount
        self.now = now
    }

    /// Returns the cached root for `path`, calling `resolve` only when there is
    /// no fresh answer. A `nil` root (not inside a repository) is cached too.
    func root(for path: String, resolve: (String) -> String?) -> String? {
        let currentTime = now()

        lock.lock()
        if let entry = entriesByPath[path], entry.expiresAt > currentTime {
            lock.unlock()
            return entry.root
        }
        lock.unlock()

        let root = resolve(path)

        lock.lock()
        if entriesByPath.count >= maximumEntryCount, entriesByPath[path] == nil {
            entriesByPath = entriesByPath.filter { $0.value.expiresAt > currentTime }
            if entriesByPath.count >= maximumEntryCount {
                entriesByPath.removeAll(keepingCapacity: true)
            }
        }
        entriesByPath[path] = Entry(root: root, expiresAt: currentTime + timeToLive)
        lock.unlock()

        return root
    }

    func removeAll() {
        lock.lock()
        entriesByPath.removeAll()
        lock.unlock()
    }
}
