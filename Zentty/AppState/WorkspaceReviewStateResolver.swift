import Foundation

struct WorkspaceReviewResolution: Equatable, Sendable {
    let reviewState: WorkspaceReviewState?
    let inferredArtifact: WorkspaceArtifactLink?
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
    func run(arguments: [String], currentDirectoryPath: String) async -> WorkspaceReviewCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)

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
                    continuation.resume(returning: WorkspaceReviewCommandResult(
                        terminationStatus: -1,
                        stdout: Data(),
                        stderr: Data(error.localizedDescription.utf8)
                    ))
                }
            }
        }
    }
}

@MainActor
final class WorkspaceReviewStateResolver {
    private struct RepositoryKey: Hashable {
        let path: String
        let branch: String
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
                guard let metadata = workspace.metadataByPaneID[pane.id] else {
                    continue
                }
                guard let path = WorkspaceContextFormatter.resolvedWorkingDirectory(for: metadata) else {
                    continue
                }

                let metadataBranch = preferredBranch(from: metadata.gitBranch)
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
        let key = RepositoryKey(path: path, branch: branch)
        if let cached = cache[key] {
            return cached
        }

        let resolution = await loadPullRequestResolution(path: path, branch: branch)
        cache[key] = resolution
        return resolution
    }

    private func loadResolution(path: String, preferredBranch: String?) async -> WorkspaceReviewResolution {
        let branch: String
        if let sanitizedPreferredBranch = self.preferredBranch(from: preferredBranch) {
            branch = sanitizedPreferredBranch
        } else if let derivedBranch = await resolveCurrentBranch(path: path) {
            branch = derivedBranch
        } else {
            return WorkspaceReviewResolution(reviewState: nil, inferredArtifact: nil)
        }

        let key = RepositoryKey(path: path, branch: branch)
        if let cached = cache[key] {
            return cached
        }

        return await loadPullRequestResolution(path: path, branch: branch)
    }

    private func loadPullRequestResolution(path: String, branch: String) async -> WorkspaceReviewResolution {
        let pullRequestResult = await runner.run(
            arguments: ["gh", "pr", "view", branch, "--json", "number,url,isDraft,state"],
            currentDirectoryPath: path
        )

        if pullRequestResult.terminationStatus != 0 {
            if isNoPullRequestResult(pullRequestResult) {
                return WorkspaceReviewResolution(
                    reviewState: WorkspaceReviewState(
                        branch: branch,
                        pullRequest: nil,
                        reviewChips: [WorkspaceReviewChip(text: "No PR", style: .neutral)]
                    ),
                    inferredArtifact: nil
                )
            }

            return WorkspaceReviewResolution(reviewState: nil, inferredArtifact: nil)
        }

        guard let pullRequestPayload = decodePullRequest(from: pullRequestResult.stdout) else {
            return WorkspaceReviewResolution(reviewState: nil, inferredArtifact: nil)
        }

        let pullRequest = WorkspacePullRequestSummary(
            number: pullRequestPayload.number,
            url: pullRequestPayload.url,
            state: pullRequestState(from: pullRequestPayload)
        )
        let checksResult = await runner.run(
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
        let branchResult = await runner.run(
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
