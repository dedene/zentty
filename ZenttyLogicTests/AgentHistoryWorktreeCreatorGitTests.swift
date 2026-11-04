import XCTest
@testable import Zentty

/// The timeout cleanup against real git, in a throwaway repository under a temp folder.
final class AgentHistoryWorktreeCreatorGitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not installed")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// SIGTERM while a slow `post-checkout` hook runs: git has finished the checkout and unlocked
    /// the registration, so the worktree (and anything written into it meanwhile) must survive.
    func test_timeout_during_post_checkout_hook_keeps_the_worktree_and_its_work() throws {
        let main = root.appendingPathComponent("main").path
        let worktree = root.appendingPathComponent("wt").path
        let environment = isolatedGitEnvironment()
        try git(["init", "-q", "-b", "trunk", main], environment)
        try "hello\n".write(toFile: main + "/README", atomically: true, encoding: .utf8)
        try git(["-C", main, "add", "README"], environment)
        try git(["-C", main, "-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-qm", "init"], environment)
        try git(["-C", main, "branch", "feature"], environment)
        // The hook writes "agent work" into the new worktree, then hangs past the timeout.
        let hook = main + "/.git/hooks/post-checkout"
        try "#!/bin/sh\necho work > agent_work.txt\nexec sleep 30\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        var creator = GitWorktreeCreator()
        creator.environment = environment
        creator.timeout = 3
        creator.terminationGracePeriod = 1
        let recreation = AgentHistoryWorktreeRecreation(
            mainRepoRoot: main,
            worktreePath: worktree,
            branch: "feature",
            hasStaleRegistration: false,
            resumeDirectory: worktree,
            staleRegistrationRemovalArguments: nil,
            gitArguments: ["-C", main, "worktree", "add", "--", worktree, "feature"]
        )

        let result = creator.recreateSynchronously(recreation)

        guard case .failure(let error) = result else {
            return XCTFail("the add timed out, so recreation reports a failure")
        }
        XCTAssertEqual(error.message, GitWorktreeCreator.checkoutHookTimedOutMessage(path: worktree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/README"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/agent_work.txt"))
        XCTAssertEqual(
            AgentHistoryFolderResolver.registrationNames(
                pointingAt: worktree, mainRepoRoot: main, fileSystem: LiveAgentHistoryFileSystem()),
            ["wt"]
        )
    }

    /// No global or system config (a global `core.hooksPath` would replace the fixture's hook).
    private func isolatedGitEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
        ]
    }

    private func git(_ arguments: [String], _ environment: [String: String]) throws {
        let result = try SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            environment: environment,
            timeout: 30
        )
        XCTAssertEqual(result.terminationStatus, 0, String(decoding: result.stderr, as: UTF8.self))
    }
}
