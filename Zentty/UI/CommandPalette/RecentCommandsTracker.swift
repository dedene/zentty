import Foundation

struct RecentCommandsTracker {
    private static let maxRecent = 8
    private(set) var recentCommandIDs: [AppCommandID] = []

    /// Records a command execution. Moves it to the front if already present.
    mutating func record(_ commandID: AppCommandID) {
        recentCommandIDs.removeAll { $0 == commandID }
        recentCommandIDs.insert(commandID, at: 0)
        if recentCommandIDs.count > Self.maxRecent {
            recentCommandIDs.removeLast(recentCommandIDs.count - Self.maxRecent)
        }
    }
}
