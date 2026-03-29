import Foundation

struct RecentCommandsTracker {
    private static let maxRecent = 8
    private(set) var recentItemIDs: [CommandPaletteItemID] = []

    /// Records an item execution. Moves it to the front if already present.
    mutating func record(_ itemID: CommandPaletteItemID) {
        recentItemIDs.removeAll { $0 == itemID }
        recentItemIDs.insert(itemID, at: 0)
        if recentItemIDs.count > Self.maxRecent {
            recentItemIDs.removeLast(recentItemIDs.count - Self.maxRecent)
        }
    }
}
