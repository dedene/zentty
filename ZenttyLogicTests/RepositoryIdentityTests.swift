import Foundation
import XCTest
@testable import Zentty

final class RepositoryIdentityTests: XCTestCase {
    /// A fresh temp directory with symlinks resolved (`/var` → `/private/var`), removed on teardown.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.resolvingSymlinksInPath()
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try makeFolder(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
    }

    /// `<root>/.git/` with `HEAD` on `branch`.
    @discardableResult
    private func makeMainRepository(at root: URL, branch: String = "main") throws -> URL {
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try makeFolder(gitDirectory.appendingPathComponent("refs/heads", isDirectory: true))
        try write("ref: refs/heads/\(branch)\n", to: gitDirectory.appendingPathComponent("HEAD"))
        return gitDirectory
    }

    /// Lays out a linked worktree like `git worktree add` does.
    private func makeLinkedWorktree(
        at worktree: URL,
        mainRepository: URL,
        name: String,
        branch: String,
        gitdirLine: String? = nil,
        commondir: String? = "../.."
    ) throws {
        let adminDirectory = mainRepository
            .appendingPathComponent(".git/worktrees/\(name)", isDirectory: true)
        try makeFolder(adminDirectory)
        try write("ref: refs/heads/\(branch)\n", to: adminDirectory.appendingPathComponent("HEAD"))
        if let commondir {
            try write("\(commondir)\n", to: adminDirectory.appendingPathComponent("commondir"))
        }
        try makeFolder(worktree)
        try write(
            "gitdir: \(gitdirLine ?? adminDirectory.path)\n",
            to: worktree.appendingPathComponent(".git")
        )
    }

    // MARK: - Resolver

    func test_plain_repo_nested_dir() throws {
        let base = try makeDirectory()
        let root = base.appendingPathComponent("repo", isDirectory: true)
        try makeMainRepository(at: root, branch: "main")
        let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
        try makeFolder(nested)

        let identity = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: nested.path))
        XCTAssertEqual(identity.repoRoot, root.path)
        XCTAssertEqual(identity.mainRepoRoot, root.path)
        XCTAssertFalse(identity.isLinkedWorktree)
        XCTAssertEqual(identity.headBranch, "main")

        XCTAssertEqual(RepositoryIdentityResolver.resolve(directory: root.path + "/"), identity)
    }

    func test_linked_worktree_absolute_gitdir() throws {
        let base = try makeDirectory()
        let main = base.appendingPathComponent("zentty", isDirectory: true)
        try makeMainRepository(at: main)
        let worktree = base.appendingPathComponent("worktrees/feat/history", isDirectory: true)
        try makeLinkedWorktree(at: worktree, mainRepository: main, name: "history", branch: "feat/history")
        let nested = worktree.appendingPathComponent("Zentty", isDirectory: true)
        try makeFolder(nested)

        let identity = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: nested.path))
        XCTAssertEqual(identity.repoRoot, worktree.path)
        XCTAssertEqual(identity.mainRepoRoot, main.path)
        XCTAssertTrue(identity.isLinkedWorktree)
        XCTAssertEqual(identity.headBranch, "feat/history")
    }

    func test_relative_gitdir() throws {
        let base = try makeDirectory()
        let main = base.appendingPathComponent("repo", isDirectory: true)
        try makeMainRepository(at: main)
        let worktree = base.appendingPathComponent("wt", isDirectory: true)
        try makeLinkedWorktree(
            at: worktree,
            mainRepository: main,
            name: "wt",
            branch: "topic",
            gitdirLine: "../repo/.git/worktrees/wt"
        )

        let identity = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: worktree.path))
        XCTAssertEqual(identity.repoRoot, worktree.path)
        XCTAssertEqual(identity.mainRepoRoot, main.path)
        XCTAssertTrue(identity.isLinkedWorktree)
        XCTAssertEqual(identity.headBranch, "topic")
    }

    func test_commondir_missing_marker_fallback() throws {
        let base = try makeDirectory()
        let main = base.appendingPathComponent("repo", isDirectory: true)
        try makeMainRepository(at: main)
        let worktree = base.appendingPathComponent("wt", isDirectory: true)
        try makeLinkedWorktree(at: worktree, mainRepository: main, name: "wt", branch: "topic", commondir: nil)

        let identity = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: worktree.path))
        XCTAssertEqual(identity.repoRoot, worktree.path)
        XCTAssertEqual(identity.mainRepoRoot, main.path)
        XCTAssertTrue(identity.isLinkedWorktree)
        XCTAssertEqual(identity.headBranch, "topic")

        // The admin directory is gone entirely (main repo pruned): the marker still names the main repo.
        let orphan = base.appendingPathComponent("orphan", isDirectory: true)
        try makeFolder(orphan)
        let missingMain = base.appendingPathComponent("gone-repo", isDirectory: true)
        try write("gitdir: \(missingMain.path)/.git/worktrees/orphan\n", to: orphan.appendingPathComponent(".git"))
        let orphaned = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: orphan.path))
        XCTAssertEqual(orphaned.repoRoot, orphan.path)
        XCTAssertEqual(orphaned.mainRepoRoot, missingMain.path)
        XCTAssertTrue(orphaned.isLinkedWorktree)
        XCTAssertNil(orphaned.headBranch)
    }

    func test_submodule_main_is_self() throws {
        let base = try makeDirectory()
        let superproject = base.appendingPathComponent("super", isDirectory: true)
        let superGit = try makeMainRepository(at: superproject)
        let moduleGit = superGit.appendingPathComponent("modules/lib", isDirectory: true)
        try makeFolder(moduleGit)
        try write("ref: refs/heads/develop\n", to: moduleGit.appendingPathComponent("HEAD"))
        let submodule = superproject.appendingPathComponent("lib", isDirectory: true)
        try makeFolder(submodule)
        try write("gitdir: ../.git/modules/lib\n", to: submodule.appendingPathComponent(".git"))

        let identity = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: submodule.path))
        XCTAssertEqual(identity.repoRoot, submodule.path)
        XCTAssertEqual(identity.mainRepoRoot, submodule.path)
        XCTAssertFalse(identity.isLinkedWorktree)
        XCTAssertEqual(identity.headBranch, "develop")
    }

    func test_bare_common_dir_is_main() throws {
        let base = try makeDirectory()
        let bare = base.appendingPathComponent("project.git", isDirectory: true)
        let adminDirectory = bare.appendingPathComponent("worktrees/main", isDirectory: true)
        try makeFolder(adminDirectory)
        try write("ref: refs/heads/main\n", to: adminDirectory.appendingPathComponent("HEAD"))
        try write("../..\n", to: adminDirectory.appendingPathComponent("commondir"))
        let worktree = base.appendingPathComponent("main", isDirectory: true)
        try makeFolder(worktree)
        try write("gitdir: \(adminDirectory.path)\n", to: worktree.appendingPathComponent(".git"))

        let identity = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: worktree.path))
        XCTAssertEqual(identity.repoRoot, worktree.path)
        XCTAssertEqual(identity.mainRepoRoot, bare.path)
        XCTAssertTrue(identity.isLinkedWorktree)
    }

    func test_gitdir_in_protected_location_is_not_read() throws {
        let base = try makeDirectory()
        let home = base.appendingPathComponent("home", isDirectory: true)
        // The main repo lives under the fixture home's Documents. Its admin dir has a readable
        // HEAD and a decoy commondir: reading either would change the result.
        let protectedMain = home.appendingPathComponent("Documents/proj", isDirectory: true)
        let adminDirectory = protectedMain.appendingPathComponent(".git/worktrees/wt", isDirectory: true)
        try makeFolder(adminDirectory)
        try write("ref: refs/heads/topic\n", to: adminDirectory.appendingPathComponent("HEAD"))
        try write("../../../../decoy/.git\n", to: adminDirectory.appendingPathComponent("commondir"))
        let worktree = home.appendingPathComponent("dev/wt", isDirectory: true)
        try makeFolder(worktree)
        try write("gitdir: \(adminDirectory.path)\n", to: worktree.appendingPathComponent(".git"))

        let expected = RepositoryIdentity(
            repoRoot: worktree.path,
            mainRepoRoot: protectedMain.path,
            isLinkedWorktree: true,
            headBranch: nil
        )
        XCTAssertEqual(RepositoryIdentityResolver.resolve(directory: worktree.path, homeDirectory: home.path), expected)
        XCTAssertEqual(RepositoryIdentityCache(homeDirectory: home.path).identity(for: worktree.path), expected)

        // A relative gitdir that lands in the protected folder is not read either.
        let relative = home.appendingPathComponent("dev/rel", isDirectory: true)
        try makeFolder(relative)
        try write("gitdir: ../../Documents/proj/.git/worktrees/wt\n", to: relative.appendingPathComponent(".git"))
        XCTAssertEqual(
            RepositoryIdentityResolver.resolve(directory: relative.path, homeDirectory: home.path),
            RepositoryIdentity(repoRoot: relative.path, mainRepoRoot: protectedMain.path, isLinkedWorktree: true, headBranch: nil)
        )

        // A gitdir on another volume: lexical marker only.
        let external = home.appendingPathComponent("dev/external", isDirectory: true)
        try makeFolder(external)
        try write("gitdir: /Volumes/External/repo/.git/worktrees/external\n", to: external.appendingPathComponent(".git"))
        XCTAssertEqual(
            RepositoryIdentityResolver.resolve(directory: external.path, homeDirectory: home.path),
            RepositoryIdentity(repoRoot: external.path, mainRepoRoot: "/Volumes/External/repo", isLinkedWorktree: true, headBranch: nil)
        )

        // A protected submodule-style gitdir (no marker): the folder is its own main tree.
        let module = home.appendingPathComponent("dev/module", isDirectory: true)
        try makeFolder(module)
        try write("gitdir: \(protectedMain.path)/.git/modules/lib\n", to: module.appendingPathComponent(".git"))
        XCTAssertEqual(
            RepositoryIdentityResolver.resolve(directory: module.path, homeDirectory: home.path),
            RepositoryIdentity(repoRoot: module.path, mainRepoRoot: module.path, isLinkedWorktree: false, headBranch: nil)
        )

        // Starting inside the protected folder resolves to nothing.
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: protectedMain.path, homeDirectory: home.path))
    }

    func test_symlinked_cwd_canonical_equal() throws {
        let base = try makeDirectory()
        let root = base.appendingPathComponent("repo", isDirectory: true)
        try makeMainRepository(at: root)
        try makeFolder(root.appendingPathComponent("src", isDirectory: true))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        let viaLink = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: link.appendingPathComponent("src").path))
        let direct = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: root.appendingPathComponent("src").path))
        XCTAssertEqual(viaLink, direct)
        XCTAssertEqual(viaLink.repoRoot, AgentHistoryPath.canonical(root.path))

        // The unresolved temp path (`/var/...`) resolves to the same `/private/var/...` identity.
        let unresolvedBase = FileManager.default.temporaryDirectory
        if unresolvedBase.path != unresolvedBase.resolvingSymlinksInPath().path {
            let unresolved = unresolvedBase
                .appendingPathComponent(base.lastPathComponent)
                .appendingPathComponent("repo/src")
            XCTAssertEqual(RepositoryIdentityResolver.resolve(directory: unresolved.path), direct)
        }
    }

    func test_non_repo_and_missing_dir_nil() throws {
        let base = try makeDirectory()
        let plain = base.appendingPathComponent("plain/nested", isDirectory: true)
        try makeFolder(plain)
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: plain.path))

        let root = base.appendingPathComponent("repo", isDirectory: true)
        try makeMainRepository(at: root)
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: root.appendingPathComponent("deleted").path))
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: "relative/path"))
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: ""))

        // A `.git` file that is not a gitfile is not a repository.
        let broken = base.appendingPathComponent("broken", isDirectory: true)
        try makeFolder(broken)
        try write("not a gitfile\n", to: broken.appendingPathComponent(".git"))
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: broken.path))

        // An oversized `.git` file is ignored.
        let huge = base.appendingPathComponent("huge", isDirectory: true)
        try makeFolder(huge)
        try write("gitdir: " + String(repeating: "x", count: 5000), to: huge.appendingPathComponent(".git"))
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: huge.path))
    }

    func test_head_branch_and_detached() throws {
        let base = try makeDirectory()
        let root = base.appendingPathComponent("repo", isDirectory: true)
        let gitDirectory = try makeMainRepository(at: root, branch: "feature/a-b")
        XCTAssertEqual(RepositoryIdentityResolver.resolve(directory: root.path)?.headBranch, "feature/a-b")

        try write("0123456789abcdef0123456789abcdef01234567\n", to: gitDirectory.appendingPathComponent("HEAD"))
        let detached = try XCTUnwrap(RepositoryIdentityResolver.resolve(directory: root.path))
        XCTAssertNil(detached.headBranch)
        XCTAssertEqual(detached.repoRoot, root.path)

        try write("ref: refs/tags/v1\n", to: gitDirectory.appendingPathComponent("HEAD"))
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: root.path)?.headBranch)

        try FileManager.default.removeItem(at: gitDirectory.appendingPathComponent("HEAD"))
        XCTAssertNil(RepositoryIdentityResolver.resolve(directory: root.path)?.headBranch)
    }

    // MARK: - Cache

    func test_cache_memo_ttl_and_miss_caching() throws {
        let base = try makeDirectory()
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try makeFolder(repo)
        try makeFolder(other)

        let calls = LockedCalls()
        let clock = LockedClock()
        let identity = RepositoryIdentity(repoRoot: repo.path, mainRepoRoot: repo.path, isLinkedWorktree: false, headBranch: "main")
        let cache = RepositoryIdentityCache(
            ttl: 60,
            resolve: { directory in
                calls.record(directory)
                return directory == repo.path ? identity : nil
            },
            now: { clock.now }
        )

        XCTAssertEqual(cache.identity(for: repo.path), identity)
        XCTAssertEqual(cache.identity(for: repo.path + "/"), identity)
        XCTAssertNil(cache.identity(for: other.path))
        XCTAssertNil(cache.identity(for: other.path))
        XCTAssertEqual(calls.values, [repo.path, other.path])

        clock.advance(59)
        XCTAssertEqual(cache.identity(for: repo.path), identity)
        XCTAssertEqual(calls.values.count, 2)

        clock.advance(2)
        XCTAssertEqual(cache.identity(for: repo.path), identity)
        XCTAssertNil(cache.identity(for: other.path))
        XCTAssertEqual(calls.values, [repo.path, other.path, repo.path, other.path])
    }

    func test_cache_skips_protected_prefixes_and_missing_parents() throws {
        let base = try makeDirectory()
        let home = base.appendingPathComponent("home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents/project", isDirectory: true)
        try makeFolder(documents)

        let calls = LockedCalls()
        let cache = RepositoryIdentityCache(
            resolve: { directory in
                calls.record(directory)
                return nil
            },
            homeDirectory: home.path
        )

        XCTAssertNil(cache.identity(for: documents.path))
        XCTAssertNil(cache.identity(for: home.appendingPathComponent("Desktop/x").path))
        XCTAssertNil(cache.identity(for: home.appendingPathComponent("Library/CloudStorage/Drive/x").path))
        XCTAssertNil(cache.identity(for: "/Volumes/External/repo"))
        XCTAssertNil(cache.identity(for: "/net/host/repo"))
        XCTAssertNil(cache.identity(for: base.appendingPathComponent("gone/child").path))
        XCTAssertNil(cache.identity(for: "relative/dir"))
        XCTAssertEqual(calls.values, [])

        // Siblings of protected folders are not protected.
        let code = home.appendingPathComponent("DocumentsArchive", isDirectory: true)
        try makeFolder(code)
        XCTAssertNil(cache.identity(for: code.path))
        XCTAssertEqual(calls.values, [code.path])
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}
