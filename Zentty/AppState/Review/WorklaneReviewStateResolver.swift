import Foundation
import os

private let reviewLogger = Logger(subsystem: "be.zenjoy.zentty", category: "ReviewState")

struct WorklaneReviewResolution: Equatable, Sendable {
    enum UpdatePolicy: Equatable, Sendable {
        case replace
        case preserveExistingOnEmpty
    }

    let reviewState: WorklaneReviewState?
    let updatePolicy: UpdatePolicy

    init(
        reviewState: WorklaneReviewState?,
        updatePolicy: UpdatePolicy = .replace
    ) {
        self.reviewState = reviewState
        self.updatePolicy = updatePolicy
    }
}

struct WorklaneReviewCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

protocol WorklaneReviewCommandRunning: Sendable {
    func run(arguments: [String], currentDirectoryPath: String) async -> WorklaneReviewCommandResult
}

struct DefaultWorklaneReviewCommandRunner: WorklaneReviewCommandRunning {
    /// `gh` talks to the network; bound it so a hung call cannot pin a worker thread.
    private static let commandTimeout: TimeInterval = 30

    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func run(arguments: [String], currentDirectoryPath: String) async -> WorklaneReviewCommandResult {
        await withCheckedContinuation { continuation in
            let environment = self.environment
            DispatchQueue.global(qos: .utility).async {
                guard let command = arguments.first,
                      let executablePath = Self.resolveExecutablePath(for: command, environment: environment)
                else {
                    let missingCommand = arguments.first ?? "<missing>"
                    continuation.resume(returning: WorklaneReviewCommandResult(
                        terminationStatus: -1,
                        stdout: Data(),
                        stderr: Data("Unable to locate executable for command: \(missingCommand)".utf8)
                    ))
                    return
                }

                do {
                    let result = try SubprocessRunner.run(
                        executableURL: URL(fileURLWithPath: executablePath),
                        arguments: Array(arguments.dropFirst()),
                        environment: Self.subprocessEnvironment(from: environment),
                        currentDirectoryURL: URL(fileURLWithPath: currentDirectoryPath, isDirectory: true),
                        timeout: Self.commandTimeout
                    )
                    continuation.resume(returning: WorklaneReviewCommandResult(
                        terminationStatus: result.terminationStatus,
                        stdout: result.stdout,
                        stderr: result.stderr
                    ))
                } catch {
                    reviewLogger.debug("Review command failed: \(String(describing: error))")
                    continuation.resume(returning: WorklaneReviewCommandResult(
                        terminationStatus: -1,
                        stdout: Data(),
                        stderr: Data(String(describing: error).utf8)
                    ))
                }
            }
        }
    }

    static func resolveExecutablePath(
        for command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default
        if trimmedCommand.contains("/") {
            return fileManager.isExecutableFile(atPath: trimmedCommand) ? trimmedCommand : nil
        }

        for directory in executableSearchPaths(environment: environment) {
            let candidatePath = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(trimmedCommand, isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }

        return nil
    }

    static func subprocessEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        var nextEnvironment = environment
        nextEnvironment["PATH"] = executableSearchPaths(environment: environment).joined(separator: ":")
        return nextEnvironment
    }

    static func executableSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let commonLocations = [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var orderedPaths: [String] = []
        for entry in pathEntries + commonLocations {
            let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedEntry.isEmpty, !orderedPaths.contains(trimmedEntry) else {
                continue
            }
            orderedPaths.append(trimmedEntry)
        }

        return orderedPaths
    }
}

@MainActor
final class WorklaneReviewStateResolver {
    private struct RepositoryKey: Hashable {
        let repoRoot: String
        let branch: String
    }

    private enum GitHubRepositoryResolution: Equatable {
        case repository(String)
        case gitLabProject(String)
        case noGitHubRepository
        case unresolved
    }

    /// Which remote a repository resolves to depends on the branch, so its
    /// branch URLs have to come from the same discovery.
    private struct DiscoveredGitHubRepository {
        let resolution: GitHubRepositoryResolution
        let hostInfo: GitRemoteHostInfo?
        let discoveredAt: Date
    }

    private enum RemoteLookupOutcome: Equatable {
        case repository(String)
        case gitLabProject(String)
        case notGitHub
        case failed
    }

    private enum RepositoryStatus: Equatable {
        case repository(gitDirectory: String)
        case notRepository
    }

    private struct PullRequestPayload: Decodable {
        let number: Int
        let url: URL?
        let isDraft: Bool
        let state: String
        /// GitHub review decision: APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null.
        let reviewDecision: String?
        /// Mergeability: MERGEABLE | CONFLICTING | UNKNOWN.
        let mergeable: String?
        /// Rolled-up CI check contexts (CheckRun + StatusContext entries).
        let statusCheckRollup: [StatusCheckRollupEntry]?
        /// GitLab only: the pipeline is blocked until someone starts a manual job.
        var isWaitingForManualAction: Bool? = nil
    }

    private struct StatusCheckRollupEntry: Decodable {
        /// StatusContext state: SUCCESS | PENDING | FAILURE | ERROR | EXPECTED.
        let state: String?
        /// CheckRun status: QUEUED | IN_PROGRESS | COMPLETED | WAITING | PENDING | REQUESTED.
        let status: String?
        /// CheckRun conclusion when COMPLETED: SUCCESS | FAILURE | NEUTRAL | CANCELLED | TIMED_OUT | ...
        let conclusion: String?
    }

    private struct MergeRequestPayload: Decodable {
        struct Pipeline: Decodable {
            let status: String?
        }

        let iid: Int
        let webURL: URL?
        let state: String
        let draft: Bool
        let hasConflicts: Bool?
        let detailedMergeStatus: String?
        let headPipeline: Pipeline?
        let sourceProjectID: Int?
        let targetProjectID: Int?

        var isFromFork: Bool {
            guard let sourceProjectID, let targetProjectID else {
                return false
            }
            return sourceProjectID != targetProjectID
        }

        enum CodingKeys: String, CodingKey {
            case iid
            case webURL = "web_url"
            case state
            case draft
            case hasConflicts = "has_conflicts"
            case detailedMergeStatus = "detailed_merge_status"
            case headPipeline = "head_pipeline"
            case sourceProjectID = "source_project_id"
            case targetProjectID = "target_project_id"
        }
    }

    /// How long a cached resolution is served before a non-forced read refetches it.
    /// The active poll force-refreshes far more often; this bounds staleness for panes that
    /// are not the current poll target (background windows, unfocused worklanes).
    /// Repository discovery expires on the same clock, and forced reads honor that, so a
    /// changed remote is picked up without running git on every poll.
    private static let cacheTimeToLive: TimeInterval = 90

    private let runner: any WorklaneReviewCommandRunning
    private let now: () -> Date
    private var cache: [RepositoryKey: WorklaneReviewResolution] = [:]
    private var repositoryStatusByPath: [String: RepositoryStatus] = [:]
    private var githubRepositoryByKey: [RepositoryKey: DiscoveredGitHubRepository] = [:]
    private var pendingRepositoryKeys: Set<RepositoryKey> = []
    private var waitersByRepositoryKey: [RepositoryKey: [(paneID: PaneID, update: (PaneID, WorklaneReviewResolution) -> Void)]] = [:]

    init(
        runner: any WorklaneReviewCommandRunning = DefaultWorklaneReviewCommandRunner(),
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.now = now
    }

    /// Returns a cached resolution only when it is still within the TTL. Used by the non-forced
    /// "serve" reads; forced reads (the poll, manual refresh) bypass the cache entirely. Fallback
    /// reads (`cache[key]` for failure preservation) intentionally ignore the TTL — a stale
    /// last-known value still beats showing nothing when a refresh fails.
    private func freshCachedResolution(for key: RepositoryKey) -> WorklaneReviewResolution? {
        guard let cached = cache[key] else {
            return nil
        }
        guard let fetchedAt = cached.reviewState?.reviewFetchedAt else {
            // No timestamp (e.g. legacy/seeded entry) — treat as fresh to preserve prior behavior.
            return cached
        }
        guard now().timeIntervalSince(fetchedAt) < Self.cacheTimeToLive else {
            return nil
        }
        return cached
    }

    func refresh(
        for worklanes: [WorklaneState],
        update: @escaping (PaneID, WorklaneReviewResolution) -> Void
    ) {
        for worklane in worklanes {
            for pane in worklane.allPanes {
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                guard
                    let repoRoot = auxiliaryState?.presentation.repoRoot,
                    let branch = preferredBranch(from: auxiliaryState?.presentation.lookupBranch)
                else {
                    continue
                }

                let key = RepositoryKey(repoRoot: repoRoot, branch: branch)
                if let cached = freshCachedResolution(for: key) {
                    update(pane.id, cached)
                    continue
                }

                waitersByRepositoryKey[key, default: []].append((pane.id, update))
                guard pendingRepositoryKeys.insert(key).inserted else {
                    continue
                }

                Task { [weak self] in
                    guard let self else {
                        return
                    }

                    let resolution = await self.loadPullRequestResolution(
                        path: repoRoot,
                        branch: branch,
                        fallback: self.cache[key]
                    )
                    await self.completeFetch(key: key, resolution: resolution)
                }
            }
        }
    }

    func resolve(path: String, branch: String) async -> WorklaneReviewResolution {
        await resolve(path: path, branch: branch, forceReload: false)
    }

    func resolve(
        path: String,
        branch: String,
        forceReload: Bool
    ) async -> WorklaneReviewResolution {
        guard let sanitizedBranch = preferredBranch(from: branch) ?? WorklaneContextFormatter.trimmed(branch) else {
            return emptyResolution()
        }

        let key = RepositoryKey(repoRoot: path, branch: sanitizedBranch)
        if !forceReload, let cached = freshCachedResolution(for: key) {
            return cached
        }

        guard await isRepository(path: path) else {
            return emptyResolution()
        }

        let resolution = await loadPullRequestResolution(
            path: path,
            branch: sanitizedBranch,
            fallback: cache[key]
        )
        if resolution.reviewState?.branch != nil {
            cache[key] = resolution
        }
        return resolution
    }

    func refreshForTesting(for worklanes: [WorklaneState]) async -> [PaneID: WorklaneReviewResolution] {
        var updates: [PaneID: WorklaneReviewResolution] = [:]

        for worklane in worklanes {
            for pane in worklane.allPanes {
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                guard
                    let repoRoot = auxiliaryState?.presentation.repoRoot,
                    let branch = preferredBranch(from: auxiliaryState?.presentation.lookupBranch)
                else {
                    continue
                }

                let key = RepositoryKey(repoRoot: repoRoot, branch: branch)
                let resolution: WorklaneReviewResolution
                if let cached = freshCachedResolution(for: key) {
                    resolution = cached
                } else {
                    resolution = await loadPullRequestResolution(
                        path: repoRoot,
                        branch: branch,
                        fallback: cache[key]
                    )
                    if resolution.reviewState?.branch != nil {
                        cache[key] = resolution
                    }
                }

                updates[pane.id] = resolution
            }
        }

        return updates
    }

    func refreshPaneForTesting(
        repoRoot: String,
        branch: String,
        paneID _: PaneID,
        forceReload: Bool = false
    ) async -> WorklaneReviewResolution? {
        guard let sanitizedBranch = preferredBranch(from: branch) else {
            return nil
        }

        let key = RepositoryKey(repoRoot: repoRoot, branch: sanitizedBranch)
        if !forceReload, let cached = freshCachedResolution(for: key) {
            return cached
        }

        let resolution = await loadPullRequestResolution(
            path: repoRoot,
            branch: sanitizedBranch,
            fallback: cache[key]
        )
        if resolution.reviewState?.branch != nil {
            cache[key] = resolution
        }
        return resolution
    }

    func refreshFocusedPane(
        repoRoot: String,
        branch: String,
        paneID: PaneID,
        forceReload: Bool = false,
        update: @escaping (PaneID, WorklaneReviewResolution) -> Void
    ) {
        refreshPane(
            repoRoot: repoRoot,
            branch: branch,
            paneID: paneID,
            forceReload: forceReload,
            update: update
        )
    }

    func refreshPane(
        repoRoot: String,
        branch: String,
        paneID: PaneID,
        forceReload: Bool = false,
        update: @escaping (PaneID, WorklaneReviewResolution) -> Void
    ) {
        guard let sanitizedBranch = preferredBranch(from: branch) else {
            return
        }

        let key = RepositoryKey(repoRoot: repoRoot, branch: sanitizedBranch)
        if !forceReload, let cached = freshCachedResolution(for: key) {
            update(paneID, cached)
            return
        }

        waitersByRepositoryKey[key, default: []].append((paneID, update))
        // A forced refresh that arrives while a fetch is already in flight joins that fetch instead
        // of spawning a second `gh` process. It still never serves cache; the shared result is live.
        guard pendingRepositoryKeys.insert(key).inserted else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            let resolution = await self.loadPullRequestResolution(
                path: repoRoot,
                branch: sanitizedBranch,
                fallback: self.cache[key]
            )
            await self.completeFetch(key: key, resolution: resolution)
        }
    }

    private func completeFetch(
        key: RepositoryKey,
        resolution: WorklaneReviewResolution
    ) {
        pendingRepositoryKeys.remove(key)
        if resolution.reviewState?.branch != nil {
            cache[key] = resolution
        }
        let waiters = waitersByRepositoryKey.removeValue(forKey: key) ?? []
        waiters.forEach { waiter in
            waiter.update(waiter.paneID, resolution)
        }
    }

    private func loadPullRequestResolution(
        path: String,
        branch: String,
        fallback: WorklaneReviewResolution?
    ) async -> WorklaneReviewResolution {
        let discovered = await resolveGitHubRepository(path: path, branch: branch)
        switch discovered.resolution {
        case .noGitHubRepository:
            return branchOnlyResolution(branch: branch, hostInfo: discovered.hostInfo)
        case .unresolved:
            return failureResolution(
                fallback: fallback,
                branch: branch,
                reason: "could not resolve GitHub repository"
            )
        case .gitLabProject(let project):
            return await loadMergeRequestResolution(
                project: project,
                path: path,
                hostInfo: discovered.hostInfo,
                branch: branch,
                fallback: fallback
            )
        case .repository(let repository):
            let pullRequestResult = await runCommand(
                arguments: [
                    "gh", "pr", "view", branch, "--repo", repository,
                    "--json", "number,url,isDraft,state,reviewDecision,mergeable,statusCheckRollup",
                ],
                currentDirectoryPath: path
            )

            if pullRequestResult.terminationStatus != 0 {
                if isNoPullRequestResult(pullRequestResult) {
                    return branchOnlyResolution(branch: branch, hostInfo: discovered.hostInfo)
                }

                return failureResolution(
                    fallback: fallback,
                    branch: branch,
                    reason: "gh pr view exited \(pullRequestResult.terminationStatus)"
                )
            }

            guard let pullRequestPayload = decodePullRequest(from: pullRequestResult.stdout) else {
                return failureResolution(
                    fallback: fallback,
                    branch: branch,
                    reason: "could not decode gh pr view output"
                )
            }

            return reviewResolution(from: pullRequestPayload, kind: .pullRequest, hostInfo: discovered.hostInfo, branch: branch)
        }
    }

    private func reviewResolution(
        from payload: PullRequestPayload,
        kind: WorklanePullRequestSummary.Kind,
        hostInfo: GitRemoteHostInfo?,
        branch: String
    ) -> WorklaneReviewResolution {
        let pullRequest = WorklanePullRequestSummary(
            number: payload.number,
            url: payload.url,
            state: pullRequestState(from: payload),
            kind: kind
        )
        let checksState = aggregateChecksState(from: payload.statusCheckRollup)
        let chips = reviewChips(for: pullRequest, payload: payload, checksState: checksState)
        let branchURL = hostInfo?.branchURL(branch: branch)
        return WorklaneReviewResolution(
            reviewState: WorklaneReviewState(
                branch: branch,
                branchURL: branchURL,
                pullRequest: pullRequest,
                reviewChips: chips,
                reviewFetchedAt: now(),
                reviewRefreshFailed: false,
                checksState: checksState
            )
        )
    }

    private func loadMergeRequestResolution(
        project: String,
        path: String,
        hostInfo: GitRemoteHostInfo?,
        branch: String,
        fallback: WorklaneReviewResolution?
    ) async -> WorklaneReviewResolution {
        // `glab mr view <branch>` fails when a branch has several merge requests and reads a numeric
        // branch name as a merge request ID, so select the merge request first and view it by ID.
        // `glab mr list` only returns its first page, so open merge requests are searched on their
        // own: an old open one must not fall behind newer merged ones.
        let listStates: [[String]] = [[], ["--all"]]
        var selectedMergeRequest: MergeRequestPayload?
        for states in listStates where selectedMergeRequest == nil {
            let listResult = await runCommand(
                arguments: ["glab", "mr", "list"] + states + ["--source-branch", branch, "-R", project, "-F", "json"],
                currentDirectoryPath: path
            )
            guard listResult.terminationStatus == 0,
                  let mergeRequests = decodeMergeRequests(from: listResult.stdout) else {
                return mergeRequestFailureResolution(
                    fallback: fallback,
                    hostInfo: hostInfo,
                    branch: branch,
                    reason: "glab mr list failed with status \(listResult.terminationStatus)"
                )
            }
            selectedMergeRequest = preferredMergeRequest(from: mergeRequests)
        }

        guard let selected = selectedMergeRequest else {
            return branchOnlyResolution(branch: branch, hostInfo: hostInfo)
        }

        guard selected.state == "opened" else {
            return reviewResolution(from: pullRequestPayload(from: selected), kind: .mergeRequest, hostInfo: hostInfo, branch: branch)
        }

        let viewResult = await runCommand(
            arguments: ["glab", "mr", "view", String(selected.iid), "-R", project, "-F", "json"],
            currentDirectoryPath: path
        )
        guard viewResult.terminationStatus == 0,
              let payload = decodeMergeRequest(from: viewResult.stdout) else {
            return mergeRequestFailureResolution(
                fallback: fallback,
                hostInfo: hostInfo,
                branch: branch,
                reason: "glab mr view failed with status \(viewResult.terminationStatus)"
            )
        }

        return reviewResolution(from: pullRequestPayload(from: payload), kind: .mergeRequest, hostInfo: hostInfo, branch: branch)
    }

    /// `glab` is optional: without it (or signed out) GitLab repos keep their branch link. A failure
    /// only counts as a failed refresh when there is a merge request to preserve.
    private func mergeRequestFailureResolution(
        fallback: WorklaneReviewResolution?,
        hostInfo: GitRemoteHostInfo?,
        branch: String,
        reason: String
    ) -> WorklaneReviewResolution {
        guard fallback?.reviewState?.pullRequest != nil else {
            return branchOnlyResolution(branch: branch, hostInfo: hostInfo)
        }
        return failureResolution(fallback: fallback, branch: branch, reason: reason)
    }

    private func preferredMergeRequest(from mergeRequests: [MergeRequestPayload]) -> MergeRequestPayload? {
        let ownMergeRequests = mergeRequests.filter { !$0.isFromFork }
        return ownMergeRequests.first { $0.state == "opened" } ?? ownMergeRequests.first
    }

    /// Result to show when a refresh fails transiently (bad exit, decode failure, unresolved repo).
    /// Preserves the last-known data but flags it as failed so the UI can dim it and surface
    /// "last refresh failed". Without any prior data there is nothing to preserve, so we keep the
    /// existing (possibly empty) state via `.preserveExistingOnEmpty`. Logs a `.warning` — unlike
    /// the expected "no pull requests found" case, this is an unexpected refresh failure worth
    /// surfacing over a long session (auth expiry, network, rate limit).
    private func failureResolution(
        fallback: WorklaneReviewResolution?,
        branch: String,
        reason: String
    ) -> WorklaneReviewResolution {
        reviewLogger.warning(
            "PR status refresh failed branch=\(branch, privacy: .public) reason=\(reason, privacy: .public)"
        )
        guard let fallback, var reviewState = fallback.reviewState else {
            return WorklaneReviewResolution(
                reviewState: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        }
        reviewState.reviewRefreshFailed = true
        return WorklaneReviewResolution(reviewState: reviewState)
    }

    private func preferredBranch(from value: String?) -> String? {
        WorklaneContextFormatter.displayBranch(value)
    }

    private func emptyResolution() -> WorklaneReviewResolution {
        WorklaneReviewResolution(
            reviewState: nil,
            updatePolicy: .preserveExistingOnEmpty
        )
    }

    private func branchOnlyResolution(branch: String, hostInfo: GitRemoteHostInfo?) -> WorklaneReviewResolution {
        WorklaneReviewResolution(
            reviewState: WorklaneReviewState(
                branch: branch,
                branchURL: hostInfo?.branchURL(branch: branch),
                pullRequest: nil,
                reviewChips: [],
                reviewFetchedAt: now(),
                reviewRefreshFailed: false,
                checksState: .none
            )
        )
    }

    private func isRepository(path: String) async -> Bool {
        if let cached = repositoryStatusByPath[path] {
            if case .repository = cached {
                return true
            }
            return false
        }

        let result = await runCommand(
            arguments: ["git", "rev-parse", "--git-dir"],
            currentDirectoryPath: path
        )
        guard result.terminationStatus == 0 else {
            repositoryStatusByPath[path] = .notRepository
            return false
        }

        let gitDirectory = WorklaneContextFormatter.trimmed(String(decoding: result.stdout, as: UTF8.self)) ?? ".git"
        repositoryStatusByPath[path] = .repository(gitDirectory: gitDirectory)
        return true
    }

    private func resolveGitHubRepository(path: String, branch: String) async -> DiscoveredGitHubRepository {
        let key = RepositoryKey(repoRoot: path, branch: branch)
        if let cached = githubRepositoryByKey[key],
           now().timeIntervalSince(cached.discoveredAt) < Self.cacheTimeToLive {
            return cached
        }

        // Discovery can walk every remote; the first one it consults owns the branch URL.
        var hostInfo: GitRemoteHostInfo?
        let resolution = await discoverGitHubRepository(path: path, branch: branch, hostInfo: &hostInfo)
        let discovered = DiscoveredGitHubRepository(resolution: resolution, hostInfo: hostInfo, discoveredAt: now())
        if resolution != .unresolved {
            githubRepositoryByKey[key] = discovered
        }
        return discovered
    }

    private func discoverGitHubRepository(
        path: String,
        branch: String,
        hostInfo: inout GitRemoteHostInfo?
    ) async -> GitHubRepositoryResolution {
        var hadLookupFailure = false
        var gitLabProject: String?

        if let upstreamRemote = await resolveUpstreamRemoteName(path: path, branch: branch) {
            switch await resolveGitHubRepositorySpecifier(forRemoteNamed: upstreamRemote, path: path, hostInfo: &hostInfo) {
            case .repository(let repository):
                return .repository(repository)
            case .gitLabProject(let project):
                return .gitLabProject(project)
            case .notGitHub, .failed:
                break
            }
        }

        switch await resolveGitHubRepositorySpecifier(forRemoteNamed: "origin", path: path, hostInfo: &hostInfo) {
        case .repository(let repository):
            return .repository(repository)
        case .gitLabProject(let project):
            gitLabProject = project
        case .failed:
            hadLookupFailure = true
        case .notGitHub:
            break
        }

        let remoteListResult = await runCommand(
            arguments: ["git", "remote"],
            currentDirectoryPath: path
        )
        guard remoteListResult.terminationStatus == 0 else {
            return gitLabProject.map(GitHubRepositoryResolution.gitLabProject)
                ?? (hadLookupFailure ? .unresolved : .noGitHubRepository)
        }

        let remoteNames = String(decoding: remoteListResult.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "origin" }

        for remoteName in remoteNames {
            switch await resolveGitHubRepositorySpecifier(forRemoteNamed: remoteName, path: path, hostInfo: &hostInfo) {
            case .repository(let repository):
                return .repository(repository)
            case .gitLabProject(let project):
                gitLabProject = gitLabProject ?? project
            case .failed:
                hadLookupFailure = true
            case .notGitHub:
                break
            }
        }

        return gitLabProject.map(GitHubRepositoryResolution.gitLabProject)
            ?? (hadLookupFailure ? .unresolved : .noGitHubRepository)
    }

    private func resolveUpstreamRemoteName(path: String, branch: String) async -> String? {
        let result = await runCommand(
            arguments: ["git", "config", "--get", "branch.\(branch).remote"],
            currentDirectoryPath: path
        )

        guard result.terminationStatus == 0 else {
            return nil
        }

        return WorklaneContextFormatter.trimmed(String(decoding: result.stdout, as: UTF8.self))
    }

    private func resolveGitHubRepositorySpecifier(
        forRemoteNamed remoteName: String,
        path: String,
        hostInfo: inout GitRemoteHostInfo?
    ) async -> RemoteLookupOutcome {
        let result = await runCommand(
            arguments: ["git", "remote", "get-url", remoteName],
            currentDirectoryPath: path
        )
        guard result.terminationStatus == 0 else {
            return .failed
        }

        guard let remoteURL = WorklaneContextFormatter.trimmed(String(decoding: result.stdout, as: UTF8.self)) else {
            return .notGitHub
        }

        let parsedHostInfo = GitRemoteHostInfo.parse(remoteURL: remoteURL)
        if hostInfo == nil {
            hostInfo = parsedHostInfo
        }

        if let repository = githubRepositorySpecifier(from: remoteURL) {
            return .repository(repository)
        }

        if let parsedHostInfo, parsedHostInfo.kind == .gitlab {
            return .gitLabProject(parsedHostInfo.projectURL)
        }

        return .notGitHub
    }

    private func isGitHubRemoteURL(_ value: String) -> Bool {
        githubRepositorySpecifier(from: value) != nil
    }

    private func githubRepositorySpecifier(from value: String) -> String? {
        let remote = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            return nil
        }

        if remote.hasPrefix("git@github.com:") {
            return normalizeGitHubRepositoryPath(String(remote.dropFirst("git@github.com:".count)))
        }

        if remote.hasPrefix("ssh://git@github.com/") {
            return normalizeGitHubRepositoryPath(String(remote.dropFirst("ssh://git@github.com/".count)))
        }

        if let url = URL(string: remote), let host = url.host?.lowercased() {
            guard host == "github.com" || host == "www.github.com" else {
                return nil
            }

            return normalizeGitHubRepositoryPath(url.path)
        }

        return nil
    }

    private func normalizeGitHubRepositoryPath(_ path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let normalizedPath: String
        if trimmedPath.hasSuffix(".git") {
            normalizedPath = String(trimmedPath.dropLast(4))
        } else {
            normalizedPath = trimmedPath
        }

        let components = normalizedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            return nil
        }

        return "\(components[0])/\(components[1])"
    }

    private func runCommand(
        arguments: [String],
        currentDirectoryPath: String
    ) async -> WorklaneReviewCommandResult {
        let result = await runner.run(
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath
        )
        logCommandFailure(arguments: arguments, currentDirectoryPath: currentDirectoryPath, result: result)
        return result
    }

    private func logCommandFailure(
        arguments: [String],
        currentDirectoryPath: String,
        result: WorklaneReviewCommandResult
    ) {
        guard result.terminationStatus != 0 else {
            return
        }

        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let firstErrorLine = stderr
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "<no stderr>"
        reviewLogger.debug(
            "Review command failed cwd=\(currentDirectoryPath, privacy: .public) status=\(result.terminationStatus) command=\(arguments.joined(separator: " "), privacy: .public) stderr=\(firstErrorLine, privacy: .public)"
        )
    }

    private func decodePullRequest(from data: Data) -> PullRequestPayload? {
        try? JSONDecoder().decode(PullRequestPayload.self, from: data)
    }

    private func decodeMergeRequests(from data: Data) -> [MergeRequestPayload]? {
        try? JSONDecoder().decode([MergeRequestPayload].self, from: data)
    }

    private func decodeMergeRequest(from data: Data) -> MergeRequestPayload? {
        try? JSONDecoder().decode(MergeRequestPayload.self, from: data)
    }

    private func pullRequestPayload(from mergeRequest: MergeRequestPayload) -> PullRequestPayload {
        PullRequestPayload(
            number: mergeRequest.iid,
            url: mergeRequest.webURL,
            isDraft: mergeRequest.draft,
            state: mergeRequest.state,
            reviewDecision: reviewDecision(fromDetailedMergeStatus: mergeRequest.detailedMergeStatus),
            mergeable: mergeRequest.hasConflicts == true ? "CONFLICTING" : nil,
            statusCheckRollup: statusCheckRollup(fromPipelineStatus: mergeRequest.headPipeline?.status),
            isWaitingForManualAction: mergeRequest.headPipeline?.status == "manual"
        )
    }

    private func reviewDecision(fromDetailedMergeStatus status: String?) -> String? {
        switch status {
        case "not_approved":
            return "REVIEW_REQUIRED"
        case "requested_changes":
            return "CHANGES_REQUESTED"
        default:
            return nil
        }
    }

    private func statusCheckRollup(fromPipelineStatus status: String?) -> [StatusCheckRollupEntry]? {
        let state: String
        switch status {
        case "success":
            state = "SUCCESS"
        case "failed", "canceled":
            state = "FAILURE"
        case "created", "waiting_for_resource", "preparing", "pending", "running", "scheduled", "canceling":
            state = "PENDING"
        default:
            return nil
        }
        return [StatusCheckRollupEntry(state: state, status: nil, conclusion: nil)]
    }

    private func pullRequestState(from payload: PullRequestPayload) -> WorklanePullRequestState {
        switch payload.state.uppercased() {
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return payload.isDraft ? .draft : .open
        }
    }

    private func reviewChips(
        for pullRequest: WorklanePullRequestSummary,
        payload: PullRequestPayload,
        checksState: WorklaneChecksState
    ) -> [WorklaneReviewChip] {
        var chips = stateChips(for: pullRequest.state)

        guard pullRequest.state == .open || pullRequest.state == .draft else {
            return chips
        }

        // Approval and conflict signals only make sense on an open PR.
        if pullRequest.state == .open, let approval = approvalChip(for: payload.reviewDecision) {
            chips.append(approval)
        }

        chips.append(contentsOf: checksChips(
            for: pullRequest.state,
            checksState: checksState,
            rollup: payload.statusCheckRollup,
            isWaitingForManualAction: payload.isWaitingForManualAction == true
        ))

        if pullRequest.state == .open, isConflicting(payload.mergeable) {
            chips.append(WorklaneReviewChip(text: "Conflicts", style: .danger))
        }

        return chips
    }

    private func stateChips(for state: WorklanePullRequestState) -> [WorklaneReviewChip] {
        switch state {
        case .draft:
            return [WorklaneReviewChip(text: "Draft", style: .info)]
        case .open:
            return []
        case .merged:
            return [WorklaneReviewChip(text: "Merged", style: .success)]
        case .closed:
            return [WorklaneReviewChip(text: "Closed", style: .neutral)]
        }
    }

    private func approvalChip(for reviewDecision: String?) -> WorklaneReviewChip? {
        switch reviewDecision?.uppercased() {
        case "APPROVED":
            return WorklaneReviewChip(text: "Approved", style: .success)
        case "CHANGES_REQUESTED":
            return WorklaneReviewChip(text: "Changes requested", style: .danger)
        case "REVIEW_REQUIRED":
            return WorklaneReviewChip(text: "Review required", style: .warning)
        default:
            return nil
        }
    }

    private func isConflicting(_ mergeable: String?) -> Bool {
        mergeable?.uppercased() == "CONFLICTING"
    }

    private func checksChips(
        for state: WorklanePullRequestState,
        checksState: WorklaneChecksState,
        rollup: [StatusCheckRollupEntry]?,
        isWaitingForManualAction: Bool
    ) -> [WorklaneReviewChip] {
        switch checksState {
        case .failing:
            let failureCount = (rollup ?? []).filter(isFailingRollupEntry).count
            return [WorklaneReviewChip(
                text: failureCount <= 1 ? "1 failing" : "\(failureCount) failing",
                style: .danger
            )]
        case .running:
            return [WorklaneReviewChip(text: "Running", style: .warning)]
        case .passed:
            return [WorklaneReviewChip(text: "Checks passed", style: .success)]
        case .none:
            if isWaitingForManualAction {
                return [WorklaneReviewChip(text: "Manual action", style: .warning)]
            }
            // No checks reported. An open PR with nothing pending is "Ready"; drafts stay bare.
            return state == .open ? [WorklaneReviewChip(text: "Ready", style: .success)] : []
        }
    }

    /// Collapses a `statusCheckRollup` array into a single aggregate CI state. Failing wins over
    /// running, which wins over passed; an empty/absent rollup is `.none`.
    private func aggregateChecksState(from rollup: [StatusCheckRollupEntry]?) -> WorklaneChecksState {
        guard let rollup, !rollup.isEmpty else {
            return .none
        }
        if rollup.contains(where: isFailingRollupEntry) {
            return .failing
        }
        if rollup.contains(where: isPendingRollupEntry) {
            return .running
        }
        return .passed
    }

    private func isFailingRollupEntry(_ entry: StatusCheckRollupEntry) -> Bool {
        switch entry.conclusion?.uppercased() {
        // STALE is a terminal, non-green conclusion (the run is outdated and won't recover on its
        // own), so surface it as failing rather than letting the rollup fall through to "passed".
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE":
            return true
        default:
            break
        }
        switch entry.state?.uppercased() {
        case "FAILURE", "ERROR":
            return true
        default:
            return false
        }
    }

    private func isPendingRollupEntry(_ entry: StatusCheckRollupEntry) -> Bool {
        if let status = entry.status?.uppercased() {
            // CheckRun: anything not yet COMPLETED is still in flight.
            return status != "COMPLETED"
        }
        switch entry.state?.uppercased() {
        case "PENDING", "EXPECTED":
            return true
        default:
            return false
        }
    }

    private func isNoPullRequestResult(_ result: WorklaneReviewCommandResult) -> Bool {
        var combinedData = result.stdout
        combinedData.append(result.stderr)
        let combinedOutput = String(decoding: combinedData, as: UTF8.self).lowercased()
        return combinedOutput.contains("no pull requests found")
    }
}

#if DEBUG
extension WorklaneReviewStateResolver {
    func seedResolutionForTesting(
        path: String,
        branch: String,
        resolution: WorklaneReviewResolution
    ) {
        guard let sanitizedBranch = preferredBranch(from: branch) else {
            return
        }

        let key = RepositoryKey(repoRoot: path, branch: sanitizedBranch)
        cache[key] = resolution
    }
}
#endif

struct GitRemoteHostInfo: Equatable, Sendable {
    enum HostKind: Equatable, Sendable {
        case github
        case gitlab
        case bitbucket
        case unknown
    }

    let scheme: String
    let host: String
    let owner: String
    let repo: String
    let projectPath: String
    let kind: HostKind

    var projectURL: String {
        "\(scheme)://\(host)/\(projectPath)"
    }

    func branchURL(branch: String) -> URL? {
        let encodedBranch = branch
            .split(separator: "/", omittingEmptySubsequences: false)
            .compactMap { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }
            .joined(separator: "/")
        let path: String
        switch kind {
        case .github, .unknown:
            path = "/\(owner)/\(repo)/tree/\(encodedBranch)"
        case .gitlab:
            path = "/\(projectPath)/-/tree/\(encodedBranch)"
        case .bitbucket:
            path = "/\(owner)/\(repo)/src/\(encodedBranch)"
        }
        return URL(string: "\(scheme)://\(host)\(path)")
    }

    static func parse(remoteURL value: String) -> GitRemoteHostInfo? {
        let remote = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            return nil
        }

        if let info = parseSSH(remote) {
            return info
        }

        return parseHTTPS(remote)
    }

    private static func parseSSH(_ remote: String) -> GitRemoteHostInfo? {
        if remote.hasPrefix("git@") {
            let remainder = String(remote.dropFirst("git@".count))
            guard let colonIndex = remainder.firstIndex(of: ":"),
                  colonIndex != remainder.startIndex else {
                return nil
            }
            let host = String(remainder[remainder.startIndex..<colonIndex])
            let pathPart = String(remainder[remainder.index(after: colonIndex)...])
            return buildFromHostAndPath(host: host, path: pathPart, scheme: "https")
        }

        if remote.hasPrefix("ssh://git@") {
            let remainder = String(remote.dropFirst("ssh://git@".count))
            guard let slashIndex = remainder.firstIndex(of: "/"),
                  slashIndex != remainder.startIndex else {
                return nil
            }
            var host = String(remainder[remainder.startIndex..<slashIndex])
            if let portIndex = host.firstIndex(of: ":") {
                host = String(host[host.startIndex..<portIndex])
            }
            let pathPart = String(remainder[remainder.index(after: slashIndex)...])
            return buildFromHostAndPath(host: host, path: pathPart, scheme: "https")
        }

        return nil
    }

    private static func parseHTTPS(_ remote: String) -> GitRemoteHostInfo? {
        guard let url = URL(string: remote),
              let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else {
            return nil
        }

        return buildFromHostAndPath(host: host, port: url.port, path: url.path, scheme: scheme)
    }

    private static func buildFromHostAndPath(
        host: String,
        port: Int? = nil,
        path: String,
        scheme: String
    ) -> GitRemoteHostInfo? {
        var normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix(".git") {
            normalizedPath = String(normalizedPath.dropLast(4))
        }

        let components = normalizedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            return nil
        }

        let owner = components[0]
        let repo = components[1]
        let kind = hostKind(for: host.lowercased())

        return GitRemoteHostInfo(
            scheme: scheme,
            host: port.map { "\(host):\($0)" } ?? host,
            owner: owner,
            repo: repo,
            projectPath: normalizedPath,
            kind: kind
        )
    }

    private static func hostKind(for host: String) -> HostKind {
        if host == "github.com" || host == "www.github.com" {
            return .github
        }
        if host.split(separator: ".").contains("gitlab") {
            return .gitlab
        }
        if host == "bitbucket.org" || host == "www.bitbucket.org" {
            return .bitbucket
        }
        return .unknown
    }
}
