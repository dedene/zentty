import Foundation

extension AgentHistoryController: AgentHistoryUsageRecording {
    /// Safe from any thread: hops to main to reach the indexer, which writes on its own queue.
    nonisolated func recordOpen(sessionRowID: Int64, at date: Date) {
        let atMs = AgentHistorySchema.milliseconds(since1970: date)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                recordOpen(sessionRowID: sessionRowID, atMs: atMs)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.recordOpen(sessionRowID: sessionRowID, atMs: atMs)
                }
            }
        }
    }
}
