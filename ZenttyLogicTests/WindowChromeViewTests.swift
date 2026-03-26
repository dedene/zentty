import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WindowChromeViewTests: XCTestCase {
    func test_window_chrome_renders_attention_focused_label_branch_pr_and_review_chips() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 900, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
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

        XCTAssertEqual(view.attentionText, "Needs input")
        XCTAssertEqual(view.focusedLabelText, "Claude Code")
        XCTAssertEqual(view.branchText, "feature/review-band")
        XCTAssertEqual(view.pullRequestText, "PR #128")
        XCTAssertEqual(view.reviewChipTexts, ["Draft", "2 failing"])
    }

    func test_window_chrome_renders_branch_without_pr_and_hides_review_chips() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertEqual(view.branchText, "main")
        XCTAssertEqual(view.pullRequestText, "")
        XCTAssertEqual(view.reviewChipTexts, [])
    }

    func test_window_chrome_renders_non_git_summary_with_only_focused_label() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "zsh",
            branch: nil,
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertEqual(view.focusedLabelText, "zsh")
        XCTAssertEqual(view.branchText, "")
        XCTAssertEqual(view.pullRequestText, "")
        XCTAssertEqual(view.reviewChipTexts, [])
    }

    func test_window_chrome_hides_attention_chip_when_summary_has_no_attention() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "feature/review-band",
            pullRequest: nil,
            reviewChips: []
        ))

        XCTAssertTrue(view.isAttentionHidden)
    }

    func test_window_chrome_never_surfaces_cwd_text_and_keeps_branch_monospace() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 520, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())

        let renderedText = ([view.focusedLabelText, view.branchText, view.pullRequestText] + view.reviewChipTexts)
            .joined(separator: " ")
        XCTAssertFalse(renderedText.contains("cwd"))
        XCTAssertTrue(view.isBranchMonospaced)
    }

    func test_window_chrome_keeps_attention_branch_pr_and_review_chips_visible_on_narrow_width_while_truncating_focused_label() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 420, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.isAttentionHidden)
        XCTAssertEqual(view.branchText, "feature/review-band")
        XCTAssertEqual(view.pullRequestText, "PR #128")
        XCTAssertEqual(view.rowLineCount, 1)
        XCTAssertTrue(
            view.isFocusedLabelCompressed,
            "focused label width \(view.focusedLabelFrameWidth) vs intrinsic \(view.focusedLabelIntrinsicWidth)"
        )
        XCTAssertEqual(view.reviewChipTexts, ["Draft", "2 failing"])
    }

    func test_window_chrome_keeps_row_visible_inside_cramped_visible_lane() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 360, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())
        view.layoutSubtreeIfNeeded()
        view.leadingVisibleInset = 300
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.rowFrame.width, 0.5)
        XCTAssertGreaterThanOrEqual(view.rowFrame.minX, view.visibleLaneFrame.minX - 0.5)
        XCTAssertEqual(view.rowLineCount, 1)
    }

    func test_window_chrome_uses_full_visible_lane_width_on_wide_windows() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1440, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "~/Development/Zenjoy/Nimbu/Rails/nimbu",
            branch: "main",
            pullRequest: nil,
            reviewChips: []
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.rowFrame.minX, view.visibleLaneFrame.minX, accuracy: 0.5)
        XCTAssertEqual(view.rowFrame.width, view.visibleLaneFrame.width, accuracy: 0.5)
    }

    func test_window_chrome_centers_content_within_full_visible_lane_when_width_is_available() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1440, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
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
        let rightSlack = view.rowFrame.width - contentMaxX

        XCTAssertGreaterThan(leftSlack, 40)
        XCTAssertEqual(leftSlack, rightSlack, accuracy: 24)
        XCTAssertFalse(view.didCompressItems)
        XCTAssertEqual(view.preferredTotalWidth, view.finalTotalWidth, accuracy: 0.5)
        XCTAssertEqual(view.focusedLabelFrameWidth, view.focusedLabelIntrinsicWidth, accuracy: 0.5)
        XCTAssertEqual(view.branchFrameWidth, view.branchIntrinsicWidth, accuracy: 0.5)
        XCTAssertEqual(view.pullRequestFrameWidth, view.pullRequestIntrinsicWidth, accuracy: 0.5)
    }

    func test_window_chrome_keeps_long_worktree_branch_and_pr_uncompressed_when_visible_lane_is_wide() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1720, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
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

        XCTAssertEqual(view.overflowBeforeCompression, 0, accuracy: 0.5)
        XCTAssertFalse(view.didCompressItems)
        XCTAssertEqual(view.preferredTotalWidth, view.finalTotalWidth, accuracy: 0.5)
        XCTAssertEqual(view.focusedLabelFrameWidth, view.focusedLabelIntrinsicWidth, accuracy: 0.5)
        XCTAssertEqual(view.branchFrameWidth, view.branchIntrinsicWidth, accuracy: 0.5)
        XCTAssertEqual(view.pullRequestFrameWidth, view.pullRequestIntrinsicWidth, accuracy: 0.5)
    }

    func test_window_chrome_uses_fitting_widths_for_labels_to_avoid_appkit_ellipsis() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 1440, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
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

        view.render(summary: WorkspaceChromeSummary(
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

        view.render(summary: WorkspaceChromeSummary(
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

        view.render(summary: WorkspaceChromeSummary(
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

        view.render(summary: WorkspaceChromeSummary(
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

        view.render(summary: WorkspaceChromeSummary(
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

    func test_window_chrome_keeps_four_digit_pull_request_padded_in_tight_lane_before_branch() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 360, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
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
        XCTAssertGreaterThan(branchLabel.frame.width, 0.5)
        XCTAssertEqual(view.pullRequestText, "PR #1413")
        XCTAssertGreaterThanOrEqual(
            view.pullRequestFrameWidth,
            view.pullRequestIntrinsicWidth - 0.5,
            "pull request width \(view.pullRequestFrameWidth) vs intrinsic \(view.pullRequestIntrinsicWidth)"
        )
    }

    func test_window_chrome_drops_tight_lane_review_chip_before_shrinking_four_digit_pull_request() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 360, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
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
        XCTAssertGreaterThan(branchLabel.frame.width, 0.5)
        XCTAssertEqual(view.reviewChipTexts, ["1 failing"])
        XCTAssertGreaterThanOrEqual(
            view.pullRequestFrameWidth,
            view.pullRequestIntrinsicWidth - 0.5,
            "pull request width \(view.pullRequestFrameWidth) vs intrinsic \(view.pullRequestIntrinsicWidth)"
        )
        XCTAssertLessThan(view.finalTotalWidth, view.preferredTotalWidth)
    }

    func test_window_chrome_reserves_trailing_lane_for_open_with_split_button() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: makeCrowdedSummary())
        view.render(openWith: WindowChromeOpenWithState(
            title: "Cursor",
            icon: nil,
            isPrimaryEnabled: true,
            isMenuEnabled: true
        ))
        view.leadingVisibleInset = 280
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.openWithControlFrame.width, 0.5)
        XCTAssertLessThanOrEqual(view.visibleLaneFrame.maxX, view.openWithControlFrame.minX - 8)
        XCTAssertLessThanOrEqual(view.rowFrame.maxX, view.visibleLaneFrame.maxX + 0.5)
    }

    func test_window_chrome_uses_larger_open_with_glass_button_geometry() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(openWith: WindowChromeOpenWithState(
            title: "Cursor",
            icon: nil,
            isPrimaryEnabled: true,
            isMenuEnabled: true
        ))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.openWithControlFrame.height, 30, accuracy: 0.5)
        XCTAssertEqual(view.openWithControlFrame.width, 66, accuracy: 0.5)
        XCTAssertEqual(view.openWithPrimaryFrame.width, 40, accuracy: 0.5)
        XCTAssertEqual(view.openWithMenuFrame.width, 24, accuracy: 0.5)
    }

    func test_window_chrome_open_with_control_uses_dedicated_theme_tokens() {
        let theme = ZenttyTheme.fallback(for: nil)
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.apply(theme: theme, animated: false)
        view.render(openWith: WindowChromeOpenWithState(
            title: "Cursor",
            icon: nil,
            isPrimaryEnabled: true,
            isMenuEnabled: true
        ))

        XCTAssertEqual(view.openWithBackgroundTokenForTesting, theme.openWithChromeBackground.themeToken)
        XCTAssertEqual(view.openWithDividerTokenForTesting, theme.openWithChromeDivider.themeToken)
        XCTAssertEqual(view.openWithPrimaryTintTokenForTesting, theme.openWithChromePrimaryTint.themeToken)
        XCTAssertEqual(view.openWithMenuTintTokenForTesting, theme.openWithChromeChevronTint.themeToken)
        XCTAssertLessThan(view.openWithDividerAlphaForTesting, theme.contextStripBorder.srgbClamped.alphaComponent)
    }

    func test_window_chrome_invokes_open_with_primary_and_menu_actions() {
        var primaryActionCount = 0
        var menuActionCount = 0
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )
        view.onOpenWithPrimaryAction = { primaryActionCount += 1 }
        view.onOpenWithMenuAction = { menuActionCount += 1 }

        view.render(openWith: WindowChromeOpenWithState(
            title: "Finder",
            icon: nil,
            isPrimaryEnabled: true,
            isMenuEnabled: true
        ))

        view.performOpenWithPrimaryClickForTesting()
        view.performOpenWithMenuClickForTesting()

        XCTAssertEqual(primaryActionCount, 1)
        XCTAssertEqual(menuActionCount, 1)
    }

    func test_window_chrome_opens_pull_request_url_when_button_is_clicked() throws {
        var openedURL: URL?
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight),
            urlOpener: { openedURL = $0 }
        )

        let pullRequestURL = try XCTUnwrap(URL(string: "https://example.com/pr/1413"))
        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: pullRequestURL,
                state: .open
            ),
            reviewChips: []
        ))

        let pullRequestButton = try XCTUnwrap(findButton(in: view, withTitle: "PR #1413"))
        pullRequestButton.performClick(pullRequestButton)

        XCTAssertEqual(openedURL, pullRequestURL)
        XCTAssertTrue(view.isPullRequestEnabled)
        XCTAssertEqual(view.pullRequestToolTip, "Open pull request #1413 in browser")
    }

    func test_window_chrome_treats_pull_request_pill_as_a_control_not_window_drag_background() throws {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))

        let pullRequestButton = try XCTUnwrap(findButton(in: view, withTitle: "PR #1413"))
        XCTAssertFalse(pullRequestButton.mouseDownCanMoveWindow)
        XCTAssertTrue(pullRequestButton.acceptsFirstMouse(for: nil))
    }

    func test_window_chrome_disables_pull_request_click_affordance_when_url_is_missing() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: nil,
                state: .open
            ),
            reviewChips: []
        ))

        XCTAssertFalse(view.isPullRequestEnabled)
        XCTAssertEqual(view.pullRequestToolTip, "")
    }

    func test_window_chrome_keeps_pull_request_background_constant_while_tinting_text_and_border_by_state() {
        let theme = ZenttyTheme.fallback(for: nil)
        let states: [WorkspacePullRequestState] = [.draft, .open, .merged, .closed]
        let views = states.map { state -> WindowChromeView in
            let view = WindowChromeView(
                frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
            )
            view.apply(theme: theme, animated: false)
            view.render(summary: WorkspaceChromeSummary(
                attention: nil,
                focusedLabel: "Claude Code",
                branch: "main",
                pullRequest: WorkspacePullRequestSummary(
                    number: 1413,
                    url: URL(string: "https://example.com/pr/1413"),
                    state: state
                ),
                reviewChips: []
            ))
            return view
        }

        let backgrounds = Set(views.map(\.pullRequestBackgroundTokenForTesting))
        XCTAssertEqual(backgrounds.count, 1)
        XCTAssertEqual(backgrounds.first, theme.contextStripBackground.themeToken)

        let textTokens = views.map(\.pullRequestTextColorTokenForTesting)
        XCTAssertEqual(Set(textTokens).count, states.count)

        let borderTokens = views.map(\.pullRequestBorderColorTokenForTesting)
        XCTAssertEqual(Set(borderTokens).count, states.count)

        for view in views {
            XCTAssertNotEqual(view.pullRequestTextColorTokenForTesting, theme.secondaryText.themeToken)
            XCTAssertNotEqual(view.pullRequestBorderColorTokenForTesting, theme.contextStripBorder.themeToken)
            XCTAssertLessThan(view.pullRequestBorderAlphaForTesting, view.pullRequestTextAlphaForTesting)
        }
    }

    func test_window_chrome_sizes_pull_request_pill_to_required_button_draw_width() {
        let view = WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight)
        )

        view.render(summary: WorkspaceChromeSummary(
            attention: nil,
            focusedLabel: "Claude Code",
            branch: "main",
            pullRequest: WorkspacePullRequestSummary(
                number: 1413,
                url: URL(string: "https://example.com/pr/1413"),
                state: .open
            ),
            reviewChips: []
        ))
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            view.pullRequestFrameWidth,
            view.pullRequestCellRequiredWidthForTesting - 0.5,
            "pull request width \(view.pullRequestFrameWidth) vs draw width \(view.pullRequestCellRequiredWidthForTesting)"
        )
        XCTAssertGreaterThanOrEqual(
            view.pullRequestFrameWidth,
            view.pullRequestTitleWidthForTesting + 20 - 0.5,
            "pull request width \(view.pullRequestFrameWidth) vs title width \(view.pullRequestTitleWidthForTesting)"
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

    private func makeCrowdedSummary() -> WorkspaceChromeSummary {
        WorkspaceChromeSummary(
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
        let fittingWidth = button.fittingSize.width
        let intrinsicWidth = button.intrinsicContentSize.width
        let cellWidth = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 22)).width ?? 0
        return ceil(max(fittingWidth, intrinsicWidth, cellWidth))
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
