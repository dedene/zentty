struct PaneAuxiliaryState: Equatable, Sendable {
    var metadata: TerminalMetadata?
    var shellContext: PaneShellContext?
    var agentStatus: PaneAgentStatus?
    var inferredArtifact: WorkspaceArtifactLink?
    var reviewState: WorkspaceReviewState?
}
