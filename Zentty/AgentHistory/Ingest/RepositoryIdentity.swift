import Foundation

/// Where a folder sits in git, read from the `.git` layout on disk (no git subprocess).
///
/// All paths are canonical (`AgentHistoryPath.canonical`), so they compare equal to the
/// repository roots in pane git contexts.
struct RepositoryIdentity: Equatable, Sendable {
    /// The working tree that contains the folder (a linked worktree's own root).
    let repoRoot: String
    /// The main working tree; the bare repository for worktrees of a bare repo; `repoRoot`
    /// for plain repositories and submodules.
    let mainRepoRoot: String
    let isLinkedWorktree: Bool
    /// `HEAD`'s branch name; nil when detached or unreadable.
    let headBranch: String?
}

/// Resolves `RepositoryIdentity` by walking up from a folder and reading `.git` markers.
///
/// - `.git` directory: the folder is a main working tree.
/// - `.git` file (≤ 4 KB, `gitdir: X`, X relative to the folder holding the file):
///   - `X/commondir` readable: resolve it relative to X; the main tree is the common dir's
///     parent when the common dir is named `.git`, otherwise the common dir itself (bare).
///   - no readable commondir but X contains `/.git/worktrees/`: the main tree is the part
///     before that marker.
///   - otherwise (submodule): the main tree is the folder itself.
///
/// Only existing folders resolve; the indexer keeps stored values once a folder is gone.
enum RepositoryIdentityResolver {
    static let maxLevels = 64
    static let maxGitFileBytes = 4096

    static func resolve(directory: String, fileManager: FileManager = .default) -> RepositoryIdentity? {
        guard directory.hasPrefix("/") else {
            return nil
        }
        let start = AgentHistoryPath.canonical(directory)
        guard isDirectory(start, fileManager: fileManager) else {
            return nil
        }

        var current = start
        for _ in 0..<maxLevels {
            let marker = join(current, ".git")
            var markerIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker, isDirectory: &markerIsDirectory) {
                if markerIsDirectory.boolValue {
                    return RepositoryIdentity(
                        repoRoot: current,
                        mainRepoRoot: current,
                        isLinkedWorktree: false,
                        headBranch: headBranch(gitDirectory: marker)
                    )
                }
                return identity(gitFile: marker, root: current)
            }
            guard current != "/" else {
                return nil
            }
            current = parent(of: current)
        }
        return nil
    }

    // MARK: - Private

    private static func identity(gitFile: String, root: String) -> RepositoryIdentity? {
        guard
            let contents = readSmallFile(gitFile, limit: maxGitFileBytes),
            let gitdirValue = gitdirValue(contents)
        else {
            return nil
        }
        let gitDirectory = AgentHistoryPath.canonical(absolute(gitdirValue, relativeTo: root))
        let branch = headBranch(gitDirectory: gitDirectory)

        if let commondirContents = readSmallFile(join(gitDirectory, "commondir"), limit: maxGitFileBytes) {
            let value = commondirContents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                let commonDirectory = AgentHistoryPath.canonical(absolute(value, relativeTo: gitDirectory))
                let main = lastComponent(commonDirectory) == ".git" ? parent(of: commonDirectory) : commonDirectory
                return RepositoryIdentity(
                    repoRoot: root,
                    mainRepoRoot: main,
                    isLinkedWorktree: main != root,
                    headBranch: branch
                )
            }
        }

        // No readable commondir: fall back to the worktree admin-dir marker in the gitdir string.
        let worktreesMarker = "/.git/worktrees/"
        let candidates = [gitDirectory, absolute(gitdirValue, relativeTo: root)]
        if
            let source = candidates.first(where: { $0.contains(worktreesMarker) }),
            let markerRange = source.range(of: worktreesMarker)
        {
            let prefix = String(source[source.startIndex..<markerRange.lowerBound])
            let main = AgentHistoryPath.canonical(prefix.isEmpty ? "/" : prefix)
            return RepositoryIdentity(
                repoRoot: root,
                mainRepoRoot: main,
                isLinkedWorktree: main != root,
                headBranch: branch
            )
        }

        // Submodule (or any other gitfile without a common dir): its own main tree.
        return RepositoryIdentity(repoRoot: root, mainRepoRoot: root, isLinkedWorktree: false, headBranch: branch)
    }

    /// The value of a `gitdir: <path>` line; nil for anything else.
    private static func gitdirValue(_ contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else {
                continue
            }
            let value = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `ref: refs/heads/<name>` → `<name>`; anything else (detached, other refs) → nil.
    private static func headBranch(gitDirectory: String) -> String? {
        guard let contents = readSmallFile(join(gitDirectory, "HEAD"), limit: maxGitFileBytes) else {
            return nil
        }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let name = String(line.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    /// Reads a regular file of at most `limit` bytes as UTF-8; nil when missing, larger, or not text.
    private static func readSmallFile(_ path: String, limit: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(upToCount: limit + 1),
            data.count <= limit
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func absolute(_ path: String, relativeTo base: String) -> String {
        path.hasPrefix("/") ? path : join(base, path)
    }

    private static func join(_ base: String, _ component: String) -> String {
        base == "/" ? "/" + component : base + "/" + component
    }

    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Memoizes `RepositoryIdentity` per canonical folder, including misses, for `ttl` seconds.
///
/// Safe from any thread: the memo is guarded by an `NSLock`; resolution runs outside the lock.
/// Folders under TCC-protected locations (`AgentHistoryPath.isProtected`) and folders whose
/// parent does not exist are skipped without touching the disk beyond one `stat` and are not
/// memoized, so they resolve once they appear.
final class RepositoryIdentityCache: @unchecked Sendable {
    static let maxEntries = 4096

    private struct Entry {
        let identity: RepositoryIdentity?
        let expiresAt: TimeInterval
    }

    private let ttl: TimeInterval
    private let resolve: @Sendable (String) -> RepositoryIdentity?
    private let now: @Sendable () -> TimeInterval
    private let homeDirectory: String
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(
        ttl: TimeInterval = 60,
        resolve: @escaping @Sendable (String) -> RepositoryIdentity? = { RepositoryIdentityResolver.resolve(directory: $0) },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.ttl = ttl
        self.resolve = resolve
        self.now = now
        self.homeDirectory = homeDirectory
    }

    func identity(for directory: String) -> RepositoryIdentity? {
        let canonical = AgentHistoryPath.canonical(directory, homeDirectory: homeDirectory)
        guard
            canonical.hasPrefix("/"),
            !AgentHistoryPath.isProtected(canonical, homeDirectory: homeDirectory),
            parentExists(canonical)
        else {
            return nil
        }

        let timestamp = now()
        lock.lock()
        if let entry = entries[canonical], entry.expiresAt > timestamp {
            lock.unlock()
            return entry.identity
        }
        lock.unlock()

        let identity = resolve(canonical)

        lock.lock()
        if entries.count >= Self.maxEntries {
            entries = entries.filter { $0.value.expiresAt > timestamp }
            if entries.count >= Self.maxEntries {
                entries.removeAll(keepingCapacity: true)
            }
        }
        entries[canonical] = Entry(identity: identity, expiresAt: timestamp + ttl)
        lock.unlock()
        return identity
    }

    private func parentExists(_ canonical: String) -> Bool {
        guard canonical != "/" else {
            return true
        }
        var isDirectory: ObjCBool = false
        let parent = (canonical as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: parent.isEmpty ? "/" : parent, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
