import Foundation
import OSLog

private let runtimeStateRelocationLogger = Logger(subsystem: "be.zenjoy.zentty", category: "RuntimeState")

/// One-time move of per-Mac session state out of the config directory into
/// the flavor's Application Support folder, so `~/.config/zentty` only holds
/// files worth syncing between Macs (config.toml, bookmarks.json, agents/).
/// Runs on every launch; once the old files are gone it is a no-op.
enum RuntimeStateRelocation {
    static let fileNames = [
        "restore-snapshot.json",
        "restore-lifecycle.json",
        "tmux-compat-store.json",
        "tmux-compat-trace.jsonl",
    ]

    /// Moves each state file that still sits in `configDirectoryURL`. When
    /// both copies exist (an older build ran in between and wrote the old
    /// location again) the newer one wins and the old location is cleared.
    /// Returns the names that were moved.
    @discardableResult
    static func migrateIfNeeded(
        from configDirectoryURL: URL,
        to stateDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        var moved: [String] = []
        for name in fileNames {
            let sourceURL = configDirectoryURL.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let destinationURL = stateDirectoryURL.appendingPathComponent(name, isDirectory: false)
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    guard modificationDate(of: sourceURL, fileManager) > modificationDate(of: destinationURL, fileManager) else {
                        try fileManager.removeItem(at: sourceURL)
                        continue
                    }
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                moved.append(name)
            } catch {
                runtimeStateRelocationLogger.error(
                    "Failed to move \(name, privacy: .public) to \(stateDirectoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return moved
    }

    private static func modificationDate(of url: URL, _ fileManager: FileManager) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
