import Foundation
import os

private let reviewLogger = Logger(subsystem: "be.zentty", category: "ReviewState")

struct WorkspaceReviewResolution: Equatable, Sendable {
    enum UpdatePolicy: Equatable, Sendable {
        case replace
        case preserveExistingOnEmpty
    }

    let reviewState: WorkspaceReviewState?
    let inferredArtifact: WorkspaceArtifactLink?
    let updatePolicy: UpdatePolicy

    init(
        reviewState: WorkspaceReviewState?,
        inferredArtifact: WorkspaceArtifactLink?,
        updatePolicy: UpdatePolicy = .replace
    ) {
        self.reviewState = reviewState
        self.inferredArtifact = inferredArtifact
        self.updatePolicy = updatePolicy
    }
}

struct WorkspaceReviewCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

protocol WorkspaceReviewCommandRunning: Sendable {
    func run(arguments: [String], currentDirectoryPath: String) async -> WorkspaceReviewCommandResult
}

struct DefaultWorkspaceReviewCommandRunner: WorkspaceReviewCommandRunning {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func run(arguments: [String], currentDirectoryPath: String) async -> WorkspaceReviewCommandResult {
        await withCheckedContinuation { continuation in
            let environment = self.environment
            DispatchQueue.global(qos: .utility).async {
                guard let command = arguments.first,
                      let executablePath = Self.resolveExecutablePath(for: command, environment: environment)
                else {
                    let missingCommand = arguments.first ?? "<missing>"
                    continuation.resume(returning: WorkspaceReviewCommandResult(
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
                    continuation.resume(returning: WorkspaceReviewCommandResult(
                        terminationStatus: process.terminationStatus,
                        stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                        stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    ))
                } catch {
                    reviewLogger.debug("Review command failed: \(error.localizedDescription)")
                    continuation.resume(returning: WorkspaceReviewCommandResult(
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
final class WorkspaceReviewStateResolver {
    private struct RepositoryKey: Hashable {
        let path: String
        let branch: String
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

    private let runner: any WorkspaceReviewCommandRunning
    private var cache: [RepositoryKey: WorkspaceReviewResolution] = [:]
    private var repositoryStatusByPath: [String: RepositoryStatus] = [:]
    private var githubOriginByPath: [String: Bool] = [:]
    private var pendingPaths: Set<String> = []
    private var waitingPaneIDsByPath: [String: Set<PaneID>] = [:]

    init(runner: any WorkspaceReviewCommandRunning = DefaultWorkspaceReviewCommandRunner()) {
        self.runner = runner
    }

    func refresh(
        for workspaces: [WorkspaceState],
        update: @escaping (PaneID, WorkspaceReviewResolution) -> Void
    ) {
        for workspace in workspaces {
            for pane in workspace.paneStripState.panes {
                let auxiliaryState = workspace.auxiliaryStateByPaneID[pane.id]
                guard let path = auxiliaryState?.localReviewWorkingDirectory else {
                    continue
                }

                let metadataBranch = preferredBranch(from: auxiliaryState?.metadata?.gitBranch)
                if
                    let metadataBranch,
                    let cached = cache[RepositoryKey(path: path, branch: metadataBranch)]
                {
                    update(pane.id, cached)
                    continue
                }

                waitingPaneIDsByPath[path, default: []].insert(pane.id)
                guard pendingPaths.insert(path).inserted else {
                    continue
                }

                Task { [weak self] in
                    guard let self else {
                        return
                    }

                    let resolution = await self.loadResolution(path: path, preferredBranch: metadataBranch)
                    await MainActor.run {
                        self.pendingPaths.remove(path)
                        if let branch = resolution.reviewState?.branch {
                            self.cache[RepositoryKey(path: path, branch: branch)] = resolution
                        }
                        let paneIDs = self.waitingPaneIDsByPath.removeValue(forKey: path) ?? []
                        paneIDs.forEach { paneID in
                            update(paneID, resolution)
                        }
                    }
                }
            }
        }
    }

    func resolve(path: String, branch: String) async -> WorkspaceReviewResolution {
        guard let sanitizedBranch = preferredBranch(from: branch) ?? WorkspaceContextFormatter.trimmed(branch) else {
            return emptyResolution()
        }

        let key = RepositoryKey(path: path, branch: sanitizedBranch)
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
        path: String,
        preferredBranch: String?,
        paneID: PaneID,
        forceReload: Bool = false,
        update: @escaping (PaneID, WorkspaceReviewResolution) -> Void
    ) {
        if !forceReload,
           let branch = self.preferredBranch(from: preferredBranch),
           let cached = cache[RepositoryKey(path: path, branch: branch)] {
            update(paneID, cached)
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            let resolution = await self.loadResolution(
                path: path,
                preferredBranch: preferredBranch,
                forceReload: forceReload
            )
            await MainActor.run {
                if let branch = resolution.reviewState?.branch {
                    self.cache[RepositoryKey(path: path, branch: branch)] = resolution
                }
                update(paneID, resolution)
            }
        }
    }

    private func loadResolution(
        path: String,
        preferredBranch: String?,
        forceReload: Bool = false
    ) async -> WorkspaceReviewResolution {
        guard await isRepository(path: path) else {
            return emptyResolution()
        }

        let branch: String
        if let sanitizedPreferredBranch = self.preferredBranch(from: preferredBranch) {
            branch = sanitizedPreferredBranch
        } else if let derivedBranch = await resolveCurrentBranch(path: path) {
            branch = derivedBranch
        } else {
            return WorkspaceReviewResolution(
                reviewState: nil,
                inferredArtifact: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        }

        let key = RepositoryKey(path: path, branch: branch)
        if !forceReload, let cached = cache[key] {
            return cached
        }

        let resolution = await loadPullRequestResolution(
            path: path,
            branch: branch,
            fallback: cache[key]
        )
        if resolution.reviewState?.branch != nil {
            cache[key] = resolution
        }
        return resolution
    }

    private func loadPullRequestResolution(
        path: String,
        branch: String,
        fallback: WorkspaceReviewResolution?
    ) async -> WorkspaceReviewResolution {
        guard await hasGitHubOrigin(path: path) else {
            return branchOnlyResolution(branch: branch)
        }

        let pullRequestResult = await runCommand(
            arguments: ["gh", "pr", "view", branch, "--json", "number,url,isDraft,state"],
            currentDirectoryPath: path
        )

        if pullRequestResult.terminationStatus != 0 {
            if isNoPullRequestResult(pullRequestResult) {
                return branchOnlyResolution(branch: branch)
            }

            if let fallback {
                return fallback
            }

            return WorkspaceReviewResolution(
                reviewState: nil,
                inferredArtifact: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        }

        guard let pullRequestPayload = decodePullRequest(from: pullRequestResult.stdout) else {
            if let fallback {
                return fallback
            }

            return WorkspaceReviewResolution(
                reviewState: nil,
                inferredArtifact: nil,
                updatePolicy: .preserveExistingOnEmpty
            )
        }

        let pullRequest = WorkspacePullRequestSummary(
            number: pullRequestPayload.number,
            url: pullRequestPayload.url,
            state: pullRequestState(from: pullRequestPayload)
        )
        let checksResult = await runCommand(
            arguments: ["gh", "pr", "checks", branch, "--json", "bucket,state,name,link"],
            currentDirectoryPath: path
        )
        let reviewChips = reviewChips(for: pullRequest, checksResult: checksResult)
        let inferredArtifact = pullRequest.url.map { url in
            WorkspaceArtifactLink(
                kind: .pullRequest,
                label: "PR #\(pullRequest.number)",
                url: url,
                isExplicit: false
            )
        }

        return WorkspaceReviewResolution(
            reviewState: WorkspaceReviewState(
                branch: branch,
                pullRequest: pullRequest,
                reviewChips: reviewChips
            ),
            inferredArtifact: inferredArtifact
        )
    }

    private func resolveCurrentBranch(path: String) async -> String? {
        let branchResult = await runCommand(
            arguments: ["git", "branch", "--show-current"],
            currentDirectoryPath: path
        )

        guard branchResult.terminationStatus == 0 else {
            return nil
        }

        return WorkspaceContextFormatter.trimmed(String(decoding: branchResult.stdout, as: UTF8.self))
    }

    private func preferredBranch(from value: String?) -> String? {
        WorkspaceContextFormatter.displayBranch(value)
    }

    private func emptyResolution() -> WorkspaceReviewResolution {
        WorkspaceReviewResolution(
            reviewState: nil,
            inferredArtifact: nil,
            updatePolicy: .preserveExistingOnEmpty
        )
    }

    private func branchOnlyResolution(branch: String) -> WorkspaceReviewResolution {
        WorkspaceReviewResolution(
            reviewState: WorkspaceReviewState(
                branch: branch,
                pullRequest: nil,
                reviewChips: []
            ),
            inferredArtifact: nil
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

        let gitDirectory = WorkspaceContextFormatter.trimmed(String(decoding: result.stdout, as: UTF8.self)) ?? ".git"
        repositoryStatusByPath[path] = .repository(gitDirectory: gitDirectory)
        return true
    }

    private func hasGitHubOrigin(path: String) async -> Bool {
        if let cached = githubOriginByPath[path] {
            return cached
        }

        let result = await runCommand(
            arguments: ["git", "remote", "get-url", "origin"],
            currentDirectoryPath: path
        )
        guard result.terminationStatus == 0 else {
            githubOriginByPath[path] = false
            return false
        }

        guard let remoteURL = WorkspaceContextFormatter.trimmed(String(decoding: result.stdout, as: UTF8.self)) else {
            githubOriginByPath[path] = false
            return false
        }
        let isGitHubOrigin = isGitHubRemoteURL(remoteURL)
        githubOriginByPath[path] = isGitHubOrigin
        return isGitHubOrigin
    }

    private func isGitHubRemoteURL(_ value: String) -> Bool {
        let remote = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !remote.isEmpty else {
            return false
        }

        if remote.hasPrefix("git@github.com:") || remote.hasPrefix("ssh://git@github.com/") {
            return true
        }

        if let url = URL(string: remote), let host = url.host?.lowercased() {
            return host == "github.com" || host == "www.github.com"
        }

        return false
    }

    private func runCommand(
        arguments: [String],
        currentDirectoryPath: String
    ) async -> WorkspaceReviewCommandResult {
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
        result: WorkspaceReviewCommandResult
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

    private func pullRequestState(from payload: PullRequestPayload) -> WorkspacePullRequestState {
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
        for pullRequest: WorkspacePullRequestSummary,
        checksResult: WorkspaceReviewCommandResult
    ) -> [WorkspaceReviewChip] {
        var chips = stateChips(for: pullRequest.state)

        guard pullRequest.state == .open || pullRequest.state == .draft else {
            return chips
        }

        guard checksResult.terminationStatus == 0 else {
            if pullRequest.state == .open {
                chips.append(WorkspaceReviewChip(text: "Ready", style: .success))
            }
            return chips
        }

        guard let checks = decodeChecks(from: checksResult.stdout), !checks.isEmpty else {
            if pullRequest.state == .open {
                chips.append(WorkspaceReviewChip(text: "Ready", style: .success))
            }
            return chips
        }

        let failureCount = checks.filter(isFailingCheck).count
        if failureCount > 0 {
            chips.append(WorkspaceReviewChip(
                text: failureCount == 1 ? "1 failing" : "\(failureCount) failing",
                style: .danger
            ))
            return chips
        }

        if checks.contains(where: isPendingCheck) {
            chips.append(WorkspaceReviewChip(text: "Running", style: .warning))
            return chips
        }

        chips.append(WorkspaceReviewChip(text: "Checks passed", style: .success))
        return chips
    }

    private func stateChips(for state: WorkspacePullRequestState) -> [WorkspaceReviewChip] {
        switch state {
        case .draft:
            return [WorkspaceReviewChip(text: "Draft", style: .info)]
        case .open:
            return []
        case .merged:
            return [WorkspaceReviewChip(text: "Merged", style: .success)]
        case .closed:
            return [WorkspaceReviewChip(text: "Closed", style: .neutral)]
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

    private func isNoPullRequestResult(_ result: WorkspaceReviewCommandResult) -> Bool {
        var combinedData = result.stdout
        combinedData.append(result.stderr)
        let combinedOutput = String(decoding: combinedData, as: UTF8.self).lowercased()
        return combinedOutput.contains("no pull requests found")
    }
}
