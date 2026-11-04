import Foundation

/// The Claude config root a session lives in, as the `env` prefix a command typed into a fresh
/// shell needs so `claude` reads that root and not whatever `CLAUDE_CONFIG_DIR` the shell exports.
/// Shared by Agent History resume and live fork.
enum ClaudeConfigRoot: Equatable, Sendable {
    /// An alternate config directory: a standardized absolute path, never the default root.
    case alternate(String)
    /// The default `<home>/.claude`, including through a symlink.
    case defaultRoot

    /// nil when the root is missing or unusable (relative, `~`-prefixed, `/`, control characters):
    /// nothing is known about the account, so the environment is left alone.
    init?(sourceRoot: String?, homeDirectory: String) {
        guard let standardized = Self.standardized(sourceRoot) else {
            return nil
        }
        self = Self.isDefault(standardized: standardized, homeDirectory: homeDirectory)
            ? .defaultRoot
            : .alternate(standardized)
    }

    /// The alternate directory, or nil for the default root.
    var alternateDirectory: String? {
        if case .alternate(let directory) = self {
            return directory
        }
        return nil
    }

    /// `env CLAUDE_CONFIG_DIR=<dir> <command>` for an alternate root. The default root unsets the
    /// variable instead of pointing it at `~/.claude`, which would also move where Claude reads
    /// `.claude.json`.
    func prefixing(_ command: String) -> String {
        switch self {
        case .alternate(let directory):
            return "env CLAUDE_CONFIG_DIR=\(AgentResumeCommandBuilder.shellQuotedArgument(directory)) \(command)"
        case .defaultRoot:
            return "env -u CLAUDE_CONFIG_DIR \(command)"
        }
    }

    private static func standardized(_ sourceRoot: String?) -> String? {
        guard let root = sourceRoot, root.hasPrefix("/"),
              !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let standardized = (root as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/" else {
            return nil
        }
        return standardized
    }

    private static func isDefault(standardized: String, homeDirectory: String) -> Bool {
        let defaultRoot = ((homeDirectory as NSString).appendingPathComponent(".claude") as NSString).standardizingPath
        return standardized == defaultRoot
            || (standardized as NSString).resolvingSymlinksInPath == (defaultRoot as NSString).resolvingSymlinksInPath
    }
}
