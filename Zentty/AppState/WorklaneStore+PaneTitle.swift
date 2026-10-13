import Foundation

extension WorklaneStore {
    func updateWebURL(_ url: String, on paneID: PaneID) {
        guard let index = worklanes.firstIndex(where: { $0.paneStripState.panes.contains(where: { $0.id == paneID && $0.webURL != nil }) }),
              worklanes[index].paneStripState.panes.first(where: { $0.id == paneID })?.webURL != url else { return }
        worklanes[index].paneStripState.setWebURL(url, for: paneID)
        notify(.paneStructure(worklanes[index].id))
    }
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
