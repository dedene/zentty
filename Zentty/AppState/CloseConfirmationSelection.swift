import Foundation

/// Where the user was before a close-confirmation sheet moved the selection
/// onto the pane or worklane about to close.
///
/// The sheet highlights its target so the prompt matches what is on screen.
/// If the user cancels, the selection goes back to where it was, as long as
/// that place still exists.
struct CloseConfirmationSelectionSnapshot: Equatable, Sendable {
    let worklaneID: WorklaneID
    let paneID: PaneID?

    enum RestoreAction: Equatable, Sendable {
        case none
        case selectWorklane(WorklaneID)
        case selectWorklaneAndFocusPane(WorklaneID, PaneID)
    }

    static func capture(worklanes: [WorklaneState], activeWorklaneID: WorklaneID) -> CloseConfirmationSelectionSnapshot? {
        guard let worklane = worklanes.first(where: { $0.id == activeWorklaneID }) else {
            return nil
        }
        return CloseConfirmationSelectionSnapshot(
            worklaneID: worklane.id,
            paneID: worklane.focusedPaneID
        )
    }

    /// What it takes to get back to this snapshot given the current state.
    /// `.none` when nothing moved or when the previous place is gone.
    func restoreAction(worklanes: [WorklaneState], activeWorklaneID: WorklaneID) -> RestoreAction {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }) else {
            return .none
        }

        let paneStillExists = paneID.map { id in
            worklane.containsPane(id: id)
        } ?? false

        if activeWorklaneID == worklaneID {
            guard let paneID, paneStillExists, worklane.focusedPaneID != paneID else {
                return .none
            }
            return .selectWorklaneAndFocusPane(worklaneID, paneID)
        }

        if let paneID, paneStillExists {
            return .selectWorklaneAndFocusPane(worklaneID, paneID)
        }
        return .selectWorklane(worklaneID)
    }
}
