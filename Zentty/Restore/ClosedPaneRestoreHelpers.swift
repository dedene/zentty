import Foundation
import OSLog

private let restoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "restore-pane")

enum ClosedPaneCWDResolver {
    struct Resolution: Equatable {
        let path: String
        /// True when the original path didn't exist and we either walked up
        /// to an ancestor or fell back to home.
        let originalMissing: Bool
    }

    static func resolve(
        original: String?,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Resolution {
        guard let original = original?.trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty else {
            return Resolution(path: homeDirectory, originalMissing: true)
        }

        let standardized = (original as NSString).standardizingPath
        if isExistingDirectory(standardized, fileManager: fileManager) {
            return Resolution(path: standardized, originalMissing: false)
        }

        var current = standardized
        while true {
            let parent = (current as NSString).deletingLastPathComponent
            // Bail when we can't go any higher: parent of "/" is "/", and
            // bottoming out a relative path returns "". Without this, "/"
            // and "" would loop forever.
            if parent == current || parent.isEmpty {
                return Resolution(path: homeDirectory, originalMissing: true)
            }
            current = parent
            if isExistingDirectory(current, fileManager: fileManager) {
                return Resolution(path: current, originalMissing: true)
            }
        }
    }

    private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}

@MainActor
enum ClosedPaneScrollbackArchive {
    static let directoryName = "Zentty/restore-output"
    static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    static func write(scrollback: String, entryID: UUID, fileManager: FileManager = .default) -> URL? {
        guard let directory = directoryURL(fileManager: fileManager) else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            restoreLogger.error("Failed to create restore-output directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let url = directory.appendingPathComponent("\(entryID.uuidString).txt")
        do {
            try scrollback.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            restoreLogger.error("Failed to write scrollback archive: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func purgeStale(now: Date = Date(), fileManager: FileManager = .default) {
        guard let directory = directoryURL(fileManager: fileManager) else { return }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func directoryURL(fileManager: FileManager) -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent(directoryName, isDirectory: true)
    }
}

enum ClosedPaneRestoreCommandResolver {
    enum Outcome: Equatable {
        case agentResume(command: String, tool: AgentTool, sessionID: String?)
        case replayCommand(String)
        case plainShell
    }

    static func resolve(entry: ClosedPaneEntry) -> Outcome {
        if let snapshot = entry.agentSnapshot {
            let draft = PaneRestoreDraft(
                paneID: entry.originalPaneID.rawValue,
                kind: .agentResume,
                toolName: snapshot.toolDisplayName,
                sessionID: snapshot.sessionID ?? "",
                workingDirectory: snapshot.workingDirectory ?? entry.workingDirectory,
                trackedPID: 0
            )

            if let resumeCommand = AgentResumeCommandBuilder.command(for: draft) {
                return .agentResume(command: resumeCommand, tool: snapshot.tool, sessionID: snapshot.sessionID)
            }
        }

        let trimmedNative = entry.originalNativeCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedNative, !trimmedNative.isEmpty {
            return .replayCommand(trimmedNative)
        }
        let trimmedCommand = entry.originalCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCommand, !trimmedCommand.isEmpty {
            return .replayCommand(trimmedCommand)
        }

        return .plainShell
    }
}
