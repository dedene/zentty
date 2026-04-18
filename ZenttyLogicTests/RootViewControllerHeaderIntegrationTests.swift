import AppKit
import XCTest
@testable import Zentty

@MainActor
private final class StubRenderEnvironment: RenderEnvironmentProviding {
    var renderTheme: ZenttyTheme = .fallback(for: nil)
    var renderSidebarWidth: CGFloat = 0
    func renderLeadingInset(sidebarWidth: CGFloat) -> CGFloat { 0 }
    var renderWindowState: (isVisible: Bool, isKeyWindow: Bool) = (true, true)
    func renderSidebarSyncNeeded() {}
}

@MainActor
final class RootViewControllerHeaderIntegrationTests: AppKitTestCase {
    func test_root_controller_renders_worklane_header_summary_for_active_worklane() {
        let controller = makeController()
        let paneID = PaneID("pane-claude")

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "claude")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "Claude Code",
                        currentWorkingDirectory: "/tmp/project",
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
                    paneID: WorklaneReviewState(
                        branch: "feature/review-band",
                        pullRequest: WorklanePullRequestSummary(
                            number: 128,
                            url: URL(string: "https://example.com/pr/128"),
                            state: .draft
                        ),
                        reviewChips: [
                            WorklaneReviewChip(text: "Draft", style: .info),
                            WorklaneReviewChip(text: "2 failing", style: .danger),
                        ]
                    ),
                ],
                gitContextByPaneID: [
                    paneID: PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("feature/review-band")
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.attentionText, "Needs input")
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])
    }

    func test_root_controller_updates_header_when_focus_changes_between_non_git_and_git_panes() {
        let controller = makeController()
        let shellPaneID = PaneID("pane-shell")
        let claudePaneID = PaneID("pane-claude")

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
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
                        currentWorkingDirectory: "/tmp/project",
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
                    claudePaneID: WorklaneReviewState(
                        branch: "feature/review-band",
                        pullRequest: WorklanePullRequestSummary(
                            number: 128,
                            url: URL(string: "https://example.com/pr/128"),
                            state: .draft
                        ),
                        reviewChips: [
                            WorklaneReviewChip(text: "Draft", style: .info),
                            WorklaneReviewChip(text: "2 failing", style: .danger),
                        ]
                    ),
                ],
                gitContextByPaneID: [
                    claudePaneID: PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("feature/review-band")
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
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
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

    func test_root_controller_populates_header_from_live_review_state_resolver() {
        let controller = makeController()
        let paneID = PaneID("pane-claude")

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
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
                ,
                reviewStateByPaneID: [
                    paneID: WorklaneReviewState(
                        branch: "feature/review-band",
                        pullRequest: WorklanePullRequestSummary(
                            number: 128,
                            url: URL(string: "https://example.com/pr/128"),
                            state: .draft
                        ),
                        reviewChips: [
                            WorklaneReviewChip(text: "Draft", style: .info),
                            WorklaneReviewChip(text: "2 failing", style: .danger),
                        ]
                    ),
                ],
                gitContextByPaneID: [
                    paneID: PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("feature/review-band")
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])
    }

    func test_root_controller_populates_header_when_terminal_reports_cwd() {
        let homePath = NSHomeDirectory()
        let repoPath = "\(homePath)/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        let controller = makeController()
        let paneID = PaneID("pane-shell")

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "peter@m1-pro-peter:~/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        currentWorkingDirectory: repoPath,
                        processName: "zsh"
                    ),
                ]
                ,
                reviewStateByPaneID: [
                    paneID: WorklaneReviewState(
                        branch: "feature/scaleway-transactional-mails",
                        pullRequest: WorklanePullRequestSummary(
                            number: 1413,
                            url: URL(string: "https://example.com/pr/1413"),
                            state: .open
                        ),
                        reviewChips: [
                            WorklaneReviewChip(text: "1 failing", style: .danger),
                        ]
                    ),
                ],
                gitContextByPaneID: [
                    paneID: PaneGitContext(
                        workingDirectory: repoPath,
                        repositoryRoot: repoPath,
                        reference: .branch("feature/scaleway-transactional-mails")
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "…/scaleway-transactional-mails")
        XCTAssertEqual(chrome.branchText, "feature/scaleway-transactional-mails")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])
    }

    func test_root_controller_populates_header_when_local_pane_context_supplies_cwd() {
        let controller = makeController()
        let paneID = PaneID("pane-shell")

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
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
                ],
                reviewStateByPaneID: [
                    paneID: WorklaneReviewState(
                        branch: "main",
                        pullRequest: WorklanePullRequestSummary(
                            number: 1413,
                            url: URL(string: "https://example.com/pr/1413"),
                            state: .open
                        ),
                        reviewChips: [
                            WorklaneReviewChip(text: "1 failing", style: .danger),
                        ]
                    ),
                ],
                gitContextByPaneID: [
                    paneID: PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("main")
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
        XCTAssertEqual(chrome.branchText, "main")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])
    }

    func test_root_controller_renders_remote_context_without_local_proxy_icon() {
        let controller = makeController()
        let paneID = PaneID("pane-shell")

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "General coding assistance session",
                        currentWorkingDirectory: nil,
                        processName: "codex",
                        gitBranch: "main"
                    ),
                ],
                paneContextByPaneID: [
                    paneID: PaneShellContext(
                        scope: .remote,
                        path: "/home/peter/project",
                        home: "/home/peter",
                        user: "peter",
                        host: "gilfoyle"
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "General coding assistance session")
        XCTAssertEqual(chrome.remoteContextLabelText, "gilfoyle ~/project")
        XCTAssertEqual(chrome.branchText, "")
        XCTAssertTrue(chrome.isFocusedProxyIconHidden)
    }

    func test_root_controller_keeps_long_terminal_title_readable_inside_real_visible_lane() throws {
        let controller = makeController()
        let paneID = PaneID("pane-shell")
        let focusedLabel = "…/scaleway-transactional-mails"
        let branch = "feature/scaleway-transactional-mails"

        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "shell")],
                    focusedPaneID: paneID
                ),
                metadataByPaneID: [
                    paneID: TerminalMetadata(
                        title: "feature/scaleway-transactional-mails · …/scaleway-transactional-mails",
                        currentWorkingDirectory: "\(NSHomeDirectory())/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        processName: "zsh"
                    ),
                ],
                reviewStateByPaneID: [
                    paneID: WorklaneReviewState(
                        branch: branch,
                        pullRequest: WorklanePullRequestSummary(
                            number: 1413,
                            url: URL(string: "https://example.com/pr/1413"),
                            state: .open
                        ),
                        reviewChips: []
                    ),
                ],
                gitContextByPaneID: [
                    paneID: PaneGitContext(
                        workingDirectory: "\(NSHomeDirectory())/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        repositoryRoot: "\(NSHomeDirectory())/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails",
                        reference: .branch(branch)
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
        XCTAssertLessThanOrEqual(chrome.branchFrameWidth, chrome.branchIntrinsicWidth + 0.5)
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

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
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
                    paneID: WorklaneReviewState(
                        branch: "main",
                        pullRequest: WorklanePullRequestSummary(
                            number: 1413,
                            url: URL(string: "https://example.com/pr/1413"),
                            state: .open
                        ),
                        reviewChips: []
                    ),
                ],
                gitContextByPaneID: [
                    paneID: PaneGitContext(
                        workingDirectory: "/tmp/project",
                        repositoryRoot: "/tmp/project",
                        reference: .branch("main")
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

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
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

        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
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
                    paneID: WorklaneReviewState(
                        branch: "main",
                        pullRequest: nil,
                        reviewChips: []
                    ),
                ]
            ),
        ])

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
        XCTAssertEqual(chrome.branchText, "")
    }

    func test_render_coordinator_retargets_review_polling_when_lookup_branch_changes() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: nil
            )
        )
        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )

        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { _ in QuietTerminalAdapter() })
        let renderEnvironment = StubRenderEnvironment()
        let coordinator = WorklaneRenderCoordinator(
            worklaneStore: store,
            runtimeRegistry: runtimeRegistry,
            notificationStore: NotificationStore()
        )
        coordinator.environment = renderEnvironment
        coordinator.bind(to: WorklaneRenderCoordinator.ViewBindings(
            sidebarView: SidebarView(),
            windowChromeView: WindowChromeView(),
            appCanvasView: AppCanvasView(runtimeRegistry: runtimeRegistry)
        ))
        coordinator.startObserving()
        coordinator.render()

        XCTAssertEqual(coordinator.reviewPollingTargetForTesting?.branch, "main")

        store.updateGitContext(
            paneID: paneID,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("feature/review-band")
            )
        )

        XCTAssertEqual(coordinator.reviewPollingTargetForTesting?.branch, "feature/review-band")
    }

    func test_render_coordinator_does_not_resynchronize_runtimes_on_repeated_full_render() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let adapterFactory = HeaderIntegrationTerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let renderEnvironment = StubRenderEnvironment()
        let coordinator = WorklaneRenderCoordinator(
            worklaneStore: store,
            runtimeRegistry: runtimeRegistry,
            notificationStore: NotificationStore()
        )
        coordinator.environment = renderEnvironment
        coordinator.bind(to: WorklaneRenderCoordinator.ViewBindings(
            sidebarView: SidebarView(),
            windowChromeView: WindowChromeView(),
            appCanvasView: AppCanvasView(runtimeRegistry: runtimeRegistry)
        ))

        coordinator.render()
        let adapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[paneID])
        XCTAssertEqual(adapter.eventLog, ["prepare"])

        coordinator.render()

        XCTAssertEqual(adapter.eventLog, ["prepare"])
    }

    func test_render_coordinator_applies_updated_pane_display_settings_from_config_store() throws {
        let logsPaneID = PaneID("logs")
        let editorPaneID = PaneID("editor")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: logsPaneID, title: "logs", width: 420),
                    PaneState(id: editorPaneID, title: "editor", width: 420),
                ],
                focusedPaneID: editorPaneID
            ),
            auxiliaryStateByPaneID: [
                editorPaneID: PaneAuxiliaryState(
                    shellContext: PaneShellContext(
                        scope: .local,
                        path: "/Users/peter/src/zentty",
                        home: "/Users/peter",
                        user: "peter",
                        host: "zenbook"
                    )
                )
            ]
        )
        let store = WorklaneStore()
        store.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { _ in QuietTerminalAdapter() })
        let renderEnvironment = StubRenderEnvironment()
        let configStore = AppConfigStore(
            fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.RenderCoordinator.Panes")
        )
        let appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
        appCanvasView.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        appCanvasView.layoutSubtreeIfNeeded()
        let coordinator = WorklaneRenderCoordinator(
            worklaneStore: store,
            runtimeRegistry: runtimeRegistry,
            notificationStore: NotificationStore(),
            configStore: configStore
        )
        coordinator.environment = renderEnvironment
        coordinator.bind(to: WorklaneRenderCoordinator.ViewBindings(
            sidebarView: SidebarView(),
            windowChromeView: WindowChromeView(),
            appCanvasView: appCanvasView
        ))

        coordinator.render()
        appCanvasView.layoutSubtreeIfNeeded()
        let initialPaneViewsByTitle = Dictionary(uniqueKeysWithValues: try appCanvasView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })
        XCTAssertEqual(
            try XCTUnwrap(initialPaneViewsByTitle["editor"]).paneBorderContextTextForTesting,
            "~/src/zentty"
        )
        XCTAssertEqual(try XCTUnwrap(initialPaneViewsByTitle["logs"]).alphaValue, 0.7, accuracy: 0.001)

        try configStore.update { config in
            config.panes.showLabels = false
            config.panes.inactiveOpacity = 0.82
        }
        coordinator.render()
        appCanvasView.layoutSubtreeIfNeeded()
        let updatedPaneViewsByTitle = Dictionary(uniqueKeysWithValues: try appCanvasView.descendantPaneViews().map {
            let title = try XCTUnwrap($0.titleText.isEmpty ? nil : $0.titleText)
            return (title, $0)
        })
        XCTAssertNil(try XCTUnwrap(updatedPaneViewsByTitle["editor"]).paneBorderContextTextForTesting)
        XCTAssertEqual(try XCTUnwrap(updatedPaneViewsByTitle["logs"]).alphaValue, 0.82, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(updatedPaneViewsByTitle["editor"]).borderLabelGapWidthForTesting,
            0,
            accuracy: 0.001
        )
    }

    func test_root_controller_keeps_in_pane_context_aligned_with_border_gap_when_sidebar_is_pinned() throws {
        SidebarVisibilityPreference.persist(.pinnedOpen, in: SidebarVisibilityPreference.userDefaults())

        let controller = makeController()
        let paneID = PaneID("pane-editor")
        controller.replaceWorklanes([
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: paneID, title: "editor")],
                    focusedPaneID: paneID
                ),
                auxiliaryStateByPaneID: [
                    paneID: PaneAuxiliaryState(
                        shellContext: PaneShellContext(
                            scope: .local,
                            path: "/Users/peter/src/zentty",
                            home: "/Users/peter",
                            user: "peter",
                            host: "zenbook"
                        )
                    )
                ]
            ),
        ])
        controller.view.layoutSubtreeIfNeeded()

        let sidebarView = try XCTUnwrap(
            controller.view.subviews.first(where: { $0 is SidebarView }) as? SidebarView
        )
        let paneView = try XCTUnwrap(controller.view.descendantPaneViews().first)
        let labelFrame = try XCTUnwrap(paneView.paneBorderContextFrameForTesting)
        let expectedMinX = paneView.insetBorderFrame.minX + (24 - paneView.insetBorderInset)
        let expectedMidY = paneView.insetBorderFrame.maxY - 0.5

        XCTAssertEqual(labelFrame.minX, expectedMinX, accuracy: 0.001)
        XCTAssertEqual(labelFrame.midY, expectedMidY, accuracy: 0.001)
        XCTAssertGreaterThan(paneView.convert(labelFrame, to: controller.view).minX, sidebarView.frame.maxX)
    }

    private func makeController(
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver(),
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver()
    ) -> RootViewController {
        let controller = RootViewController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in QuietTerminalAdapter() }),
            reviewStateResolver: reviewStateResolver,
            gitContextResolver: gitContextResolver,
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: SidebarVisibilityPreference.userDefaults()
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        controller.view.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                controller.prepareForTestingTearDown()
            }
        }
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

private extension NSView {
    func descendantPaneViews() -> [PaneContainerView] {
        var paneViews: [PaneContainerView] = []

        func walk(_ view: NSView) {
            if let paneView = view as? PaneContainerView {
                paneViews.append(paneView)
            }

            view.subviews.forEach(walk)
        }

        walk(self)
        return paneViews
    }
}

private struct StubPaneGitContextResolver: PaneGitContextResolving {
    let resultByWorkingDirectory: [String: PaneGitContext]

    func resolve(for workingDirectory: String) async -> PaneGitContext {
        resultByWorkingDirectory[workingDirectory]
            ?? PaneGitContext(
                workingDirectory: workingDirectory,
                repositoryRoot: nil,
                reference: nil
            )
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

    func close() {}
    func sendText(_ text: String) {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
    }
}

@MainActor
private final class HeaderIntegrationTerminalAdapterFactorySpy {
    private(set) var adaptersByPaneID: [PaneID: HeaderIntegrationTerminalAdapterSpy] = [:]

    func makeAdapter(for paneID: PaneID) -> any TerminalAdapter {
        let adapter = HeaderIntegrationTerminalAdapterSpy()
        adaptersByPaneID[paneID] = adapter
        return adapter
    }
}

@MainActor
private final class HeaderIntegrationTerminalAdapterSpy: TerminalAdapter, TerminalSessionInheritanceConfiguring {
    private let terminalView = NSView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var eventLog: [String] = []

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        eventLog.append("start")
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}

    func close() {}
    func sendText(_ text: String) {}

    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    ) {
        eventLog.append("prepare")
    }
}
