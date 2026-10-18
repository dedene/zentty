import CryptoKit
import Foundation
import OSLog

private let sessionScrollbackLogger = Logger(subsystem: "be.zenjoy.zentty", category: "SessionScrollback")

/// Turns captured pane text into the file Zentty prints back into the pane on
/// the next launch. Pure and thread-agnostic, so it runs off the main thread.
enum SessionScrollbackText {
    struct Limits: Equatable, Sendable {
        var maxLines: Int
        var maxBytes: Int

        static let perPane = Limits(maxLines: 4_000, maxBytes: 1_048_576)
    }

    /// Upper bound across every pane of one save. Each pane's byte cap
    /// shrinks to its share once there are enough panes to exceed it.
    static let totalByteBudget = 32 * 1_048_576

    static let separatorTitle = "── restored from previous session ──"
    /// Printed after the saved text: SGR 2 (faint), reset afterwards.
    static let separatorLine = "\u{1B}[2m\(separatorTitle)\u{1B}[0m\n"

    /// The separator as read back from the screen, and as found in a saved
    /// payload once its escape bytes are stripped.
    private static let replayedSeparatorLines: Set<String> = [
        separatorTitle,
        sanitized(separatorLine).trimmingCharacters(in: .whitespacesAndNewlines),
    ]

    static func limits(forPaneCount paneCount: Int, base: Limits = .perPane) -> Limits {
        guard paneCount > 0 else { return base }
        let share = max(1, totalByteBudget / paneCount)
        return Limits(maxLines: base.maxLines, maxBytes: min(base.maxBytes, share))
    }

    /// Sanitized, capped text with the trailing separator, or nil when the
    /// pane shows nothing worth restoring.
    static func replayPayload(from raw: String, limits: Limits = .perPane) -> String? {
        guard let text = preparedText(from: raw, limits: limits) else {
            return nil
        }
        return text + "\n" + separatorLine
    }

    /// Strips terminal control characters (so printing the file can never
    /// run escape sequences), drops trailing blank lines, and keeps the
    /// newest lines within `limits`, trimming from the top. Separators
    /// replayed by an earlier restore are dropped, so a pane restored many
    /// times still shows only the newest one.
    static func preparedText(from raw: String, limits: Limits = .perPane) -> String? {
        var lines = sanitized(raw).components(separatedBy: "\n").filter { line in
            !replayedSeparatorLines.contains(line.trimmingCharacters(in: .whitespaces))
        }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            return nil
        }

        if lines.count > limits.maxLines {
            lines.removeFirst(lines.count - max(0, limits.maxLines))
        }

        // Keep whole lines from the bottom up until the byte budget is spent.
        var kept: [String] = []
        var byteCount = 0
        for line in lines.reversed() {
            let lineBytes = line.utf8.count + 1
            if byteCount + lineBytes > limits.maxBytes {
                break
            }
            byteCount += lineBytes
            kept.append(line)
        }
        guard !kept.isEmpty else {
            return nil
        }
        return kept.reversed().joined(separator: "\n")
    }

    static func hasVisibleContent(_ raw: String) -> Bool {
        raw.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func sanitized(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09:
                scalars.append(scalar)
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// The `session-scrollback` directory beside the session restore snapshot:
/// one file per pane, named after the pane's stable restore id. Scrollback
/// can hold secrets, so the directory is 0700, every file 0600, and the
/// directory is excluded from backups.
struct SessionScrollbackArchive: Sendable {
    static let directoryName = "session-scrollback"
    static let fileExtension = "txt"
    private static let fileNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    let directoryURL: URL

    init(stateDirectoryURL: URL) {
        directoryURL = stateDirectoryURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// File name for a pane. Pane ids are opaque `pn_…` tokens; anything
    /// outside a safe character set falls back to a hash so a hand-edited
    /// recipe can never steer a write outside the directory. `launchID`
    /// scopes the name to one app launch (see `SessionScrollbackCoordinator`).
    static func fileName(forPaneID paneID: String, launchID: String? = nil) -> String {
        let stem = isSafeStem(paneID, maxLength: 128) ? paneID : "pane-" + digest(paneID).prefix(32)
        guard let launchID, isSafeStem(launchID, maxLength: 32) else {
            return "\(stem).\(fileExtension)"
        }
        return "\(stem)-\(launchID).\(fileExtension)"
    }

    /// Accepts only bare names this archive could have produced.
    static func isValidFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".\(fileExtension)") else { return false }
        return isSafeStem(String(name.dropLast(fileExtension.count + 1)), maxLength: 161)
    }

    private static func isSafeStem(_ stem: String, maxLength: Int) -> Bool {
        !stem.isEmpty
            && stem.count <= maxLength
            && stem.unicodeScalars.allSatisfy { fileNameCharacters.contains($0) }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func url(forFileName name: String) -> URL? {
        guard Self.isValidFileName(name) else { return nil }
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    /// Path of an existing file for a recipe reference, or nil.
    func existingFilePath(forFileName name: String?, fileManager: FileManager = .default) -> String? {
        guard let name, let url = url(forFileName: name),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url.path
    }

    func write(_ payload: String, fileName: String, fileManager: FileManager = .default) throws {
        guard let url = url(forFileName: fileName) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try ensureDirectory(fileManager: fileManager)
        // Write to a private temp file first so the content is never
        // readable by others, even for the instant before the rename.
        let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: Data(payload.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
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

    /// Deletes every file in the directory that is not in `keeping`.
    func purge(keeping: Set<String>, fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return
        }
        for name in names where !keeping.contains(name) {
            do {
                try fileManager.removeItem(at: directoryURL.appendingPathComponent(name, isDirectory: false))
            } catch {
                sessionScrollbackLogger.error("Failed to purge session scrollback file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeAll(fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            sessionScrollbackLogger.error("Failed to remove session scrollback directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureDirectory(fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` leaves an existing directory's mode alone.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        // Keep saved output out of Time Machine: a backup would outlive the
        // purge. Best effort; a failure must not stop the save.
        var excludedURL = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try excludedURL.setResourceValues(values)
        } catch {
            sessionScrollbackLogger.error("Failed to exclude session scrollback from backups: \(error.localizedDescription, privacy: .public)")
        }
    }
}
