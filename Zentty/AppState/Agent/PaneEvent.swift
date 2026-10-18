import Foundation

/// Event types on the `zentty events` stream.
enum PaneEventType: String, CaseIterable, Sendable {
    case worklaneCreated = "worklane.created"
    case worklaneClosed = "worklane.closed"
    /// A window switched to this worklane.
    case worklaneActivated = "worklane.activated"
    case paneCreated = "pane.created"
    case paneClosed = "pane.closed"
    case paneMoved = "pane.moved"
    case paneFocused = "pane.focused"
    case agentPhase = "agent.phase"
    case attentionRaised = "attention.raised"
    case attentionCleared = "attention.cleared"
    /// First line after subscribing: the stream is live.
    case streamReady = "stream.ready"
    /// Events were dropped because the client fell behind.
    case streamDropped = "stream.dropped"
}

/// One line of the `zentty events` NDJSON stream: a small versioned
/// envelope (`v`, `type`, `ts`) plus the fields that apply to the type.
/// Absent fields are omitted rather than written as null.
struct PaneEvent: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int = PaneEvent.currentVersion
    var type: String
    var ts: String = ""
    var window: String?
    var worklane: String?
    var pane: String?
    var agent: String?
    var phase: String?
    var previousPhase: String?
    var interaction: String?
    var attention: String?
    var previousAttention: String?
    var fromWorklane: String?
    var count: Int?

    enum CodingKeys: String, CodingKey {
        case v, type, ts, window, worklane, pane, agent, phase, interaction, attention, count
        case previousPhase = "previous_phase"
        case previousAttention = "previous_attention"
        case fromWorklane = "from_worklane"
    }

    init(
        type: PaneEventType,
        window: String? = nil,
        worklane: String? = nil,
        pane: String? = nil,
        agent: String? = nil,
        phase: String? = nil,
        previousPhase: String? = nil,
        interaction: String? = nil,
        attention: String? = nil,
        previousAttention: String? = nil,
        fromWorklane: String? = nil,
        count: Int? = nil
    ) {
        self.type = type.rawValue
        self.window = window
        self.worklane = worklane
        self.pane = pane
        self.agent = agent
        self.phase = phase
        self.previousPhase = previousPhase
        self.interaction = interaction
        self.attention = attention
        self.previousAttention = previousAttention
        self.fromWorklane = fromWorklane
        self.count = count
    }

    /// Returns a copy stamped with `date` as an ISO 8601 UTC timestamp.
    func stamped(_ date: Date) -> PaneEvent {
        var copy = self
        copy.ts = PaneEvent.timestamp(date)
        return copy
    }

    /// One NDJSON line, newline-terminated.
    func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!)
        )
    }
}
