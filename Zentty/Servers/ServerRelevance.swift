import Foundation

/// Where a detected server lands in the menu / IPC list after ranking.
enum ServerRelevanceTier: Hashable, Sendable {
    /// The single best visible candidate (default open target).
    case primary
    /// A visible, non-primary server.
    case shown
    /// Suppressed by an ignored-port rule; inspectable but never primary.
    case hidden
}

/// Why a server received its score/tier. Structured so menus, tooltips, IPC, and
/// tests read signals directly instead of parsing debug strings.
enum ServerRelevanceReason: Hashable, Sendable {
    case sessionSelected
    case ignoredPort(Int)
    case manual
    case runningPane
    case focusedPane
    case source(DetectedServerSource)
    case confidence(DetectedServerConfidence)
    case fresh
}

struct RankedServer: Equatable, Sendable {
    let server: DetectedServer
    let tier: ServerRelevanceTier
    let score: Int
    let reasons: Set<ServerRelevanceReason>
}

/// Inputs the scorer reads beyond the detected servers themselves. All volatile
/// signals (focus, running panes, the clock) are supplied live by the caller.
struct ServerRelevanceContext: Sendable {
    let focusedPaneID: PaneID?
    let runningPaneIDs: Set<PaneID>
    let ignoredPortRules: [ServerPortRule]
    let sessionSelectedOrigin: String?
    let now: Date

    init(
        focusedPaneID: PaneID? = nil,
        runningPaneIDs: Set<PaneID> = [],
        ignoredPortRules: [ServerPortRule] = [],
        sessionSelectedOrigin: String? = nil,
        now: Date = Date()
    ) {
        self.focusedPaneID = focusedPaneID
        self.runningPaneIDs = runningPaneIDs
        self.ignoredPortRules = ignoredPortRules
        self.sessionSelectedOrigin = sessionSelectedOrigin
        self.now = now
    }
}

/// Deterministic, pure relevance scorer for detected servers.
///
/// Hides ignored-port servers (except manual ones), scores the rest, and elects a
/// single primary. Activity and focus intentionally outweigh source priority so the
/// server you are actively running surfaces first.
enum ServerRelevance {
    /// A server first seen within this window counts as "fresh".
    static let freshWindow: TimeInterval = 60

    static func rank(_ servers: [DetectedServer], context: ServerRelevanceContext) -> [RankedServer] {
        var visible: [(server: DetectedServer, score: Int, reasons: Set<ServerRelevanceReason>)] = []
        var hidden: [RankedServer] = []

        for server in servers {
            let port = server.url.port ?? server.ports.first
            let isManual = server.source == .manual

            if !isManual, let port, context.ignoredPortRules.contains(where: { $0.contains(port) }) {
                hidden.append(RankedServer(server: server, tier: .hidden, score: 0, reasons: [.ignoredPort(port)]))
                continue
            }

            let scored = score(server, context: context, isManual: isManual)
            visible.append((server, scored.score, scored.reasons))
        }

        let ordered = visible.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.server.origin < rhs.server.origin
        }

        var ranked = ordered.enumerated().map { index, entry in
            RankedServer(
                server: entry.server,
                tier: index == 0 ? .primary : .shown,
                score: entry.score,
                reasons: entry.reasons
            )
        }
        ranked.append(contentsOf: hidden)
        return ranked
    }

    private static func score(
        _ server: DetectedServer,
        context: ServerRelevanceContext,
        isManual: Bool
    ) -> (score: Int, reasons: Set<ServerRelevanceReason>) {
        var score = 0
        var reasons: Set<ServerRelevanceReason> = []

        if let origin = context.sessionSelectedOrigin, server.origin == origin {
            score += 1000
            reasons.insert(.sessionSelected)
        }
        if let paneID = server.paneID, paneID == context.focusedPaneID {
            score += 200
            reasons.insert(.focusedPane)
        }
        if let paneID = server.paneID, context.runningPaneIDs.contains(paneID) {
            score += 150
            reasons.insert(.runningPane)
        }

        score += sourceScore(server.source)
        reasons.insert(.source(server.source))
        if isManual {
            reasons.insert(.manual)
        }

        score += confidenceScore(server.confidence)
        reasons.insert(.confidence(server.confidence))

        if context.now.timeIntervalSince(server.firstSeenAt) <= freshWindow {
            score += 5
            reasons.insert(.fresh)
        }

        return (score, reasons)
    }

    private static func sourceScore(_ source: DetectedServerSource) -> Int {
        switch source {
        case .manual: 80
        case .watch: 60
        case .docker: 40
        case .scanner: 0
        }
    }

    private static func confidenceScore(_ confidence: DetectedServerConfidence) -> Int {
        switch confidence {
        case .explicit: 30
        case .pid: 20
        case .cwd: 10
        case .worklane: 0
        }
    }
}
