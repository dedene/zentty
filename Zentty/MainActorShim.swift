import Foundation

enum MainActorShim {
    static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        if #available(macOS 14.0, *) {
            return try MainActor.assumeIsolated(operation)
        } else {
            precondition(Thread.isMainThread)
            let nonisolatedOp = unsafeBitCast(operation, to: (() throws -> T).self)
            return try nonisolatedOp()
        }
    }
}
