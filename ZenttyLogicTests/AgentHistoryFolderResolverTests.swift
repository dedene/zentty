import XCTest
@testable import Zentty

final class AgentHistoryFolderResolverTests: XCTestCase {
    private let home = "/Users/test-history-home"
    private let mainRoot = "/Users/test/src/app"
    private let worktreeRoot = "/Users/test/src/worktrees/app-feature"
    private let branch = "feature/x"

    private var gitDir: String { mainRoot + "/.git" }

    // MARK: - Fixtures

    /// A main repository with `main` checked out and a `feature/x` loose branch ref.
    private func mainRepository() -> FakeHistoryFileSystem {
        var fs = FakeHistoryFileSystem()
        fs.makeDirectory(mainRoot + "/Sources")
        fs.write(gitDir + "/HEAD", "ref: refs/heads/main\n")
        fs.write(gitDir + "/refs/heads/main", "1111111111111111111111111111111111111111\n")
        fs.write(gitDir + "/refs/heads/feature/x", "2222222222222222222222222222222222222222\n")
        return fs
    }

    private func registerWorktree(
        in fs: inout FakeHistoryFileSystem,
        name: String,
        holder: String,
        branch: String,
        locked: Bool = false
    ) {
        let registration = gitDir + "/worktrees/" + name
        fs.write(registration + "/HEAD", "ref: refs/heads/\(branch)\n")
        fs.write(registration + "/gitdir", holder + "/.git\n")
        fs.write(registration + "/commondir", "../..\n")
        if locked {
            fs.write(registration + "/locked", "")
        }
    }

    private func source(
        cwd: String?,
        repoRoot: String?,
        mainRepoRoot: String?,
        branch: String? = nil
    ) -> AgentHistoryResumeSource {
        AgentHistoryResumeSource(
            sessionRowID: 7,
            agent: .claude,
            nativeSessionID: "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f",
            title: "Session",
            workingDirectory: cwd,
            repoRoot: repoRoot,
            mainRepoRoot: mainRepoRoot,
            branch: branch,
            model: nil,
            effort: nil,
            generation: nil,
            sourceRoot: nil
        )
    }

    private func worktreeSource(cwd: String? = nil, branch: String? = nil) -> AgentHistoryResumeSource {
        source(
            cwd: cwd ?? worktreeRoot + "/Sources/Core",
            repoRoot: worktreeRoot,
            mainRepoRoot: mainRoot,
            branch: branch ?? self.branch
        )
    }

    private func resolve(_ source: AgentHistoryResumeSource, _ fs: FakeHistoryFileSystem) -> AgentHistoryFolderResolution {
        AgentHistoryFolderResolver.resolve(source, fileSystem: fs, homeDirectory: home)
    }

    // MARK: - Resolution

    func test_existing_cwd_is_ready() {
        let fs = mainRepository()
        let session = source(cwd: mainRoot + "/Sources", repoRoot: mainRoot, mainRepoRoot: mainRoot)

        XCTAssertEqual(resolve(session, fs), .ready(workingDirectory: mainRoot + "/Sources"))
        XCTAssertFalse(AgentHistoryFolderResolver.isFolderMissing(session, fileSystem: fs))
    }

    func test_missing_cwd_in_existing_repo_offers_repo_root_default_and_copy() {
        let fs = mainRepository()
        let session = source(cwd: mainRoot + "/deleted/dir", repoRoot: mainRoot, mainRepoRoot: mainRoot, branch: "main")

        XCTAssertTrue(AgentHistoryFolderResolver.isFolderMissing(session, fileSystem: fs))
        XCTAssertEqual(
            resolve(session, fs),
            .folderGone(
                options: [.repositoryRoot(mainRoot), .copyResumeCommand],
                defaultChoice: .repositoryRoot(mainRoot)
            )
        )
    }

    func test_missing_worktree_offers_main_repo_root_and_recreate() throws {
        let fs = mainRepository()
        let session = worktreeSource()

        guard case let .folderGone(options, defaultChoice) = resolve(session, fs) else {
            return XCTFail("expected folderGone")
        }
        XCTAssertEqual(defaultChoice, .repositoryRoot(mainRoot))
        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options.first, .repositoryRoot(mainRoot))
        XCTAssertEqual(options.last, .copyResumeCommand)
        guard case let .recreateWorktree(recreation) = options[1] else {
            return XCTFail("expected recreate option second")
        }
        XCTAssertEqual(recreation.mainRepoRoot, mainRoot)
        XCTAssertEqual(recreation.worktreePath, worktreeRoot)
        XCTAssertEqual(recreation.branch, branch)
    }

    func test_existing_worktree_root_is_preferred_over_main_root_when_only_cwd_is_gone() {
        var fs = mainRepository()
        fs.makeDirectory(worktreeRoot)
        let session = worktreeSource(cwd: worktreeRoot + "/gone")

        XCTAssertEqual(
            resolve(session, fs),
            .folderGone(
                options: [.repositoryRoot(worktreeRoot), .copyResumeCommand],
                defaultChoice: .repositoryRoot(worktreeRoot)
            )
        )
    }

    func test_no_repository_offers_home_folder_first() {
        let fs = FakeHistoryFileSystem()
        let session = source(cwd: "/Users/test/scratch/gone", repoRoot: nil, mainRepoRoot: nil)

        XCTAssertEqual(
            resolve(session, fs),
            .folderGone(options: [.homeFolder(home), .copyResumeCommand], defaultChoice: .homeFolder(home))
        )
    }

    func test_repository_roots_all_gone_offers_home_folder() {
        let fs = FakeHistoryFileSystem()
        let session = worktreeSource()

        XCTAssertEqual(
            resolve(session, fs),
            .folderGone(options: [.homeFolder(home), .copyResumeCommand], defaultChoice: .homeFolder(home))
        )
    }

    func test_missing_working_directory_value_is_treated_as_gone() {
        let fs = mainRepository()
        let session = source(cwd: nil, repoRoot: mainRoot, mainRepoRoot: mainRoot)

        XCTAssertTrue(AgentHistoryFolderResolver.isFolderMissing(session, fileSystem: fs))
        XCTAssertEqual(
            resolve(session, fs),
            .folderGone(options: [.repositoryRoot(mainRoot), .copyResumeCommand], defaultChoice: .repositoryRoot(mainRoot))
        )
    }

    // MARK: - Worktree eligibility

    func test_recreate_without_stale_registration_has_no_force() throws {
        let fs = mainRepository()
        let recreation = try XCTUnwrap(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))

        XCTAssertFalse(recreation.needsForce)
        XCTAssertFalse(recreation.gitArguments.contains("--force"))
    }

    func test_recreate_with_own_stale_registration_needs_force() throws {
        var fs = mainRepository()
        registerWorktree(in: &fs, name: "app-feature", holder: worktreeRoot, branch: branch)

        let recreation = try XCTUnwrap(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))

        XCTAssertTrue(recreation.needsForce)
        XCTAssertEqual(
            recreation.gitArguments,
            ["-C", mainRoot, "worktree", "add", "--force", "--", worktreeRoot, branch]
        )
    }

    func test_recreate_matches_own_registration_recorded_under_private_prefix() throws {
        let tmpMain = "/tmp/zentty-history/app"
        let tmpWorktree = "/tmp/zentty-history/app-feature"
        var fs = FakeHistoryFileSystem()
        fs.write(tmpMain + "/.git/HEAD", "ref: refs/heads/main\n")
        fs.write(tmpMain + "/.git/refs/heads/feature/x", "2222222222222222222222222222222222222222\n")
        fs.write(tmpMain + "/.git/worktrees/app-feature/HEAD", "ref: refs/heads/feature/x\n")
        fs.write(tmpMain + "/.git/worktrees/app-feature/gitdir", "/private" + tmpWorktree + "/.git\n")
        let session = source(cwd: tmpWorktree, repoRoot: tmpWorktree, mainRepoRoot: tmpMain, branch: branch)

        let recreation = try XCTUnwrap(AgentHistoryFolderResolver.worktreeRecreation(for: session, fileSystem: fs))

        XCTAssertTrue(recreation.needsForce)
    }

    func test_recreate_ineligible_when_branch_missing() {
        let fs = mainRepository()

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(branch: "feature/deleted"), fileSystem: fs))
    }

    func test_recreate_finds_branch_in_packed_refs() throws {
        var fs = mainRepository()
        fs.write(
            gitDir + "/packed-refs",
            """
            # pack-refs with: peeled fully-peeled sorted
            3333333333333333333333333333333333333333 refs/heads/feature/packed
            ^4444444444444444444444444444444444444444
            5555555555555555555555555555555555555555 refs/tags/v1
            """
        )

        let recreation = try XCTUnwrap(
            AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(branch: "feature/packed"), fileSystem: fs)
        )
        XCTAssertEqual(recreation.branch, "feature/packed")
        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(branch: "v1"), fileSystem: fs))
    }

    func test_recreate_ineligible_when_branch_checked_out_in_main_worktree() {
        var fs = mainRepository()
        fs.write(gitDir + "/HEAD", "ref: refs/heads/feature/x\n")

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
    }

    func test_recreate_ineligible_when_live_worktree_holds_branch() {
        var fs = mainRepository()
        let otherWorktree = "/Users/test/src/worktrees/app-other"
        fs.makeDirectory(otherWorktree)
        registerWorktree(in: &fs, name: "app-other", holder: otherWorktree, branch: branch)

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
    }

    func test_recreate_ineligible_when_other_stale_worktree_holds_branch() {
        var fs = mainRepository()
        registerWorktree(in: &fs, name: "app-other", holder: "/Users/test/src/worktrees/app-other", branch: branch)

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
    }

    func test_recreate_ignores_registrations_holding_other_branches() throws {
        var fs = mainRepository()
        let otherWorktree = "/Users/test/src/worktrees/app-other"
        fs.makeDirectory(otherWorktree)
        registerWorktree(in: &fs, name: "app-other", holder: otherWorktree, branch: "main-2")

        let recreation = try XCTUnwrap(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
        XCTAssertFalse(recreation.needsForce)
    }

    func test_recreate_ineligible_when_stale_registration_is_locked() {
        var fs = mainRepository()
        registerWorktree(in: &fs, name: "app-feature", holder: worktreeRoot, branch: branch, locked: true)

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
    }

    func test_recreate_ineligible_for_non_worktree_session() {
        let fs = mainRepository()
        let session = source(cwd: mainRoot + "/gone", repoRoot: mainRoot, mainRepoRoot: mainRoot, branch: branch)

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: session, fileSystem: fs))
    }

    func test_recreate_ineligible_when_worktree_folder_still_exists() {
        var fs = mainRepository()
        fs.makeDirectory(worktreeRoot)

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
    }

    func test_recreate_ineligible_when_main_git_is_not_a_directory() {
        var fs = FakeHistoryFileSystem()
        fs.write(gitDir, "gitdir: /elsewhere/.git/worktrees/app\n")

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))
    }

    func test_invalid_branch_names_rejected() {
        let invalid = [
            "", "HEAD", "@", "-delete", "--force", "a..b", "a@{1}", "a\\b", "a b", "a~1", "a^", "a:b", "a?", "a*",
            "a[b", "a\u{07}", "a\u{7f}", "a/", "/a", "a//b", "a.lock", "a/b.lock", "a.", ".hidden", "a/.hidden",
            "a\nb", String(repeating: "x", count: 256),
        ]
        for name in invalid {
            XCTAssertFalse(AgentHistoryFolderResolver.isValidBranchName(name), "expected invalid: \(name.debugDescription)")
        }
        for name in ["main", "feature/x", "peter/fix-123", "release-1.2", "a.b", "user@host", "x_y"] {
            XCTAssertTrue(AgentHistoryFolderResolver.isValidBranchName(name), "expected valid: \(name)")
        }
    }

    func test_invalid_branch_is_never_read_from_disk() {
        var fs = mainRepository()
        fs.write(gitDir + "/refs/heads/../../config", "x")

        XCTAssertNil(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(branch: "../../config"), fileSystem: fs))
    }

    func test_resumeDirectory_keeps_subdirectory_inside_worktree() throws {
        let fs = mainRepository()

        let inside = try XCTUnwrap(
            AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(cwd: worktreeRoot + "/Sources/Core"), fileSystem: fs)
        )
        XCTAssertEqual(inside.resumeDirectory, worktreeRoot + "/Sources/Core")

        let atRoot = try XCTUnwrap(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(cwd: worktreeRoot), fileSystem: fs))
        XCTAssertEqual(atRoot.resumeDirectory, worktreeRoot)

        let sibling = try XCTUnwrap(
            AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(cwd: worktreeRoot + "-sibling/x"), fileSystem: fs)
        )
        XCTAssertEqual(sibling.resumeDirectory, worktreeRoot)
    }

    func test_git_arguments_put_double_dash_before_path() throws {
        let fs = mainRepository()
        let recreation = try XCTUnwrap(AgentHistoryFolderResolver.worktreeRecreation(for: worktreeSource(), fileSystem: fs))

        XCTAssertEqual(recreation.gitArguments, ["-C", mainRoot, "worktree", "add", "--", worktreeRoot, branch])
        let dashIndex = try XCTUnwrap(recreation.gitArguments.firstIndex(of: "--"))
        let pathIndex = try XCTUnwrap(recreation.gitArguments.firstIndex(of: worktreeRoot))
        XCTAssertLessThan(dashIndex, pathIndex)
    }
}

/// An in-memory directory tree for folder-resolution tests; never touches disk.
struct FakeHistoryFileSystem: AgentHistoryFileSystemProbing {
    private(set) var directories: Set<String> = ["/"]
    private(set) var files: [String: String] = [:]

    mutating func makeDirectory(_ path: String) {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            directories.insert(current)
        }
    }

    mutating func write(_ path: String, _ contents: String) {
        makeDirectory((path as NSString).deletingLastPathComponent)
        files[path] = contents
    }

    func isDirectory(_ path: String) -> Bool {
        directories.contains(path)
    }

    func fileExists(_ path: String) -> Bool {
        directories.contains(path) || files[path] != nil
    }

    func contents(_ path: String) -> String? {
        files[path]
    }

    func directoryEntries(_ path: String) -> [String] {
        let prefix = path == "/" ? "/" : path + "/"
        let children = (Array(directories) + Array(files.keys)).compactMap { candidate -> String? in
            guard candidate.hasPrefix(prefix), candidate != path else { return nil }
            let rest = candidate.dropFirst(prefix.count)
            guard !rest.isEmpty, !rest.contains("/") else { return nil }
            return String(rest)
        }
        return Array(Set(children)).sorted()
    }
}
