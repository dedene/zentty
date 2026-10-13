import Foundation

enum PaneDisplayIdentityResolver {
    static func webLabel(for pane: PaneState) -> String? {
        guard let value = pane.webURL else { return nil }
        if let url = URL(string: value), url.isFileURL { return url.lastPathComponent }
        return value.contains("://") ? value : URL(fileURLWithPath: value).lastPathComponent
    }
    static func trimmedCustomTitle(for pane: PaneState) -> String? {
        WorklaneContextFormatter.trimmed(pane.customTitle)
    }

    static func hasCustomTitle(for pane: PaneState) -> Bool {
        trimmedCustomTitle(for: pane) != nil
    }

    static func borderLabelText(
        pane: PaneState,
        presentation: PanePresentationState
    ) -> String? {
        if let customTitle = trimmedCustomTitle(for: pane) {
            return customTitle
        }

        return webLabel(for: pane) ?? WorklaneContextFormatter.trimmed(presentation.sshConnectionLabel)
    }

    static func primaryLabel(
        pane: PaneState,
        presentation: PanePresentationState,
        metadata: TerminalMetadata?
    ) -> String? {
        if let customTitle = trimmedCustomTitle(for: pane) {
            return customTitle
        }

        if let webLabel = webLabel(for: pane) { return webLabel }

        if let sshConnectionLabel = WorklaneContextFormatter.trimmed(presentation.sshConnectionLabel) {
            return sshConnectionLabel
        }

        if let recognizedTool = presentation.recognizedTool,
           let volatileTitle = WorklaneContextFormatter.trimmed(metadata?.title),
           TerminalMetadataChangeClassifier.isRealtimeAgentStatusTitle(
               volatileTitle,
               recognizedTool: recognizedTool
           ) {
            return volatileTitle
        }

        if let rememberedTitle = WorklaneContextFormatter.trimmed(presentation.rememberedTitle) {
            if let decomposedTitle = decomposedRememberedTitle(
                rememberedTitle,
                presentation: presentation
            ) {
                return decomposedTitle
            }
            return rememberedTitle
        }

        return nil
    }

    static func animatesLocalCodexSpinner(
        pane: PaneState,
        presentation: PanePresentationState,
        metadata: TerminalMetadata?
    ) -> Bool {
        guard presentation.isWorking,
              presentation.recognizedTool == .codex,
              presentation.isRemotePane == false,
              hasCustomTitle(for: pane) == false,
              let title = WorklaneContextFormatter.trimmed(metadata?.title),
              TerminalMetadataChangeClassifier.codexActivitySpinnerRange(in: title) != nil else {
            return false
        }

        return primaryLabel(
            pane: pane,
            presentation: presentation,
            metadata: metadata
        ) == title
    }

    private static func decomposedRememberedTitle(
        _ rememberedTitle: String,
        presentation: PanePresentationState
    ) -> String? {
        guard let branch = WorklaneContextFormatter.trimmed(presentation.branchDisplayText) else {
            return nil
        }

        for separator in [" · ", " • "] {
            let prefix = branch + separator
            if rememberedTitle.hasPrefix(prefix) {
                return WorklaneContextFormatter.trimmed(String(rememberedTitle.dropFirst(prefix.count)))
            }
        }

        return nil
    }
}
