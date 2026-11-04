import Foundation

/// Light artifacts adapters pull out of tool calls and replies: paths touched, commands run,
/// commit hashes and PR links. Raw tool output is never stored; only these short values.
/// Values still pass through `AgentHistoryBatchBuilder.addArtifact`, which redacts them.
enum AgentHistoryArtifactExtractor {
    static let maxCommandLength = 200

    /// A one-line command (whitespace runs collapsed) capped at `maxCommandLength` characters.
    /// Redacts before cutting, so a secret straddling the cap is never left half-visible.
    static func command(_ raw: String) -> String? {
        let redacted = AgentHistoryRedactor.shared.redact(raw)
        guard let display = AgentHistoryDisplayText.displayText(redacted) else {
            return nil
        }
        let line = AgentHistoryDisplayText.firstPromptTitle(display, limit: maxCommandLength)
        return line.isEmpty ? nil : line
    }

    /// A path relative to `base` (repo root or cwd) when it lies inside it, else the lexically
    /// standardized absolute path. Relative input stays relative (leading `./` dropped).
    /// Purely lexical: never touches the disk.
    static func path(_ raw: String, relativeTo base: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\0") else {
            return nil
        }
        guard trimmed.hasPrefix("/") else {
            var relative = Substring(trimmed)
            while relative.hasPrefix("./") {
                relative = relative.dropFirst(2).drop { $0 == "/" }
            }
            return relative.isEmpty || relative == "." ? nil : String(relative)
        }

        let absolute = lexicallyStandardized(trimmed)
        if let base, base.hasPrefix("/") {
            let root = lexicallyStandardized(base)
            if root != "/", absolute.hasPrefix(root + "/") {
                return String(absolute.dropFirst(root.count + 1))
            }
        }
        return absolute
    }

    /// File paths from `apply_patch` headers (`*** Add|Update|Delete File:` and `*** Move to:`),
    /// in order, without duplicates.
    static func applyPatchPaths(_ patch: String) -> [String] {
        let headers = ["*** Add File:", "*** Update File:", "*** Delete File:", "*** Move to:"]
        var seen = Set<String>()
        var paths: [String] = []
        for line in patch.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            guard let header = headers.first(where: { line.hasPrefix($0) }) else {
                continue
            }
            let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    static func isGitCommitCommand(_ command: String) -> Bool {
        guard let regex = Patterns.shared.gitCommit else {
            return false
        }
        return regex.firstMatch(in: command, range: fullRange(command)) != nil
    }

    /// Short or full hashes from `git commit` output (`[branch 1a2b3c4] message`).
    static func commitHashes(inGitOutput text: String) -> [String] {
        uniqueMatches(Patterns.shared.commitHash, in: text, group: 1)
    }

    /// GitHub pull request and GitLab merge request URLs, in order, without duplicates.
    static func pullRequestURLs(in text: String) -> [String] {
        uniqueMatches(Patterns.shared.pullRequest, in: text, group: 0)
    }

    // MARK: - Helpers

    private static func lexicallyStandardized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func uniqueMatches(_ regex: NSRegularExpression?, in text: String, group: Int) -> [String] {
        guard let regex else {
            return []
        }
        let source = text as NSString
        var seen = Set<String>()
        var values: [String] = []
        for match in regex.matches(in: text, range: fullRange(text)) {
            let range = match.range(at: group)
            guard range.location != NSNotFound else {
                continue
            }
            let value = source.substring(with: range)
            if seen.insert(value).inserted {
                values.append(value)
            }
        }
        return values
    }

    /// Compiled once. `NSRegularExpression` is immutable and thread-safe after creation, and
    /// nothing here mutates, hence `@unchecked Sendable`.
    private final class Patterns: @unchecked Sendable {
        static let shared = Patterns()

        let gitCommit: NSRegularExpression?
        let commitHash: NSRegularExpression?
        let pullRequest: NSRegularExpression?

        private init() {
            gitCommit = Self.compile(#"\bgit\b[^\n|;&]*\bcommit\b"#)
            commitHash = Self.compile(#"\[[^\]\n]+ ([0-9a-f]{7,40})\]"#)
            pullRequest = Self.compile(
                #"https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+(?![0-9A-Za-z])"#
                    + "|"
                    + #"https?://[A-Za-z0-9.-]+(?::[0-9]+)?/(?:[A-Za-z0-9_.-]+/)+-/merge_requests/[0-9]+(?![0-9A-Za-z])"#
            )
        }

        private static func compile(_ pattern: String) -> NSRegularExpression? {
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                AgentHistoryLog.indexer.error("Artifact pattern failed to compile")
                return nil
            }
        }
    }
}
