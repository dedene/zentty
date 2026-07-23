import Foundation

// MARK: - transcript.*

/// Why a transcript could not be provided.
enum CompanionTranscriptUnavailableReason: String, Codable, Equatable, Sendable {
    case noAdapter = "no_adapter"
    case sessionEnded = "session_ended"
    case fileMissing = "file_missing"
}

/// `transcript.subscribe` (phone → mac).
struct CompanionTranscriptSubscribe: CompanionMessagePayload {
    static let messageType = "transcript.subscribe"

    var paneId: String
}

/// `transcript.snapshot` (mac → phone).
struct CompanionTranscriptSnapshot: CompanionMessagePayload {
    static let messageType = "transcript.snapshot"

    var paneId: String
    var sessionId: String
    var truncated: Bool
    var entries: [CompanionTranscriptEntry]
}

/// `transcript.delta` (mac → phone).
struct CompanionTranscriptDelta: CompanionMessagePayload {
    static let messageType = "transcript.delta"

    var paneId: String
    var entries: [CompanionTranscriptEntry]
}

/// `transcript.unavailable` (mac → phone).
struct CompanionTranscriptUnavailable: CompanionMessagePayload {
    static let messageType = "transcript.unavailable"

    var paneId: String
    var reason: CompanionTranscriptUnavailableReason
}
