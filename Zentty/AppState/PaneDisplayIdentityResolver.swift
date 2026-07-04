import Foundation

enum PaneDisplayIdentityResolver {
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

        return WorklaneContextFormatter.trimmed(presentation.sshConnectionLabel)
    }

    static func primaryLabel(
        pane: PaneState,
        presentation: PanePresentationState,
        metadata: TerminalMetadata?
    ) -> String? {
        if let customTitle = trimmedCustomTitle(for: pane) {
            return customTitle
        }

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
