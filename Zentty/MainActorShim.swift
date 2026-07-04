import Foundation

enum MainActorShim {
    static func assumeIsolated<T: Sendable>(_ operation: @MainActor () throws -> T) rethrows -> T {
        if #available(macOS 14.0, *) {
            return try MainActor.assumeIsolated(operation)
        } else {
            return try assumeIsolatedUnchecked(operation)
        }
    }

    static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        try assumeIsolatedUnchecked(operation)
    }

    private static func assumeIsolatedUnchecked<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread)
        return try withoutActuallyEscaping(operation) { escapingOp in
            let nonisolatedOp = unsafeBitCast(escapingOp, to: (() throws -> T).self)
            return try nonisolatedOp()
        }
    }
}
