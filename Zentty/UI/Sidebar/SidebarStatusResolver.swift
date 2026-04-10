import Foundation

/// Single source of truth for resolving a worklane or pane row's displayed
/// status text and symbol from raw status + attention + interaction inputs.
///
/// Historically this logic lived in two places that drifted over time:
/// `SidebarWorklaneRowLayout.displayedStatusText` (static/pure, for layout
/// measurement) and `SidebarWorklaneRowButton.resolvedStatusCopy` (instance
/// method, for display). The two differed in how they handled the
/// "generic-input substitution" — display wanted the specific interaction
/// label to replace the generic label in-place inside the raw status; layout
/// wanted the raw selection for measurement.
///
/// This type exposes the two legal behaviors explicitly:
///
/// - `resolveDisplayStatusText(...)` — returns a non-optional String,
///   applies the generic-input substitution. Use when writing label text.
/// - `resolveMeasurementStatusText(...)` — returns an optional String,
///   performs no substitution. Use when measuring status row width/height.
///
/// The symbol-name resolution is identical for both display and measurement
/// callers and lives in a single method.
enum SidebarStatusResolver {
    /// Whether the interaction-specific presentation should win over the
    /// raw status text. True when attention is `.needsInput` and the
    /// interaction kind is present and is anything other than `.genericInput`.
    static func shouldPreferInteractionPresentation(
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?
    ) -> Bool {
        attentionState == .needsInput
            && interactionKind != nil
            && interactionKind != .genericInput
    }

    /// Resolves status text for DISPLAY. Always returns a String (empty
    /// when nothing is available). When an explicit interaction is active,
    /// the interaction label replaces the generic-input substring inside the
    /// raw status text in-place, preserving the surrounding status prose.
    /// Called from the row button when assigning label strings.
    static func resolveDisplayStatusText(
        statusText: String?,
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?,
        interactionLabel: String?
    ) -> String {
        guard shouldPreferInteractionPresentation(
            attentionState: attentionState,
            interactionKind: interactionKind
        ) else {
            return statusText
                ?? interactionLabel
                ?? interactionKind?.defaultLabel
                ?? ""
        }

        let preferredLabel = interactionLabel ?? interactionKind?.defaultLabel ?? ""
        guard let statusText else {
            return preferredLabel
        }

        if let genericRange = statusText.range(
            of: PaneInteractionKind.genericInput.defaultLabel,
            options: [.caseInsensitive, .backwards]
        ) {
            return statusText.replacingCharacters(in: genericRange, with: preferredLabel)
        }

        return preferredLabel
    }

    /// Resolves status text for MEASUREMENT. Returns nil when nothing is
    /// available so callers can guard-let out of width calculations.
    /// Performs no substring substitution — measurement should reflect the
    /// raw text the normalizer fed in, not the final display string.
    /// Called from `SidebarWorklaneRowLayout` when computing status row width.
    static func resolveMeasurementStatusText(
        statusText: String?,
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?,
        interactionLabel: String?
    ) -> String? {
        if shouldPreferInteractionPresentation(
            attentionState: attentionState,
            interactionKind: interactionKind
        ) {
            return interactionLabel
                ?? interactionKind?.defaultLabel
                ?? statusText
        }
        return statusText
            ?? interactionLabel
            ?? interactionKind?.defaultLabel
    }

    /// Resolves the SF Symbol name for the status icon. Identical behavior
    /// for display and measurement callers. Returns "" when no symbol is
    /// available (callers use `.isEmpty` to detect "no icon").
    static func resolveStatusSymbolName(
        statusSymbolName: String?,
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?,
        interactionSymbolName: String?
    ) -> String {
        if shouldPreferInteractionPresentation(
            attentionState: attentionState,
            interactionKind: interactionKind
        ) {
            return interactionSymbolName
                ?? interactionKind?.defaultSymbolName
                ?? statusSymbolName
                ?? ""
        }
        return statusSymbolName
            ?? interactionSymbolName
            ?? interactionKind?.defaultSymbolName
            ?? ""
    }
}
