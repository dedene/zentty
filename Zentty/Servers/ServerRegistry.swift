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
        recordsByKey[key] = preservingFirstSeen(server, key: key, previous: recordsByKey[key])
    }

    /// Replaces every record for `(worklaneID, source)` in one shot, preserving
    /// `firstSeenAt` for keys that survive the swap and forgetting removed ones.
    ///
    /// Passive sources (scanner, docker) re-publish their full result set every
    /// poll; a plain clear-then-upsert would reset `firstSeenAt` to "now" each
    /// cycle, so freshness is carried forward here for keys present before and
    /// after.
    func replaceSource(
        _ source: DetectedServerSource,
        worklaneID: WorklaneID,
        servers: [DetectedServer]
    ) {
        let previous = recordsByKey
        recordsByKey = recordsByKey.filter { key, _ in
            key.worklaneID != worklaneID || key.source != source
        }

        for server in servers {
            let key = RecordKey(
                worklaneID: server.worklaneID,
                origin: server.origin,
                source: server.source,
                paneID: server.paneID
            )
            recordsByKey[key] = preservingFirstSeen(server, key: key, previous: previous[key])
        }
    }

    private func preservingFirstSeen(
        _ server: DetectedServer,
        key: RecordKey,
        previous: DetectedServer?
    ) -> DetectedServer {
        guard let previous else {
            return server
        }
        var preserved = server
        preserved.firstSeenAt = min(previous.firstSeenAt, server.firstSeenAt)
        return preserved
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
            updatedAt: winner.updatedAt,
            firstSeenAt: records.map(\.firstSeenAt).min()
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
