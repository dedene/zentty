import Foundation

extension WorklaneStore {
    /// Sets or clears the optional user-visible pane title. The value is
    /// trimmed; empty or whitespace-only input clears the title (nil).
    @discardableResult
    func setPaneCustomTitle(_ title: String?, on paneID: PaneID) -> Bool {
        let resolved = WorklaneContextFormatter.trimmed(title)

        for worklaneIndex in worklanes.indices {
            for columnIndex in worklanes[worklaneIndex].paneStripState.columns.indices {
                guard let paneIndex = worklanes[worklaneIndex].paneStripState.columns[columnIndex].panes
                    .firstIndex(where: { $0.id == paneID }) else {
                    continue
                }

                guard worklanes[worklaneIndex].paneStripState.columns[columnIndex].panes[paneIndex].customTitle
                    != resolved else {
                    return false
                }

                worklanes[worklaneIndex].paneStripState.columns[columnIndex].panes[paneIndex].customTitle = resolved
                let worklaneID = worklanes[worklaneIndex].id
                if worklaneID == activeWorklaneID {
                    activeWorklane = worklanes[worklaneIndex]
                }
                notify(.paneStructure(worklaneID))
                return true
            }
        }

        return false
    }
}