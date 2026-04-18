import Foundation

enum WorklaneAttentionSummaryBuilder {
    static func summary(for worklane: WorklaneState) -> WorklaneAttentionSummary? {
        summaries(for: worklane).first
    }

    static func summaries(for worklane: WorklaneState) -> [WorklaneAttentionSummary] {
        worklane.paneStripState.panes
            .compactMap { pane in
                summary(for: pane, in: worklane)
            }
            .sorted(by: preferred(lhs:rhs:))
    }

    private static func summary(
        for pane: PaneState,
        in worklane: WorklaneState
    ) -> WorklaneAttentionSummary? {
        guard let paneContext = worklane.paneContext(for: pane.id) else {
            return nil
        }

        let presentation = paneContext.presentation
        guard
            let attentionState = attentionState(for: presentation),
            let tool = presentation.recognizedTool
        else {
            return nil
        }

        return WorklaneAttentionSummary(
            paneID: pane.id,
            tool: tool,
            state: attentionState,
            interactionKind: presentation.interactionKind,
            interactionLabel: presentation.interactionLabel ?? presentation.interactionKind?.defaultLabel,
            primaryText: primaryText(for: presentation),
            statusText: summaryStatusText(for: presentation),
            contextText: contextText(for: presentation),
            artifactLink: presentation.attentionArtifactLink,
            interactionSymbolName: presentation.interactionSymbolName ?? presentation.interactionKind?.defaultSymbolName,
            updatedAt: presentation.updatedAt
        )
    }

    private static func primaryText(for presentation: PanePresentationState) -> String {
        guard presentation.isRemoteShell else {
            return presentation.visibleIdentityText ?? "Shell"
        }

        let host = WorklaneContextFormatter.trimmed(presentation.remoteHostLabel)
        let title = meaningfulRemoteTitle(for: presentation)

        switch (host, title) {
        case let (host?, title?) where !host.isEmpty && !title.isEmpty:
            return "\(host) · \(title)"
        case let (host?, _):
            return host
        case let (_, title?):
            return title
        case (nil, nil):
            return presentation.visibleIdentityText ?? "Shell"
        }
    }

    private static func contextText(for presentation: PanePresentationState) -> String {
        if presentation.isRemoteShell,
           let remotePath = WorklaneContextFormatter.trimmed(presentation.remotePathLabel) {
            return remotePath
        }

        return presentation.contextText ?? ""
    }

    private static func meaningfulRemoteTitle(for presentation: PanePresentationState) -> String? {
        let candidates = [
            WorklaneContextFormatter.trimmed(presentation.rememberedTitle),
            WorklaneContextFormatter.trimmed(presentation.identityText),
        ]

        for candidate in candidates {
            guard let candidate else {
                continue
            }

            let lowered = candidate.lowercased()
            if lowered == "shell" {
                continue
            }
            if candidate.contains("/") || candidate.hasPrefix("~") {
                continue
            }
            if candidate == presentation.remoteHostLabel {
                continue
            }

            return candidate
        }

        return nil
    }

    private static func attentionState(for presentation: PanePresentationState) -> WorklaneAttentionState? {
        if presentation.isReady {
            return .ready
        }

        switch presentation.runtimePhase {
        case .idle, .starting:
            return nil
        case .running:
            return .running
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        }
    }

    private static func summaryStatusText(for presentation: PanePresentationState) -> String {
        if presentation.runtimePhase == .needsInput {
            return presentation.interactionLabel
                ?? presentation.interactionKind?.defaultLabel
                ?? presentation.statusText
                ?? ""
        }

        return presentation.statusText ?? ""
    }

    private static func preferred(lhs: WorklaneAttentionSummary, rhs: WorklaneAttentionSummary) -> Bool {
        if lhs.state.priority != rhs.state.priority {
            return lhs.state.priority > rhs.state.priority
        }

        return lhs.updatedAt > rhs.updatedAt
    }
}

private extension WorklaneAttentionState {
    var priority: Int {
        switch self {
        case .needsInput:
            return 4
        case .unresolvedStop:
            return 3
        case .ready:
            return 2
        case .running:
            return 1
        }
    }
}
