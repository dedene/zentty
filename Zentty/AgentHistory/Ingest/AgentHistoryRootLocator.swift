import Foundation

/// Finds the on-disk history roots of every indexed agent. Stat-only: it lists the home directory
/// for `~/.claude*` variants and checks that directories exist, but never reads their contents.
///
/// Rules:
/// - Claude: `$CLAUDE_CONFIG_DIR` (only when it has `projects/`), `~/.claude`, and every other
///   `~/.claude*` directory with `projects/` (e.g. `~/.claudex`), deduplicated by canonical path.
/// - Codex: `$CODEX_HOME` unless it points into Zentty's launch cache, else `~/.codex`.
/// - Grok: `$GROK_HOME`, else `~/.grok`.
/// - opencode: `$XDG_DATA_HOME/opencode` (absolute only), else `~/.local/share/opencode`.
///
/// Missing roots are omitted from the `*Roots()` results but still listed by `candidatePaths(for:)`,
/// which feeds the "checked paths" of the not-found UI.
struct AgentHistoryRootLocator {
    /// `~/.claude*` directories that look like Claude roots but belong to other tools.
    private static let ignoredClaudeVariantNames: Set<String> = [".claude-history-viewer"]

    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func allRoots() -> [AgentHistorySourceRoot] {
        claudeRoots() + codexRoots() + grokRoots() + openCodeRoots()
    }

    func roots(for agent: AgentHistoryAgent) -> [AgentHistorySourceRoot] {
        switch agent {
        case .claude:
            return claudeRoots()
        case .codex:
            return codexRoots()
        case .grok:
            return grokRoots()
        case .opencode:
            return openCodeRoots()
        }
    }

    func claudeRoots() -> [AgentHistorySourceRoot] {
        let defaultPath = canonical(homePath(".claude"))
        var candidates: [String] = []
        if let configured = configuredPath("CLAUDE_CONFIG_DIR"),
           isDirectory(configured + "/projects") {
            candidates.append(configured)
        }
        if isDirectory(defaultPath) {
            candidates.append(defaultPath)
        }
        candidates += claudeVariantPaths()

        var seen = Set<String>()
        var roots: [AgentHistorySourceRoot] = []
        for candidate in candidates {
            let path = canonical(candidate)
            guard seen.insert(path).inserted else {
                continue
            }
            roots.append(AgentHistorySourceRoot(agent: .claude, path: path, isDefault: path == defaultPath))
        }
        return roots
    }

    func codexRoots() -> [AgentHistorySourceRoot] {
        singleRoot(agent: .codex, path: codexPath(), defaultPath: homePath(".codex"))
    }

    func grokRoots() -> [AgentHistorySourceRoot] {
        singleRoot(agent: .grok, path: grokPath(), defaultPath: homePath(".grok"))
    }

    func openCodeRoots() -> [AgentHistorySourceRoot] {
        singleRoot(agent: .opencode, path: openCodePath(), defaultPath: defaultOpenCodePath)
    }

    /// The canonical paths checked for `agent`, existing or not, without `~/.claude*` variants.
    func candidatePaths(for agent: AgentHistoryAgent) -> [String] {
        let paths: [String]
        switch agent {
        case .claude:
            paths = [configuredPath("CLAUDE_CONFIG_DIR"), homePath(".claude")].compactMap { $0 }
        case .codex:
            paths = [codexPath()]
        case .grok:
            paths = [grokPath()]
        case .opencode:
            paths = [openCodePath()]
        }
        var seen = Set<String>()
        return paths.map(canonical).filter { seen.insert($0).inserted }
    }

    // MARK: - Per-agent paths

    private func codexPath() -> String {
        if let configured = configuredPath("CODEX_HOME"),
           !AgentLaunchBootstrap.isZenttyLaunchCachePath(configured) {
            return configured
        }
        return homePath(".codex")
    }

    private func grokPath() -> String {
        configuredPath("GROK_HOME") ?? homePath(".grok")
    }

    private func openCodePath() -> String {
        if let dataHome = configuredPath("XDG_DATA_HOME") {
            return dataHome + "/opencode"
        }
        return defaultOpenCodePath
    }

    private var defaultOpenCodePath: String {
        homePath(".local/share/opencode")
    }

    /// Every `~/.claude*` directory except `~/.claude` itself that contains `projects/`, sorted by name.
    private func claudeVariantPaths() -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: homeDirectory.path) else {
            return []
        }
        return names
            .filter { name in
                name.hasPrefix(".claude")
                    && name != ".claude"
                    && !Self.ignoredClaudeVariantNames.contains(name)
            }
            .sorted()
            .map(homePath)
            .filter { isDirectory($0 + "/projects") }
    }

    // MARK: - Helpers

    private func singleRoot(agent: AgentHistoryAgent, path: String, defaultPath: String) -> [AgentHistorySourceRoot] {
        guard isDirectory(path) else {
            return []
        }
        let canonicalPath = canonical(path)
        return [AgentHistorySourceRoot(agent: agent, path: canonicalPath, isDefault: canonicalPath == canonical(defaultPath))]
    }

    /// The environment value as an absolute path (`~` expanded), or nil when unset, blank or relative.
    private func configuredPath(_ key: String) -> String? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let expanded: String
        if raw == "~" {
            expanded = homeDirectory.path
        } else if raw.hasPrefix("~/") {
            expanded = homePath(String(raw.dropFirst(2)))
        } else {
            expanded = raw
        }
        guard expanded.hasPrefix("/") else {
            return nil
        }
        return expanded
    }

    private func homePath(_ relativePath: String) -> String {
        homeDirectory.appendingPathComponent(relativePath, isDirectory: true).path
    }

    private func canonical(_ path: String) -> String {
        AgentHistoryPath.canonical(path, homeDirectory: homeDirectory.path)
    }

    /// Follows symlinks, so a symlinked root counts when its target is a directory.
    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
