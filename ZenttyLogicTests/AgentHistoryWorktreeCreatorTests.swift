import XCTest
@testable import Zentty

final class AgentHistoryWorktreeCreatorTests: XCTestCase {
    let recreation = AgentHistoryWorktreeRecreation(
        mainRepoRoot: "/Users/test/src/app",
        worktreePath: "/Users/test/src/worktrees/app-feature",
        branch: "feature/x",
        hasStaleRegistration: false,
        resumeDirectory: "/Users/test/src/worktrees/app-feature",
        staleRegistrationRemovalArguments: nil,
        gitArguments: ["-C", "/Users/test/src/app", "worktree", "add", "--", "/Users/test/src/worktrees/app-feature", "feature/x"]
    )

    var staleRecreation: AgentHistoryWorktreeRecreation {
        var stale = recreation
        stale.hasStaleRegistration = true
        stale.staleRegistrationRemovalArguments = [
            "-C", "/Users/test/src/app", "worktree", "remove", "--", "/Users/test/src/worktrees/app-feature",
        ]
        return stale
    }

    func creator(
        path: String = "/usr/bin",
        executables: Set<String> = ["/usr/bin/git"],
        folder: FakeWorktreeDisk = FakeWorktreeDisk(),
        recorder: WorktreeCreatorCallRecorder,
        respond: @escaping @Sendable (String, [String]) throws -> SubprocessResult
    ) -> GitWorktreeCreator {
        var creator = GitWorktreeCreator()
        creator.environment = ["PATH": path, "HOME": "/Users/test-history-home"]
        creator.isExecutableFile = { executables.contains($0) }
        creator.fileExists = { folder.exists(at: $0) }
        creator.fileSystem = folder
        creator.runner = { url, arguments, environment, timeout, grace in
            recorder.record(WorktreeCreatorCall(
                executable: url.path,
                arguments: arguments,
                environment: environment ?? [:],
                timeout: timeout,
                terminationGracePeriod: grace
            ))
            return try respond(url.path, arguments)
        }
        return creator
    }

    func recreate(
        with creator: GitWorktreeCreator,
        _ recreation: AgentHistoryWorktreeRecreation? = nil
    ) -> Result<Void, AgentHistoryWorktreeError> {
        let done = expectation(description: "recreate completes")
        let box = WorktreeCreatorResultBox()
        creator.recreate(recreation ?? self.recreation) { result in
            box.set(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return box.value ?? .failure(AgentHistoryWorktreeError(exitCode: nil, message: "no result"))
    }

    static func ok() -> SubprocessResult {
        SubprocessResult(terminationStatus: 0, stdout: Data(), stderr: Data())
    }

    func test_git_creator_reports_missing_command_line_tools() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { executable, _ in
            if executable == "/usr/bin/xcrun" {
                return SubprocessResult(
                    terminationStatus: 1,
                    stdout: Data(),
                    stderr: Data("xcrun: error: invalid active developer path".utf8)
                )
            }
            return Self.ok()
        }

        let result = recreate(with: creator)

        XCTAssertEqual(
            result.failure,
            AgentHistoryWorktreeError(exitCode: nil, message: GitWorktreeCreator.gitUnavailableMessage)
        )
        XCTAssertEqual(recorder.calls.map(\.executable), ["/usr/bin/xcrun"])
        XCTAssertEqual(recorder.calls.first?.arguments, ["--find", "git"])
        XCTAssertEqual(recorder.calls.first?.timeout, 2)
    }

    func test_git_creator_reports_xcrun_launch_failure_as_missing_tools() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { executable, _ in
            if executable == "/usr/bin/xcrun" { throw SubprocessError.timedOut }
            return Self.ok()
        }

        XCTAssertEqual(recreate(with: creator).failure?.message, GitWorktreeCreator.gitUnavailableMessage)
        XCTAssertEqual(recorder.calls.count, 1)
    }

    func test_git_creator_runs_env_git_with_recreation_arguments() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { _, _ in Self.ok() }

        let result = recreate(with: creator)

        XCTAssertNil(result.failure)
        XCTAssertEqual(recorder.calls.map(\.executable), ["/usr/bin/xcrun", "/usr/bin/env"])
        let gitCall = recorder.calls[1]
        XCTAssertEqual(gitCall.arguments, ["git"] + recreation.gitArguments)
        XCTAssertEqual(gitCall.timeout, 120)
        XCTAssertEqual(gitCall.terminationGracePeriod, 10, "a timed-out add gets SIGTERM and a grace period first")
        XCTAssertEqual(gitCall.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(gitCall.environment["PATH"], "/usr/bin")
    }

    func test_git_creator_skips_xcrun_probe_for_non_system_git() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(
            path: "/opt/homebrew/bin:/usr/bin",
            executables: ["/opt/homebrew/bin/git", "/usr/bin/git"],
            recorder: recorder
        ) { _, _ in Self.ok() }

        XCTAssertNil(recreate(with: creator).failure)
        XCTAssertEqual(recorder.calls.map(\.executable), ["/usr/bin/env"])
    }

    func test_git_creator_reports_missing_git_without_running_anything() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(executables: [], recorder: recorder) { _, _ in Self.ok() }

        XCTAssertEqual(recreate(with: creator).failure?.message, GitWorktreeCreator.gitUnavailableMessage)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func test_git_creator_maps_nonzero_exit_to_error_with_stderr() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { executable, _ in
            if executable == "/usr/bin/env" {
                return SubprocessResult(
                    terminationStatus: 128,
                    stdout: Data(),
                    stderr: Data("Preparing worktree\nfatal: 'feature/x' is already used by worktree\n".utf8)
                )
            }
            return Self.ok()
        }

        XCTAssertEqual(
            recreate(with: creator).failure,
            AgentHistoryWorktreeError(exitCode: 128, message: "fatal: 'feature/x' is already used by worktree")
        )
    }

    func test_git_creator_removes_stale_registration_before_add_without_force() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { _, _ in Self.ok() }
        let stale = staleRecreation

        XCTAssertNil(recreate(with: creator, stale).failure)

        let gitCalls = recorder.calls.filter { $0.executable == "/usr/bin/env" }
        XCTAssertEqual(gitCalls.map(\.arguments), [
            ["git"] + (stale.staleRegistrationRemovalArguments ?? []),
            ["git"] + stale.gitArguments,
        ])
        XCTAssertEqual(gitCalls.first?.timeout, 30)
        XCTAssertFalse(gitCalls.flatMap(\.arguments).contains { $0 == "--force" || $0 == "-f" })
    }

    func test_git_creator_still_runs_add_when_stale_registration_removal_fails() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { executable, arguments in
            if executable == "/usr/bin/env", arguments.contains("remove") {
                return SubprocessResult(terminationStatus: 128, stdout: Data(), stderr: Data("fatal: not a working tree\n".utf8))
            }
            if executable == "/usr/bin/env" {
                return SubprocessResult(
                    terminationStatus: 128,
                    stdout: Data(),
                    stderr: Data("fatal: 'feature/x' is already used by worktree at '/Users/test/src/rebasing'\n".utf8)
                )
            }
            return Self.ok()
        }

        XCTAssertEqual(
            recreate(with: creator, staleRecreation).failure,
            AgentHistoryWorktreeError(exitCode: 128, message: "fatal: 'feature/x' is already used by worktree at '/Users/test/src/rebasing'"),
            "add is authoritative: git's own in-use check reports the real reason"
        )
        XCTAssertEqual(recorder.calls.filter { $0.executable == "/usr/bin/env" }.count, 2)
    }

    func test_git_creator_stops_when_stale_registration_removal_times_out() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { executable, arguments in
            if executable == "/usr/bin/env", arguments.contains("remove") { throw SubprocessError.timedOut }
            return Self.ok()
        }

        XCTAssertEqual(recreate(with: creator, staleRecreation).failure?.message, GitWorktreeCreator.timedOutMessage)
        XCTAssertEqual(recorder.calls.filter { $0.executable == "/usr/bin/env" }.count, 1)
    }

    func test_git_creator_reports_timeout() {
        let recorder = WorktreeCreatorCallRecorder()
        let creator = creator(recorder: recorder) { executable, _ in
            if executable == "/usr/bin/env" { throw SubprocessError.timedOut }
            return Self.ok()
        }

        XCTAssertEqual(recreate(with: creator).failure?.message, GitWorktreeCreator.timedOutMessage)
        XCTAssertEqual(
            recorder.calls.filter { $0.executable == "/usr/bin/env" }.count,
            1,
            "git removed its own half-made worktree on SIGTERM; nothing left to clean up"
        )
    }

    func test_git_creator_refuses_when_folder_reappeared_before_add() {
        let recorder = WorktreeCreatorCallRecorder()
        let folder = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot, exists: true)
        let creator = creator(folder: folder, recorder: recorder) { _, _ in Self.ok() }

        XCTAssertEqual(
            recreate(with: creator).failure,
            AgentHistoryWorktreeError(exitCode: nil, message: GitWorktreeCreator.folderExistsMessage)
        )
        XCTAssertFalse(recorder.calls.contains { $0.arguments.contains("add") })
    }

    func test_git_creator_reports_incomplete_folder_it_could_not_remove() {
        let recorder = WorktreeCreatorCallRecorder()
        let folder = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot, exists: false)
        let worktreePath = recreation.worktreePath
        let creator = creator(folder: folder, recorder: recorder) { executable, arguments in
            guard executable == "/usr/bin/env" else { return Self.ok() }
            if arguments.contains("add") {
                folder.setExists(true)
                folder.register("app-feature", worktree: worktreePath, locked: "initializing")
                throw SubprocessError.timedOut
            }
            if arguments.contains("unlock") {
                folder.unlockRegistrations(pointingAt: worktreePath)
                return Self.ok()
            }
            return SubprocessResult(terminationStatus: 128, stdout: Data(), stderr: Data("fatal: not a working tree\n".utf8))
        }

        XCTAssertEqual(
            recreate(with: creator).failure,
            AgentHistoryWorktreeError(
                exitCode: nil,
                message: GitWorktreeCreator.incompleteWorktreeMessage(path: recreation.worktreePath)
            )
        )
    }
}
