import Foundation

/// The palette and Settings drive Agent History through `AgentHistoryControlling` (A-11). Every
/// other requirement is implemented on the controller itself.
extension AgentHistoryController: AgentHistoryControlling {
    /// Recounts sessions, sources and disk usage on the indexer's queue and publishes the result
    /// (observers hear about it only when something changed). While no indexer runs it looks at
    /// the index left on disk instead.
    func refreshStatus() {
        guard let indexer else {
            recountOffStatus()
            return
        }
        indexer.queue.async { [weak indexer] in
            guard let indexer, indexer.lifecycle == .running else {
                return
            }
            indexer.publish(force: true)
        }
    }
}
