import Foundation

/// config.toml stores a custom sound by file name, but macOS only plays it
/// from ~/Library/Sounds, which isn't synced. Each install also keeps a copy
/// in `<config dir>/sounds`, so a second Mac sharing config.toml can install
/// the same file the first time it needs it.
extension NotificationSoundManager {
    /// Override for tests. Set before use and clear in tearDown.
    nonisolated(unsafe) static var sharedSoundsDirectoryOverride: URL?

    /// `nil` when the sounds directory is overridden without a shared one:
    /// that's a test or tool, which must never write to the real config dir.
    static var sharedSoundsDirectory: URL? {
        if let sharedSoundsDirectoryOverride { return sharedSoundsDirectoryOverride }
        guard soundsDirectoryOverride == nil, libraryDirectoryOverride == nil else { return nil }
        return ZenttyBuildFlavor.current
            .configDirectoryURL(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("sounds", isDirectory: true)
    }

    /// Copies an installed custom sound into the shared directory and drops
    /// this flavor's older copies there. Best effort: playback doesn't need it.
    static func shareInstalledSound(named name: String) {
        guard let sharedDirectory = sharedSoundsDirectory else { return }
        let fileManager = FileManager.default
        let destinationURL = sharedDirectory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: soundsDirectory.appendingPathComponent(name), to: destinationURL)
        } catch {
            return
        }
        removeCustomSoundFiles(in: sharedDirectory, keeping: name, ownedPrefix: customFilePrefix)
    }

    /// Installs `name` into ~/Library/Sounds from the shared copy when this
    /// Mac doesn't have it yet. Returns true when a file was installed.
    @discardableResult
    static func installSharedSoundIfMissing(named name: String) -> Bool {
        guard isCustomSoundName(name), let sharedDirectory = sharedSoundsDirectory else { return false }
        let fileManager = FileManager.default
        let installedURL = soundsDirectory.appendingPathComponent(name)
        let sharedURL = sharedDirectory.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: installedURL.path),
              fileManager.fileExists(atPath: sharedURL.path) else {
            return false
        }
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sharedURL, to: installedURL)
            return true
        } catch {
            return false
        }
    }

    static func removeCustomSoundFiles(in directory: URL, keeping keepName: String?, ownedPrefix: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for entry in entries
        where entry.hasPrefix(ownedPrefix) && entry.hasSuffix(".\(customFileExtension)") && entry != keepName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}
