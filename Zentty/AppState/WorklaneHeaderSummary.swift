import Foundation

struct WorklaneChromeSummary: Equatable, Sendable {
    var attention: WorklaneAttentionSummary?
    var focusedLabel: String?
    var branch: String?
    var branchURL: URL?
    var pullRequest: WorklanePullRequestSummary?
    var reviewChips: [WorklaneReviewChip]
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

struct WorklaneReviewState: Equatable, Sendable {
    var branch: String?
    var branchURL: URL?
    var pullRequest: WorklanePullRequestSummary?
    var reviewChips: [WorklaneReviewChip]
}
