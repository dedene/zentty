import Foundation

/// Runs blocking file work (repository lookups, Claude Code's settings) off the main thread and
/// hands the result back on main. Callers check on delivery that the result still applies.
/// Tests inject `.inline` to stay synchronous, or their own dispatch to hold the work.
struct AgentHistoryOffMainRunner: Sendable {
    typealias Dispatch = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let dispatch: Dispatch

    init(dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    /// A user is waiting on the answer (a panel or a settings row), so not `.utility`.
    static let userInitiated = AgentHistoryOffMainRunner { work in
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Runs the work where it is asked; from main, the completion runs before `run` returns.
    static let inline = AgentHistoryOffMainRunner { work in work() }

    func run<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value,
        then completion: @escaping @MainActor (Value) -> Void
    ) {
        dispatch {
            let value = work()
            if Thread.isMainThread {
                MainActor.assumeIsolated { completion(value) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(value) }
                }
            }
        }
    }
}
