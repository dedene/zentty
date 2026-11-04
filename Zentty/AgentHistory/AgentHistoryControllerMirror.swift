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
    /// Agent access turned off while config.toml couldn't be written. Off holds, whatever the
    /// config says, until a writable config says off too (fail closed: a fixed file that still
    /// says on doesn't quietly grant access back).
    private var revocationPendingSave = false
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

    struct ConfigChange: Equatable {
        /// The matcher must be rebuilt.
        var excludedFoldersChanged = false
        /// config.toml is writable again but still says on: write the revocation.
        var revocationNeedsSave = false
    }

    /// `isWriteProtected`: the config store couldn't write this config to config.toml.
    @discardableResult
    func setConfig(_ section: AppConfig.AgentHistory, isWriteProtected: Bool = false) -> ConfigChange {
        withLock {
            let allows = section.allowAgentsAllProjects
            if isWriteProtected {
                // Access can only go down while nothing reaches the file.
                revocationPendingSave = revocationPendingSave || (allowsAll && !allows)
                allowsAll = allowsAll && allows
            } else {
                if !allows {
                    revocationPendingSave = false
                }
                allowsAll = allows && !revocationPendingSave
            }
            var change = ConfigChange(revocationNeedsSave: revocationPendingSave && !isWriteProtected)
            guard excludedFolders != section.excludedFolders else { return change }
            excludedFolders = section.excludedFolders
            cachedExclusions = nil
            change.excludedFoldersChanged = true
            return change
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
