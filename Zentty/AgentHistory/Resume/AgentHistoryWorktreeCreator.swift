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
        _ timeout: TimeInterval
    ) throws -> SubprocessResult

    static let gitUnavailableMessage = "Git isn't available. Install the Xcode Command Line Tools to recreate worktrees."
    static let timedOutMessage = "Git took too long to recreate the worktree."
    static let launchFailedMessage = "Git couldn't be started."
    static let systemGitShimPath = "/usr/bin/git"
    static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    var timeout: TimeInterval = 120
    /// For `git worktree remove` of a stale registration: it only deletes git's admin files.
    var staleRegistrationTimeout: TimeInterval = 30
    var xcrunTimeout: TimeInterval = 2
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var isExecutableFile: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var runner: Runner = { executableURL, arguments, environment, timeout in
        try SubprocessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout
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
            case .failure(let error):
                return .failure(error)
            }
        }

        let result: SubprocessResult
        switch runGit(recreation.gitArguments, environment: gitEnvironment, timeout: timeout) {
        case .success(let finished):
            result = finished
        case .failure(let error):
            return .failure(error)
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

    /// Runs `/usr/bin/env git <arguments>`. A finished git, whatever its exit status, is a success.
    private func runGit(
        _ arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Result<SubprocessResult, AgentHistoryWorktreeError> {
        do {
            return .success(try runner(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments, environment, timeout))
        } catch SubprocessError.timedOut {
            AgentHistoryLog.indexer.error("Worktree recreate timed out")
            return .failure(AgentHistoryWorktreeError(exitCode: nil, message: Self.timedOutMessage))
        } catch {
            AgentHistoryLog.indexer.error("Worktree recreate could not launch git")
            return .failure(AgentHistoryWorktreeError(exitCode: nil, message: Self.launchFailedMessage))
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
            let probe = try runner(URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", "git"], environment, xcrunTimeout)
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
