import CoreGraphics
import Foundation

/// Remembers the last size a named float was shown at, so reopening `lazygit` or
/// `claude` as a float brings back the size it had last time. Bounded LRU.
struct FloatGeometryStore: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var size: CGSize
        var lastShownAt: Date
    }

    private static let maxEntries = 50
    private static let defaultCanvasFraction: CGFloat = 0.6

    private(set) var entriesByName: [FloatName: Entry]

    init(entriesByName: [FloatName: Entry] = [:]) {
        self.entriesByName = entriesByName
    }

    var entryCount: Int { entriesByName.count }

    func recall(_ name: FloatName) -> CGSize? {
        entriesByName[name]?.size
    }

    mutating func remember(_ name: FloatName, size: CGSize, now: Date = Date()) {
        entriesByName[name] = Entry(size: size, lastShownAt: now)
        pruneIfNeeded()
    }

    /// Size for a float with no remembered geometry: 60% of the canvas.
    func defaultSize(forCanvas canvas: CGSize) -> CGSize {
        CGSize(
            width: canvas.width * Self.defaultCanvasFraction,
            height: canvas.height * Self.defaultCanvasFraction
        )
    }

    private mutating func pruneIfNeeded() {
        guard entriesByName.count > Self.maxEntries else { return }
        if let oldest = entriesByName.min(by: { $0.value.lastShownAt < $1.value.lastShownAt }) {
            entriesByName.removeValue(forKey: oldest.key)
        }
    }
}
