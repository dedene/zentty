import Foundation

/// Text with highlight ranges (UTF-16) to draw over it.
struct AgentHistoryHighlightedText: Equatable {
    let text: String
    let ranges: [NSRange]

    init(_ text: String, ranges: [NSRange] = []) {
        self.text = text
        self.ranges = ranges
    }
}

/// A content hit's excerpt under a row: who wrote it and the highlighted 150-character snippet.
struct AgentHistorySnippetLine: Equatable {
    let role: HistoryHitRole
    let text: AgentHistoryHighlightedText
}

/// One palette row. Identity is the session key, not the index row id: a "Running now" row may
/// have no index row yet (A-12).
struct AgentHistoryResultRow: Equatable, Identifiable {
    let key: AgentHistorySessionKey
    var summary: AgentHistorySessionSummary?
    var live: LiveAgentSessionLocation?
    var title: AgentHistoryHighlightedText
    /// Why the row matched when its title didn't (`Branch: …`, `Changed: …`).
    var note: HistoryMatchNote?
    var snippet: AgentHistorySnippetLine?
    /// Content hits in this session; "N matches" shows when > 1.
    var hitCount: Int
    /// When the best content hit was written; nil for metadata and recent rows.
    var matchedAt: Date?
    /// Left over from the previous query until the new content response arrives.
    var isStale: Bool

    var id: AgentHistorySessionKey { key }
    var sessionID: Int64? { summary?.id }
    var agent: AgentHistoryAgent { key.agent }
    /// The time the right column shows: the matching message, else the last activity.
    var displayDate: Date? { matchedAt ?? summary?.updatedAt ?? live?.updatedAt }

    init(
        key: AgentHistorySessionKey,
        summary: AgentHistorySessionSummary?,
        live: LiveAgentSessionLocation? = nil,
        title: AgentHistoryHighlightedText,
        note: HistoryMatchNote? = nil,
        snippet: AgentHistorySnippetLine? = nil,
        hitCount: Int = 0,
        matchedAt: Date? = nil,
        isStale: Bool = false
    ) {
        self.key = key
        self.summary = summary
        self.live = live
        self.title = title
        self.note = note
        self.snippet = snippet
        self.hitCount = hitCount
        self.matchedAt = matchedAt
        self.isStale = isStale
    }

    /// A "Recent" row.
    init(summary: AgentHistorySessionSummary, live: LiveAgentSessionLocation? = nil) {
        self.init(key: summary.key, summary: summary, live: live, title: AgentHistoryHighlightedText(summary.title))
    }

    /// A "Running now" row; without an index row it shows the pane's name.
    init(live: LiveAgentSessionLocation, summary: AgentHistorySessionSummary?) {
        self.init(
            key: live.key,
            summary: summary,
            live: live,
            title: AgentHistoryHighlightedText(summary?.title ?? live.paneDisplayName)
        )
    }

    /// A "Sessions" row.
    init(metadata: HistoryMetadataResult) {
        self.init(
            key: metadata.session.key,
            summary: metadata.session,
            title: AgentHistoryHighlightedText(metadata.session.title, ranges: metadata.titleHighlights),
            note: metadata.note
        )
    }

    /// An "In conversations" row.
    init(content: HistoryContentResult) {
        self.init(
            key: content.session.key,
            summary: content.session,
            title: AgentHistoryHighlightedText(content.session.title, ranges: content.titleHighlights),
            note: content.note,
            snippet: content.snippet.map {
                AgentHistorySnippetLine(
                    role: content.best.role,
                    text: AgentHistoryHighlightedText($0.text, ranges: $0.highlights)
                )
            },
            hitCount: content.totalHits,
            matchedAt: content.best.at
        )
    }
}

enum AgentHistorySectionKind: Equatable, CaseIterable {
    case runningNow
    case recent
    case sessions
    case inConversations

    var title: String {
        switch self {
        case .runningNow: "Running now"
        case .recent: "Recent"
        case .sessions: "Sessions"
        case .inConversations: "In conversations"
        }
    }
}

struct AgentHistorySection: Equatable, Identifiable {
    let kind: AgentHistorySectionKind
    var rows: [AgentHistoryResultRow]
    /// The muted note beside the header ("↩ jumps to the pane", "1,284 sessions").
    var note: String?

    var id: AgentHistorySectionKind { kind }
}

/// A filter pill under the search field, from an operator token as typed.
struct AgentHistoryFilterPill: Equatable, Identifiable {
    let key: HistoryOperatorToken.Key
    let value: String
    /// `key:` with nothing typed after it yet.
    let isPending: Bool

    var id: String { "\(key.rawValue):\(value)" }

    var label: String {
        isPending ? "\(Self.keyTitle(key)):" : "\(Self.keyTitle(key)): \(value)"
    }

    var accessibilityLabel: String {
        isPending ? "\(Self.keyTitle(key)) filter, waiting for a value" : "\(Self.keyTitle(key)) filter: \(value)"
    }

    /// Valid and pending operators, in typed order. Invalid values search as plain text, so
    /// they get no pill.
    static func pills(for query: HistoryQuery) -> [AgentHistoryFilterPill] {
        query.operatorTokens.compactMap { token in
            guard token.isPending || token.isValid else {
                return nil
            }
            return AgentHistoryFilterPill(key: token.key, value: token.rawValue, isPending: token.isPending)
        }
    }

    static func keyTitle(_ key: HistoryOperatorToken.Key) -> String {
        switch key {
        case .agent: "Agent"
        case .repo: "Repo"
        case .branch: "Branch"
        case .before: "Before"
        case .after: "After"
        }
    }
}

/// What a content response does to the palette: the new "In conversations" rows and the
/// "Sessions" rows with their content enrichment applied.
struct AgentHistoryContentMerge: Equatable {
    let conversations: [AgentHistoryResultRow]
    let sessions: [AgentHistoryResultRow]
}

/// Pure merging rules for the two search tiers. Content rows never duplicate a "Sessions" row,
/// and a content response never reorders the rows above it.
enum AgentHistoryResultMerger {
    static let sessionsLimit = 20
    static let conversationsLimit = 30

    static func metadataRows(_ response: HistoryMetadataResponse) -> [AgentHistoryResultRow] {
        response.results.prefix(sessionsLimit).map(AgentHistoryResultRow.init(metadata:))
    }

    /// The previous query's content rows, kept (marked stale) until the new response arrives;
    /// sessions now shown under "Sessions" are dropped.
    static func staleContent(
        _ rows: [AgentHistoryResultRow],
        droppingSessionsIn metadataIDs: Set<Int64>
    ) -> [AgentHistoryResultRow] {
        rows.compactMap { row in
            if let id = row.sessionID, metadataIDs.contains(id) {
                return nil
            }
            var stale = row
            stale.isStale = true
            return stale
        }
    }

    /// Replaces the stale content rows with the response's ranked rows (minus sessions already
    /// in `metadataRows`) and applies its enrichments to `metadataRows` in place.
    static func applyContent(
        response: HistoryContentResponse,
        to metadataRows: [AgentHistoryResultRow],
        metadataIDs: Set<Int64>
    ) -> AgentHistoryContentMerge {
        var seen = metadataIDs
        var conversations: [AgentHistoryResultRow] = []
        for result in response.results where conversations.count < conversationsLimit {
            guard seen.insert(result.session.id).inserted else {
                continue
            }
            conversations.append(AgentHistoryResultRow(content: result))
        }
        let sessions = metadataRows.map { row -> AgentHistoryResultRow in
            guard let id = row.sessionID, let enrichment = response.enrichments[id] else {
                return row
            }
            var enriched = row
            enriched.hitCount = enrichment.totalHits
            return enriched
        }
        return AgentHistoryContentMerge(conversations: conversations, sessions: sessions)
    }

    /// Keeps the selected session when it is still listed; otherwise the row now at the
    /// previous position (clamped), else the first row.
    static func resolveSelection(
        previous: AgentHistorySessionKey?,
        previousIndex: Int?,
        in rows: [AgentHistoryResultRow]
    ) -> AgentHistorySessionKey? {
        guard !rows.isEmpty else {
            return nil
        }
        if let previous, rows.contains(where: { $0.key == previous }) {
            return previous
        }
        let index = min(max(previousIndex ?? 0, 0), rows.count - 1)
        return rows[index].key
    }
}
