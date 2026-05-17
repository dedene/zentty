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
}
