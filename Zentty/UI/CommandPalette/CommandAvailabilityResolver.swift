import Foundation

enum CommandAvailabilityResolver {
    static func availableCommandIDs(
        worklaneCount: Int,
        paneCount: Int
    ) -> Set<AppCommandID> {
        var available = Set(AppCommandID.allCases)

        available.remove(.showCommandPalette)

        if paneCount <= 1 {
            available.remove(.closeFocusedPane)
            available.remove(.focusLeftPane)
            available.remove(.focusRightPane)
            available.remove(.focusUpInColumn)
            available.remove(.focusDownInColumn)
            available.remove(.focusFirstColumn)
            available.remove(.focusLastColumn)
            available.remove(.resizePaneLeft)
            available.remove(.resizePaneRight)
            available.remove(.resizePaneUp)
            available.remove(.resizePaneDown)
            available.remove(.resetPaneLayout)
        }

        if worklaneCount <= 1 {
            available.remove(.nextWorklane)
            available.remove(.previousWorklane)
        }

        return available
    }
}
