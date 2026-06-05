import Foundation

enum BookmarkNameSuggester {
    static func suggest(for worklane: WorklaneState, kind: WorkspaceTemplate.Kind) -> String {
        switch kind {
        case .bookmark:
            return suggestBookmarkName(for: worklane)
        case .preset:
            return suggestPresetName(for: worklane)
        }
    }

    private static func suggestBookmarkName(for worklane: WorklaneState) -> String {
        if let title = WorklaneContextFormatter.trimmed(worklane.title) {
            return title
        }

        let cwds = worklane.paneStripState.panes.compactMap { pane -> String? in
            let auxiliary = worklane.auxiliaryStateByPaneID[pane.id]
            return auxiliary?.metadata?.currentWorkingDirectory
                ?? auxiliary?.presentation.cwd
                ?? pane.sessionRequest.workingDirectory
        }
        if let lca = WorkspaceTemplateCapture.longestCommonAncestor(of: cwds) {
            return URL(fileURLWithPath: lca).lastPathComponent
        }
        if let first = cwds.first {
            return URL(fileURLWithPath: first).lastPathComponent
        }
        return "Untitled bookmark"
    }

    private static func suggestPresetName(for worklane: WorklaneState) -> String {
        let count = worklane.paneStripState.panes.count
        let focusedPaneID = worklane.paneStripState.focusedPaneID
        let focusedCommand: String? = focusedPaneID.flatMap { paneID in
            worklane.auxiliaryStateByPaneID[paneID]?.metadata?.processName
        }
        if let focusedCommand, !isShellName(focusedCommand) {
            return "\(count) \(count == 1 ? "pane" : "panes"): \(focusedCommand)"
        }
        return "\(count)-pane preset"
    }

    private static func isShellName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return [
            "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh",
            "-zsh", "-bash", "-sh", "-fish", "-dash", "-ksh", "-tcsh", "-csh",
            "login",
        ].contains(normalized)
    }
}
