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
    /// instance's lifecycle file can turn into a bogus crash recovery. The
    /// snapshot goes first, so dying between the two copies leaves a snapshot
    /// with no lifecycle, which reads as a normal restore.
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

        var copied: [String] = []
        var failed = false
        if restorePairNeedsCopy(from: configDirectoryURL, to: stateDirectoryURL, fileManager) {
            do {
                copied.append(contentsOf: try copyRestorePair(from: configDirectoryURL, to: stateDirectoryURL, fileManager))
            } catch {
                failed = true
                logCopyFailure("restore files", to: stateDirectoryURL, error)
            }
        }
        do {
            if try copyIfMissing(tmuxCompatFileName, from: configDirectoryURL, to: stateDirectoryURL, fileManager) {
                copied.append(tmuxCompatFileName)
            }
        } catch {
            failed = true
            logCopyFailure(tmuxCompatFileName, to: stateDirectoryURL, error)
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

    /// Where this launch's restore store belongs. A pair that could not be
    /// copied stays authoritative in the config directory: the launch writes
    /// its lifecycle and snapshots straight away, and in the empty state
    /// directory those would read as existing state and end the retry for good.
    static func restoreStoreDirectory(
        from configDirectoryURL: URL,
        to stateDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        restorePairNeedsCopy(from: configDirectoryURL, to: stateDirectoryURL, fileManager)
            ? configDirectoryURL
            : stateDirectoryURL
    }

    private static func restorePairNeedsCopy(
        from configDirectoryURL: URL,
        to stateDirectoryURL: URL,
        _ fileManager: FileManager
    ) -> Bool {
        !exists(markerFileName, in: stateDirectoryURL, fileManager)
            && !restoreFileNames.contains { exists($0, in: stateDirectoryURL, fileManager) }
            && exists(restoreFileNames[0], in: configDirectoryURL, fileManager)
    }

    /// All or nothing: on failure it removes what this attempt created, so the
    /// retry sees an empty slot rather than half a pair.
    private static func copyRestorePair(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        _ fileManager: FileManager
    ) throws -> [String] {
        var created: [String] = []
        do {
            for name in restoreFileNames {
                if try copyIfMissing(name, from: sourceDirectory, to: destinationDirectory, fileManager) {
                    created.append(name)
                }
            }
            return created
        } catch {
            for name in created {
                do {
                    try fileManager.removeItem(at: destinationDirectory.appendingPathComponent(name, isDirectory: false))
                } catch {
                    runtimeStateRelocationLogger.error(
                        "Failed to roll back \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    private static func logCopyFailure(_ name: String, to directory: URL, _ error: Error) {
        runtimeStateRelocationLogger.error(
            "Failed to copy \(name, privacy: .public) to \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
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
