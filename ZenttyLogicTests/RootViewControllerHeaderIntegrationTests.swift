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

        let reviewLoaded = expectation(description: "review state loaded")
        Task { @MainActor in
            for _ in 0..<50 {
                if controller.chromeView.pullRequestText == "PR #128" {
                    reviewLoaded.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await fulfillment(of: [reviewLoaded], timeout: 1.2)

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "Claude Code")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])

        let calls = await runner.calls
        XCTAssertGreaterThanOrEqual(calls.count, 6)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[1].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.feature/review-band.remote"])
        XCTAssertEqual(calls[2].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
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
            "feature/scaleway-transactional-mails · …/scaleway-transactional-mails"
        )
        XCTAssertEqual(chrome.branchText, "")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])

        let calls = await runner.calls
        XCTAssertGreaterThanOrEqual(calls.count, 6)
        if let firstCall = calls.first {
            XCTAssertEqual(firstCall.arguments, ["git", "rev-parse", "--git-dir"])
            XCTAssertEqual(firstCall.currentDirectoryPath, repoPath)
        }
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.feature/scaleway-transactional-mails.remote"])
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
    }

    func test_root_controller_populates_header_when_local_pane_context_supplies_cwd() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
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
                        title: "Claude Code",
                        currentWorkingDirectory: nil,
                        processName: "zsh"
                    ),
                ],
                paneContextByPaneID: [
                    paneID: PaneShellContext(
                        scope: .local,
                        path: "/tmp/project",
                        home: "/Users/peter",
                        user: "peter",
                        host: "m1-pro-peter"
                    ),
                ]
            ),
        ])

        try? await Task.sleep(nanoseconds: 100_000_000)

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "Claude Code")
        XCTAssertEqual(chrome.branchText, "main")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])

        let calls = await runner.calls
        XCTAssertGreaterThanOrEqual(calls.count, 6)
        XCTAssertEqual(calls[0].arguments, ["git", "rev-parse", "--git-dir"])
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[1].arguments, ["git", "branch", "--show-current"])
        XCTAssertEqual(calls[1].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[2].arguments, ["git", "config", "--get", "branch.main.remote"])
        XCTAssertEqual(calls[2].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[3].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[3].currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(calls[4].arguments.contains("--repo"))
        XCTAssertTrue(calls[5].arguments.contains("--repo"))
    }

    func test_root_controller_keeps_long_terminal_title_readable_inside_real_visible_lane() throws {
        let controller = makeController()
        let paneID = PaneID("pane-shell")
        let focusedLabel = "feature/scaleway-transactional-mails · …/scaleway-transactional-mails"
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
                        title: focusedLabel,
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
        let pullRequestButton = try XCTUnwrap(findButton(in: chrome, withTitle: "PR #1413"))

        XCTAssertEqual(
            chrome.leadingVisibleInset,
            controller.currentSidebarWidth + ShellMetrics.shellGap,
            accuracy: 0.5
        )
        XCTAssertLessThanOrEqual(chrome.overflowBeforeCompression, 4)
        XCTAssertLessThanOrEqual(chrome.finalTotalWidth, chrome.rowFrame.width + 0.5)
        XCTAssertGreaterThanOrEqual(chrome.focusedLabelFrameWidth, chrome.focusedLabelIntrinsicWidth - 4)
        XCTAssertLessThanOrEqual(chrome.branchFrameWidth, 4.5)
        XCTAssertEqual(chrome.pullRequestFrameWidth, chrome.pullRequestIntrinsicWidth, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(focusedLabelView.frame.width, requiredSingleLineWidth(of: focusedLabelView) - 4)
        XCTAssertGreaterThanOrEqual(pullRequestButton.frame.width, requiredSingleLineWidth(of: pullRequestButton) - 0.5)

        let contentMinX = min(focusedLabelView.frame.minX, pullRequestButton.frame.minX)
        let contentMaxX = max(focusedLabelView.frame.maxX, pullRequestButton.frame.maxX)
        XCTAssertGreaterThanOrEqual(contentMinX, -0.5)
        XCTAssertLessThanOrEqual(contentMaxX, chrome.rowFrame.width + 0.5)
    }

    func test_root_controller_hit_testing_reaches_pull_request_button_through_overlay_stack() throws {
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
                        title: "Claude Code",
                        currentWorkingDirectory: "/tmp/project",
                        processName: "zsh"
                    ),
                ],
                reviewStateByPaneID: [
                    paneID: WorkspaceReviewState(
                        branch: "main",
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
        let pullRequestButton = try XCTUnwrap(findButton(in: chrome, withTitle: "PR #1413"))
        let hitPoint = pullRequestButton.convert(
            NSPoint(x: pullRequestButton.bounds.midX, y: pullRequestButton.bounds.midY),
            to: controller.view
        )

        XCTAssertTrue(controller.view.hitTest(hitPoint) === pullRequestButton)
    }

    func test_root_controller_prefers_terminal_title_when_shell_title_is_pretruncated() {
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
        XCTAssertEqual(chrome.focusedLabelText, "…/nimbu")
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
        XCTAssertEqual(chrome.focusedLabelText, "main · …/project")
        XCTAssertEqual(chrome.branchText, "")
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
    let cellWidth: CGFloat = 0
    let cellHeight: CGFloat = 0
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

    private let gitRepositoryProbeResult: ResultFixture
    private let gitBranchResult: ResultFixture
    private let gitUpstreamRemoteResult: ResultFixture
    private let gitRemoteResult: ResultFixture
    private let prViewResult: ResultFixture
    private let prChecksResult: ResultFixture
    private(set) var calls: [Invocation] = []

    init(
        gitRepositoryProbeResult: ResultFixture = .stdout(".git\n"),
        gitBranchResult: ResultFixture,
        gitUpstreamRemoteResult: ResultFixture = .failure(stderr: "no upstream remote"),
        gitRemoteResult: ResultFixture = .stdout("git@github.com:zenjoy/zentty.git\n"),
        prViewResult: ResultFixture,
        prChecksResult: ResultFixture
    ) {
        self.gitRepositoryProbeResult = gitRepositoryProbeResult
        self.gitBranchResult = gitBranchResult
        self.gitUpstreamRemoteResult = gitUpstreamRemoteResult
        self.gitRemoteResult = gitRemoteResult
        self.prViewResult = prViewResult
        self.prChecksResult = prChecksResult
    }

    func run(arguments: [String], currentDirectoryPath: String) async -> WorkspaceReviewCommandResult {
        calls.append(Invocation(arguments: arguments, currentDirectoryPath: currentDirectoryPath))

        if arguments == ["git", "rev-parse", "--git-dir"] {
            return makeCommandResult(from: gitRepositoryProbeResult)
        }

        if arguments == ["git", "branch", "--show-current"] {
            return makeCommandResult(from: gitBranchResult)
        }

        if arguments.count == 4,
           arguments[0] == "git",
           arguments[1] == "config",
           arguments[2] == "--get",
           arguments[3].hasPrefix("branch."),
           arguments[3].hasSuffix(".remote") {
            return makeCommandResult(from: gitUpstreamRemoteResult)
        }

        if arguments == ["git", "remote", "get-url", "origin"] {
            return makeCommandResult(from: gitRemoteResult)
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
