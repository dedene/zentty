import AppKit

/// Decides what VoiceOver hears when a put-away float (pill or PiP) of the
/// active worklane starts needing input. A pill or PiP is easy to miss
/// without sight, and its amber ring and label change are silent.
///
/// Edge-triggered per pane: one announcement when it starts needing input
/// while put away, none while it stays there (a pill that auto-pops into a
/// PiP is the same pane, so it isn't announced twice). Switching worklanes
/// re-seeds without speaking, so arriving in a lane never reads out its
/// backlog.
struct FloatNeedsInputAnnouncer {
    private var worklaneID: WorklaneID?
    private var needingInput: Set<PaneID> = []

    /// Messages to announce for `worklane` (the active one, or nil).
    mutating func update(worklane: WorklaneState?) -> [String] {
        guard let worklane else {
            worklaneID = nil
            needingInput = []
            return []
        }
        // Every float counts for the edge, so minimizing a float that
        // already needs input stays quiet; only pills and PiPs speak.
        let current = Set(worklane.floatingPanes.compactMap { float -> PaneID? in
            let presentation = worklane.auxiliaryStateByPaneID[float.pane.id]?.presentation
            guard let presentation,
                  WorklaneAttentionSummaryBuilder.attentionState(for: presentation) == .needsInput else {
                return nil
            }
            return float.pane.id
        })
        defer {
            worklaneID = worklane.id
            needingInput = current
        }
        guard worklaneID == worklane.id else { return [] }
        return worklane.floatingPanes.compactMap { float in
            let paneID = float.pane.id
            guard !float.mode.isFloating,
                  current.contains(paneID),
                  !needingInput.contains(paneID) else {
                return nil
            }
            return Self.message(for: PillBarContent.item(for: float, in: worklane))
        }
    }

    static func message(for item: PillBarItem) -> String {
        "\(item.name) needs input"
    }

    /// Posts `message` as a high-priority VoiceOver announcement.
    @MainActor
    static func post(_ message: String, from element: Any) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
