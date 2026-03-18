import Foundation

struct WorkspaceHeaderSummary: Equatable, Sendable {
    var attention: WorkspaceAttentionSummary?
    var focusedLabel: String?
    var branch: String?
    var pullRequest: WorkspacePullRequestSummary?
    var reviewChips: [WorkspaceReviewChip]
}

struct WorkspacePullRequestSummary: Equatable, Sendable {
    var number: Int
    var url: URL?
    var state: WorkspacePullRequestState
}

enum WorkspacePullRequestState: Equatable, Sendable {
    case draft
    case open
    case merged
    case closed
}

struct WorkspaceReviewChip: Equatable, Sendable {
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

struct WorkspaceReviewState: Equatable, Sendable {
    var branch: String?
    var pullRequest: WorkspacePullRequestSummary?
    var reviewChips: [WorkspaceReviewChip]
}
