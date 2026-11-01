import Foundation
import os

/// What a search runs against: the scope, the repository of the pane the search started from
/// (for the ranking boost) and the clock used for recency.
struct HistorySearchContext: Hashable, Sendable {
    var scope: AgentHistoryScope
    /// Canonical main repo root (else repo root) of the current worklane; nil outside a repo.
    var currentRepositoryKey: String?
    var now: Date

    init(scope: AgentHistoryScope, currentRepositoryKey: String? = nil, now: Date = Date()) {
        self.scope = scope
        self.currentRepositoryKey = currentRepositoryKey
        self.now = now
    }
}

/// Who wrote the text a content hit matched.
enum HistoryHitRole: Hashable, Sendable {
    case user
    case agent
    case artifact(AgentHistoryArtifactKind)

    init(_ role: AgentHistoryRole) {
        switch role {
        case .user: self = .user
        case .agent: self = .agent
        }
    }

    var isArtifact: Bool {
        if case .artifact = self { return true }
        return false
    }

    /// Tie-break order between equally good hits: user, then agent, then artifact.
    var tieBreakPriority: Int {
        switch self {
        case .user: 0
        case .agent: 1
        case .artifact: 2
        }
    }
}

/// A session field the metadata tier grades.
enum HistoryMetadataField: String, Hashable, Sendable {
    case title, branch, repo, folder
}

/// Why a row matched when its title did not: `Branch: …`, `Repo: …`, `Changed: path`, `Ran: …`.
enum HistoryMatchNote: Hashable, Sendable {
    case field(HistoryMetadataField, value: String)
    case artifact(AgentHistoryArtifactKind, value: String)
}

/// One graded message or artifact row of the content tier.
struct HistoryContentHit: Hashable, Sendable {
    /// Artifact hits weigh slightly less than a message hit of the same grade.
    static let artifactQualityFactor = 0.9

    let sessionID: Int64
    /// `messages.id` or `artifacts.id`.
    let rowID: Int64
    let role: HistoryHitRole
    let atMs: Int64
    /// The graded quality, already multiplied by `artifactQualityFactor` for artifact hits.
    let quality: Double
    /// From the unweighted grade (`HistoryGrade.isWordLevel`).
    let isWordLevel: Bool
    /// The matched artifact value (for the `Changed:` / `Ran:` note); nil for messages.
    let artifactValue: String?

    var at: Date { Date(timeIntervalSince1970: TimeInterval(atMs) / 1000) }

    /// `gradedQuality` is the matcher's quality; the artifact discount is applied here, once.
    init(
        sessionID: Int64,
        rowID: Int64,
        role: HistoryHitRole,
        atMs: Int64,
        gradedQuality: Double,
        isWordLevel: Bool,
        artifactValue: String? = nil
    ) {
        self.sessionID = sessionID
        self.rowID = rowID
        self.role = role
        self.atMs = atMs
        self.quality = role.isArtifact ? gradedQuality * Self.artifactQualityFactor : gradedQuality
        self.isWordLevel = isWordLevel
        self.artifactValue = artifactValue
    }

    init(sessionID: Int64, rowID: Int64, role: HistoryHitRole, atMs: Int64, grade: HistoryGrade,
         artifactValue: String? = nil) {
        self.init(
            sessionID: sessionID,
            rowID: rowID,
            role: role,
            atMs: atMs,
            gradedQuality: grade.quality,
            isWordLevel: grade.isWordLevel,
            artifactValue: artifactValue
        )
    }
}

/// A row of the metadata tier ("Sessions").
struct HistoryMetadataResult: Equatable, Sendable {
    let session: AgentHistorySessionSummary
    let score: Double
    let isWordLevel: Bool
    let titleHighlights: [NSRange]
    /// The best non-title field when it matched; nil when only the title matched.
    let note: HistoryMatchNote?
}

/// A session of the content tier ("In conversations"), or an enrichment of a metadata row.
struct HistoryContentResult: Equatable, Sendable {
    let session: AgentHistorySessionSummary
    let best: HistoryContentHit
    /// Hits whose quality equals the best one's (within 1e-9); feeds the hits multiplier.
    let bestQualityHits: Int
    let totalHits: Int
    let score: Double
    let isWordLevel: Bool
    let snippet: HistorySnippet?
    let note: HistoryMatchNote?
    let titleHighlights: [NSRange]
}

struct HistoryMetadataResponse: Equatable, Sendable {
    let query: HistoryQuery
    /// The metadata snapshot generation the results came from.
    let generation: UInt64
    let results: [HistoryMetadataResult]
    let elapsed: TimeInterval
}

struct HistoryContentResponse: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Full-text index.
        case fts
        /// No usable tokenizer: `instr` over the newest messages only.
        case scanFallback
        /// Every term too short for the content tier; no query ran.
        case metadataOnly
    }

    let query: HistoryQuery
    /// The cancellation generation the search ran under.
    let generation: UInt64
    let results: [HistoryContentResult]
    /// Content hits of sessions already shown by the metadata tier, keyed by session id.
    let enrichments: [Int64: HistoryContentResult]
    let mode: Mode
    /// The ordered scan stopped at its row limit, so older hits were not considered.
    let truncated: Bool
    let elapsed: TimeInterval
}

/// One message of a session, with highlight ranges (UTF-16) on `text`.
struct HistoryTurnMatch: Equatable, Sendable {
    let messageID: Int64
    let seq: Int
    let role: AgentHistoryRole
    let at: Date
    let text: String
    let highlights: [NSRange]
}

/// One CLI search row: the better of a session's metadata and content matches.
struct HistoryMergedResult: Equatable, Sendable {
    enum Match: Equatable, Sendable {
        case content(role: HistoryHitRole, at: Date, snippet: HistorySnippet?, note: HistoryMatchNote?)
        case metadata(note: HistoryMatchNote?)
    }

    let session: AgentHistorySessionSummary
    let score: Double
    let isWordLevel: Bool
    let match: Match
}

enum HistorySearchError: Error, Equatable {
    case cancelled
    /// The index cannot be read; the associated value is a state name, never a message.
    case indexUnavailable(String)
    /// The session row is gone (removed, purged or hidden) or excluded.
    case sessionNotFound
}

/// The preview pane's content for one session: the turns that match the query, or, without
/// content terms (or without a matching turn), the first user prompt and the latest agent reply.
struct HistoryPreview: Equatable, Sendable {
    let session: AgentHistorySessionSummary
    let turns: [HistoryTurnMatch]
    let turnsAreMatches: Bool
}

/// A session's full transcript, oldest first, capped at `HistorySearchEngine.transcriptLimit`
/// (the latest turns when longer).
struct HistoryTranscript: Equatable, Sendable {
    let turns: [HistoryTurnMatch]
    /// The first turn the query grades as a match; nil without terms or without a match.
    let firstMatchMessageID: Int64?
    /// Older turns were left out.
    let isTruncated: Bool
}

/// A per-query cancellation flag, checked by the content tier between rows and by SQLite's
/// progress handler.
final class HistorySearchCancellation: Sendable {
    let generation: UInt64
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(generation: UInt64 = 0) {
        self.generation = generation
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}
