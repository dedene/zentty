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
        return WorklaneContextFormatter.trimmed(branch)
    }

    var lookupBranch: String? {
        branchName
    }

    var branchDisplayText: String {
        switch reference {
        case .branch(let branch):
            return WorklaneContextFormatter.trimmed(branch) ?? ""
        case .detached(let sha):
            let shortSHA = WorklaneContextFormatter.trimmed(sha) ?? ""
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
    case unresolvedStop
}

enum PaneInteractionKind: String, Equatable, Sendable {
    case approval
    case question
    case decision
    case auth
    case genericInput = "generic-input"
}

extension PaneInteractionKind {
    init?(_ kind: PaneAgentInteractionKind) {
        switch kind {
        case .none:
            return nil
        case .approval:
            self = .approval
        case .question:
            self = .question
        case .decision:
            self = .decision
        case .auth:
            self = .auth
        case .genericInput:
            self = .genericInput
        }
    }

    var defaultLabel: String {
        switch self {
        case .approval:
            return "Requires approval"
        case .question:
            return "Needs decision"
        case .decision:
            return "Needs decision"
        case .auth:
            return "Needs sign-in"
        case .genericInput:
            return "Needs input"
        }
    }

    var defaultSymbolName: String? {
        switch self {
        case .approval:
            return "checkmark.shield"
        case .question:
            return "list.bullet"
        case .decision:
            return "list.bullet"
        case .auth:
            return "key.fill"
        case .genericInput:
            return "ellipsis.circle"
        }
    }
}

struct PanePresentationState: Equatable, Sendable {
    var cwd: String?
    var repoRoot: String?
    var branch: String?
    var branchDisplayText: String?
    var lookupBranch: String?
    var branchURL: URL?
    var identityText: String?
    var contextText: String?
    var rememberedTitle: String?
    var recognizedTool: AgentTool?
    var runtimePhase: PanePresentationPhase = .idle
    var statusText: String?
    var pullRequest: WorklanePullRequestSummary?
    var reviewChips: [WorklaneReviewChip] = []
    var attentionArtifactLink: WorklaneArtifactLink?
    var updatedAt: Date = .distantPast
    var isWorking = false
    var isReady = false
    var statusSymbolName: String?
    var interactionKind: PaneInteractionKind?
    var interactionLabel: String?
    var interactionSymbolName: String?
    var taskProgress: PaneAgentTaskProgress? = nil

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
    var agentReducerState: PaneAgentReducerState = .init()
    var shellActivityState: PaneShellActivityState = .unknown
    var hasCommandHistory = false
    var terminalProgress: TerminalProgressReport?
    var reviewState: WorklaneReviewState?
    var gitContext: PaneGitContext?
    var wantsReadyStatus = false
    var showsReadyStatus = false
    var codexTitleIdleSuppressionUntil: Date?
    var lastDesktopNotificationText: String?
    var lastDesktopNotificationDate: Date?
}

struct PaneTerminalLocationSnapshot: Equatable, Sendable {
    let scope: PaneShellContextScope?
    let workingDirectory: String?
    let isBootstrapOnly: Bool
}

enum PaneTerminalLocationResolver {
    static func snapshot(
        metadata: TerminalMetadata?,
        shellContext: PaneShellContext?,
        requestWorkingDirectory: String? = nil
    ) -> PaneTerminalLocationSnapshot {
        let metadataWorkingDirectory = WorklaneContextFormatter.trimmed(metadata?.currentWorkingDirectory)
        let contextWorkingDirectory = WorklaneContextFormatter.trimmed(shellContext?.path)
        let bootstrapWorkingDirectory = WorklaneContextFormatter.trimmed(requestWorkingDirectory)

        let terminalWorkingDirectory: String?
        if shellContext?.scope == .local {
            terminalWorkingDirectory = localWorkingDirectory(
                metadataWorkingDirectory: metadataWorkingDirectory,
                contextWorkingDirectory: contextWorkingDirectory,
                bootstrapWorkingDirectory: bootstrapWorkingDirectory
            )
        } else {
            terminalWorkingDirectory = metadataWorkingDirectory ?? contextWorkingDirectory
        }

        if let terminalWorkingDirectory {
            return PaneTerminalLocationSnapshot(
                scope: shellContext?.scope,
                workingDirectory: terminalWorkingDirectory,
                isBootstrapOnly: false
            )
        }

        return PaneTerminalLocationSnapshot(
            scope: shellContext?.scope,
            workingDirectory: bootstrapWorkingDirectory,
            isBootstrapOnly: bootstrapWorkingDirectory != nil
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func localWorkingDirectory(
        metadataWorkingDirectory: String?,
        contextWorkingDirectory: String?,
        bootstrapWorkingDirectory: String?
    ) -> String? {
        guard let metadataWorkingDirectory else {
            return contextWorkingDirectory ?? bootstrapWorkingDirectory
        }

        guard let contextWorkingDirectory else {
            return metadataWorkingDirectory
        }

        if standardizedPath(metadataWorkingDirectory) == standardizedPath(contextWorkingDirectory) {
            return metadataWorkingDirectory
        }

        if let bootstrapWorkingDirectory,
           standardizedPath(contextWorkingDirectory) == standardizedPath(bootstrapWorkingDirectory) {
            return metadataWorkingDirectory
        }

        return contextWorkingDirectory
    }
}

enum PanePresentationNormalizer {
    static func normalize(
        paneTitle: String?,
        raw: PaneRawState,
        previous: PanePresentationState?,
        sessionRequestWorkingDirectory: String? = nil
    ) -> PanePresentationState {
        let cwd = resolvedWorkingDirectory(
            from: raw,
            sessionRequestWorkingDirectory: sessionRequestWorkingDirectory
        )
        let gitContext = normalizedGitContext(raw.gitContext, fallbackWorkingDirectory: cwd)
        let repoRoot = gitContext?.repoRoot
        let branchDisplayText = WorklaneContextFormatter.trimmed(gitContext?.branchDisplayText)
            ?? provisionalShellBranchDisplayText(from: raw.shellContext)
        let lookupBranch = gitContext?.lookupBranch
        let cwdLabel = cwd.flatMap { WorklaneContextFormatter.formattedWorkingDirectory($0, branch: nil) }
        let contextText = [branchDisplayText, cwdLabel]
            .compactMap(WorklaneContextFormatter.trimmed)
            .joined(separator: " · ")
            .nilIfEmpty
        let recognizedTool = raw.agentStatus?.tool ?? AgentToolRecognizer.recognize(metadata: raw.metadata)
        let latestMeaningfulTitle = meaningfulTitle(
            metadata: raw.metadata,
            fallbackTitle: paneTitle,
            recognizedTool: recognizedTool
        )
        let rememberedTitle: String?
        if let latestMeaningfulTitle {
            rememberedTitle = latestMeaningfulTitle
        } else if recognizedTool != nil {
            rememberedTitle = previous?.rememberedTitle
        } else {
            rememberedTitle = nil
        }
        let titlePhase = codexTitlePhase(from: raw.metadata, recognizedTool: recognizedTool)
        let copilotTitleNeedsInput = copilotTitleIndicatesNeedsInput(
            metadata: raw.metadata
        )
        let runtimePhase = normalizedRuntimePhase(
            from: raw,
            recognizedTool: recognizedTool,
            titlePhase: titlePhase,
            copilotTitleNeedsInput: copilotTitleNeedsInput
        )
        let agentInteractionKind: PaneAgentInteractionKind = copilotTitleNeedsInput
            ? .question
            : (raw.agentStatus?.interactionKind ?? .none)
        let codexBackgroundWait = recognizedTool == .codex
            && TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: raw.metadata?.title) == .backgroundWait
        let showsReadyStatus = raw.showsReadyStatus && !codexBackgroundWait
        let hasObservedRunning = raw.agentStatus?.hasObservedRunning == true
            || titlePhase == .running
            || previous?.runtimePhase == .running
        let statusText = visibleStatusText(
            for: runtimePhase,
            interactionKind: agentInteractionKind,
            taskProgress: raw.agentStatus?.taskProgress,
            hasObservedRunning: hasObservedRunning,
            showsReadyStatus: showsReadyStatus,
            suppressIdleLabel: codexBackgroundWait,
            notificationText: raw.lastDesktopNotificationText,
            notificationDate: raw.lastDesktopNotificationDate
        )
        let interactionKind = PaneInteractionKind(agentInteractionKind)
        let interactionLabel: String?
        let interactionSymbolName: String?
        if copilotTitleNeedsInput {
            // Copilot's hook-driven agentStatus is still .idle when the
            // title flips to "Asking ..."; derive labels from the override
            // instead of agentStatus to avoid showing "Idle" next to the
            // needs-input state.
            interactionLabel = agentInteractionKind.statusLabel
            interactionSymbolName = agentInteractionKind.symbolName
        } else {
            interactionLabel = runtimePhase == .needsInput ? raw.agentStatus?.statusLabel : nil
            interactionSymbolName = runtimePhase == .needsInput ? raw.agentStatus?.statusSymbolName : nil
        }
        let statusSymbolName = statusSymbolName(
            for: runtimePhase,
            showsReadyStatus: showsReadyStatus,
            taskProgress: raw.agentStatus?.taskProgress
        )
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
        let terminalFallback = WorklaneContextFormatter.displayTerminalIdentity(
            for: raw.metadata,
            fallbackTitle: paneTitle
        ) ?? WorklaneContextFormatter.trimmed(paneTitle)
        let identityText = WorklaneContextFormatter.trimmed(rememberedTitle)
            ?? contextText
            ?? terminalFallback
            ?? "Shell"
        let attentionArtifactLink = deriveAttentionArtifact(from: raw.agentStatus?.artifactLink)
        let updatedAt = raw.agentStatus?.updatedAt ?? .distantPast
        let branchURL = deriveBranchURL(from: raw, repoRoot: repoRoot, lookupBranch: lookupBranch)
        let isReady = runtimePhase == .idle
            && showsReadyStatus
            && incompleteTaskProgress(raw.agentStatus?.taskProgress) == nil

        return PanePresentationState(
            cwd: cwd,
            repoRoot: repoRoot,
            branch: gitContext?.branchName,
            branchDisplayText: branchDisplayText,
            lookupBranch: lookupBranch,
            branchURL: branchURL,
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
            isWorking: runtimePhase == .running,
            isReady: isReady,
            statusSymbolName: statusSymbolName,
            interactionKind: interactionKind,
            interactionLabel: interactionLabel,
            interactionSymbolName: interactionSymbolName,
            taskProgress: raw.agentStatus?.taskProgress
        )
    }

    private static func provisionalShellBranchDisplayText(from shellContext: PaneShellContext?) -> String? {
        guard shellContext?.scope == .local else {
            return nil
        }

        return WorklaneContextFormatter.displayBranch(shellContext?.gitBranch)
    }

    private static func resolvedWorkingDirectory(
        from raw: PaneRawState,
        sessionRequestWorkingDirectory: String?
    ) -> String? {
        PaneTerminalLocationResolver.snapshot(
            metadata: raw.metadata,
            shellContext: raw.shellContext,
            requestWorkingDirectory: sessionRequestWorkingDirectory
        ).workingDirectory
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

        let workingDirectory = WorklaneContextFormatter.trimmed(gitContext.workingDirectory)
            ?? fallbackWorkingDirectory
        guard let workingDirectory else {
            return nil
        }

        return PaneGitContext(
            workingDirectory: workingDirectory,
            repositoryRoot: WorklaneContextFormatter.trimmed(gitContext.repositoryRoot),
            reference: gitContext.reference
        )
    }

    private static func normalizedRuntimePhase(
        from raw: PaneRawState,
        recognizedTool: AgentTool?,
        titlePhase: PanePresentationPhase?,
        copilotTitleNeedsInput: Bool
    ) -> PanePresentationPhase {
        let context = PresentationReducerContext(
            raw: raw,
            recognizedTool: recognizedTool,
            titlePhase: titlePhase,
            copilotTitleNeedsInput: copilotTitleNeedsInput
        )
        return PresentationPipeline.standard.resolve(context: context)
    }

    /// Detects Copilot CLI's "Asking ..."-style terminal title, emitted
    /// while an askuserquestion-style tool is awaiting user input. Copilot's
    /// LLM generates the phrase itself (gerund form), so we accept a set of
    /// common question verbs as the first word OR the word "question"
    /// anywhere in the title.
    ///
    /// Detection is driven off `metadata.processName` via the full
    /// `AgentTool.resolve(named:)` — not `AgentToolRecognizer.recognize`,
    /// which uses `resolveKnown` and deliberately excludes copilot so the
    /// OSC fallback stays alive when hooks aren't firing. Without this we'd
    /// only match copilot panes that already have an explicit hook-driven
    /// `agentStatus`, defeating the point of the title-based heuristic.
    private static func copilotTitleIndicatesNeedsInput(
        metadata: TerminalMetadata?
    ) -> Bool {
        guard AgentTool.resolve(named: metadata?.processName) == .copilot,
              let rawTitle = WorklaneContextFormatter.trimmed(metadata?.title) else {
            return false
        }
        let normalized = rawTitle.lowercased()
        let firstWord = String(normalized.prefix(while: { $0.isLetter }))
        let questionVerbs: Set<String> = [
            "asking",
            "awaiting",
            "waiting",
            "requesting",
            "prompting",
            "confirming",
            "needing",
        ]
        if questionVerbs.contains(firstWord) {
            return true
        }
        let words = normalized.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains("question")
    }

    private static func codexTitlePhase(
        from metadata: TerminalMetadata?,
        recognizedTool: AgentTool?
    ) -> PanePresentationPhase? {
        if let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata?.title,
            recognizedTool: recognizedTool
        ) {
            switch signature.phase {
            case .running:
                return .running
            case .starting:
                return .starting
            case .needsInput:
                return .needsInput
            case .idle:
                return .idle
            }
        }

        if recognizedTool == .claudeCode,
           let signature = TerminalMetadataChangeClassifier.diagnosticAgentStatusTitleSignature(
               metadata?.title,
               recognizedTool: .claudeCode
           ) {
            switch signature.phase {
            case .running:
                return .running
            case .starting:
                return .starting
            case .needsInput:
                return .needsInput
            case .idle:
                return .idle
            }
        }

        return nil
    }

    private static let notificationVisibilityWindow: TimeInterval = 60

    private static func completionNotificationIndicatesReady(_ notificationText: String?) -> Bool {
        guard let notificationText = WorklaneContextFormatter.trimmed(notificationText)?.lowercased() else {
            return false
        }

        return notificationText.contains("agent run complete")
            || notificationText.contains("agent ready")
            || notificationText.contains("agent turn complete")
    }

    private static func visibleStatusText(
        for phase: PanePresentationPhase,
        interactionKind: PaneAgentInteractionKind,
        taskProgress: PaneAgentTaskProgress?,
        hasObservedRunning: Bool,
        showsReadyStatus: Bool,
        suppressIdleLabel: Bool = false,
        notificationText: String? = nil,
        notificationDate: Date? = nil,
        now: Date = Date()
    ) -> String? {
        switch phase {
        case .idle:
            if let taskProgress = incompleteTaskProgress(taskProgress) {
                return idleStatusText(taskProgress: taskProgress)
            }
            if showsReadyStatus { return "Agent ready" }
            if suppressIdleLabel { return nil }
            if hasObservedRunning { return "Idle" }
            // Show fresh notification text as informational status when no agent state is active.
            if let notificationText, let notificationDate,
               now.timeIntervalSince(notificationDate) < notificationVisibilityWindow {
                return notificationText
            }
            return nil
        case .starting:
            return nil
        case .running:
            return runningStatusText(taskProgress: taskProgress)
        case .needsInput:
            return interactionKind.statusLabel
        case .unresolvedStop:
            return "Stopped early"
        }
    }

    private static func runningStatusText(taskProgress: PaneAgentTaskProgress?) -> String {
        guard let taskProgress = incompleteTaskProgress(taskProgress) else {
            return "Running"
        }

        return "Running (\(taskProgress.doneCount)/\(taskProgress.totalCount))"
    }

    private static func idleStatusText(taskProgress: PaneAgentTaskProgress) -> String {
        "Idle (\(taskProgress.doneCount)/\(taskProgress.totalCount))"
    }

    private static func incompleteTaskProgress(_ taskProgress: PaneAgentTaskProgress?) -> PaneAgentTaskProgress? {
        guard let taskProgress, taskProgress.doneCount < taskProgress.totalCount else {
            return nil
        }

        return taskProgress
    }

    private static func statusSymbolName(
        for phase: PanePresentationPhase,
        showsReadyStatus: Bool,
        taskProgress: PaneAgentTaskProgress?
    ) -> String? {
        guard
            phase == .idle,
            showsReadyStatus,
            incompleteTaskProgress(taskProgress) == nil
        else {
            return nil
        }

        return "checkmark.circle.fill"
    }

    private static func meaningfulTitle(
        metadata: TerminalMetadata?,
        fallbackTitle: String?,
        recognizedTool: AgentTool?
    ) -> String? {
        let candidates = [
            WorklaneContextFormatter.normalizeDisplayIdentity(metadata?.title),
            WorklaneContextFormatter.normalizeDisplayIdentity(metadata?.processName),
        ]

        for candidate in candidates {
            guard let candidate else {
                continue
            }
            let resolvedCandidate: String
            if let displaySubject = TerminalMetadataChangeClassifier.volatileAgentStatusDisplaySubject(
                candidate,
                recognizedTool: recognizedTool
            ) {
                resolvedCandidate = displaySubject
            } else {
                guard TerminalMetadataChangeClassifier.isVolatileAgentStatusTitle(
                    candidate,
                    recognizedTool: recognizedTool
                ) == false else {
                    continue
                }
                resolvedCandidate = candidate
            }
            guard rawShellLabelLooksMeaningful(resolvedCandidate) else {
                continue
            }
            guard let displayIdentity = WorklaneContextFormatter.displayMeaningfulTerminalIdentity(
                for: TerminalMetadata(
                    title: resolvedCandidate,
                    currentWorkingDirectory: nil,
                    processName: nil,
                    gitBranch: nil
                )
            ) else {
                continue
            }
            if matchesRecognizedTool(resolvedCandidate, tool: recognizedTool) {
                continue
            }
            return displayIdentity
        }

        let normalizedFallbackTitle = WorklaneContextFormatter.normalizeDisplayIdentity(fallbackTitle)
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
        case .copilot:
            return ["copilot"].contains(normalized)
        case .openCode:
            return ["opencode", "open code"].contains(normalized)
        case .custom(let name):
            return normalized == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func deriveBranchURL(
        from raw: PaneRawState,
        repoRoot: String?,
        lookupBranch: String?
    ) -> URL? {
        guard repoRoot != nil, lookupBranch != nil else {
            return nil
        }
        return raw.reviewState?.branchURL
    }

    private static func derivePullRequest(
        from raw: PaneRawState,
        repoRoot: String?,
        lookupBranch: String?
    ) -> WorklanePullRequestSummary? {
        guard repoRoot != nil, lookupBranch != nil else {
            return nil
        }
        return raw.reviewState?.pullRequest
    }

    private static func deriveReviewChips(
        reviewState: WorklaneReviewState?,
        pullRequest: WorklanePullRequestSummary?,
        repoRoot: String?,
        lookupBranch: String?
    ) -> [WorklaneReviewChip] {
        guard repoRoot != nil, lookupBranch != nil else {
            return []
        }

        let reviewChips = reviewState?.reviewChips ?? []
        guard reviewChips.isEmpty, let pullRequest else {
            return reviewChips
        }

        switch pullRequest.state {
        case .draft:
            return [WorklaneReviewChip(text: "Draft", style: .info)]
        case .open:
            return [WorklaneReviewChip(text: "Ready", style: .success)]
        case .merged:
            return [WorklaneReviewChip(text: "Merged", style: .success)]
        case .closed:
            return [WorklaneReviewChip(text: "Closed", style: .neutral)]
        }
    }

    private static func deriveAttentionArtifact(from artifact: WorklaneArtifactLink?) -> WorklaneArtifactLink? {
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
        agentReducerState: PaneAgentReducerState = .init(),
        terminalProgress: TerminalProgressReport? = nil,
        reviewState: WorklaneReviewState? = nil,
        gitContext: PaneGitContext? = nil,
        presentation: PanePresentationState = PanePresentationState()
    ) {
        self.raw = PaneRawState(
            metadata: metadata,
            shellContext: shellContext,
            agentStatus: agentStatus,
            agentReducerState: agentReducerState,
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

    var agentReducerState: PaneAgentReducerState {
        get { raw.agentReducerState }
        set { raw.agentReducerState = newValue }
    }

    var shellActivityState: PaneShellActivityState {
        get { raw.shellActivityState }
        set { raw.shellActivityState = newValue }
    }

    var hasCommandHistory: Bool {
        get { raw.hasCommandHistory }
        set { raw.hasCommandHistory = newValue }
    }

    var terminalProgress: TerminalProgressReport? {
        get { raw.terminalProgress }
        set { raw.terminalProgress = newValue }
    }

    var reviewState: WorklaneReviewState? {
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
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: raw.metadata,
            shellContext: raw.shellContext
        )
        guard terminalLocation.scope != .remote else {
            return nil
        }

        return terminalLocation.workingDirectory
    }
}

extension WorklanePaneContext {
    var presentation: PanePresentationState {
        if let auxiliaryState, auxiliaryState.presentation.hasResolvedIdentity {
            return auxiliaryState.presentation
        }

        return PanePresentationNormalizer.normalize(
            paneTitle: pane.title,
            raw: auxiliaryState?.raw ?? PaneRawState(),
            previous: auxiliaryState?.presentation,
            sessionRequestWorkingDirectory: pane.sessionRequest.inheritFromPaneID == nil
                ? pane.sessionRequest.workingDirectory
                : nil
        )
    }
}

protocol PaneGitContextResolving: Sendable {
    func resolve(for workingDirectory: String) async -> PaneGitContext
}

extension PaneGitContextResolving {
    func resolve(path: String) async -> PaneGitContext? {
        guard WorklaneContextFormatter.trimmed(path) != nil else {
            return nil
        }

        return await resolve(for: path)
    }
}

struct WorklaneGitContextResolver: PaneGitContextResolving {
    func resolve(for workingDirectory: String) async -> PaneGitContext {
        guard let workingDirectory = WorklaneContextFormatter.trimmed(workingDirectory) else {
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
                    continuation.resume(returning: WorklaneContextFormatter.trimmed(output))
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
