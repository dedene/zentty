import Foundation
import OSLog

private let runtimeStateRelocationLogger = Logger(subsystem: "be.zenjoy.zentty", category: "RuntimeState")

/// One-time copy of per-Mac session state from the config directory into the
/// flavor's Application Support folder, so `~/.config/zentty` only needs to
/// hold files worth syncing between Macs (config.toml, bookmarks.json, agents/).
///
/// Copies, never moves or deletes: older Zentty builds (other worktrees, a Mac
/// not yet upgraded) may still be running against the old files. A marker
/// file makes it run once, so later writes by those builds are never pulled in;
/// it is only written after every copy succeeded, so a failed run is retried.
enum RuntimeStateRelocation {
    /// Copied together or not at all: a snapshot paired with another
    /// instance's lifecycle file can turn into a bogus crash recovery.
    static let restoreFileNames = ["restore-snapshot.json", "restore-lifecycle.json"]
    static let tmuxCompatFileName = "tmux-compat-store.json"
    static let fileNames = restoreFileNames + [tmuxCompatFileName]
    static let markerFileName = ".relocated-from-config-dir"

    /// Returns the names that were copied.
    @discardableResult
    static func migrateIfNeeded(
        from configDirectoryURL: URL,
        to stateDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let markerURL = stateDirectoryURL.appendingPathComponent(markerFileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: markerURL.path) else { return [] }

        var namesToCopy: [String] = []
        let snapshotName = restoreFileNames[0]
        if !exists(snapshotName, in: stateDirectoryURL, fileManager),
           exists(snapshotName, in: configDirectoryURL, fileManager) {
            namesToCopy.append(contentsOf: restoreFileNames)
        }
        namesToCopy.append(tmuxCompatFileName)

        var copied: [String] = []
        var failed = false
        for name in namesToCopy {
            do {
                if try copyIfMissing(name, from: configDirectoryURL, to: stateDirectoryURL, fileManager) {
                    copied.append(name)
                }
            } catch {
                failed = true
                runtimeStateRelocationLogger.error(
                    "Failed to copy \(name, privacy: .public) to \(stateDirectoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard !failed else { return copied }

        do {
            try fileManager.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
            try Data().write(to: markerURL)
        } catch {
            runtimeStateRelocationLogger.error(
                "Failed to mark runtime state as relocated in \(stateDirectoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return copied
    }

    private static func exists(_ name: String, in directory: URL, _ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(name, isDirectory: false).path)
    }

    private static func copyIfMissing(
        _ name: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        _ fileManager: FileManager
    ) throws -> Bool {
        let sourceURL = sourceDirectory.appendingPathComponent(name, isDirectory: false)
        let destinationURL = destinationDirectory.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path) else {
            return false
        }
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return true
    }
}
