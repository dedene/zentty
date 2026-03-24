import Foundation

enum PaneGitReference: Equatable, Sendable {
    case branch(String)
    case detached(String)
}

struct PaneGitContext: Equatable, Sendable {
    var workingDirectory: String
    var repositoryRoot: String?
    var reference: PaneGitReference?

    var repoRoot: String? { repositoryRoot }

    var branchName: String? {
        guard case .branch(let branch)? = reference else {
            return nil
        }
        return WorkspaceContextFormatter.trimmed(branch)
    }

    var lookupBranch: String? {
        branchName
    }

    var branchDisplayText: String {
        switch reference {
        case .branch(let branch):
            return WorkspaceContextFormatter.trimmed(branch) ?? ""
        case .detached(let sha):
            let shortSHA = WorkspaceContextFormatter.trimmed(sha) ?? ""
            return shortSHA.isEmpty ? "" : "\(shortSHA) (detached)"
        case nil:
            return ""
        }
    }

    var isDetached: Bool {
        if case .detached? = reference {
            return true
        }
        return false
    }
}

enum PanePresentationPhase: String, Equatable, Sendable {
    case idle
    case starting
    case running
    case needsInput
    case completed
    case unresolvedStop
}

struct PanePresentationState: Equatable, Sendable {
    var cwd: String?
    var repoRoot: String?
    var branch: String?
    var branchDisplayText: String?
    var lookupBranch: String?
    var identityText: String?
    var contextText: String?
    var rememberedTitle: String?
    var recognizedTool: AgentTool?
    var runtimePhase: PanePresentationPhase = .idle
    var statusText: String?
    var pullRequest: WorkspacePullRequestSummary?
    var reviewChips: [WorkspaceReviewChip] = []
    var attentionArtifactLink: WorkspaceArtifactLink?
    var updatedAt: Date = .distantPast
    var isWorking = false

    var hasResolvedIdentity: Bool {
        identityText != nil || contextText != nil || rememberedTitle != nil || branch != nil || cwd != nil
    }

    var visibleIdentityText: String? {
        identityText ?? contextText
    }

    var prLookupKey: String? {
        guard let repoRoot, let lookupBranch else {
            return nil
        }

        return "\(repoRoot)::\(lookupBranch)"
    }
}

struct PaneRawState: Equatable, Sendable {
    var metadata: TerminalMetadata?
    var shellContext: PaneShellContext?
    var agentStatus: PaneAgentStatus?
    var terminalProgress: TerminalProgressReport?
    var reviewState: WorkspaceReviewState?
    var gitContext: PaneGitContext?
}

enum PanePresentationNormalizer {
    static func normalize(
        paneTitle: String?,
        raw: PaneRawState,
        previous: PanePresentationState?
    ) -> PanePresentationState {
        let cwd = resolvedWorkingDirectory(from: raw)
        let gitContext = normalizedGitContext(raw.gitContext, fallbackWorkingDirectory: cwd)
        let repoRoot = gitContext?.repoRoot
        let branchDisplayText = WorkspaceContextFormatter.trimmed(gitContext?.branchDisplayText)
            ?? provisionalShellBranchDisplayText(from: raw.shellContext)
        let lookupBranch = gitContext?.lookupBranch
        let cwdLabel = cwd.flatMap { WorkspaceContextFormatter.formattedWorkingDirectory($0, branch: nil) }
        let contextText = [branchDisplayText, cwdLabel]
            .compactMap(WorkspaceContextFormatter.trimmed)
            .joined(separator: " · ")
            .nilIfEmpty
        let recognizedTool = raw.agentStatus?.tool ?? AgentToolRecognizer.recognize(metadata: raw.metadata)
        let latestMeaningfulTitle = meaningfulTitle(
            metadata: raw.metadata,
            fallbackTitle: paneTitle,
            recognizedTool: recognizedTool
        )
        let rememberedTitle = latestMeaningfulTitle ?? previous?.rememberedTitle
        let runtimePhase = normalizedRuntimePhase(from: raw, recognizedTool: recognizedTool)
        let statusText = visibleStatusText(for: runtimePhase)
        let pullRequest = derivePullRequest(
            from: raw,
            repoRoot: repoRoot,
            lookupBranch: lookupBranch
        )
        let reviewChips = deriveReviewChips(
            reviewState: raw.reviewState,
            pullRequest: pullRequest,
            repoRoot: repoRoot,
            lookupBranch: lookupBranch
        )
        let terminalFallback = WorkspaceContextFormatter.displayTerminalIdentity(
            for: raw.metadata,
            fallbackTitle: paneTitle
        ) ?? WorkspaceContextFormatter.trimmed(paneTitle)
        let identityText = WorkspaceContextFormatter.trimmed(rememberedTitle)
            ?? contextText
            ?? terminalFallback
            ?? "Shell"
        let attentionArtifactLink = deriveAttentionArtifact(from: raw.agentStatus?.artifactLink)
        let updatedAt = raw.agentStatus?.updatedAt ?? .distantPast

        return PanePresentationState(
            cwd: cwd,
            repoRoot: repoRoot,
            branch: gitContext?.branchName,
            branchDisplayText: branchDisplayText,
            lookupBranch: lookupBranch,
            identityText: identityText,
            contextText: contextText,
            rememberedTitle: rememberedTitle,
            recognizedTool: recognizedTool,
            runtimePhase: runtimePhase,
            statusText: statusText,
            pullRequest: pullRequest,
            reviewChips: reviewChips,
            attentionArtifactLink: attentionArtifactLink,
            updatedAt: updatedAt,
            isWorking: runtimePhase == .running
        )
    }

    private static func provisionalShellBranchDisplayText(from shellContext: PaneShellContext?) -> String? {
        guard shellContext?.scope == .local else {
            return nil
        }

        return WorkspaceContextFormatter.displayBranch(shellContext?.gitBranch)
    }

    private static func resolvedWorkingDirectory(from raw: PaneRawState) -> String? {
        WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: raw.metadata,
            shellContext: raw.shellContext
        ) ?? raw.gitContext.flatMap { WorkspaceContextFormatter.trimmed($0.workingDirectory) }
    }

    private static func normalizedGitContext(
        _ gitContext: PaneGitContext?,
        fallbackWorkingDirectory: String?
    ) -> PaneGitContext? {
        guard let gitContext else {
            guard let fallbackWorkingDirectory else {
                return nil
            }
            return PaneGitContext(
                workingDirectory: fallbackWorkingDirectory,
                repositoryRoot: nil,
                reference: nil
            )
        }

        let workingDirectory = WorkspaceContextFormatter.trimmed(gitContext.workingDirectory)
            ?? fallbackWorkingDirectory
        guard let workingDirectory else {
            return nil
        }

        return PaneGitContext(
            workingDirectory: workingDirectory,
            repositoryRoot: WorkspaceContextFormatter.trimmed(gitContext.repositoryRoot),
            reference: gitContext.reference
        )
    }

    private static func normalizedRuntimePhase(
        from raw: PaneRawState,
        recognizedTool: AgentTool?
    ) -> PanePresentationPhase {
        if let agentState = raw.agentStatus?.state {
            switch agentState {
            case .starting:
                return .starting
            case .running:
                return .running
            case .needsInput:
                return .needsInput
            case .completed:
                return .completed
            case .unresolvedStop:
                return .unresolvedStop
            }
        }

        if recognizedTool == nil, raw.terminalProgress?.state.indicatesActivity == true {
            return .running
        }

        return .idle
    }

    private static func visibleStatusText(for phase: PanePresentationPhase) -> String? {
        switch phase {
        case .idle, .starting:
            return nil
        case .running:
            return "Running"
        case .needsInput:
            return "Needs input"
        case .completed:
            return "Completed"
        case .unresolvedStop:
            return "Stopped early"
        }
    }

    private static func meaningfulTitle(
        metadata: TerminalMetadata?,
        fallbackTitle: String?,
        recognizedTool: AgentTool?
    ) -> String? {
        let candidates = [
            WorkspaceContextFormatter.normalizeDisplayIdentity(metadata?.title),
            WorkspaceContextFormatter.normalizeDisplayIdentity(metadata?.processName),
        ]

        for candidate in candidates {
            guard let candidate else {
                continue
            }
            guard rawShellLabelLooksMeaningful(candidate) else {
                continue
            }
            guard WorkspaceContextFormatter.displayMeaningfulTerminalIdentity(
                for: TerminalMetadata(
                    title: candidate,
                    currentWorkingDirectory: nil,
                    processName: nil,
                    gitBranch: nil
                )
            ) != nil else {
                continue
            }
            if matchesRecognizedTool(candidate, tool: recognizedTool) {
                continue
            }
            return candidate
        }

        let normalizedFallbackTitle = WorkspaceContextFormatter.normalizeDisplayIdentity(fallbackTitle)
        if let normalizedFallbackTitle,
           rawShellLabelLooksMeaningful(normalizedFallbackTitle),
           matchesRecognizedTool(normalizedFallbackTitle, tool: recognizedTool) == false {
            return normalizedFallbackTitle
        }

        return nil
    }

    private static func rawShellLabelLooksMeaningful(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return false
        }

        let genericPaneTitles: Set<String> = [
            "shell",
            "shell pane",
            "git",
            "agent",
            "terminal",
            "pane",
        ]
        return genericPaneTitles.contains(normalized) == false
    }

    private static func matchesRecognizedTool(_ value: String, tool: AgentTool?) -> Bool {
        guard let tool else {
            return false
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch tool {
        case .claudeCode:
            return ["claude", "claude code"].contains(normalized)
        case .codex:
            return ["codex"].contains(normalized)
        case .openCode:
            return ["opencode", "open code"].contains(normalized)
        case .custom(let name):
            return normalized == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func derivePullRequest(
        from raw: PaneRawState,
        repoRoot: String?,
        lookupBranch: String?
    ) -> WorkspacePullRequestSummary? {
        guard repoRoot != nil, lookupBranch != nil else {
            return nil
        }
        return raw.reviewState?.pullRequest
    }

    private static func deriveReviewChips(
        reviewState: WorkspaceReviewState?,
        pullRequest: WorkspacePullRequestSummary?,
        repoRoot: String?,
        lookupBranch: String?
    ) -> [WorkspaceReviewChip] {
        guard repoRoot != nil, lookupBranch != nil else {
            return []
        }

        let reviewChips = reviewState?.reviewChips ?? []
        guard reviewChips.isEmpty, let pullRequest else {
            return reviewChips
        }

        switch pullRequest.state {
        case .draft:
            return [WorkspaceReviewChip(text: "Draft", style: .info)]
        case .open:
            return [WorkspaceReviewChip(text: "Ready", style: .success)]
        case .merged:
            return [WorkspaceReviewChip(text: "Merged", style: .success)]
        case .closed:
            return [WorkspaceReviewChip(text: "Closed", style: .neutral)]
        }
    }

    private static func deriveAttentionArtifact(from artifact: WorkspaceArtifactLink?) -> WorkspaceArtifactLink? {
        guard artifact?.kind != .pullRequest else {
            return nil
        }

        return artifact
    }
}

struct PaneAuxiliaryState: Equatable, Sendable {
    var raw: PaneRawState
    var presentation: PanePresentationState

    init(
        raw: PaneRawState = PaneRawState(),
        presentation: PanePresentationState = PanePresentationState()
    ) {
        self.raw = raw
        self.presentation = presentation
    }

    init(
        metadata: TerminalMetadata? = nil,
        shellContext: PaneShellContext? = nil,
        agentStatus: PaneAgentStatus? = nil,
        terminalProgress: TerminalProgressReport? = nil,
        reviewState: WorkspaceReviewState? = nil,
        gitContext: PaneGitContext? = nil,
        presentation: PanePresentationState = PanePresentationState()
    ) {
        self.raw = PaneRawState(
            metadata: metadata,
            shellContext: shellContext,
            agentStatus: agentStatus,
            terminalProgress: terminalProgress,
            reviewState: reviewState,
            gitContext: gitContext
        )
        self.presentation = presentation
    }

    var metadata: TerminalMetadata? {
        get { raw.metadata }
        set { raw.metadata = newValue }
    }

    var shellContext: PaneShellContext? {
        get { raw.shellContext }
        set { raw.shellContext = newValue }
    }

    var agentStatus: PaneAgentStatus? {
        get { raw.agentStatus }
        set { raw.agentStatus = newValue }
    }

    var terminalProgress: TerminalProgressReport? {
        get { raw.terminalProgress }
        set { raw.terminalProgress = newValue }
    }

    var reviewState: WorkspaceReviewState? {
        get { raw.reviewState }
        set { raw.reviewState = newValue }
    }

    var gitContext: PaneGitContext? {
        get { raw.gitContext }
        set { raw.gitContext = newValue }
    }

    var isWorking: Bool {
        presentation.isWorking
    }

    var localReviewWorkingDirectory: String? {
        guard raw.shellContext?.scope != .remote else {
            return nil
        }

        let currentWorkingDirectory = WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: raw.metadata,
            shellContext: raw.shellContext
        )

        return currentWorkingDirectory ?? raw.gitContext?.workingDirectory
    }
}

extension WorkspacePaneContext {
    var presentation: PanePresentationState {
        if let auxiliaryState, auxiliaryState.presentation.hasResolvedIdentity {
            return auxiliaryState.presentation
        }

        return PanePresentationNormalizer.normalize(
            paneTitle: pane.title,
            raw: auxiliaryState?.raw ?? PaneRawState(),
            previous: auxiliaryState?.presentation
        )
    }
}

protocol PaneGitContextResolving: Sendable {
    func resolve(for workingDirectory: String) async -> PaneGitContext
}

extension PaneGitContextResolving {
    func resolve(path: String) async -> PaneGitContext? {
        guard WorkspaceContextFormatter.trimmed(path) != nil else {
            return nil
        }

        return await resolve(for: path)
    }
}

struct WorkspaceGitContextResolver: PaneGitContextResolving {
    func resolve(for workingDirectory: String) async -> PaneGitContext {
        guard let workingDirectory = WorkspaceContextFormatter.trimmed(workingDirectory) else {
            return PaneGitContext(
                workingDirectory: "",
                repositoryRoot: nil,
                reference: nil
            )
        }

        guard let rawRepositoryRoot = await gitOutput(
            ["rev-parse", "--show-toplevel"],
            currentDirectoryPath: workingDirectory
        ) else {
            return PaneGitContext(
                workingDirectory: workingDirectory,
                repositoryRoot: nil,
                reference: nil
            )
        }

        let repositoryRoot = canonicalRepositoryRoot(rawRepositoryRoot)

        let reference: PaneGitReference?
        if let branch = await gitOutput(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            currentDirectoryPath: workingDirectory
        ) {
            if branch == "HEAD" {
                reference = await gitOutput(
                    ["rev-parse", "--short=7", "HEAD"],
                    currentDirectoryPath: workingDirectory
                ).map(PaneGitReference.detached)
            } else {
                reference = .branch(branch)
            }
        } else {
            reference = nil
        }

        return PaneGitContext(
            workingDirectory: workingDirectory,
            repositoryRoot: repositoryRoot,
            reference: reference
        )
    }

    private func gitOutput(
        _ arguments: [String],
        currentDirectoryPath: String
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git"] + arguments
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)

                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(returning: WorkspaceContextFormatter.trimmed(output))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func canonicalRepositoryRoot(_ value: String) -> String {
        URL(fileURLWithPath: value, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
