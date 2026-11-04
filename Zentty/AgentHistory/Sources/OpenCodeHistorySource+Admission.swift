import Foundation

/// Re-reads opencode sessions when the exclusions or tombstones change. The indexer purges
/// rows itself when rules tighten and forgets rejected cursors when they relax, but this source
/// is one unit holding every session, so it tracks per-session admission on its own.
extension OpenCodeHistorySource {
    /// Fingerprint of the rules that decide admission for opencode: the excluded folders and the
    /// opencode tombstones. FNV-1a, so it is stable across launches.
    static func admissionSignature(_ admission: AgentHistoryAdmission) -> Int64 {
        let folders = admission.exclusions.canonicalFolders.sorted().joined(separator: "\n")
        let tombstones = admission.tombstones.filter { $0.agent == .opencode }.map(\.nativeID).sorted()
            .joined(separator: "\n")
        return AgentHistoryFileFingerprint.hash(Array((folders + "\u{0}" + tombstones).utf8))
    }

    /// When the rules changed since the last call, queues every rejected session (it may be
    /// admitted now; still-rejected ones are re-decided from their session rows alone) and every
    /// admitted session the new rules would reject (so it moves to `rejected` and comes back when
    /// the rules relax again). A failed read leaves the old signature, so the next call retries.
    func applyAdmissionChanges(
        url: URL,
        schema: OpenCodeHistorySchema,
        admission: AgentHistoryAdmission,
        state: inout OpenCodeHistoryAdapterState
    ) {
        let signature = Self.admissionSignature(admission)
        guard state.admissionSignature != signature else {
            return
        }
        guard state.admissionSignature != nil else {
            state.admissionSignature = signature
            return
        }
        var queued = Array(state.rejected.keys)
        var directories: [String: [String]] = [:]
        if !admission.exclusions.isEmpty {
            do {
                directories = try readSnapshot(url: url) { db in
                    try OpenCodeHistoryQueries.sessionDirectories(db, schema: schema)
                }
            } catch {
                AgentHistoryLog.indexer.info("opencode admission re-check deferred")
                return
            }
        }
        for id in state.lastChange.keys {
            guard let nativeID = agent.normalizedSessionID(id) else { continue }
            let candidates: [String?] = directories[id].map { $0.map { Optional($0) } } ?? [nil]
            if candidates.contains(where: { admission.decide(agent: .opencode, nativeID: nativeID, cwd: $0) != .admit }) {
                queued.append(id)
            }
        }
        state.enqueue(queued.sorted())
        state.admissionSignature = signature
    }
}
