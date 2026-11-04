import AppKit

extension AgentHistoryAgent {
    /// The value the palette suggests after `agent:` (the parser accepts more aliases).
    var filterAlias: String { rawValue }
}

/// The monochrome agent glyphs the menu bar uses, as template images for the palette (A-14).
@MainActor
enum AgentHistoryAgentIcon {
    static let fallbackSymbolName = "terminal"

    private static var cache: [AgentHistoryAgent: NSImage] = [:]

    /// Cached per agent.
    static func image(for agent: AgentHistoryAgent) -> NSImage {
        if let cached = cache[agent] {
            return cached
        }
        let image = image(for: agent, renderer: MenuBarStatusIconRenderer.agentIconTemplateImage(for:))
        cache[agent] = image
        return image
    }

    /// Uncached; `renderer` returning nil falls back to the `terminal` symbol.
    static func image(for agent: AgentHistoryAgent, renderer: (AgentTool) -> NSImage?) -> NSImage {
        let image = renderer(agent.agentTool)
            ?? NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: agent.displayName)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        image.accessibilityDescription = agent.displayName
        return image
    }
}
