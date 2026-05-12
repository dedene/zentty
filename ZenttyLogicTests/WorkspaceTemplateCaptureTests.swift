import XCTest
@testable import Zentty

final class WorkspaceTemplateCaptureTests: XCTestCase {
    func test_lca_returns_common_ancestor_for_sibling_paths() {
        let lca = WorkspaceTemplateCapture.longestCommonAncestor(of: [
            "/Users/peter/proj/api/src",
            "/Users/peter/proj/web/src",
        ])
        XCTAssertEqual(lca, "/Users/peter/proj")
    }

    func test_lca_returns_full_path_for_single_input() {
        let lca = WorkspaceTemplateCapture.longestCommonAncestor(of: ["/Users/peter/proj"])
        XCTAssertEqual(lca, "/Users/peter/proj")
    }

    func test_lca_returns_nil_for_unrelated_paths() {
        let lca = WorkspaceTemplateCapture.longestCommonAncestor(of: [
            "/Users/peter/proj",
            "/var/log",
        ])
        XCTAssertNil(lca)
    }

    func test_lca_returns_nil_for_empty_input() {
        XCTAssertNil(WorkspaceTemplateCapture.longestCommonAncestor(of: []))
    }

    func test_capture_bookmark_records_per_pane_cwd_and_project_root() {
        let worklane = makeWorklane(
            panes: [
                paneFixture(id: "p1", cwd: "/Users/peter/proj/api", processName: "claude"),
                paneFixture(id: "p2", cwd: "/Users/peter/proj/web", processName: "zsh"),
            ],
            color: .blue
        )

        let template = WorkspaceTemplateCapture.capture(
            worklane: worklane,
            kind: .bookmark,
            name: "Demo"
        )

        XCTAssertEqual(template.kind, .bookmark)
        XCTAssertEqual(template.projectRoot, "/Users/peter/proj")
        XCTAssertEqual(template.color, "blue")
        XCTAssertEqual(template.allPanes.map(\.workingDirectory), [
            "/Users/peter/proj/api",
            "/Users/peter/proj/web",
        ])
        XCTAssertEqual(template.allPanes.map(\.command), ["claude", nil])
        XCTAssertEqual(template.allPanes.map(\.wasUserEdited), [false, false])
    }

    func test_capture_preset_strips_working_directories_and_project_root() {
        let worklane = makeWorklane(
            panes: [
                paneFixture(id: "p1", cwd: "/Users/peter/proj/api", processName: "claude"),
            ],
            color: nil
        )

        let template = WorkspaceTemplateCapture.capture(
            worklane: worklane,
            kind: .preset,
            name: "Claude pane"
        )

        XCTAssertEqual(template.kind, .preset)
        XCTAssertNil(template.projectRoot)
        XCTAssertEqual(template.allPanes.first?.workingDirectory, nil)
        XCTAssertEqual(template.allPanes.first?.command, "claude")
    }

    func test_capture_skips_shell_process_names() {
        for shell in ["zsh", "-zsh", "bash", "-bash", "fish"] {
            let worklane = makeWorklane(
                panes: [
                    paneFixture(id: "p1", cwd: "/Users/peter", processName: shell),
                ],
                color: nil
            )
            let template = WorkspaceTemplateCapture.capture(
                worklane: worklane,
                kind: .bookmark,
                name: "Test"
            )
            XCTAssertNil(template.allPanes.first?.command, "shell name '\(shell)' should not be captured as command")
        }
    }

    func test_capture_uses_running_shell_title_as_command_when_process_is_shell() {
        let worklane = makeWorklane(
            panes: [
                paneFixture(
                    id: "p1",
                    cwd: "/Users/peter/proj",
                    title: "npm run dev",
                    processName: "zsh",
                    shellActivityState: .commandRunning
                ),
            ],
            color: nil
        )

        let template = WorkspaceTemplateCapture.capture(
            worklane: worklane,
            kind: .bookmark,
            name: "Dev"
        )

        XCTAssertEqual(template.allPanes.first?.command, "npm run dev")
    }

    func test_capture_does_not_use_directory_title_as_running_command() {
        let worklane = makeWorklane(
            panes: [
                paneFixture(
                    id: "p1",
                    cwd: "/Users/peter/proj",
                    title: "/Users/peter/proj",
                    processName: "zsh",
                    shellActivityState: .commandRunning
                ),
            ],
            color: nil
        )

        let template = WorkspaceTemplateCapture.capture(
            worklane: worklane,
            kind: .bookmark,
            name: "Dev"
        )

        XCTAssertNil(template.allPanes.first?.command)
    }

    func test_capture_uses_direct_child_process_when_shell_metadata_has_no_command_title() {
        let worklane = makeWorklane(
            panes: [
                paneFixture(
                    id: "p1",
                    cwd: "/Users/peter/proj",
                    processName: "zsh",
                    paneRootPID: 100,
                    shellActivityState: .commandRunning
                ),
            ],
            color: nil
        )
        let processTree = TaskManagerProcessTree(
            rootPID: 100,
            processes: [
                TaskManagerProcessMetric(pid: 100, parentPID: nil, name: "zsh", cpuPercent: 0, memoryBytes: 10),
                TaskManagerProcessMetric(pid: 101, parentPID: 100, name: "xcodebuild", cpuPercent: 0, memoryBytes: 20),
                TaskManagerProcessMetric(pid: 102, parentPID: 101, name: "swift-frontend", cpuPercent: 0, memoryBytes: 30),
            ],
            networkBytesPerSecond: nil
        )

        let template = WorkspaceTemplateCapture.capture(
            worklane: worklane,
            kind: .bookmark,
            name: "Build",
            processTreeProvider: { pid in
                pid == 100 ? processTree : nil
            }
        )

        XCTAssertEqual(template.allPanes.first?.command, "xcodebuild")
    }

    func test_capture_uses_remembered_title_as_title_seed_when_present() {
        let pane = paneFixture(id: "p1", cwd: "/Users/peter", processName: nil, rememberedTitle: "My favourite shell")
        let worklane = makeWorklane(panes: [pane], color: nil)
        let template = WorkspaceTemplateCapture.capture(worklane: worklane, kind: .bookmark, name: "Test")
        XCTAssertEqual(template.allPanes.first?.titleSeed, "My favourite shell")
    }

    func test_capture_persists_only_template_safe_environment_overrides() {
        let pane = paneFixture(
            id: "p1",
            cwd: "/Users/peter",
            processName: nil,
            environment: [
                "NODE_ENV": "production",
                "TERM": "xterm-256color",
                "ZENTTY_WINDOW_ID": "window-stale",
                "ZENTTY_PANE_TOKEN": "token-stale",
                "PATH": "/tmp/stale-bin",
                "ZDOTDIR": "/tmp/stale-zdotdir",
                "PROMPT_COMMAND": "stale-prompt",
                "GHOSTTY_LOG": "macos,no-stderr",
            ]
        )
        let worklane = makeWorklane(panes: [pane], color: nil)

        let template = WorkspaceTemplateCapture.capture(worklane: worklane, kind: .bookmark, name: "Test")

        XCTAssertEqual(template.allPanes.first?.environment, [
            "NODE_ENV": "production",
            "TERM": "xterm-256color",
        ])
    }

    private struct PaneFixture {
        let pane: PaneState
        let auxiliary: PaneAuxiliaryState
    }

    private func paneFixture(
        id: String,
        cwd: String,
        title: String? = nil,
        processName: String?,
        rememberedTitle: String? = nil,
        paneRootPID: Int32? = nil,
        shellActivityState: PaneShellActivityState = .unknown,
        environment: [String: String] = [:]
    ) -> PaneFixture {
        let paneID = PaneID(id)
        let pane = PaneState(
            id: paneID,
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: cwd,
                environmentVariables: environment
            )
        )
        let metadata = TerminalMetadata(
            title: title,
            currentWorkingDirectory: cwd,
            processName: processName,
            gitBranch: nil
        )
        var presentation = PanePresentationState()
        presentation.cwd = cwd
        presentation.rememberedTitle = rememberedTitle
        let auxiliary = PaneAuxiliaryState(
            raw: PaneRawState(
                metadata: metadata,
                paneRootPID: paneRootPID,
                shellActivityState: shellActivityState
            ),
            presentation: presentation
        )
        return PaneFixture(pane: pane, auxiliary: auxiliary)
    }

    private func makeWorklane(
        panes: [PaneFixture],
        color: WorklaneColor?
    ) -> WorklaneState {
        let columns = panes.enumerated().map { index, fixture in
            PaneColumnState(
                id: PaneColumnID("c\(index)"),
                panes: [fixture.pane],
                width: fixture.pane.width,
                focusedPaneID: fixture.pane.id,
                lastFocusedPaneID: fixture.pane.id
            )
        }
        let auxiliary = Dictionary(uniqueKeysWithValues: panes.map { fixture in
            (fixture.pane.id, fixture.auxiliary)
        })
        return WorklaneState(
            id: WorklaneID("w1"),
            title: "",
            paneStripState: PaneStripState(columns: columns),
            nextPaneNumber: 1,
            auxiliaryStateByPaneID: auxiliary,
            color: color
        )
    }
}
