struct PaneAuxiliaryState: Equatable, Sendable {
    var metadata: TerminalMetadata?
    var shellContext: PaneShellContext?
    var agentStatus: PaneAgentStatus?
    var terminalProgress: TerminalProgressReport? = nil
    var inferredArtifact: WorkspaceArtifactLink?
    var reviewState: WorkspaceReviewState?

    var isWorking: Bool {
        if let terminalProgress {
            return terminalProgress.state.indicatesActivity
        }

        return agentStatus?.state == .running
    }

    var localReviewWorkingDirectory: String? {
        let metadataWorkingDirectory = WorkspaceContextFormatter.resolvedWorkingDirectory(for: metadata)
        guard let shellContext else {
            return metadataWorkingDirectory
        }
        guard shellContext.scope == .local else {
            return nil
        }

        return metadataWorkingDirectory ?? WorkspaceContextFormatter.trimmed(shellContext.path)
    }
}
