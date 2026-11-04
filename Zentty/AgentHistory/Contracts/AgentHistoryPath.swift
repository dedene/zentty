import Darwin
import Foundation

/// Path canonicalization shared by ingest, exclusions, scope and the SQL purge.
///
/// `FileEventStream.canonicalPath` (realpath(3), keeps `/private`) is separate and is used
/// for FSEvents path matching only.
enum AgentHistoryPath {
    /// `~` expand → lexical standardize → resolve symlinks → strip the trailing `/` (except `/`).
    ///
    /// Symlinks are resolved only outside TCC-protected locations (`~/Documents`, `~/Desktop`,
    /// `~/Downloads`, iCloud and cloud storage, `/Volumes`, `/net`, `/Network`), so canonicalizing
    /// never touches those folders; there the result is lexical only. When the path does not exist,
    /// its deepest existing ancestor is resolved and the rest is appended, so `/private/tmp/gone`
    /// and `/tmp/gone` agree. Relative paths are returned without the trailing `/` only.
    static func canonical(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let expanded = expandingTilde(path, homeDirectory: homeDirectory)
        guard expanded.hasPrefix("/") else {
            return strippingTrailingSlash(expanded)
        }
        let lexical = strippingTrailingSlash(
            URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        )
        if isProtected(lexical, homeDirectory: homeDirectory) {
            return lexical
        }
        return resolvingSymlinks(lexical)
    }

    /// Canonicalizes both sides, then matches case-sensitively on a `/` boundary:
    /// `/a/foobar` is not inside `/a/foo`.
    static func isPath(_ path: String, inside folder: String) -> Bool {
        isCanonicalPath(canonical(path), insideCanonical: canonical(folder))
    }

    /// Boundary check on already-canonical paths; no file-system access.
    static func isCanonicalPath(_ path: String, insideCanonical folder: String) -> Bool {
        guard path.hasPrefix("/"), folder.hasPrefix("/") else {
            return false
        }
        if folder == "/" || path == folder {
            return true
        }
        return path.hasPrefix(folder + "/")
    }

    /// Whether a lexically standardized absolute path lies under a TCC-protected location.
    static func isProtected(_ lexicalPath: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let home = strippingTrailingSlash(homeDirectory)
        let prefixes = [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/CloudStorage",
            "/Volumes",
            "/net",
            "/Network",
        ]
        return prefixes.contains { isCanonicalPath(lexicalPath, insideCanonical: $0) }
    }

    private static func expandingTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return strippingTrailingSlash(homeDirectory) + "/" + path.dropFirst(2)
        }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    private static func resolvingSymlinks(_ lexical: String) -> String {
        var head = lexical
        var tail: [String] = []
        while head != "/" && !exists(head) {
            let url = URL(fileURLWithPath: head, isDirectory: true)
            tail.insert(url.lastPathComponent, at: 0)
            head = url.deletingLastPathComponent().path
            if head.isEmpty {
                head = "/"
            }
        }
        var resolved = strippingTrailingSlash(
            URL(fileURLWithPath: head, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )
        for component in tail {
            resolved = resolved == "/" ? "/" + component : resolved + "/" + component
        }
        return resolved
    }

    private static func exists(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0
    }

    private static func strippingTrailingSlash(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1 && result.hasSuffix("/") {
            result = result.dropLast()
        }
        return String(result)
    }
}

/// Excluded folders, canonicalized once. Matching is case-sensitive (D5).
struct AgentHistoryExclusionMatcher: Equatable, Sendable {
    /// Canonical absolute folders, deduplicated in input order; for the SQL purge.
    let canonicalFolders: [String]

    /// Canonicalizes once; drops empty and non-absolute entries.
    init(folders: [String]) {
        var seen = Set<String>()
        var result: [String] = []
        for folder in folders {
            let canonical = AgentHistoryPath.canonical(folder)
            guard canonical.hasPrefix("/"), seen.insert(canonical).inserted else {
                continue
            }
            result.append(canonical)
        }
        canonicalFolders = result
    }

    var isEmpty: Bool { canonicalFolders.isEmpty }

    /// Canonicalizes `path` first; nil never matches.
    func excludes(_ path: String?) -> Bool {
        guard let path, !isEmpty else {
            return false
        }
        return excludesCanonical(AgentHistoryPath.canonical(path))
    }

    /// For paths that are already canonical (stored `cwd`s): no file-system access.
    func excludesCanonical(_ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return canonicalFolders.contains { AgentHistoryPath.isCanonicalPath(path, insideCanonical: $0) }
    }
}

/// Decides whether a session may be stored: tombstones first, then excluded folders.
struct AgentHistoryAdmission: Sendable {
    let exclusions: AgentHistoryExclusionMatcher
    let tombstones: Set<AgentHistorySessionKey>

    static let admitAll = AgentHistoryAdmission(
        exclusions: AgentHistoryExclusionMatcher(folders: []),
        tombstones: []
    )

    /// `nativeID` must be normalized. A nil `cwd` is admitted unless tombstoned.
    func decide(agent: AgentHistoryAgent, nativeID: String, cwd: String?) -> AgentHistoryAdmissionDecision {
        if tombstones.contains(AgentHistorySessionKey(agent: agent, nativeID: nativeID)) {
            return .tombstoned
        }
        if exclusions.excludes(cwd) {
            return .excludedFolder
        }
        return .admit
    }
}
