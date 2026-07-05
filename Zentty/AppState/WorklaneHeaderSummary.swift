import Foundation

/// Formats a short, human-relative "time since" string for the PR-status age tooltip
/// (e.g. "just now", "4m ago", "2h ago"). Kept pure so it can be unit-tested off the main actor.
enum ReviewAgeFormatter {
    static func string(since fetchedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(fetchedAt))
        switch seconds {
        case ..<45:
            return "just now"
        case ..<90:
            return "1m ago"
        case ..<3600:
            return "\(Int((seconds / 60).rounded()))m ago"
        case ..<86_400:
            return "\(Int(seconds / 3600))h ago"
        default:
            return "\(Int(seconds / 86_400))d ago"
        }
    }
}

struct WorklaneChromeSummary: Equatable, Sendable {
    var attention: WorklaneAttentionSummary?
    /// Custom worklane name, shown left of the proxy icon when set.
    var worklaneTitle: String?
    var focusedLabel: String?
    var remoteContextLabel: String?
    var cwdPath: String?
    var branch: String?
    var branchURL: URL?
    var pullRequest: WorklanePullRequestSummary?
    var reviewChips: [WorklaneReviewChip]
    /// When the PR/review data behind this summary was last fetched. Drives the staleness
    /// dimming and the relative-age tooltip. `nil` when there is no PR data.
    var reviewFetchedAt: Date?
    /// True when the most recent refresh attempt failed and we are showing preserved (stale) data.
    var reviewRefreshFailed: Bool

    init(
        attention: WorklaneAttentionSummary?,
        worklaneTitle: String? = nil,
        focusedLabel: String?,
        remoteContextLabel: String? = nil,
        cwdPath: String? = nil,
        branch: String?,
        branchURL: URL? = nil,
        pullRequest: WorklanePullRequestSummary?,
        reviewChips: [WorklaneReviewChip],
        reviewFetchedAt: Date? = nil,
        reviewRefreshFailed: Bool = false
    ) {
        self.attention = attention
        self.worklaneTitle = worklaneTitle
        self.focusedLabel = focusedLabel
        self.remoteContextLabel = remoteContextLabel
        self.cwdPath = cwdPath
        self.branch = branch
        self.branchURL = branchURL
        self.pullRequest = pullRequest
        self.reviewChips = reviewChips
        self.reviewFetchedAt = reviewFetchedAt
        self.reviewRefreshFailed = reviewRefreshFailed
    }
}

struct WorklanePullRequestSummary: Equatable, Sendable {
    var number: Int
    var url: URL?
    var state: WorklanePullRequestState
}

enum WorklanePullRequestState: Equatable, Sendable {
    case draft
    case open
    case merged
    case closed
}

struct WorklaneReviewChip: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case neutral
        case success
        case warning
        case danger
        case info
    }

    var text: String
    var style: Style
}

/// Aggregate state of a pull request's CI checks, used to drive the adaptive poll cadence.
enum WorklaneChecksState: Equatable, Sendable {
    /// No checks reported (or not applicable, e.g. no PR).
    case none
    /// At least one check is queued or in progress.
    case running
    /// All checks completed successfully.
    case passed
    /// At least one check failed.
    case failing
}

struct WorklaneReviewState: Equatable, Sendable {
    var branch: String?
    var branchURL: URL?
    var pullRequest: WorklanePullRequestSummary?
    var reviewChips: [WorklaneReviewChip]
    /// When this state was fetched from `gh`. Drives cache TTL, staleness dimming, and the age tooltip.
    var reviewFetchedAt: Date?
    /// True when the last refresh attempt failed and this is preserved (stale) data.
    var reviewRefreshFailed: Bool = false
    /// Aggregate CI state, used by the poller to pick an adaptive interval.
    var checksState: WorklaneChecksState = .none
}
