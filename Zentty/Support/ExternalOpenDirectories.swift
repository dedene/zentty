import Foundation

/// Resolves the URLs LaunchServices hands to `application(_:open:)` into the
/// working directories new windows should start in. This is what makes
/// `open -a Zentty <dir>`, Finder's "Open With" and dropping a folder on the
/// Dock icon open a terminal there.
///
/// Folders open as themselves. A regular file opens its parent folder, which
/// matches Terminal.app. Non-file URLs and paths that no longer exist are
/// dropped; duplicates collapse so one drop never opens the same folder twice.
enum ExternalOpenDirectories {
    static func resolve(_ urls: [URL], fileManager: FileManager = .default) -> [String] {
        var directories: [String] = []
        var seen = Set<String>()
        for url in urls where url.isFileURL {
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
                continue
            }
            let directory = isDirectory.boolValue
                ? standardized.path
                : standardized.deletingLastPathComponent().path
            if seen.insert(directory).inserted {
                directories.append(directory)
            }
        }
        return directories
    }
}
