import Foundation

/// The "folder gone" sheet: where to resume a session whose folder no longer exists. Built from
/// the launcher's `.needsFolderChoice` outcome; ↑↓ move, ↩ confirms, esc cancels.
struct AgentHistoryFolderGoneSheetModel: Equatable {
    static let title = "The folder for this session is gone"
    static let confirmTitle = "Continue"
    static let cancelTitle = "Cancel"

    /// A run of sheet copy: plain text, or a path / command shown in monospace.
    enum TextPart: Equatable {
        case text(String)
        case code(String)
    }

    /// One choice as the sheet shows it.
    struct Option: Equatable, Identifiable {
        let id: Int
        let choice: AgentHistoryFolderChoice
        let title: String
        let detail: [TextPart]

        var accessibilityLabel: String {
            "\(title). \(AgentHistoryFolderGoneSheetModel.plainText(detail))"
        }
    }

    /// The session to resume; kept whole so a rebuild of the result list can't lose it.
    let source: AgentHistoryResumeSource
    let intent: AgentHistoryLaunchIntent
    let agentName: String
    /// The folder that is gone; nil when the session never recorded one.
    let missingPath: String?
    /// Never empty. The resolver decides which choices are eligible (repository root or home
    /// folder, worktree recreation, copy); the sheet shows them in that order.
    let options: [AgentHistoryFolderChoice]
    /// Paths under it read as `~/…`.
    let homeDirectory: String
    private(set) var selectedIndex: Int

    var key: AgentHistorySessionKey { source.key }
    var selectedChoice: AgentHistoryFolderChoice { options[selectedIndex] }

    /// nil without options. The default choice is preselected (first option when it is missing).
    static func make(
        source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        options: [AgentHistoryFolderChoice],
        defaultChoice: AgentHistoryFolderChoice,
        homeDirectory: String = NSHomeDirectory()
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
            homeDirectory: homeDirectory,
            selectedIndex: options.firstIndex(of: defaultChoice) ?? 0
        )
    }

    /// Moves the selection, clamped to the options.
    mutating func move(_ delta: Int) {
        selectedIndex = min(max(selectedIndex + delta, 0), options.count - 1)
    }

    /// A click on an option; out-of-range indexes are ignored.
    mutating func select(_ index: Int) {
        guard options.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }

    // MARK: - Copy

    /// "‹path› no longer exists, probably removed with the worktree for ‹branch›. Where should
    /// ‹Agent› continue?"
    var message: [TextPart] {
        guard let missingPath, !missingPath.isEmpty else {
            return [.text("This session didn't record its folder. Where should \(agentName) continue?")]
        }
        var parts: [TextPart] = [.code(abbreviated(missingPath)), .text(" no longer exists")]
        if let branch = source.branch, ranInLinkedWorktree {
            parts += [.text(", probably removed with the worktree for "), .code(branch)]
        }
        parts.append(.text(". Where should \(agentName) continue?"))
        return parts
    }

    var accessibilityMessage: String { Self.plainText(message) }

    var displayOptions: [Option] {
        options.enumerated().map { index, choice in
            Option(id: index, choice: choice, title: Self.title(for: choice), detail: detail(for: choice))
        }
    }

    static func title(for choice: AgentHistoryFolderChoice) -> String {
        switch choice {
        case .repositoryRoot: "Repository root"
        case .recreateWorktree: "Recreate the worktree"
        case .homeFolder: "Home folder"
        case .copyResumeCommand: "Copy the resume command"
        }
    }

    static func plainText(_ parts: [TextPart]) -> String {
        parts.map { part in
            switch part {
            case .text(let text), .code(let text): text
            }
        }.joined()
    }

    private func detail(for choice: AgentHistoryFolderChoice) -> [TextPart] {
        switch choice {
        case .repositoryRoot(let path):
            return [.code(abbreviated(path)), .text(", on whatever branch is checked out there.")]
        case .recreateWorktree(let recreation):
            var parts: [TextPart] = [
                .text("Runs "), .code("git worktree add"), .text(" for "), .code(recreation.branch),
                .text(" at "), .code(abbreviated(recreation.worktreePath)), .text(", then resumes there."),
            ]
            if recreation.hasStaleRegistration {
                parts.append(.text(" Git's stale entry for that folder is removed first."))
            }
            return parts
        case .homeFolder(let path):
            return [.code(abbreviated(path)), .text(". No repository is known for this session.")]
        case .copyResumeCommand:
            return [.text("Run it yourself wherever you like.")]
        }
    }

    private var ranInLinkedWorktree: Bool {
        guard let repoRoot = source.repoRoot, let mainRepoRoot = source.mainRepoRoot else {
            return false
        }
        return repoRoot != mainRepoRoot
    }

    private func abbreviated(_ path: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty else { return path }
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
