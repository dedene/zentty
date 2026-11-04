import Foundation

/// The removed-sessions list, kept beside `state.json` as `removals.json` so it outlives the
/// index file: a quarantine at open throws the old index away before anything reads it, and a
/// Rebuild that is cut off between deleting the old file and restoring into the new one would
/// otherwise lose every removal. The index's `tombstones` table mirrors this list; the indexer
/// reads the list before it reads any source and stops (fails closed) when it can't.
///
/// Indexer queue only, while holding the writer lock. "Delete Index" removes it with the
/// directory, by design (D8).
struct AgentHistoryRemovalLedger: Sendable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable, Sendable {
        /// `AgentHistoryAgent.rawValue`; agents this build doesn't know are kept as they are.
        var agent: String
        var nativeID: String
        var removedAt: Int64
    }

    private struct Contents: Codable {
        var version: Int
        var removed: [Entry]
    }

    let fileURL: URL

    private var fileManager: FileManager { .default }

    /// Every entry; empty when there is no file. Throws when the file exists but can't be read
    /// or decoded.
    func entries() throws -> [Entry] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Contents.self, from: data).removed
    }

    /// The removals of agents this build knows.
    func tombstones() throws -> [AgentHistoryRebuildCarryOver.Tombstone] {
        try entries().compactMap { entry in
            AgentHistoryAgent(rawValue: entry.agent).map {
                .init(key: AgentHistorySessionKey(agent: $0, nativeID: entry.nativeID), removedAtMs: entry.removedAt)
            }
        }
    }

    /// Adds the removals not listed yet (a listed one keeps its first removal time). Writes only
    /// when something is new; throws when the existing list can't be read.
    func record(_ tombstones: [AgentHistoryRebuildCarryOver.Tombstone]) throws {
        var entries = try entries()
        var listed = Set(entries.map { AgentHistorySessionKey.Raw(agent: $0.agent, nativeID: $0.nativeID) })
        let before = entries.count
        for tombstone in tombstones {
            let raw = AgentHistorySessionKey.Raw(agent: tombstone.key.agent.rawValue, nativeID: tombstone.key.nativeID)
            guard listed.insert(raw).inserted else { continue }
            entries.append(Entry(agent: raw.agent, nativeID: raw.nativeID, removedAt: tombstone.removedAtMs))
        }
        guard entries.count != before else {
            return
        }
        entries.sort { ($0.agent, $0.nativeID) < ($1.agent, $1.nativeID) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Contents(version: Self.currentVersion, removed: entries))
        try AgentHistoryPrivateFile.write(data, to: fileURL, fileManager: fileManager)
    }

    /// Restore All: forgets every removal.
    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }
}

private extension AgentHistorySessionKey {
    /// A key whose agent may be one this build doesn't know.
    struct Raw: Hashable {
        let agent: String
        let nativeID: String
    }
}

/// Files in the AgentHistory directory that hold private state (`state.json`, `removals.json`).
enum AgentHistoryPrivateFile {
    /// Writes `data` to `url` with mode 0600 through a private temporary file and a rename, so a
    /// reader sees the old or the new content, never a part, and nobody else can read it.
    /// Creates the directory (0700) when it is missing.
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        // Private temp file first, so the content is never readable by others before the rename.
        let temporaryURL = directoryURL.appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp",
                                                               isDirectory: false)
        guard fileManager.createFile(atPath: temporaryURL.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
