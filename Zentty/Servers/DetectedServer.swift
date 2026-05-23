import Foundation

enum DetectedServerSource: String, Codable, Equatable, Sendable {
    case manual
    case watch
    case docker
    case scanner
}

enum DetectedServerConfidence: String, Codable, Equatable, Sendable {
    case explicit
    case pid
    case cwd
    case worklane
}

struct DetectedServer: Equatable, Identifiable, Sendable {
    let id: String
    let origin: String
    var url: URL
    var display: String
    var worklaneID: WorklaneID
    var paneID: PaneID?
    var source: DetectedServerSource
    var ports: [Int]
    var confidence: DetectedServerConfidence
    var updatedAt: Date
    /// When this record was first observed. Stamped once and preserved by
    /// `ServerRegistry` across polling refreshes; used as a freshness signal by
    /// `ServerRelevance`. Defaults to `updatedAt` for newly constructed records.
    var firstSeenAt: Date

    init(
        id: String,
        origin: String,
        url: URL,
        display: String,
        worklaneID: WorklaneID,
        paneID: PaneID?,
        source: DetectedServerSource,
        ports: [Int],
        confidence: DetectedServerConfidence,
        updatedAt: Date,
        firstSeenAt: Date? = nil
    ) {
        self.id = id
        self.origin = origin
        self.url = url
        self.display = display
        self.worklaneID = worklaneID
        self.paneID = paneID
        self.source = source
        self.ports = ports
        self.confidence = confidence
        self.updatedAt = updatedAt
        self.firstSeenAt = firstSeenAt ?? updatedAt
    }
}
