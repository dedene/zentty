import Foundation

/// The bold name a float shows ahead of its cwd: custom title, ssh label,
/// live agent title, then the remembered title (the same order as the
/// worklane header's focused label). Nil when nothing names the pane.
enum FloatDisplayName {
    static func resolve(
        pane: PaneState,
        presentation: PanePresentationState?,
        metadata: TerminalMetadata?
    ) -> String? {
        guard let presentation else {
            return PaneDisplayIdentityResolver.trimmedCustomTitle(for: pane)
        }
        return PaneDisplayIdentityResolver.primaryLabel(
            pane: pane,
            presentation: presentation,
            metadata: metadata
        )
    }
}
