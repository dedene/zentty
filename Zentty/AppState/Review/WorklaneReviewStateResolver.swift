import Foundation
import os

private let reviewLogger = Logger(subsystem: "be.zentty", category: "ReviewState")

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

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = Array(arguments.dropFirst())
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                process.environment = Self.subprocessEnvironment(from: environment)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: WorklaneReviewCommandResult(
                        terminationStatus: process.terminationStatus,
                        stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                        stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    ))
                } catch {
                    reviewLogger.debug("Review command failed: \(error.localizedDescription)")
                    continuation.resume(returning: WorklaneReviewCommandResult(
                        terminationStatus: -1,
                        stdout: Data(),
                        stderr: Data(error.localizedDescription.utf8)
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
        case noGitHubRepository
        case unresolved
    }

    private enum RemoteLookupOutcome: Equatable {
        case repository(String)
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
    }

    private struct PullRequestCheckPayload: Decodable {
        let bucket: String?
        let state: String?
        let name: String?
        let link: URL?
    }

    private let runner: any WorklaneReviewCommandRunning
    private var cache: [RepositoryKey: WorklaneReviewResolution] = [:]
    private var repositoryStatusByPath: [String: RepositoryStatus] = [:]
    private var githubRepositoryByKey: [RepositoryKey: GitHubRepositoryResolution] = [:]
    private var remoteHostInfoByRepoRoot: [String: GitRemoteHostInfo?] = [:]
    private var pendingRepositoryKeys: Set<RepositoryKey> = []
    private var waitingPaneIDsByRepositoryKey: [RepositoryKey: Set<PaneID>] = [:]

    init(runner: any WorklaneReviewCommandRunning = DefaultWorklaneReviewCommandRunner()) {
        self.runner = runner
    }

    func refresh(
        for worklanes: [WorklaneState],
        update: @escaping (PaneID, WorklaneReviewResolution) -> Void
    ) {
        for worklane in worklanes {
            for pane in worklane.paneStripState.panes {
                let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id]
                guard
                    let repoRoot = auxiliaryState?.presentation.repoRoot,
                    let branch = preferredBranch(from: auxiliaryState?.presentation.lookupBranch)
                else {
                    continue
                }

                let key = RepositoryKey(repoRoot: repoRoot, branch: branch)
                if let cached = cache[key] {
                    update(pane.id, cached)
                    continue
                }

                waitingPaneIDsByRepositoryKey[key, default: []].insert(pane.id)
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
                    await MainActor.run {
                        self.pendingRepositoryKeys.remove(key)
                        if resolution.reviewState?.branch != nil {
                            self.cache[key] = resolution
                        }
                        let paneIDs = self.waitingPaneIDsByRepositoryKey.removeValue(forKey: key) ?? []
                        paneIDs.forEach { paneID in
                            update(paneID, resolution)
                        }
                    }
                }
            }
        }
    }

    func resolve(path: String, branch: String) async -> WorklaneReviewResolution {
        guard let sanitizedBranch = preferredBranch(from: branch) ?? WorklaneContextFormatter.trimmed(branch) else {
            return emptyResolution()
        }

        let key = RepositoryKey(repoRoot: path, branch: sanitizedBranch)
        if let cached = cache[key] {
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

    func refreshFocusedPane(
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
        if !forceReload, let cached = cache[key] {
            update(paneID, cached)
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
            await MainActor.run {
                if resolution.reviewState?.branch != nil {
                    self.cache[key] = resolution
                }
                update(paneID, resolution)
            }
        }
    }

    private func loadPullRequestResolution(
        path: String,
        branch: String,
        fallback: WorklaneReviewResolution?
    ) async -> WorklaneReviewResolution {
        switch await resolveGitHubRepository(path: path, branch: branch) {
        case .noGitHubRepository:
            return branchOnlyResolution(branch: branch, repoRoot: path)
        case .unresolved:
            if let fallback {
                return fallback
            }

            return WorklaneReviewResolution(
                reviewState: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        case .repository(let repository):
            let pullRequestResult = await runCommand(
                arguments: ["gh", "pr", "view", branch, "--repo", repository, "--json", "number,url,isDraft,state"],
                currentDirectoryPath: path
            )

            if pullRequestResult.terminationStatus != 0 {
                if isNoPullRequestResult(pullRequestResult) {
                    return branchOnlyResolution(branch: branch, repoRoot: path)
                }

                if let fallback {
                    return fallback
                }

                return WorklaneReviewResolution(
                    reviewState: nil,
                    updatePolicy: .preserveExistingOnEmpty
                )
            }

            guard let pullRequestPayload = decodePullRequest(from: pullRequestResult.stdout) else {
                if let fallback {
                    return fallback
                }

                return WorklaneReviewResolution(
                    reviewState: nil,
                    updatePolicy: .preserveExistingOnEmpty
                )
            }

            let pullRequest = WorklanePullRequestSummary(
                number: pullRequestPayload.number,
                url: pullRequestPayload.url,
                state: pullRequestState(from: pullRequestPayload)
            )
            let checksResult = await runCommand(
                arguments: ["gh", "pr", "checks", branch, "--repo", repository, "--json", "bucket,state,name,link"],
                currentDirectoryPath: path
            )
            let reviewChips = reviewChips(for: pullRequest, checksResult: checksResult)
            let branchURL = remoteHostInfoByRepoRoot[path]??.branchURL(branch: branch)
            return WorklaneReviewResolution(
                reviewState: WorklaneReviewState(
                    branch: branch,
                    branchURL: branchURL,
                    pullRequest: pullRequest,
                    reviewChips: reviewChips
                )
            )
        }
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

    private func branchOnlyResolution(branch: String, repoRoot: String) -> WorklaneReviewResolution {
        WorklaneReviewResolution(
            reviewState: WorklaneReviewState(
                branch: branch,
                branchURL: remoteHostInfoByRepoRoot[repoRoot]??.branchURL(branch: branch),
                pullRequest: nil,
                reviewChips: []
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

    private func resolveGitHubRepository(path: String, branch: String) async -> GitHubRepositoryResolution {
        let key = RepositoryKey(repoRoot: path, branch: branch)
        if let cached = githubRepositoryByKey[key] {
            return cached
        }

        let resolution = await discoverGitHubRepository(path: path, branch: branch)
        if resolution != .unresolved {
            githubRepositoryByKey[key] = resolution
        }
        return resolution
    }

    private func discoverGitHubRepository(path: String, branch: String) async -> GitHubRepositoryResolution {
        var hadLookupFailure = false

        if let upstreamRemote = await resolveUpstreamRemoteName(path: path, branch: branch),
           case .repository(let repository) = await resolveGitHubRepositorySpecifier(
            forRemoteNamed: upstreamRemote,
            path: path
           ) {
            return .repository(repository)
        }

        switch await resolveGitHubRepositorySpecifier(forRemoteNamed: "origin", path: path) {
        case .repository(let repository):
            return .repository(repository)
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
            return hadLookupFailure ? .unresolved : .noGitHubRepository
        }

        let remoteNames = String(decoding: remoteListResult.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "origin" }

        for remoteName in remoteNames {
            switch await resolveGitHubRepositorySpecifier(forRemoteNamed: remoteName, path: path) {
            case .repository(let repository):
                return .repository(repository)
            case .failed:
                hadLookupFailure = true
            case .notGitHub:
                break
            }
        }

        return hadLookupFailure ? .unresolved : .noGitHubRepository
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
        path: String
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

        if remoteHostInfoByRepoRoot[path] == nil,
           let hostInfo = GitRemoteHostInfo.parse(remoteURL: remoteURL) {
            remoteHostInfoByRepoRoot[path] = hostInfo
        }

        if let repository = githubRepositorySpecifier(from: remoteURL) {
            return .repository(repository)
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

    private func decodeChecks(from data: Data) -> [PullRequestCheckPayload]? {
        try? JSONDecoder().decode([PullRequestCheckPayload].self, from: data)
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
        checksResult: WorklaneReviewCommandResult
    ) -> [WorklaneReviewChip] {
        var chips = stateChips(for: pullRequest.state)

        guard pullRequest.state == .open || pullRequest.state == .draft else {
            return chips
        }

        guard checksResult.terminationStatus == 0 else {
            if pullRequest.state == .open {
                chips.append(WorklaneReviewChip(text: "Ready", style: .success))
            }
            return chips
        }

        guard let checks = decodeChecks(from: checksResult.stdout), !checks.isEmpty else {
            if pullRequest.state == .open {
                chips.append(WorklaneReviewChip(text: "Ready", style: .success))
            }
            return chips
        }

        let failureCount = checks.filter(isFailingCheck).count
        if failureCount > 0 {
            chips.append(WorklaneReviewChip(
                text: failureCount == 1 ? "1 failing" : "\(failureCount) failing",
                style: .danger
            ))
            return chips
        }

        if checks.contains(where: isPendingCheck) {
            chips.append(WorklaneReviewChip(text: "Running", style: .warning))
            return chips
        }

        chips.append(WorklaneReviewChip(text: "Checks passed", style: .success))
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

    private func isFailingCheck(_ check: PullRequestCheckPayload) -> Bool {
        let bucket = check.bucket?.lowercased()
        let state = check.state?.lowercased()
        return bucket == "fail"
            || bucket == "cancel"
            || state == "failure"
            || state == "failed"
            || state == "cancelled"
            || state == "timed_out"
    }

    private func isPendingCheck(_ check: PullRequestCheckPayload) -> Bool {
        let bucket = check.bucket?.lowercased()
        let state = check.state?.lowercased()
        return bucket == "pending"
            || state == "pending"
            || state == "queued"
            || state == "waiting"
            || state == "requested"
            || state == "in_progress"
    }

    private func isNoPullRequestResult(_ result: WorklaneReviewCommandResult) -> Bool {
        var combinedData = result.stdout
        combinedData.append(result.stderr)
        let combinedOutput = String(decoding: combinedData, as: UTF8.self).lowercased()
        return combinedOutput.contains("no pull requests found")
    }
}

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
    let kind: HostKind

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
            path = "/\(owner)/\(repo)/-/tree/\(encodedBranch)"
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

        return buildFromHostAndPath(host: host, path: url.path, scheme: scheme)
    }

    private static func buildFromHostAndPath(host: String, path: String, scheme: String) -> GitRemoteHostInfo? {
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
            host: host,
            owner: owner,
            repo: repo,
            kind: kind
        )
    }

    private static func hostKind(for host: String) -> HostKind {
        if host == "github.com" || host == "www.github.com" {
            return .github
        }
        if host == "gitlab.com" || host == "www.gitlab.com" {
            return .gitlab
        }
        if host == "bitbucket.org" || host == "www.bitbucket.org" {
            return .bitbucket
        }
        return .unknown
    }
}
