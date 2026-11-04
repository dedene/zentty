import XCTest
@testable import Zentty

/// What a timed-out `git worktree add` may clean up. Only a registration git created during this
/// add and still locked (checkout never finished) is git's own; everything else at the path may
/// hold someone's work and is kept.
extension AgentHistoryWorktreeCreatorTests {
    /// SIGTERM during a slow `post-checkout` hook (husky, `npm install`, LFS): git has already
    /// cleared its junk marker and unlocked the registration, so the checkout is complete and may
    /// already hold an agent's work. It must never be force-removed.
    func test_timeout_keeps_finished_worktree_whose_checkout_hook_ran_long() {
        let recorder = WorktreeCreatorCallRecorder()
        let disk = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot)
        let worktreePath = recreation.worktreePath
        let creator = creator(folder: disk, recorder: recorder) { executable, arguments in
            guard executable == "/usr/bin/env" else { return Self.ok() }
            if arguments.contains("add") {
                disk.setExists(true)
                disk.register("app-feature", worktree: worktreePath)
                throw SubprocessError.timedOut
            }
            return Self.ok()
        }

        let result = recreate(with: creator)

        XCTAssertEqual(recorder.gitArguments, [recreation.gitArguments], "nothing but the add ran")
        XCTAssertFalse(recorder.gitArguments.joined().contains("--force"))
        XCTAssertTrue(disk.exists(at: recreation.worktreePath))
        XCTAssertEqual(disk.registrationNames, ["app-feature"])
        XCTAssertEqual(
            result.failure?.message,
            GitWorktreeCreator.checkoutHookTimedOutMessage(path: recreation.worktreePath)
        )
    }

    /// git normally refuses a path that exists, so a folder after a timed-out add that git never
    /// registered came from something else. Keep it.
    func test_timeout_keeps_folder_git_did_not_register() {
        let recorder = WorktreeCreatorCallRecorder()
        let disk = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot)
        let creator = creator(folder: disk, recorder: recorder) { executable, arguments in
            guard executable == "/usr/bin/env" else { return Self.ok() }
            if arguments.contains("add") {
                disk.setExists(true)
                throw SubprocessError.timedOut
            }
            return Self.ok()
        }

        let result = recreate(with: creator)

        XCTAssertEqual(recorder.gitArguments, [recreation.gitArguments])
        XCTAssertTrue(disk.exists(at: recreation.worktreePath))
        XCTAssertEqual(result.failure?.message, GitWorktreeCreator.keptFolderMessage(path: recreation.worktreePath))
    }

    /// A locked registration that existed before this add is someone else's lock, not git's
    /// "initializing" marker from this run.
    func test_timeout_keeps_locked_registration_that_predates_the_add() {
        let recorder = WorktreeCreatorCallRecorder()
        let disk = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot)
        disk.register("app-feature", worktree: recreation.worktreePath, locked: "agent at work")
        let creator = creator(folder: disk, recorder: recorder) { executable, arguments in
            guard executable == "/usr/bin/env" else { return Self.ok() }
            if arguments.contains("add") {
                disk.setExists(true)
                throw SubprocessError.timedOut
            }
            return Self.ok()
        }

        let result = recreate(with: creator)

        XCTAssertEqual(recorder.gitArguments, [recreation.gitArguments])
        XCTAssertTrue(disk.exists(at: recreation.worktreePath))
        XCTAssertTrue(disk.isLocked("app-feature"))
        XCTAssertEqual(result.failure?.message, GitWorktreeCreator.keptFolderMessage(path: recreation.worktreePath))
    }

    /// git was killed after the grace period mid-checkout: the registration it created in this
    /// run is still locked ("initializing"). Unlock it and remove it with a single `--force`
    /// (the partial checkout looks dirty), never the double force that also overrides a lock.
    func test_timeout_removes_unfinished_add_it_created_without_double_force() {
        let recorder = WorktreeCreatorCallRecorder()
        let disk = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot)
        let worktreePath = recreation.worktreePath
        let creator = creator(folder: disk, recorder: recorder) { executable, arguments in
            guard executable == "/usr/bin/env" else { return Self.ok() }
            if arguments.contains("add") {
                disk.setExists(true)
                disk.register("app-feature", worktree: worktreePath, locked: "initializing")
                throw SubprocessError.timedOut
            }
            if arguments.contains("unlock") {
                disk.unlockRegistrations(pointingAt: worktreePath)
            }
            if arguments.contains("remove") {
                disk.removeRegistrations(pointingAt: worktreePath)
                disk.setExists(false)
            }
            return Self.ok()
        }

        let result = recreate(with: creator)

        XCTAssertEqual(result.failure?.message, GitWorktreeCreator.timedOutMessage)
        XCTAssertEqual(recorder.gitArguments, [
            recreation.gitArguments,
            ["-C", recreation.mainRepoRoot, "worktree", "unlock", "--", recreation.worktreePath],
            ["-C", recreation.mainRepoRoot, "worktree", "remove", "--force", "--", recreation.worktreePath],
        ])
        XCTAssertFalse(disk.exists(at: recreation.worktreePath))
        XCTAssertEqual(disk.registrationNames, [])
    }

    /// If `unlock` did not leave the same unlocked registration behind, something else changed
    /// the worktree meanwhile: stop before removing anything.
    func test_timeout_does_not_remove_when_unlock_fails() {
        let recorder = WorktreeCreatorCallRecorder()
        let disk = FakeWorktreeDisk(path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot)
        let worktreePath = recreation.worktreePath
        let creator = creator(folder: disk, recorder: recorder) { executable, arguments in
            guard executable == "/usr/bin/env" else { return Self.ok() }
            if arguments.contains("add") {
                disk.setExists(true)
                disk.register("app-feature", worktree: worktreePath, locked: "initializing")
                throw SubprocessError.timedOut
            }
            return SubprocessResult(terminationStatus: 128, stdout: Data(), stderr: Data("fatal: not locked\n".utf8))
        }

        let result = recreate(with: creator)

        XCTAssertFalse(recorder.gitArguments.contains { $0.contains("remove") })
        XCTAssertTrue(disk.exists(at: recreation.worktreePath))
        XCTAssertEqual(
            result.failure?.message,
            GitWorktreeCreator.incompleteWorktreeMessage(path: recreation.worktreePath)
        )
    }

    /// The stale registration is removed only while its folder is still gone: `worktree remove`
    /// on a folder that came back (clean) would delete it, ignored files included.
    func test_stale_registration_is_not_removed_when_folder_reappeared() {
        let recorder = WorktreeCreatorCallRecorder()
        let disk = FakeWorktreeDisk(
            path: recreation.worktreePath, mainRepoRoot: recreation.mainRepoRoot, exists: true)
        let creator = creator(folder: disk, recorder: recorder) { _, _ in Self.ok() }

        XCTAssertEqual(
            recreate(with: creator, staleRecreation).failure,
            AgentHistoryWorktreeError(exitCode: nil, message: GitWorktreeCreator.folderExistsMessage)
        )
        XCTAssertEqual(recorder.gitArguments, [], "neither remove nor add ran")
    }
}
