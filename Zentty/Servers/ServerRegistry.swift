import Foundation

@MainActor
final class ServerRegistry {
    private struct RecordKey: Hashable {
        let worklaneID: WorklaneID
        let origin: String
        let source: DetectedServerSource
        let paneID: PaneID?
    }

    private var recordsByKey: [RecordKey: DetectedServer] = [:]

    func upsert(_ server: DetectedServer) {
        let key = RecordKey(
            worklaneID: server.worklaneID,
            origin: server.origin,
            source: server.source,
            paneID: server.paneID
        )
        recordsByKey[key] = server
    }

    func clear(worklaneID: WorklaneID, paneID: PaneID) {
        recordsByKey = recordsByKey.filter { key, _ in
            key.worklaneID != worklaneID || key.paneID != paneID
        }
    }

    func clear(worklaneID: WorklaneID) {
        recordsByKey = recordsByKey.filter { key, _ in
            key.worklaneID != worklaneID
        }
    }

    func clearSource(_ source: DetectedServerSource, worklaneID: WorklaneID, paneID: PaneID?) {
        recordsByKey = recordsByKey.filter { key, _ in
            guard key.worklaneID == worklaneID, key.source == source else {
                return true
            }

            guard let paneID else {
                return false
            }

            return key.paneID != paneID
        }
    }

    func servers(in worklaneID: WorklaneID) -> [DetectedServer] {
        let grouped = Dictionary(grouping: recordsByKey.values.filter { $0.worklaneID == worklaneID }) { server in
            server.origin
        }

        return grouped.values
            .compactMap(mergedServer)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.origin < rhs.origin
            }
    }

    func primaryServer(activeWorklaneID: WorklaneID, focusedPaneID: PaneID?) -> DetectedServer? {
        let candidates = servers(in: activeWorklaneID)

        if let focusedPaneID,
           let focused = candidates
               .filter({ $0.paneID == focusedPaneID })
               .max(by: serverSortAscending)
        {
            return focused
        }

        return candidates.max(by: serverSortAscending)
    }

    func server(matching rawOriginOrURL: String, in worklaneID: WorklaneID) -> DetectedServer? {
        let origin = (try? ServerURLNormalizer.normalize(rawOriginOrURL).origin) ?? rawOriginOrURL
        return servers(in: worklaneID).first { $0.origin == origin }
    }

    private func mergedServer(from records: [DetectedServer]) -> DetectedServer? {
        guard let winner = records.max(by: serverSortAscending) else {
            return nil
        }

        let ports = Set(records.flatMap(\.ports) + [winner.url.port].compactMap(\.self)).sorted()

        return DetectedServer(
            id: serverID(worklaneID: winner.worklaneID, origin: winner.origin),
            origin: winner.origin,
            url: winner.url,
            display: winner.display,
            worklaneID: winner.worklaneID,
            paneID: winner.paneID,
            source: winner.source,
            ports: ports,
            confidence: winner.confidence,
            updatedAt: winner.updatedAt
        )
    }

    private func serverSortAscending(_ lhs: DetectedServer, _ rhs: DetectedServer) -> Bool {
        let lhsPriority = sourcePriority(lhs.source)
        let rhsPriority = sourcePriority(rhs.source)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }

        return lhs.origin > rhs.origin
    }

    private func sourcePriority(_ source: DetectedServerSource) -> Int {
        switch source {
        case .manual:
            4
        case .watch:
            3
        case .docker:
            2
        case .scanner:
            1
        }
    }

    private func serverID(worklaneID: WorklaneID, origin: String) -> String {
        "\(worklaneID.rawValue)|\(origin)"
    }
}
