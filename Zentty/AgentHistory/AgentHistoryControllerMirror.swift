import Foundation

/// What other threads read from the controller, and the lazily created state store.
final class AgentHistoryControllerMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus = AgentHistoryStatus.off
    private var storedSnapshot = AgentHistoryMetadataSnapshot.empty
    private var storedStorage: AgentHistoryStorage?
    private var excludedFolders: [String] = []
    private var cachedExclusions: AgentHistoryExclusionMatcher?
    private var allowsAll = false
    private var storedEnabledAgents: Set<AgentHistoryAgent> = []
    /// Guarded separately: creating the store reads the file, which must not hold up `lock`.
    private let stateStoreLock = NSLock()
    private var store: AgentHistoryStateStore?

    var status: AgentHistoryStatus {
        get { withLock { storedStatus } }
        set { withLock { storedStatus = newValue } }
    }

    var snapshot: AgentHistoryMetadataSnapshot {
        get { withLock { storedSnapshot } }
        set { withLock { storedSnapshot = newValue } }
    }

    var storage: AgentHistoryStorage? {
        get { withLock { storedStorage } }
        set { withLock { storedStorage = newValue } }
    }

    var allowsAgentsAllProjects: Bool {
        withLock { allowsAll }
    }

    var enabledAgents: Set<AgentHistoryAgent> {
        get { withLock { storedEnabledAgents } }
        set { withLock { storedEnabledAgents = newValue } }
    }

    var exclusions: AgentHistoryExclusionMatcher {
        let folders = withLock { () -> [String]? in
            cachedExclusions == nil ? excludedFolders : nil
        }
        guard let folders else {
            return withLock { cachedExclusions } ?? AgentHistoryExclusionMatcher(folders: [])
        }
        // Canonicalizing may resolve symlinks (disk), so it runs outside the lock.
        let matcher = AgentHistoryExclusionMatcher(folders: folders)
        withLock {
            if excludedFolders == folders {
                cachedExclusions = matcher
            }
        }
        return matcher
    }

    /// True when the excluded folders changed (the matcher must be rebuilt).
    @discardableResult
    func setConfig(_ section: AppConfig.AgentHistory) -> Bool {
        withLock {
            allowsAll = section.allowAgentsAllProjects
            guard excludedFolders != section.excludedFolders else { return false }
            excludedFolders = section.excludedFolders
            cachedExclusions = nil
            return true
        }
    }

    func stateStore(fileURL: URL) -> AgentHistoryStateStore {
        stateStoreLock.lock()
        defer { stateStoreLock.unlock() }
        if let store {
            return store
        }
        let created = AgentHistoryStateStore(fileURL: fileURL)
        store = created
        return created
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
