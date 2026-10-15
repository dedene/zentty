import Foundation

/// A quick-action overlay as the sidebar sees it. Overlays are not panes, so
/// they render as one compact line hanging off what they cover: under their
/// pane for a pane overlay, at the end of the worklane card otherwise.
struct WorklaneSidebarOverlay: Equatable {
    static let accessibilityTitle = "Quick action overlay"

    let id: PaneID
    /// The pane the overlay is anchored to; the pane it covers for a pane overlay.
    let anchorPaneID: PaneID
    let isPaneOverlay: Bool
    /// The command the overlay was opened with; empty for an interactive shell.
    let command: String
    let runningCommand: String?
    let exitCode: Int?
    let workingDirectory: String?
    let branch: String?
    let isFocused: Bool
    let isVisible: Bool

    /// The command a command overlay runs; nil for a shell, whose icon says enough.
    var title: String? {
        WorklaneContextFormatter.trimmed(command).map(PaneCloseConfirmationContext.truncated)
    }

    /// "running", the command typed into a shell overlay, or how a command
    /// overlay ended. An idle shell says nothing.
    var statusText: String? {
        let isShell = WorklaneContextFormatter.trimmed(command) == nil
        if let runningCommand {
            return isShell ? PaneCloseConfirmationContext.truncated(runningCommand) : "running"
        }
        guard !isShell, let exitCode else { return nil }
        return exitCode == 0 ? "done" : "exit \(exitCode)"
    }

    /// Path and branch. A command overlay shows them only when they differ from
    /// the anchor pane's, since its command already names it; a shell overlay
    /// always shows them, since they are all that follows its icon.
    func locationText(anchorWorkingDirectory: String?) -> String? {
        guard let workingDirectory,
              title == nil
                || Self.standardized(workingDirectory) != anchorWorkingDirectory.map(Self.standardized),
              let path = WorklaneContextFormatter.compactSidebarPath(workingDirectory) else {
            return nil
        }
        return [path, branch].compactMap { $0 }.joined(separator: " ")
    }

    /// A command overlay reads "htop … running"; a shell overlay has no name, so
    /// its location and running command follow the icon directly.
    func sidebarRow(anchorWorkingDirectory: String?) -> WorklaneSidebarPaneRow {
        let details = [locationText(anchorWorkingDirectory: anchorWorkingDirectory), statusText]
            .compactMap { $0 }
            .joined(separator: " · ")
        let detailText = details.isEmpty ? nil : details
        var row = WorklaneSidebarPaneRow(
            paneID: id,
            primaryText: title ?? detailText ?? "",
            trailingText: title == nil ? nil : detailText,
            detailText: nil,
            statusText: nil,
            attentionState: nil,
            isFocused: isFocused,
            isWorking: false
        )
        row.isOverlay = true
        row.overlayOwnerPaneID = isPaneOverlay ? anchorPaneID : nil
        row.isOverlayHidden = !isVisible
        return row
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
