import AppKit
import XCTest
@testable import Zentty

@MainActor
final class RootViewControllerHeaderIntegrationTests: XCTestCase {
    func test_root_controller_renders_workspace_header_summary_for_active_workspace() {
        let controller = makeController()
        let paneID = PaneID("pane-claude")

        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "claude")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "Claude Code",
                        processName: "claude",
                        gitBranch: "feature/review-band"
                    ),
                ],
                agentStatusByPaneID: [
                    paneID: PaneAgentStatus(
                        tool: .claudeCode,
                        state: .needsInput,
                        text: nil,
                        artifactLink: nil,
                        updatedAt: Date(timeIntervalSince1970: 10),
                        source: .explicit
                    ),
                ],
                reviewStateByPaneID: [
                    paneID: WorkspaceReviewState(
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
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.attentionText, "Needs input")
        XCTAssertEqual(chrome.focusedLabelText, "Claude Code")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])
    }

    func test_root_controller_updates_header_when_focus_changes_between_non_git_and_git_panes() {
        let controller = makeController()
        let shellPaneID = PaneID("pane-shell")
        let claudePaneID = PaneID("pane-claude")

        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [
                        PaneState(id: shellPaneID, title: "shell"),
                        PaneState(id: claudePaneID, title: "claude"),
                    ],
                    focusedPaneID: shellPaneID
                ),
                metadataByPaneID: [
                    shellPaneID: TerminalMetadata(
                        title: "zsh",
                        processName: "zsh"
                    ),
                    claudePaneID: TerminalMetadata(
                        title: "Claude Code",
                        processName: "claude",
                        gitBranch: "feature/review-band"
                    ),
                ],
                agentStatusByPaneID: [
                    claudePaneID: PaneAgentStatus(
                        tool: .claudeCode,
                        state: .needsInput,
                        text: nil,
                        artifactLink: nil,
                        updatedAt: Date(timeIntervalSince1970: 10),
                        source: .explicit
                    ),
                ],
                reviewStateByPaneID: [
                    claudePaneID: WorkspaceReviewState(
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
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.attentionText, "Needs input")
        XCTAssertEqual(chrome.focusedLabelText, "zsh")
        XCTAssertEqual(chrome.branchText, "")
        XCTAssertEqual(chrome.pullRequestText, "")
        XCTAssertEqual(chrome.reviewChipTexts, [])

        controller.focusPaneDirectly(claudePaneID)

        XCTAssertEqual(chrome.attentionText, "Needs input")
        XCTAssertEqual(chrome.focusedLabelText, "Claude Code")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])

        controller.focusPaneDirectly(shellPaneID)

        XCTAssertEqual(chrome.attentionText, "Needs input")
        XCTAssertEqual(chrome.focusedLabelText, "zsh")
        XCTAssertEqual(chrome.branchText, "")
        XCTAssertEqual(chrome.pullRequestText, "")
        XCTAssertEqual(chrome.reviewChipTexts, [])
    }

    func test_root_controller_populates_header_from_live_review_state_resolver() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"},{"bucket":"fail","state":"FAILURE","name":"e2e-macos"}]"#)
        )
        let controller = makeController(
            reviewStateResolver: WorkspaceReviewStateResolver(runner: runner)
        )
        let paneID = PaneID("pane-claude")

        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "claude")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "Claude Code",
                        currentWorkingDirectory: "/tmp/project",
                        processName: "claude"
                    ),
                ]
            ),
        ])

        try? await Task.sleep(nanoseconds: 100_000_000)

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "Claude Code")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[0].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
    }

    func test_root_controller_populates_header_when_title_contains_cwd_and_metadata_cwd_is_missing() async {
        let homePath = NSHomeDirectory()
        let repoPath = "\(homePath)/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/scaleway-transactional-mails\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let controller = makeController(
            reviewStateResolver: WorkspaceReviewStateResolver(runner: runner)
        )
        let paneID = PaneID("pane-shell")

        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        currentWorkingDirectory: nil,
                        processName: "zsh"
                    ),
                ]
            ),
        ])

        try? await Task.sleep(nanoseconds: 100_000_000)

        let chrome = controller.chromeView
        XCTAssertEqual(
            chrome.focusedLabelText,
            "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        )
        XCTAssertEqual(chrome.branchText, "feature/scaleway-transactional-mails")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])

        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        if let firstCall = calls.first {
            XCTAssertEqual(firstCall.arguments, ["git", "branch", "--show-current"])
            XCTAssertEqual(firstCall.currentDirectoryPath, repoPath)
        }
    }

    func test_root_controller_keeps_long_worktree_header_uncompressed_and_centered_inside_real_visible_lane() throws {
        let controller = makeController()
        let paneID = PaneID("pane-shell")
        let focusedLabel = "~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        let branch = "feature/scaleway-transactional-mails"

        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "peter@m1-pro-peter:\(focusedLabel)",
                        currentWorkingDirectory: "\(NSHomeDirectory())/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        processName: "zsh"
                    ),
                ],
                reviewStateByPaneID: [
                    paneID: WorkspaceReviewState(
                        branch: branch,
                        pullRequest: WorkspacePullRequestSummary(
                            number: 1413,
                            url: URL(string: "https://example.com/pr/1413"),
                            state: .open
                        ),
                        reviewChips: []
                    ),
                ]
            ),
        ])

        controller.view.layoutSubtreeIfNeeded()

        let chrome = controller.chromeView
        let focusedLabelView = try XCTUnwrap(findLabel(in: chrome, withText: focusedLabel))
        let branchLabelView = try XCTUnwrap(findLabel(in: chrome, withText: branch))
        let pullRequestButton = try XCTUnwrap(findButton(in: chrome, withTitle: "PR #1413"))

        XCTAssertEqual(
            chrome.leadingVisibleInset,
            controller.currentSidebarWidth + ShellMetrics.shellGap,
            accuracy: 0.5
        )
        XCTAssertFalse(chrome.didCompressItems)
        XCTAssertEqual(chrome.preferredTotalWidth, chrome.finalTotalWidth, accuracy: 0.5)
        XCTAssertEqual(chrome.focusedLabelFrameWidth, chrome.focusedLabelIntrinsicWidth, accuracy: 0.5)
        XCTAssertEqual(chrome.branchFrameWidth, chrome.branchIntrinsicWidth, accuracy: 0.5)
        XCTAssertEqual(chrome.pullRequestFrameWidth, chrome.pullRequestIntrinsicWidth, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(focusedLabelView.frame.width, requiredSingleLineWidth(of: focusedLabelView) - 0.5)
        XCTAssertGreaterThanOrEqual(branchLabelView.frame.width, requiredSingleLineWidth(of: branchLabelView) - 0.5)
        XCTAssertGreaterThanOrEqual(pullRequestButton.frame.width, requiredSingleLineWidth(of: pullRequestButton) - 0.5)

        let contentMinX = min(focusedLabelView.frame.minX, branchLabelView.frame.minX, pullRequestButton.frame.minX)
        let contentMaxX = max(focusedLabelView.frame.maxX, branchLabelView.frame.maxX, pullRequestButton.frame.maxX)
        let leftSlack = contentMinX
        let rightSlack = chrome.rowFrame.width - contentMaxX
        XCTAssertGreaterThan(leftSlack, 20)
        XCTAssertEqual(leftSlack, rightSlack, accuracy: 24)
    }

    func test_root_controller_uses_full_home_relative_cwd_when_shell_title_is_pretruncated() {
        let controller = makeController()
        let paneID = PaneID("pane-shell")
        let homePath = NSHomeDirectory()

        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/nim...",
                        currentWorkingDirectory: "\(homePath)/Development/Zenjoy/Nimbu/Rails/nimbu",
                        processName: "zsh"
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "~/Development/Zenjoy/Nimbu/Rails/nimbu")
    }

    func test_root_controller_keeps_cached_review_branch_when_metadata_branch_is_compacted() {
        let controller = makeController()
        let paneID = PaneID("pane-shell")

        controller.replaceWorkspaces([
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "zsh",
                        currentWorkingDirectory: "/tmp/project",
                        processName: "zsh",
                        gitBranch: "m...n"
                    ),
                ],
                reviewStateByPaneID: [
                    paneID: WorkspaceReviewState(
                        branch: "main",
                        pullRequest: nil,
                        reviewChips: []
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.branchText, "main")
    }

    private func makeController(
        reviewStateResolver: WorkspaceReviewStateResolver = WorkspaceReviewStateResolver()
    ) -> RootViewController {
        let controller = RootViewController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in QuietTerminalAdapter() }),
            reviewStateResolver: reviewStateResolver,
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: SidebarVisibilityPreference.userDefaults()
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        return controller
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

    private func requiredSingleLineWidth(of label: NSTextField) -> CGFloat {
        ceil(max(label.fittingSize.width, label.intrinsicContentSize.width))
    }

    private func requiredSingleLineWidth(of button: NSButton) -> CGFloat {
        ceil(max(button.fittingSize.width, button.intrinsicContentSize.width))
    }
}

@MainActor
private final class QuietTerminalAdapter: TerminalAdapter {
    let hasScrollback = false
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    func makeTerminalView() -> NSView {
        NSView(frame: .zero)
    }

    func startSession(using request: TerminalSessionRequest) throws {
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
    }
}

private actor StubGHRunner: WorkspaceReviewCommandRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let currentDirectoryPath: String
    }

    enum ResultFixture {
        case stdout(String)
        case json(String)
        case failure(stderr: String)
    }

    private let gitBranchResult: ResultFixture
    private let prViewResult: ResultFixture
    private let prChecksResult: ResultFixture
    private(set) var calls: [Invocation] = []

    init(gitBranchResult: ResultFixture, prViewResult: ResultFixture, prChecksResult: ResultFixture) {
        self.gitBranchResult = gitBranchResult
        self.prViewResult = prViewResult
        self.prChecksResult = prChecksResult
    }

    func run(arguments: [String], currentDirectoryPath: String) async -> WorkspaceReviewCommandResult {
        calls.append(Invocation(arguments: arguments, currentDirectoryPath: currentDirectoryPath))

        if arguments == ["git", "branch", "--show-current"] {
            return makeCommandResult(from: gitBranchResult)
        }

        if arguments.contains("view") {
            return makeCommandResult(from: prViewResult)
        }

        return makeCommandResult(from: prChecksResult)
    }

    private func makeCommandResult(from fixture: ResultFixture) -> WorkspaceReviewCommandResult {
        switch fixture {
        case .stdout(let value):
            return WorkspaceReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .json(let value):
            return WorkspaceReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .failure(let stderr):
            return WorkspaceReviewCommandResult(
                terminationStatus: 1,
                stdout: Data(),
                stderr: Data(stderr.utf8)
            )
        }
    }
}
