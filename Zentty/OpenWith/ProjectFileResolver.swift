import Foundation

struct ProjectFileRule: Sendable {
    /// File extensions in priority order (first match wins).
    let extensions: [String]
}

enum ProjectFileResolver {
    static let rules: [OpenWithBuiltInTargetID: ProjectFileRule] = [
        .xcode: ProjectFileRule(extensions: ["xcworkspace", "xcodeproj"]),
    ]

    /// Returns the best project file URL for the given target, or `nil` to fall back to directory.
    static func resolveProjectFile(
        for targetID: OpenWithBuiltInTargetID,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let rule = rules[targetID] else {
            return nil
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for ext in rule.extensions {
            let matches = entries
                .filter { $0.pathExtension == ext }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let best = matches.first {
                return best
            }
        }

        return nil
    }
}
