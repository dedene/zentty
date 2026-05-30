import AppKit
import AudioToolbox
import Foundation

/// Manages installation and preview of custom notification sounds.
/// Custom sounds are converted via afconvert into the app's Library/Sounds directory
/// as "zentty-custom-<uuid>.caf" (the internal name stored in AppConfig).
/// A fresh file name is minted on every install so macOS never serves a stale cached
/// sound for a reused name; older custom files are pruned once the new one is committed.
/// The original display name is persisted separately for UI.
enum NotificationSoundManager {
    typealias SoundConverter = (_ source: URL, _ destination: URL) throws -> Void

    /// All custom sound files share this prefix so they can be recognised and pruned.
    static let customFilePrefix = "zentty-custom-"
    static let customFileExtension = "caf"

    /// True when `name` denotes one of our installed custom sound files.
    static func isCustomSoundName(_ name: String) -> Bool {
        name.hasPrefix(customFilePrefix) && name.hasSuffix(".\(customFileExtension)")
    }

    private static func makeCustomFileName() -> String {
        "\(customFilePrefix)\(UUID().uuidString).\(customFileExtension)"
    }

    private struct CustomSoundInstallTransaction: Sendable {
        let internalName: String
        let displayName: String
        let destinationURL: URL
        let temporaryDirectory: URL
    }

    /// Override for tests (e.g. temp dir). Set before use and clear in tearDown.
    nonisolated(unsafe) static var soundsDirectoryOverride: URL?
    nonisolated(unsafe) static var libraryDirectoryOverride: URL?
    nonisolated(unsafe) static var converterOverride: SoundConverter?

    static var soundsDirectory: URL {
        if let override = soundsDirectoryOverride { return override }
        let libraryDirectory = libraryDirectoryOverride
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return libraryDirectory
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// Installs a user-picked audio file as the active custom notification sound.
    /// Converts all selected files using `afconvert` (to CAF/ima4).
    /// Returns the internal name to store in soundName and the human display name.
    static func installCustomSound(from source: URL) throws -> (internalName: String, displayName: String) {
        try installCustomSound(from: source) { _, _ in }
    }

    /// Installs a custom sound and commits the persisted selection transactionally.
    /// If persistence fails, the previous installed sound file is restored.
    @discardableResult
    static func installCustomSound(
        from source: URL,
        persistSelection: (_ internalName: String, _ displayName: String) throws -> Void
    ) throws -> (internalName: String, displayName: String) {
        let transaction = try prepareCustomSoundInstall(from: source)
        do {
            try persistSelection(transaction.internalName, transaction.displayName)
            finishCustomSoundInstall(transaction)
        } catch {
            rollbackCustomSoundInstall(transaction)
            throw error
        }

        return (transaction.internalName, transaction.displayName)
    }

    /// Async variant for UI callers. File conversion and rollback stay off the main actor;
    /// the persisted selection is committed on the main actor.
    @discardableResult
    static func installCustomSound(
        from source: URL,
        persistSelection: @MainActor (_ internalName: String, _ displayName: String) throws -> Void
    ) async throws -> (internalName: String, displayName: String) {
        let transaction = try await Task.detached(priority: .userInitiated) {
            try prepareCustomSoundInstall(from: source)
        }.value

        do {
            try await MainActor.run {
                try persistSelection(transaction.internalName, transaction.displayName)
            }
            await Task.detached(priority: .utility) {
                finishCustomSoundInstall(transaction)
            }.value
        } catch {
            await Task.detached(priority: .utility) {
                rollbackCustomSoundInstall(transaction)
            }.value
            throw error
        }

        return (transaction.internalName, transaction.displayName)
    }

    private static func prepareCustomSoundInstall(from source: URL) throws -> CustomSoundInstallTransaction {
        let fm = FileManager.default
        let dir = soundsDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        // Each install gets a unique file name so macOS never replays a stale cached sound
        // for a reused name. The previous custom file is left untouched until the new
        // selection is committed, then pruned in finishCustomSoundInstall.
        let internalName = makeCustomFileName()
        let destURL = dir.appendingPathComponent(internalName)
        let displayName = source.lastPathComponent
        let transactionID = UUID().uuidString
        let temporaryDirectory = dir.appendingPathComponent(".zentty-sound-\(transactionID)", isDirectory: true)
        let temporaryURL = temporaryDirectory.appendingPathComponent(internalName)

        try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
        var transactionPrepared = false
        defer {
            if !transactionPrepared {
                try? fm.removeItem(at: temporaryDirectory)
            }
        }

        if let sourceDuration = audioDuration(of: source), sourceDuration > 30 {
            throw NotificationSoundInstallError.tooLong(sourceDuration)
        }

        do {
            try convertSound(from: source, to: temporaryURL)
            try validateConvertedSoundDuration(at: temporaryURL)
        } catch {
            try? fm.removeItem(at: temporaryDirectory)
            throw error
        }

        do {
            try fm.moveItem(at: temporaryURL, to: destURL)
            transactionPrepared = true
            return CustomSoundInstallTransaction(
                internalName: internalName,
                displayName: displayName,
                destinationURL: destURL,
                temporaryDirectory: temporaryDirectory
            )
        } catch {
            try? fm.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private static func finishCustomSoundInstall(_ transaction: CustomSoundInstallTransaction) {
        try? FileManager.default.removeItem(at: transaction.temporaryDirectory)
        // Drop the previous custom sound (and any orphans) now that the new one is committed.
        pruneCustomSounds(keeping: transaction.internalName)
    }

    private static func rollbackCustomSoundInstall(_ transaction: CustomSoundInstallTransaction) {
        // The new file was never committed; remove only it and the temp dir. Any previously
        // installed custom file keeps its own name and stays referenced by the persisted config.
        try? FileManager.default.removeItem(at: transaction.destinationURL)
        try? FileManager.default.removeItem(at: transaction.temporaryDirectory)
    }

    /// Removes every installed custom sound file except `keepName` (pass nil to remove all).
    /// Used to clear the previous selection on a fresh install and when the user switches
    /// back to a system or default sound.
    static func pruneCustomSounds(keeping keepName: String?) {
        let dir = soundsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return
        }
        for entry in entries where isCustomSoundName(entry) && entry != keepName {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry))
        }
    }

    private static func convertSound(from source: URL, to destination: URL) throws {
        if let converterOverride {
            try converterOverride(source, destination)
            return
        }

        let afconvert = Process()
        afconvert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        afconvert.arguments = ["-f", "caff", "-d", "ima4", source.path, destination.path]
        let stderrPipe = Pipe()
        afconvert.standardError = stderrPipe

        do {
            try afconvert.run()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw NotificationSoundInstallError.conversionFailed("Could not launch afconvert: \(error.localizedDescription)")
        }

        // Drain stderr to EOF before waiting: reading to EOF completes when afconvert closes
        // its stderr on exit, so it doubles as the wait and continuously empties the pipe —
        // it can never deadlock on a full buffer the way waitUntilExit()-then-read could.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        afconvert.waitUntilExit()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if afconvert.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: destination)
            var reason = "afconvert exited with status \(afconvert.terminationStatus)"
            if let stderr, !stderr.isEmpty {
                reason += ": \(stderr)"
            }
            throw NotificationSoundInstallError.conversionFailed(reason)
        }
    }

    private static func validateConvertedSoundDuration(at url: URL) throws {
        guard let duration = audioDuration(of: url) else {
            throw NotificationSoundInstallError.conversionFailed("Could not determine converted audio duration.")
        }
        if duration > 30 {
            throw NotificationSoundInstallError.tooLong(duration)
        }
    }

    private static func audioDuration(of url: URL) -> TimeInterval? {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard openStatus == noErr, let audioFile else {
            return nil
        }
        defer { AudioFileClose(audioFile) }

        var duration: TimeInterval = 0
        var size = UInt32(MemoryLayout<TimeInterval>.size)
        let durationStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyEstimatedDuration,
            &size,
            &duration
        )
        guard durationStatus == noErr, duration.isFinite, duration >= 0 else {
            return nil
        }
        return duration
    }

    /// Returns a file URL suitable for NSSound(contentsOf:) preview for custom sounds, or nil.
    static func urlForPreview(soundName: String) -> URL? {
        guard isCustomSoundName(soundName) else { return nil }
        let url = soundsDirectory.appendingPathComponent(soundName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Attempts to play a preview of the given sound (delegates custom to file URL).
    /// Returns true if preview was started.
    @discardableResult
    static func playPreview(for soundName: String) -> Bool {
        if let url = urlForPreview(soundName: soundName),
           let sound = NSSound(contentsOf: url, byReference: true) {
            return sound.play()
        }
        return false
    }
}

enum NotificationSoundInstallError: Error, LocalizedError {
    case tooLong(TimeInterval)
    case conversionFailed(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .tooLong(let seconds):
            let reported = max(0, Int(seconds.rounded()))
            return "The selected sound is \(reported) seconds long. Please choose a file 30 seconds or shorter."
        case .conversionFailed(let reason):
            return "Could not convert the audio file for use as a notification sound (\(reason))."
        case .fileOperationFailed(let reason):
            return "File operation failed while installing custom sound: \(reason)"
        }
    }
}
