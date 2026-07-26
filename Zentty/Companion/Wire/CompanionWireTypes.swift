import Foundation

// MARK: - Message payload protocol

/// A decodable payload that knows the envelope `type` string it belongs to.
///
/// The wire types here are intentionally independent of the app's own agent
/// enums (`PaneAgentState`, `PaneAgentInteractionKind`, …). Mapping between the
/// two lives in a later milestone; on the wire we speak the protocol spelling.
protocol CompanionMessagePayload: Codable, Equatable, Sendable {
    static var messageType: String { get }
}

// MARK: - Shared value types

/// A negotiable inclusive protocol version range: `{min, max}`.
struct CompanionVersionRange: Codable, Equatable, Sendable {
    var min: Int
    var max: Int
}

/// A LAN connection hint carried in a pairing offer.
struct CompanionLanHint: Codable, Equatable, Sendable {
    var host: String
    var port: Int
}

/// A terminal grid measured in character cells.
struct CompanionGrid: Codable, Equatable, Sendable {
    var cols: Int
    var rows: Int
}

// MARK: - Dashboard enums

/// Mirrors `PaneAgentState`, in wire spelling.
enum CompanionPaneState: String, Codable, Equatable, Sendable {
    case starting
    case running
    case needsInput
    case unresolvedStop
    case idle
}

/// Mirrors `PaneAgentInteractionKind`, in wire spelling.
enum CompanionInteractionKind: String, Codable, Equatable, Sendable {
    case none
    case approval
    case question
    case decision
    case auth
    case genericInput
}

/// Mirrors `PaneAgentTaskProgress` on the Mac side.
struct CompanionTaskProgress: Codable, Equatable, Sendable {
    var completed: Int
    var total: Int
}

// MARK: - PaneSummary

/// A single pane row in a dashboard snapshot or delta.
struct CompanionPaneSummary: Codable, Equatable, Sendable {
    var paneId: String
    var worklaneId: String
    var title: String
    var tool: String?
    var state: CompanionPaneState
    var interactionKind: CompanionInteractionKind
    var requiresHumanAttention: Bool
    var workingDirectory: String
    var sessionId: String?
    var hasTranscript: Bool
    /// Mirrors `PaneAgentTaskProgress` on the Mac side.
    var taskProgress: CompanionTaskProgress?
}

// MARK: - Transcript enums & entry

enum CompanionTranscriptRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case system
}

/// A normalized, deliberately lossy transcript line. `toolInput` is open-shaped
/// and preserved verbatim via `CompanionJSONValue`.
struct CompanionTranscriptEntry: Codable, Equatable, Sendable {
    var id: String
    var role: CompanionTranscriptRole
    var ts: Int?
    var text: String?
    var toolName: String?
    var toolInput: CompanionJSONValue?
    var toolResultSummary: String?
    var status: String?
}
