import AppKit
import XCTest
@testable import Zentty

@MainActor
final class RootViewControllerHeaderIntegrationTests: XCTestCase {
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

    func test_root_controller_populates_header_from_live_review_state_resolver() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/review-band\n"),
            prViewResult: .json(#"{"number":128,"url":"https://example.com/pr/128","isDraft":true,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"unit-tests"},{"bucket":"fail","state":"FAILURE","name":"e2e-macos"}]"#)
        )
        let gitContextResolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                "/tmp/project": PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("feature/review-band")
                ),
            ]
        )
        let controller = makeController(
            reviewStateResolver: WorklaneReviewStateResolver(runner: runner),
            gitContextResolver: gitContextResolver
        )
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
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
        XCTAssertEqual(chrome.branchText, "feature/review-band")
        XCTAssertEqual(chrome.pullRequestText, "PR #128")
        XCTAssertEqual(chrome.reviewChipTexts, ["Draft", "2 failing"])

        let calls = await runner.calls
        XCTAssertGreaterThanOrEqual(calls.count, 4)
        guard calls.count >= 4 else {
            XCTFail("Expected at least four review resolver calls")
            return
        }
        XCTAssertTrue(calls[0].arguments.contains(where: { $0.contains("feature/review-band") }))
        XCTAssertEqual(calls[1].currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(calls[2].arguments.contains("--repo"))
        XCTAssertTrue(calls[2].arguments.contains(where: { $0.contains("feature/review-band") }))
        XCTAssertTrue(calls[3].arguments.contains("--repo"))
        XCTAssertTrue(calls[3].arguments.contains(where: { $0.contains("feature/review-band") }))
    }

    func test_root_controller_populates_header_when_title_contains_cwd_and_metadata_cwd_is_missing() async {
        let homePath = NSHomeDirectory()
        let repoPath = "\(homePath)/Development/Zenjoy/Nimbu/Rails/worktrees/feature/scaleway-transactional-mails"
        let runner = StubGHRunner(
            gitBranchResult: .stdout("feature/scaleway-transactional-mails\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let gitContextResolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                repoPath: PaneGitContext(
                    workingDirectory: repoPath,
                    repositoryRoot: repoPath,
                    reference: .branch("feature/scaleway-transactional-mails")
                ),
            ]
        )
        let controller = makeController(
            reviewStateResolver: WorklaneReviewStateResolver(runner: runner),
            gitContextResolver: gitContextResolver
        )
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
                        currentWorkingDirectory: nil,
                        processName: "zsh"
                    ),
                ]
            ),
        ])

        let reviewLoaded = expectation(description: "review state loaded from title-derived cwd")
        Task { @MainActor in
            for _ in 0..<50 {
                if controller.chromeView.pullRequestText == "PR #1413" {
                    reviewLoaded.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await fulfillment(of: [reviewLoaded], timeout: 1.2)

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "…/scaleway-transactional-mails")
        XCTAssertEqual(chrome.branchText, "feature/scaleway-transactional-mails")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])

        let calls = await runner.calls
        XCTAssertGreaterThanOrEqual(calls.count, 4)
        guard calls.count >= 4 else {
            XCTFail("Expected at least four review resolver calls")
            return
        }
        XCTAssertEqual(calls[0].arguments, ["git", "config", "--get", "branch.feature/scaleway-transactional-mails.remote"])
        XCTAssertEqual(calls[0].currentDirectoryPath, repoPath)
        XCTAssertEqual(calls[1].arguments, ["git", "remote", "get-url", "origin"])
        XCTAssertEqual(calls[1].currentDirectoryPath, repoPath)
        XCTAssertTrue(calls[2].arguments.contains("--repo"))
        XCTAssertTrue(calls[2].arguments.contains("feature/scaleway-transactional-mails"))
        XCTAssertTrue(calls[3].arguments.contains("--repo"))
        XCTAssertTrue(calls[3].arguments.contains("feature/scaleway-transactional-mails"))
    }

    func test_root_controller_populates_header_when_local_pane_context_supplies_cwd() async {
        let runner = StubGHRunner(
            gitBranchResult: .stdout("main\n"),
            prViewResult: .json(#"{"number":1413,"url":"https://example.com/pr/1413","isDraft":false,"state":"OPEN"}"#),
            prChecksResult: .json(#"[{"bucket":"fail","state":"FAILURE","name":"RSpec"}]"#)
        )
        let gitContextResolver = StubPaneGitContextResolver(
            resultByWorkingDirectory: [
                "/tmp/project": PaneGitContext(
                    workingDirectory: "/tmp/project",
                    repositoryRoot: "/tmp/project",
                    reference: .branch("main")
                ),
            ]
        )
        let controller = makeController(
            reviewStateResolver: WorklaneReviewStateResolver(runner: runner),
            gitContextResolver: gitContextResolver
        )
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
                ]
            ),
        ])

        let reviewLoaded = expectation(description: "review loaded")
        Task { @MainActor in
            for _ in 0..<50 {
                if controller.chromeView.pullRequestText == "PR #1413" {
                    reviewLoaded.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await fulfillment(of: [reviewLoaded], timeout: 1.2)

        let chrome = controller.chromeView
        XCTAssertEqual(chrome.focusedLabelText, "/tmp/project")
        XCTAssertEqual(chrome.branchText, "main")
        XCTAssertEqual(chrome.pullRequestText, "PR #1413")
        XCTAssertEqual(chrome.reviewChipTexts, ["1 failing"])

        let calls = await runner.calls
        XCTAssertGreaterThanOrEqual(calls.count, 4)
        guard calls.count >= 4 else {
            XCTFail("Expected at least four review resolver calls")
            return
        }
        XCTAssertTrue(calls[0].arguments.contains(where: { $0.contains("main") }))
        XCTAssertEqual(calls[0].currentDirectoryPath, "/tmp/project")
        XCTAssertEqual(calls[1].currentDirectoryPath, "/tmp/project")
        XCTAssertTrue(calls[2].arguments.contains("--repo"))
        XCTAssertTrue(calls[2].arguments.contains("main"))
        XCTAssertTrue(calls[3].arguments.contains("--repo"))
        XCTAssertTrue(calls[3].arguments.contains("main"))
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
        let coordinator = WorklaneRenderCoordinator(
            worklaneStore: store,
            runtimeRegistry: runtimeRegistry,
            notificationStore: NotificationStore()
        )
        coordinator.windowStateProvider = { (isVisible: true, isKeyWindow: true) }
        coordinator.bind(to: WorklaneRenderCoordinator.ViewBindings(
            sidebarView: SidebarView(),
            windowChromeView: WindowChromeView(),
            appCanvasView: AppCanvasView(runtimeRegistry: runtimeRegistry),
            paneBorderContextOverlayView: PaneBorderContextOverlayView()
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
        let coordinator = WorklaneRenderCoordinator(
            worklaneStore: store,
            runtimeRegistry: runtimeRegistry,
            notificationStore: NotificationStore()
        )
        coordinator.windowStateProvider = { (isVisible: true, isKeyWindow: true) }
        coordinator.bind(to: WorklaneRenderCoordinator.ViewBindings(
            sidebarView: SidebarView(),
            windowChromeView: WindowChromeView(),
            appCanvasView: AppCanvasView(runtimeRegistry: runtimeRegistry),
            paneBorderContextOverlayView: PaneBorderContextOverlayView()
        ))

        coordinator.render()
        let adapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[paneID])
        XCTAssertEqual(adapter.eventLog, ["prepare"])

        coordinator.render()

        XCTAssertEqual(adapter.eventLog, ["prepare"])
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

    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    ) {
        eventLog.append("prepare")
    }
}

private actor StubGHRunner: WorklaneReviewCommandRunning {
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

    func run(arguments: [String], currentDirectoryPath: String) async -> WorklaneReviewCommandResult {
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

    private func makeCommandResult(from fixture: ResultFixture) -> WorklaneReviewCommandResult {
        switch fixture {
        case .stdout(let value):
            return WorklaneReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .json(let value):
            return WorklaneReviewCommandResult(
                terminationStatus: 0,
                stdout: Data(value.utf8),
                stderr: Data()
            )
        case .failure(let stderr):
            return WorklaneReviewCommandResult(
                terminationStatus: 1,
                stdout: Data(),
                stderr: Data(stderr.utf8)
            )
        }
    }
}
