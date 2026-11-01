import Foundation

extension AgentHistoryController {
    /// The search engine over the running index (palette, CLI, IPC), built once for the
    /// controller's storage and reused. Nil while the indexer is off or the index is unavailable
    /// (newer schema, failed open). Safe from any thread; the engine itself runs every query on a
    /// reader connection on the caller's thread, so callers stay off main.
    ///
    /// The metadata tier reads the published snapshot and the configured exclusions live, so an
    /// engine handed out earlier keeps seeing new sessions and newly excluded folders (A-10).
    nonisolated var searchEngine: HistorySearchEngine? {
        guard let storage, storage.availability == .ready else {
            return nil
        }
        return searchEngineCache.engine(for: storage) {
            let metadataIndex = HistoryMetadataIndex(
                snapshot: { [weak self] in self?.threadSafeSnapshot ?? .empty },
                exclusions: { [weak self] in self?.exclusions ?? AgentHistoryExclusionMatcher(folders: []) }
            )
            return HistorySearchEngine(
                readers: storage.readers,
                metadataIndex: metadataIndex,
                tokenizer: { storage.tokenizer ?? .none },
                exclusions: { [weak self] in self?.exclusions ?? AgentHistoryExclusionMatcher(folders: []) }
            )
        }
    }
}

/// Holds the one search engine per storage instance. Lock-guarded: any thread may ask.
final class AgentHistorySearchEngineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AgentHistoryStorage?
    private var engine: HistorySearchEngine?

    /// The cached engine when it was built for `storage`, else a new one from `make` (no I/O).
    func engine(for storage: AgentHistoryStorage, make: () -> HistorySearchEngine) -> HistorySearchEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine, self.storage === storage {
            return engine
        }
        let created = make()
        self.storage = storage
        engine = created
        return created
    }
}
