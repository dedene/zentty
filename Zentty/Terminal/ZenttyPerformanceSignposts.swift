import Foundation
import OSLog

enum ZenttyPerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: "be.zenjoy.zentty",
        category: .pointsOfInterest
    )

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer {
            signposter.endInterval(name, state)
        }
        return try body()
    }
}
