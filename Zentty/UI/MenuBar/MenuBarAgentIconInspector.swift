#if DEBUG
import Foundation

/// DEBUG-only helper that fabricates one synthetic ``MenuBarPaneSnapshot`` per
/// supported agent so the menu-bar dropdown can be eyeballed for icon
/// correctness and sizing. Rows render through the real ``MenuBarAgentRowView``
/// path, so what you inspect is exactly what ships.
enum MenuBarAgentIconInspector {
    /// Every agent we want to inspect, in display order. ``AgentTool`` can't be
    /// `CaseIterable` because of the `.custom` associated value, so the built-in
    /// set is listed explicitly and a sample custom agent is appended to cover
    /// the generated-fallback path.
    static let inspectedTools: [AgentTool] = [
        .zentty,
        .amp,
        .claudeCode,
        .codex,
        .copilot,
        .cursor,
        .droid,
        .gemini,
        .kimi,
        .openCode,
        .pi,
        .grok,
        .agy,
        .hermes,
        .vibe,
        .smallHarness,
        .custom("Custom Agent"),
    ]

    /// One idle snapshot per inspected agent. The context line reports whether
    /// the icon comes from a bundled asset or the generated letter-glyph
    /// fallback — the place where icon bugs hide.
    static func syntheticSnapshots(now: Date = Date()) -> [MenuBarPaneSnapshot] {
        inspectedTools.enumerated().map { index, tool in
            MenuBarPaneSnapshot(
                windowID: WindowID("icon-inspector"),
                windowTitle: "Icon Inspector",
                worklaneID: WorklaneID("icon-inspector"),
                paneID: PaneID("icon-inspector-\(index)"),
                agentTool: tool,
                primaryText: tool.displayName,
                contextText: contextLabel(for: tool),
                statusLabel: MenuBarFleetState.idle.menuStatusLabel(),
                attentionState: nil,
                fleetState: .idle,
                updatedAt: now,
                taskProgress: nil,
                sortPriority: index
            )
        }
    }

    private static func contextLabel(for tool: AgentTool) -> String {
        switch MenuBarStatusIconRenderer.agentIconSource(for: tool) {
        case .bundledAsset:
            return "bundled asset"
        case .generatedFallback:
            return "generated fallback"
        }
    }
}
#endif
