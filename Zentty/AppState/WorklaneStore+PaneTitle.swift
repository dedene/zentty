import Foundation

extension WorklaneStore {
    /// Sets or clears the optional user-visible pane title. The value is
    /// trimmed; empty or whitespace-only input clears the title (nil).
    /// Works for tiles and floats.
    @discardableResult
    func setPaneCustomTitle(_ title: String?, on paneID: PaneID) -> Bool {
        let resolved = WorklaneContextFormatter.trimmed(title)

        guard let worklaneIndex = self.worklaneIndex(containingPane: paneID),
              worklanes[worklaneIndex].pane(id: paneID)?.customTitle != resolved else {
            return false
        }

        var worklane = worklanes[worklaneIndex]
        worklane.updatePane(id: paneID) { $0.customTitle = resolved }
        worklanes[worklaneIndex] = worklane
        notifyPaneDataChanged(paneID, in: worklane)
        return true
    }
}
