import Foundation

enum MainActorShim {
    static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        if #available(macOS 14.0, *) {
            return try MainActor.assumeIsolated(operation)
        } else {
            precondition(Thread.isMainThread)
            return try withoutActuallyEscaping(operation) { escapingOp in
                let nonisolatedOp = unsafeBitCast(escapingOp, to: (() throws -> T).self)
                return try nonisolatedOp()
            }
        }
    }
}

final class NonisolatedUnsafe<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
