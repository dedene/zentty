import Foundation

/// Read-only file-system questions the folder resolver asks. Injected so tests run on an
/// in-memory tree and never touch real repositories.
protocol AgentHistoryFileSystemProbing: Sendable {
    func isDirectory(_ path: String) -> Bool
    func fileExists(_ path: String) -> Bool
    func contents(_ path: String) -> String?
    func directoryEntries(_ path: String) -> [String]
}

struct LiveAgentHistoryFileSystem: AgentHistoryFileSystemProbing {
    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func contents(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func directoryEntries(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

/// Everything needed to run `git worktree add` for a session whose linked worktree was removed.
struct AgentHistoryWorktreeRecreation: Equatable, Sendable {
    var mainRepoRoot: String
    var worktreePath: String
    var branch: String
    /// A stale registration for `worktreePath` exists; git refuses without `--force`.
    var needsForce: Bool
    /// The session's folder when it lies inside the worktree, else the worktree root.
    var resumeDirectory: String
    var gitArguments: [String]
}

enum AgentHistoryFolderChoice: Equatable, Sendable {
    case repositoryRoot(String)
    case recreateWorktree(AgentHistoryWorktreeRecreation)
    case homeFolder(String)
    case copyResumeCommand
}

enum AgentHistoryFolderResolution: Equatable, Sendable {
    case ready(workingDirectory: String)
    case folderGone(options: [AgentHistoryFolderChoice], defaultChoice: AgentHistoryFolderChoice)
}

/// Decides where an ended session can resume when its folder may be gone. Pure file reads; never
/// runs git. Worktree eligibility mirrors the checks `git worktree add` makes, so the offered
/// "Recreate the worktree" choice is one git will accept.
enum AgentHistoryFolderResolver {
    static func resolve(
        _ source: AgentHistoryResumeSource,
        fileSystem: any AgentHistoryFileSystemProbing = LiveAgentHistoryFileSystem(),
        homeDirectory: String = NSHomeDirectory()
    ) -> AgentHistoryFolderResolution {
        if !isFolderMissing(source, fileSystem: fileSystem), let cwd = absolutePath(source.workingDirectory) {
            return .ready(workingDirectory: cwd)
        }

        var options: [AgentHistoryFolderChoice] = []
        if let root = existingRepositoryRoot(source, fileSystem: fileSystem) {
            options.append(.repositoryRoot(root))
        } else {
            options.append(.homeFolder(homeDirectory))
        }
        if let recreation = worktreeRecreation(for: source, fileSystem: fileSystem) {
            options.append(.recreateWorktree(recreation))
        }
        options.append(.copyResumeCommand)
        return .folderGone(options: options, defaultChoice: options[0])
    }

    static func isFolderMissing(_ source: AgentHistoryResumeSource, fileSystem: any AgentHistoryFileSystemProbing) -> Bool {
        guard let cwd = absolutePath(source.workingDirectory) else {
            return true
        }
        return !fileSystem.isDirectory(cwd)
    }

    static func worktreeRecreation(
        for source: AgentHistoryResumeSource,
        fileSystem: any AgentHistoryFileSystemProbing
    ) -> AgentHistoryWorktreeRecreation? {
        guard let worktreePath = absolutePath(source.repoRoot),
              let mainRoot = absolutePath(source.mainRepoRoot),
              !samePath(worktreePath, mainRoot),
              let branch = source.branch,
              isValidBranchName(branch),
              !fileSystem.fileExists(worktreePath)
        else {
            return nil
        }

        let gitDirectory = mainRoot + "/.git"
        guard fileSystem.isDirectory(gitDirectory),
              branchExists(branch, gitDirectory: gitDirectory, fileSystem: fileSystem)
        else {
            return nil
        }

        let branchRef = "refs/heads/" + branch
        // git refuses to check a branch out twice; the main worktree holding it rules recreation out.
        if symbolicRef(fileSystem.contents(gitDirectory + "/HEAD")) == branchRef {
            return nil
        }

        var needsForce = false
        let registrations = gitDirectory + "/worktrees"
        for name in fileSystem.directoryEntries(registrations).sorted() {
            let registration = registrations + "/" + name
            guard fileSystem.isDirectory(registration) else {
                continue
            }
            let holder = registrationHolder(registration, fileSystem: fileSystem)
            if let holder, samePath(holder, worktreePath) {
                // Our own stale registration: `add --force` replaces it, unless it is locked.
                if fileSystem.fileExists(registration + "/locked") {
                    return nil
                }
                needsForce = true
                continue
            }
            if symbolicRef(fileSystem.contents(registration + "/HEAD")) == branchRef {
                // Another worktree, live or stale, holds the branch. Forcing would steal it.
                return nil
            }
        }

        let resumeDirectory: String
        if let cwd = absolutePath(source.workingDirectory), isPath(cwd, inside: worktreePath) {
            resumeDirectory = cwd
        } else {
            resumeDirectory = worktreePath
        }

        return AgentHistoryWorktreeRecreation(
            mainRepoRoot: mainRoot,
            worktreePath: worktreePath,
            branch: branch,
            needsForce: needsForce,
            resumeDirectory: resumeDirectory,
            gitArguments: ["-C", mainRoot, "worktree", "add"] + (needsForce ? ["--force"] : []) + ["--", worktreePath, branch]
        )
    }

    /// A conservative subset of `git check-ref-format --branch`. Anything rejected here is never
    /// read from disk or passed to git.
    static func isValidBranchName(_ branch: String) -> Bool {
        guard !branch.isEmpty,
              branch.utf8.count <= 255,
              branch != "HEAD",
              branch != "@",
              !branch.hasPrefix("-"),
              !branch.hasPrefix("/"),
              !branch.hasSuffix("/"),
              !branch.hasSuffix("."),
              !branch.contains(".."),
              !branch.contains("@{"),
              !branch.contains("//")
        else {
            return false
        }
        let forbidden: Set<Unicode.Scalar> = ["\\", " ", "~", "^", ":", "?", "*", "["]
        for scalar in branch.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || forbidden.contains(scalar) {
                return false
            }
        }
        for component in branch.split(separator: "/") {
            if component.hasPrefix(".") || component.hasSuffix(".lock") {
                return false
            }
        }
        return true
    }

    // MARK: - Helpers

    private static func existingRepositoryRoot(
        _ source: AgentHistoryResumeSource,
        fileSystem: any AgentHistoryFileSystemProbing
    ) -> String? {
        [source.repoRoot, source.mainRepoRoot]
            .compactMap(absolutePath)
            .first(where: { fileSystem.isDirectory($0) })
    }

    private static func branchExists(
        _ branch: String,
        gitDirectory: String,
        fileSystem: any AgentHistoryFileSystemProbing
    ) -> Bool {
        let loose = gitDirectory + "/refs/heads/" + branch
        if fileSystem.fileExists(loose), !fileSystem.isDirectory(loose) {
            return true
        }
        guard let packed = fileSystem.contents(gitDirectory + "/packed-refs") else {
            return false
        }
        let wanted = "refs/heads/" + branch
        for line in packed.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else {
                continue
            }
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[1].trimmingCharacters(in: .whitespaces) == wanted {
                return true
            }
        }
        return false
    }

    /// `ref: refs/heads/x` → `refs/heads/x`; a detached SHA or unreadable file → nil.
    private static func symbolicRef(_ head: String?) -> String? {
        guard let head else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref:") else { return nil }
        return trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
    }

    /// The worktree folder a registration points at: `dirname` of its `gitdir` file, which git
    /// writes as `<worktree>/.git` (absolute, or relative to the registration directory).
    private static func registrationHolder(_ registration: String, fileSystem: any AgentHistoryFileSystemProbing) -> String? {
        guard let raw = fileSystem.contents(registration + "/gitdir")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        let gitFile = raw.hasPrefix("/") ? raw : registration + "/" + raw
        return lexicallyStandardized((lexicallyStandardized(gitFile) as NSString).deletingLastPathComponent)
    }

    private static func absolutePath(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/") else { return nil }
        return lexicallyStandardized(raw)
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        let path = comparable(path)
        let root = comparable(root)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        comparable(lhs) == comparable(rhs)
    }

    /// git records worktree paths after `realpath`, so `/tmp` and `/var` come back as
    /// `/private/tmp` and `/private/var`. Strip that firmlink prefix for comparisons only.
    private static func comparable(_ path: String) -> String {
        let standardized = lexicallyStandardized(path)
        for firmlinked in ["/private/var", "/private/tmp", "/private/etc"] {
            if standardized == firmlinked || standardized.hasPrefix(firmlinked + "/") {
                return String(standardized.dropFirst("/private".count))
            }
        }
        return standardized
    }

    /// Collapses `//`, `.` and `..` without consulting the file system (the folder may be gone).
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
}
