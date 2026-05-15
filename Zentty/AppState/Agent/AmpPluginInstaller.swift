import Foundation
import os

private let ampPluginInstallerLogger = Logger(
    subsystem: "be.zenjoy.zentty",
    category: "AmpPluginInstaller"
)

enum AmpPluginInstaller {
    static let pluginFileName = "zentty-amp-zentty.ts"
    static let ownershipMarker = "zentty-amp-plugin-v1"

    static func installBundledPluginIfPossible(
        destinationConfigHomeURL: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let sourceURL = bundledPluginURL(bundle: bundle, fileManager: fileManager) else {
            ampPluginInstallerLogger.warning("AMP plugin resource missing; agent status will not be tracked")
            return false
        }

        do {
            return try install(
                sourceURL: sourceURL,
                destinationURL: bundledPluginDestinationURL(destinationConfigHomeURL: destinationConfigHomeURL),
                fileManager: fileManager
            )
        } catch {
            ampPluginInstallerLogger.error("Failed to install AMP plugin: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func install(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        if fileManager.fileExists(atPath: destinationURL.path) {
            let existing = (try? String(contentsOf: destinationURL, encoding: .utf8)) ?? ""
            guard existing.contains(ownershipMarker) else {
                ampPluginInstallerLogger.warning("Refusing to overwrite unmarked AMP plugin at \(destinationURL.path, privacy: .public)")
                return false
            }
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: destinationURL, atomically: true, encoding: .utf8)
        return true
    }

    static func defaultUserConfigHomeURL(environment: [String: String]) -> URL {
        if let configRoot = nonBlank(environment["XDG_CONFIG_HOME"]) {
            return URL(fileURLWithPath: configRoot, isDirectory: true)
        }
        return URL(fileURLWithPath: nonBlank(environment["HOME"]) ?? NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
    }

    private static func bundledPluginDestinationURL(destinationConfigHomeURL: URL) -> URL {
        destinationConfigHomeURL
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginFileName, isDirectory: false)
    }

    private static func bundledPluginURL(bundle: Bundle, fileManager: FileManager) -> URL? {
        guard let url = bundle.resourceURL?
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginFileName, isDirectory: false),
              fileManager.isReadableFile(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
