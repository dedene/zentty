import Foundation

/// Which sessions a palette or CLI search covers: every project, or one project.
enum AgentHistoryScope: Hashable, Sendable {
    case all
    case project(AgentHistoryProjectScope)
}

/// One project, identified by its canonical main repo root, else its repo root, else the pane's
/// working directory.
///
/// `admits` (metadata tier, CLI re-check) and `sqlPredicate` (content tier) implement the same
/// rule and must stay in lockstep: a session belongs to the project when its `main_repo_root` or
/// `repo_root` equals `key`, or, for repo-less sessions only, when its `cwd` equals `key` or (with
/// `allowsCWDPrefix`) lies below it on a `/` boundary. Stored session paths are already
/// canonical, so neither touches the file system.
struct AgentHistoryProjectScope: Hashable, Sendable {
    /// Canonical main repo root, else repo root, else cwd.
    let key: String
    /// Basename of `key` (`/` for the root).
    let displayName: String
    /// False when `key` is `/`, the home directory or an ancestor of it: such a scope admits
    /// repo-less sessions with exactly that cwd only, never everything below it.
    let allowsCWDPrefix: Bool

    func admits(repoRoot: String?, mainRepoRoot: String?, cwd: String?) -> Bool {
        if mainRepoRoot == key || repoRoot == key {
            return true
        }
        guard repoRoot == nil, mainRepoRoot == nil, let cwd else {
            return false
        }
        return cwd == key || (allowsCWDPrefix && cwd.hasPrefix(cwdPrefix))
    }

    /// A boolean SQL expression over the sessions table aliased `sessionAlias`, using plain `?`
    /// placeholders in order. Splice `bindings` into the outer statement's bindings at the
    /// position where the expression appears.
    ///
    /// The prefix test compares `substr(cwd, 1, length(?))` with the bound `key + "/"`: `%` and `_`
    /// stay literal (no `LIKE`), and SQLite counts characters on both sides.
    func sqlPredicate(sessionAlias: String) -> (sql: String, bindings: [AgentHistoryValue]) {
        let s = sessionAlias
        var cwdMatch = "\(s).cwd = ?"
        var bindings: [AgentHistoryValue] = [.text(key), .text(key), .text(key)]
        if allowsCWDPrefix {
            cwdMatch = "(\(cwdMatch) OR substr(\(s).cwd, 1, length(?)) = ?)"
            bindings.append(.text(cwdPrefix))
            bindings.append(.text(cwdPrefix))
        }
        let sql = "(\(s).main_repo_root = ? OR \(s).repo_root = ? OR "
            + "(\(s).repo_root IS NULL AND \(s).main_repo_root IS NULL AND \(cwdMatch)))"
        return (sql, bindings)
    }

    private var cwdPrefix: String {
        key == "/" ? "/" : key + "/"
    }
}

/// Why a pane has no project scope.
enum AgentHistoryScopeUnavailable: Error, Equatable {
    /// The pane runs on another machine, so its folders say nothing about this Mac's sessions.
    case remotePane
    /// The pane reports no usable local directory.
    case noDirectory
}

/// Resolves a pane's project scope for the palette ("current project") and the CLI (default
/// `search`/`show` scope).
enum AgentHistoryProjectScopeResolver {
    /// - Remote panes are refused (`.remotePane`).
    /// - Base folder: `repoRoot`, else `cwd`; blank, or relative after `~` expansion → `.noDirectory`.
    /// - The base is canonicalized (`AgentHistoryPath.canonical`) so it compares equal to stored
    ///   session paths; `identity` then maps a linked worktree to its main repo root.
    /// - `allowsCWDPrefix` is false for `/`, the home directory and its ancestors.
    static func resolve(
        cwd: String?,
        repoRoot: String?,
        isRemote: Bool,
        homeDirectory: String = NSHomeDirectory(),
        identity: (String) -> RepositoryIdentity? = { RepositoryIdentityResolver.resolve(directory: $0) }
    ) throws(AgentHistoryScopeUnavailable) -> AgentHistoryProjectScope {
        if isRemote {
            throw .remotePane
        }
        guard let base = nonBlank(repoRoot) ?? nonBlank(cwd) else {
            throw .noDirectory
        }
        let canonicalBase = AgentHistoryPath.canonical(base, homeDirectory: homeDirectory)
        guard canonicalBase.hasPrefix("/") else {
            throw .noDirectory
        }

        var key = canonicalBase
        if let repository = identity(canonicalBase) {
            key = AgentHistoryPath.canonical(repository.mainRepoRoot, homeDirectory: homeDirectory)
        }

        // Both the canonical and the lexical home, so a symlinked home is caught either way.
        let homes = [
            AgentHistoryPath.canonical(homeDirectory, homeDirectory: homeDirectory),
            lexical(homeDirectory),
        ]
        let isHomeOrAncestor = homes.contains { AgentHistoryPath.isCanonicalPath($0, insideCanonical: key) }
        return AgentHistoryProjectScope(
            key: key,
            displayName: key == "/" ? "/" : (key as NSString).lastPathComponent,
            allowsCWDPrefix: key != "/" && !isHomeOrAncestor
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func lexical(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1 && result.hasSuffix("/") {
            result = result.dropLast()
        }
        return String(result)
    }
}

/// A pane's folder as the window knows it, read on main without touching the disk. Its project
/// (`projectScope()`) walks the disk and reads git metadata, so the palette resolves it off main.
struct AgentHistoryPaneLocation: Equatable, Sendable {
    var cwd: String?
    var repoRoot: String?
    var isRemote: Bool

    init(cwd: String?, repoRoot: String?, isRemote: Bool) {
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.isRemote = isRemote
    }

    init?(presentation: PanePresentationState?) {
        guard let presentation else {
            return nil
        }
        self.init(cwd: presentation.cwd, repoRoot: presentation.repoRoot, isRemote: presentation.isRemotePane)
    }

    /// Nil for remote panes and panes without a folder.
    func projectScope() -> AgentHistoryProjectScope? {
        try? AgentHistoryProjectScopeResolver.resolve(cwd: cwd, repoRoot: repoRoot, isRemote: isRemote)
    }
}
