import Foundation

/// The "folder gone" sheet: where to resume a session whose folder no longer exists. Built from
/// the launcher's `.needsFolderChoice` outcome; ↑↓ move, ↩ confirms, esc cancels.
struct AgentHistoryFolderGoneSheetModel: Equatable {
    /// The session to resume; kept whole so a rebuild of the result list can't lose it.
    let source: AgentHistoryResumeSource
    let intent: AgentHistoryLaunchIntent
    let agentName: String
    /// The folder that is gone; nil when the session never recorded one.
    let missingPath: String?
    /// Never empty.
    let options: [AgentHistoryFolderChoice]
    private(set) var selectedIndex: Int

    var key: AgentHistorySessionKey { source.key }
    var selectedChoice: AgentHistoryFolderChoice { options[selectedIndex] }

    /// nil without options. The default choice is preselected (first option when it is missing).
    static func make(
        source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        options: [AgentHistoryFolderChoice],
        defaultChoice: AgentHistoryFolderChoice
    ) -> AgentHistoryFolderGoneSheetModel? {
        guard !options.isEmpty else {
            return nil
        }
        return AgentHistoryFolderGoneSheetModel(
            source: source,
            intent: intent,
            agentName: source.agent.displayName,
            missingPath: source.workingDirectory,
            options: options,
            selectedIndex: options.firstIndex(of: defaultChoice) ?? 0
        )
    }

    /// Moves the selection, clamped to the options.
    mutating func move(_ delta: Int) {
        selectedIndex = min(max(selectedIndex + delta, 0), options.count - 1)
    }

    mutating func select(_ index: Int) {
        guard options.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }
}
