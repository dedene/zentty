import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WindowChromeViewTests: XCTestCase {
    func test_window_chrome_renders_attention_focused_label_branch_pr_and_review_chips() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 900, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: makeNeedsInputAttention(),
            focusedLabel: "Claude Code",
            branch: "feature/review-band",
            pullRequest: WorkspacePullRequestSummary(
                number: 128,
                url: URL(string: "https://example.com/pr/128"),
                state: .draft
            ),
            reviewChips: [
                WorkspaceReviewChip(text: "Draft", style: .info),
                WorkspaceReviewChip(text: "2 failing", style: .danger),
            ]
        ))

        XCTAssertEqual(view.attentionTextForTesting, "Needs input")
        XCTAssertEqual(view.focusedLabelTextForTesting, "Claude Code")
        XCTAssertEqual(view.branchTextForTesting, "feature/review-band")
        XCTAssertEqual(view.pullRequestTextForTesting, "PR #128")
        XCTAssertEqual(view.reviewChipTextsForTesting, ["Draft", "2 failing"])
    }

    func test_window_chrome_renders_branch_without_pr_and_shows_no_pr_chip() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: nil,
            reviewChips: [WorkspaceReviewChip(text: "No PR", style: .neutral)]
        ))

        XCTAssertEqual(view.branchTextForTesting, "main")
        XCTAssertEqual(view.pullRequestTextForTesting, "")
        XCTAssertEqual(view.reviewChipTextsForTesting, ["No PR"])
    }

    func test_window_chrome_renders_non_git_summary_with_only_focused_label() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "zsh",
            branch: nil,
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertEqual(view.focusedLabelTextForTesting, "zsh")
        XCTAssertEqual(view.branchTextForTesting, "")
        XCTAssertEqual(view.pullRequestTextForTesting, "")
        XCTAssertEqual(view.reviewChipTextsForTesting, [])
    }

    func test_window_chrome_hides_attention_chip_when_summary_has_no_attention() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "feature/review-band",
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertTrue(view.isAttentionHiddenForTesting)
    }

    func test_window_chrome_never_surfaces_cwd_text_and_keeps_branch_monospace() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())

        let renderedText = ([view.focusedLabelTextForTesting, view.branchTextForTesting, view.pullRequestTextForTesting] + view.reviewChipTextsForTesting)
            .joined(separator: " ")
        XCTAssertFalse(renderedText.contains("cwd"))
        XCTAssertTrue(view.isBranchMonospacedForTesting)
    }

    func test_window_chrome_keeps_attention_branch_pr_and_review_chips_visible_on_narrow_width_while_truncating_focused_label() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 420, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.isAttentionHiddenForTesting)
        XCTAssertEqual(view.branchTextForTesting, "feature/review-band")
        XCTAssertEqual(view.pullRequestTextForTesting, "PR #128")
        XCTAssertEqual(view.rowLineCountForTesting, 1)
        XCTAssertTrue(
            view.isFocusedLabelCompressedForTesting,
            "focused label width \(view.focusedLabelFrameWidthForTesting) vs intrinsic \(view.focusedLabelIntrinsicWidthForTesting)"
        )
        XCTAssertEqual(view.reviewChipTextsForTesting, ["Draft", "2 failing"])
    }

    func test_window_chrome_keeps_row_visible_inside_cramped_visible_lane() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 360, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())
        view.layoutSubtreeIfNeeded()
        view.leadingVisibleInset = 300
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.rowFrameForTesting.width, 0.5)
        XCTAssertGreaterThanOrEqual(view.rowFrameForTesting.minX, view.visibleLaneFrameForTesting.minX - 0.5)
        XCTAssertEqual(view.rowLineCountForTesting, 1)
    }

    func test_window_chrome_uses_full_visible_lane_width_on_wide_windows() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1440, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.rowFrameForTesting.minX, view.visibleLaneFrameForTesting.minX, accuracy: 0.5)
        XCTAssertEqual(view.rowFrameForTesting.width, view.visibleLaneFrameForTesting.width, accuracy: 0.5)
    }

    func test_window_chrome_centers_content_within_full_visible_lane_when_width_is_available() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1440, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(in: view, withText: "~/Development/Zenjoy/Nimbu/Rails/nimbu"))
        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))
        let pullRequestButton = try XCTUnwrap(findButton(in: view, withTitle: "PR #1413"))
        XCTAssertGreaterThanOrEqual(focusedLabel.frame.width, requiredSingleLineWidth(of: focusedLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(pullRequestButton.frame.width, requiredSingleLineWidth(of: pullRequestButton) - 0.5)
        let contentMinX = min(focusedLabel.frame.minX, branchLabel.frame.minX, pullRequestButton.frame.minX)
        let contentMaxX = max(focusedLabel.frame.maxX, branchLabel.frame.maxX, pullRequestButton.frame.maxX)
        let leftSlack = contentMinX
        let rightSlack = view.rowFrameForTesting.width - contentMaxX

        XCTAssertGreaterThan(leftSlack, 40)
        XCTAssertEqual(leftSlack, rightSlack, accuracy: 24)
        XCTAssertFalse(view.didCompressItemsForTesting)
        XCTAssertEqual(view.preferredTotalWidthForTesting, view.finalTotalWidthForTesting, accuracy: 0.5)
        XCTAssertEqual(view.focusedLabelFrameWidthForTesting, view.focusedLabelIntrinsicWidthForTesting, accuracy: 0.5)
        XCTAssertEqual(view.branchFrameWidthForTesting, view.branchIntrinsicWidthForTesting, accuracy: 0.5)
        XCTAssertEqual(view.pullRequestFrameWidthForTesting, view.pullRequestIntrinsicWidthForTesting, accuracy: 0.5)
    }

    func test_window_chrome_keeps_long_worktree_branch_and_pr_uncompressed_when_visible_lane_is_wide() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1720, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
            branch: "feature/scaleway-transactional-mails",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.overflowBeforeCompressionForTesting, 0, accuracy: 0.5)
        XCTAssertFalse(view.didCompressItemsForTesting)
        XCTAssertEqual(view.preferredTotalWidthForTesting, view.finalTotalWidthForTesting, accuracy: 0.5)
        XCTAssertEqual(view.focusedLabelFrameWidthForTesting, view.focusedLabelIntrinsicWidthForTesting, accuracy: 0.5)
        XCTAssertEqual(view.branchFrameWidthForTesting, view.branchIntrinsicWidthForTesting, accuracy: 0.5)
        XCTAssertEqual(view.pullRequestFrameWidthForTesting, view.pullRequestIntrinsicWidthForTesting, accuracy: 0.5)
    }

    func test_window_chrome_uses_fitting_widths_for_labels_to_avoid_appkit_ellipsis() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1440, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(in: view, withText: "~/Development/Zenjoy/Nimbu/Rails/nimbu"))
        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))

        XCTAssertGreaterThanOrEqual(
            focusedLabel.frame.width,
            focusedLabel.fittingSize.width - 0.5,
            "focused label width \(focusedLabel.frame.width) vs fitting \(focusedLabel.fittingSize.width)"
        )
        XCTAssertGreaterThanOrEqual(
            branchLabel.frame.width,
            branchLabel.fittingSize.width - 0.5,
            "branch width \(branchLabel.frame.width) vs fitting \(branchLabel.fittingSize.width)"
        )
    }

    func test_window_chrome_keeps_long_worktree_path_branch_and_pr_uncompressed_when_visible_lane_is_wide() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1720, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
            branch: "feature/scaleway-transactional-mails",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(
            in: view,
            withText: "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        ))
        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "feature/scaleway-transactional-mails"))
        let pullRequestButton = try XCTUnwrap(findButton(in: view, withTitle: "PR #1413"))

        XCTAssertGreaterThanOrEqual(focusedLabel.frame.width, requiredSingleLineWidth(of: focusedLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(pullRequestButton.frame.width, requiredSingleLineWidth(of: pullRequestButton) - 0.5)
    }

    func test_window_chrome_expands_path_branch_and_pr_back_to_preferred_widths_after_growing_from_narrow_to_wide() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
            branch: "feature/scaleway-transactional-mails",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        view.frame = NSRect(x: 0, y: 0, width: 1720, height: WindowChromeView.preferredHeight)
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(
            in: view,
            withText: "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        ))
        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "feature/scaleway-transactional-mails"))
        let pullRequestButton = try XCTUnwrap(findButton(in: view, withTitle: "PR #1413"))

        XCTAssertGreaterThanOrEqual(focusedLabel.frame.width, requiredSingleLineWidth(of: focusedLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(pullRequestButton.frame.width, requiredSingleLineWidth(of: pullRequestButton) - 0.5)
    }

    func test_window_chrome_keeps_short_branch_fully_visible_for_long_worktree_titles() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
    }

    func test_window_chrome_keeps_short_repo_path_and_main_uncompressed_when_visible_lane_is_wide() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1720, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(in: view, withText: "~/Development/Zenjoy/Nimbu/Rails/nimbu"))
        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))

        XCTAssertGreaterThanOrEqual(focusedLabel.frame.width, requiredSingleLineWidth(of: focusedLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
    }

    func test_window_chrome_expands_short_repo_path_and_main_back_to_preferred_widths_after_growing_from_narrow_to_wide() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        view.frame = NSRect(x: 0, y: 0, width: 1720, height: WindowChromeView.preferredHeight)
        view.layoutSubtreeIfNeeded()

        let focusedLabel = try XCTUnwrap(findLabel(in: view, withText: "~/Development/Zenjoy/Nimbu/Rails/nimbu"))
        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))

        XCTAssertGreaterThanOrEqual(focusedLabel.frame.width, requiredSingleLineWidth(of: focusedLabel) - 0.5)
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
    }

    func test_window_chrome_keeps_short_branch_and_four_digit_pull_request_readable_in_tight_lane() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 360, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))
        view.layoutSubtreeIfNeeded()
        view.leadingVisibleInset = 240
        view.layoutSubtreeIfNeeded()

        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
        XCTAssertEqual(view.pullRequestTextForTesting, "PR #1413")
        XCTAssertGreaterThanOrEqual(
            view.pullRequestFrameWidthForTesting,
            view.pullRequestIntrinsicWidthForTesting - 0.5,
            "pull request width \(view.pullRequestFrameWidthForTesting) vs intrinsic \(view.pullRequestIntrinsicWidthForTesting)"
        )
    }

    func test_window_chrome_keeps_last_review_chip_visible_before_compressing_short_branch() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 360, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceHeaderSummary(
            attention: nil,
            focusedLabel: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: [WorkspaceReviewChip(text: "1 failing", style: .danger)]
        ))
        view.layoutSubtreeIfNeeded()
        view.leadingVisibleInset = 240
        view.layoutSubtreeIfNeeded()

        let branchLabel = try XCTUnwrap(findLabel(in: view, withText: "main"))
        XCTAssertGreaterThanOrEqual(branchLabel.frame.width, requiredSingleLineWidth(of: branchLabel) - 0.5)
        XCTAssertEqual(view.reviewChipTextsForTesting, ["1 failing"])
        XCTAssertGreaterThanOrEqual(
            view.pullRequestFrameWidthForTesting,
            view.pullRequestIntrinsicWidthForTesting - 0.5,
            "pull request width \(view.pullRequestFrameWidthForTesting) vs intrinsic \(view.pullRequestIntrinsicWidthForTesting)"
        )
    }

    private func makeNeedsInputAttention() -> WorkspaceAttentionSummary {
        WorkspaceAttentionSummary(
            paneID: PaneID("pane-shell"),
            tool: .claudeCode,
            state: .needsInput,
            primaryText: "Claude Code",
            statusText: "Needs input",
            contextText: "project • feature/review-band",
            artifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeCrowdedSummary() -> WorkspaceHeaderSummary {
        WorkspaceHeaderSummary(
            attention: makeNeedsInputAttention(),
            focusedLabel: "Claude Code Session With An Intentionally Long Focus Label",
            branch: "feature/review-band",
            pullRequest: WorkspacePullRequestSummary(
                number: 128,
                url: URL(string: "https://example.com/pr/128"),
                state: .draft
            ),
            reviewChips: [
                WorkspaceReviewChip(text: "Draft", style: .info),
                WorkspaceReviewChip(text: "2 failing", style: .danger),
            ]
        )
    }

    private func requiredSingleLineWidth(of label: NSTextField) -> CGFloat {
        ceil(max(label.fittingSize.width, label.intrinsicContentSize.width))
    }

    private func requiredSingleLineWidth(of button: NSButton) -> CGFloat {
        ceil(max(button.fittingSize.width, button.intrinsicContentSize.width))
    }

    private func findLabel(in rootView: NSView, withText text: String) -> NSTextField? {
        if let label = rootView as? NSTextField, label.stringValue == text {
            return label
        }

        for subview in rootView.subviews {
            if let match = findLabel(in: subview, withText: text) {
                return match
            }
        }

        return nil
    }

    private func findButton(in rootView: NSView, withTitle title: String) -> NSButton? {
        if let button = rootView as? NSButton, button.title == title {
            return button
        }

        for subview in rootView.subviews {
            if let match = findButton(in: subview, withTitle: title) {
                return match
            }
        }

        return nil
    }
}
