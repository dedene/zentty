import Foundation

struct AgentHistoryWorktreeError: Error, Equatable, Sendable {
    /// git's exit status, or nil when git never ran or did not finish.
    var exitCode: Int32?
    /// User-facing text: git's own `fatal:` line, or a fixed message from `GitWorktreeCreator`.
    var message: String
}

protocol AgentHistoryWorktreeCreating: Sendable {
    /// Recreates the worktree off the main thread. `completion` runs on a background queue.
    func recreate(
        _ recreation: AgentHistoryWorktreeRecreation,
        completion: @escaping @Sendable (Result<Void, AgentHistoryWorktreeError>) -> Void
    )
}

/// Runs `git worktree add` for a folder-gone resume, after removing a stale registration if there
/// is one. git is resolved on the inherited `PATH`; when that is the `/usr/bin/git` shim, a short
/// `xcrun --find git` probe runs first so a Mac without the Command Line Tools gets a message
/// instead of the system install dialog.
struct GitWorktreeCreator: AgentHistoryWorktreeCreating {
    typealias Runner = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval,
        _ terminationGracePeriod: TimeInterval
    ) throws -> SubprocessResult

    static let gitUnavailableMessage = "Git isn't available. Install the Xcode Command Line Tools to recreate worktrees."
    static let timedOutMessage = "Git took too long to recreate the worktree."
    static let launchFailedMessage = "Git couldn't be started."
    static let folderExistsMessage = "A folder already exists where the worktree was. Resume the session again to use it."
    static func incompleteWorktreeMessage(path: String) -> String {
        "Git took too long to recreate the worktree and left an incomplete folder at \(path). Delete it before resuming this session."
    }
    static func checkoutHookTimedOutMessage(path: String) -> String {
        "Git made the worktree at \(path), but a checkout hook took too long. It was kept; resume the session again to use it."
    }
    static func keptFolderMessage(path: String) -> String {
        "Git took too long to recreate the worktree. The folder now at \(path) was left untouched; check it before resuming this session."
    }
    static let systemGitShimPath = "/usr/bin/git"
    static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    var timeout: TimeInterval = 120
    /// On timeout git first gets `SIGTERM`; whatever still runs after this long gets `SIGKILL`.
    /// `SIGTERM` during checkout makes `worktree add` delete its half-made folder and registration,
    /// but not once checkout finished and a `post-checkout` hook runs: that worktree is complete.
    var terminationGracePeriod: TimeInterval = 10
    /// For `git worktree remove` of a stale registration (it only deletes git's admin files) and
    /// for the cleanup after a timed-out `add`.
    var staleRegistrationTimeout: TimeInterval = 30
    var xcrunTimeout: TimeInterval = 2
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var isExecutableFile: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// Reads the main repository's worktree registrations (`.git/worktrees/*`).
    var fileSystem: any AgentHistoryFileSystemProbing = LiveAgentHistoryFileSystem()
    var runner: Runner = { executableURL, arguments, environment, timeout, terminationGracePeriod in
        try SubprocessRunner.runInProcessGroup(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod
        )
    }
    var queue: DispatchQueue = .global(qos: .userInitiated)

    func recreate(
        _ recreation: AgentHistoryWorktreeRecreation,
        completion: @escaping @Sendable (Result<Void, AgentHistoryWorktreeError>) -> Void
    ) {
        let creator = self
        queue.async {
            completion(creator.recreateSynchronously(recreation))
        }
    }

    /// Blocking; call off the main thread.
    func recreateSynchronously(_ recreation: AgentHistoryWorktreeRecreation) -> Result<Void, AgentHistoryWorktreeError> {
        guard let git = resolvedGitPath() else {
            AgentHistoryLog.indexer.info("Worktree recreate skipped: git not found on PATH")
            return .failure(AgentHistoryWorktreeError(exitCode: nil, message: Self.gitUnavailableMessage))
        }
        if git == Self.systemGitShimPath, !commandLineToolsAvailable() {
            AgentHistoryLog.indexer.info("Worktree recreate skipped: Command Line Tools missing")
            return .failure(AgentHistoryWorktreeError(exitCode: nil, message: Self.gitUnavailableMessage))
        }

        var gitEnvironment = environment
        gitEnvironment["GIT_TERMINAL_PROMPT"] = "0"

        // `worktree remove` on a folder that came back would delete it (ignored files included) when
        // clean, so the stale registration is only removed while the folder is still gone.
        if let refusal = folderReappeared(recreation) {
            return .failure(refusal)
        }

        if let removal = recreation.staleRegistrationRemovalArguments {
            // Best effort: when the registration is already gone (pruned since the sheet opened)
            // this fails harmlessly, and when it can't be removed `add` reports why.
            switch runGit(removal, environment: gitEnvironment, timeout: staleRegistrationTimeout) {
            case .success(let result) where result.terminationStatus != 0:
                AgentHistoryLog.indexer.info(
                    "Stale worktree registration not removed (git exit \(result.terminationStatus, privacy: .public))"
                )
            case .success:
                break
            case .failure(let failure):
                return .failure(failure.error)
            }
        }

        if let refusal = folderReappeared(recreation) {
            return .failure(refusal)
        }
        // A registration missing from this list but present after a timed-out `add` is git's own.
        let registrationsBeforeAdd = Set(AgentHistoryFolderResolver.registrationNames(
            mainRepoRoot: recreation.mainRepoRoot,
            fileSystem: fileSystem
        ))

        let result: SubprocessResult
        switch runGit(recreation.gitArguments, environment: gitEnvironment, timeout: timeout) {
        case .success(let finished):
            result = finished
        case .failure(.timedOut):
            return .failure(errorAfterAddTimedOut(
                recreation,
                registrationsBeforeAdd: registrationsBeforeAdd,
                environment: gitEnvironment
            ))
        case .failure(let failure):
            return .failure(failure.error)
        }

        guard result.terminationStatus == 0 else {
            AgentHistoryLog.indexer.error(
                "Worktree recreate failed with git exit \(result.terminationStatus, privacy: .public)"
            )
            return .failure(AgentHistoryWorktreeError(
                exitCode: result.terminationStatus,
                message: Self.failureMessage(stderr: result.stderr, exitCode: result.terminationStatus)
            ))
        }
        AgentHistoryLog.indexer.info(
            "Worktree recreated (stale registration: \(recreation.hasStaleRegistration, privacy: .public))"
        )
        return .success(())
    }

    private func folderReappeared(_ recreation: AgentHistoryWorktreeRecreation) -> AgentHistoryWorktreeError? {
        guard fileExists(recreation.worktreePath) else {
            return nil
        }
        AgentHistoryLog.indexer.info("Worktree recreate skipped: folder reappeared")
        return AgentHistoryWorktreeError(exitCode: nil, message: Self.folderExistsMessage)
    }

    /// Cleans up only what provably belongs to this unfinished `add`: one registration for the
    /// path that git created during this run and that is still locked (git's "initializing" lock,
    /// which it drops once checkout finishes). That one is unlocked, re-read, and removed with a
    /// single `--force` (a partial checkout looks dirty); never the double force that also
    /// overrides a lock. Anything else at the path may hold someone's work and is kept.
    private func errorAfterAddTimedOut(
        _ recreation: AgentHistoryWorktreeRecreation,
        registrationsBeforeAdd: Set<String>,
        environment: [String: String]
    ) -> AgentHistoryWorktreeError {
        let path = recreation.worktreePath
        guard fileExists(path) else {
            return AgentHistoryWorktreeError(exitCode: nil, message: Self.timedOutMessage)
        }
        let registrations = registrationNames(pointingAt: recreation)
        guard registrations.count == 1, let name = registrations.first, !registrationsBeforeAdd.contains(name) else {
            AgentHistoryLog.indexer.error("Worktree recreate timed out; kept a folder this add did not register")
            return AgentHistoryWorktreeError(exitCode: nil, message: Self.keptFolderMessage(path: path))
        }
        let lockFile = recreation.mainRepoRoot + "/.git/worktrees/" + name + "/locked"
        guard fileSystem.fileExists(lockFile) else {
            AgentHistoryLog.indexer.error("Worktree recreate timed out after checkout; kept the worktree")
            return AgentHistoryWorktreeError(exitCode: nil, message: Self.checkoutHookTimedOutMessage(path: path))
        }

        AgentHistoryLog.indexer.error("Worktree recreate timed out mid-checkout; removing the partial worktree")
        let incomplete = AgentHistoryWorktreeError(exitCode: nil, message: Self.incompleteWorktreeMessage(path: path))
        let unlock = ["-C", recreation.mainRepoRoot, "worktree", "unlock", "--", path]
        guard case .success(let unlocked) = runGit(unlock, environment: environment, timeout: staleRegistrationTimeout),
              unlocked.terminationStatus == 0,
              registrationNames(pointingAt: recreation) == [name],
              !fileSystem.fileExists(lockFile)
        else {
            AgentHistoryLog.indexer.error("Partial worktree changed or stayed locked; not removing it")
            return incomplete
        }
        let removal = ["-C", recreation.mainRepoRoot, "worktree", "remove", "--force", "--", path]
        _ = runGit(removal, environment: environment, timeout: staleRegistrationTimeout)
        guard !fileExists(path) else {
            AgentHistoryLog.indexer.error("Incomplete worktree folder could not be removed")
            return incomplete
        }
        return AgentHistoryWorktreeError(exitCode: nil, message: Self.timedOutMessage)
    }

    private func registrationNames(pointingAt recreation: AgentHistoryWorktreeRecreation) -> [String] {
        AgentHistoryFolderResolver.registrationNames(
            pointingAt: recreation.worktreePath,
            mainRepoRoot: recreation.mainRepoRoot,
            fileSystem: fileSystem
        )
    }

    private enum GitRunFailure: Error {
        case timedOut
        case launchFailed

        var error: AgentHistoryWorktreeError {
            switch self {
            case .timedOut:
                return AgentHistoryWorktreeError(exitCode: nil, message: GitWorktreeCreator.timedOutMessage)
            case .launchFailed:
                return AgentHistoryWorktreeError(exitCode: nil, message: GitWorktreeCreator.launchFailedMessage)
            }
        }
    }

    /// Runs `/usr/bin/env git <arguments>`. A finished git, whatever its exit status, is a success.
    private func runGit(
        _ arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Result<SubprocessResult, GitRunFailure> {
        do {
            return .success(try runner(
                URL(fileURLWithPath: "/usr/bin/env"),
                ["git"] + arguments,
                environment,
                timeout,
                terminationGracePeriod
            ))
        } catch SubprocessError.timedOut {
            AgentHistoryLog.indexer.error("Worktree recreate timed out")
            return .failure(.timedOut)
        } catch {
            AgentHistoryLog.indexer.error("Worktree recreate could not launch git")
            return .failure(.launchFailed)
        }
    }

    /// First executable `git` on the inherited `PATH` (the same lookup `/usr/bin/env git` does).
    func resolvedGitPath() -> String? {
        let searchPath = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultSearchPath
        for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = String(directory.hasSuffix("/") ? directory + "git" : directory + "/git")
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func commandLineToolsAvailable() -> Bool {
        do {
            let probe = try runner(
                URL(fileURLWithPath: "/usr/bin/xcrun"),
                ["--find", "git"],
                environment,
                xcrunTimeout,
                1
            )
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// git prints progress lines ("Preparing worktree …") before the `fatal:` line; prefer the
    /// last `fatal:`/`error:` line, else the last non-empty line.
    static func failureMessage(stderr: Data, exitCode: Int32) -> String {
        let lines = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let chosen = lines.last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }) ?? lines.last
        guard let chosen else {
            return "git worktree add failed (exit \(exitCode))."
        }
        return chosen.count > 300 ? String(chosen.prefix(300)) + "…" : chosen
    }
}
