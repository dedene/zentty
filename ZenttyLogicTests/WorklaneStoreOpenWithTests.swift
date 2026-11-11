import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreOpenWithTests: XCTestCase {
    func test_terminal_link_uses_current_shell_directory_instead_of_stale_ghostty_directory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.md")
        try "report".write(to: file, atomically: true, encoding: .utf8)
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklaneID)
        store.updateMetadata(paneID: paneID, metadata: TerminalMetadata(currentWorkingDirectory: "/old/repo"))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .paneContext,
            state: nil,
            paneContext: PaneShellContext(scope: .local, path: directory.path, home: nil, user: nil, host: nil),
            origin: .shell, toolName: nil, text: nil, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        ))

        XCTAssertEqual(
            store.terminalOpenURLDecision(paneID: paneID, target: "report.md.", kind: .unknown),
            .open(file.resolvingSymlinksInPath())
        )
    }

    func test_focused_open_with_context_uses_local_shell_context_path() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/project",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.focusedOpenWithContext?.paneID, paneID)
        XCTAssertEqual(store.focusedOpenWithContext?.workingDirectory, "/tmp/project")
        XCTAssertEqual(store.focusedOpenWithContext?.scope, .local)
    }

    func test_focused_open_with_context_is_nil_for_remote_pane() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .remote,
                    path: "/srv/project",
                    home: "/home/peter",
                    user: "peter",
                    host: "prod"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNil(store.focusedOpenWithContext)
    }

    func test_focused_open_with_context_prefers_local_shell_context_over_stale_metadata() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/from-metadata",
                processName: "zsh",
                gitBranch: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .paneContext,
                state: nil,
                paneContext: PaneShellContext(
                    scope: .local,
                    path: "/tmp/from-shell-context",
                    home: "/Users/peter",
                    user: "peter",
                    host: "mbp"
                ),
                origin: .shell,
                toolName: nil,
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.focusedOpenWithContext?.workingDirectory, "/tmp/from-shell-context")
    }

    func test_focused_open_with_context_ignores_agent_working_directory_and_uses_terminal_cwd() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/from-terminal",
                processName: "codex",
                gitBranch: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .compatibility,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentWorkingDirectory: "/tmp/from-agent"
            )
        )

        XCTAssertEqual(store.focusedOpenWithContext?.workingDirectory, "/tmp/from-terminal")
    }

    func test_focused_open_with_context_uses_non_inherited_session_request_before_shell_context_arrives() throws {
        let store = WorklaneStore()
        store.send(.splitHorizontally)

        let worklane = try XCTUnwrap(store.activeWorklane)
        let paneID = try XCTUnwrap(worklane.paneStripState.focusedPaneID)
        let pane = try XCTUnwrap(worklane.paneStripState.panes.first(where: { $0.id == paneID }))
        let requestedWorkingDirectory = try XCTUnwrap(pane.sessionRequest.workingDirectory)

        XCTAssertEqual(store.focusedOpenWithContext?.paneID, paneID)
        XCTAssertEqual(store.focusedOpenWithContext?.workingDirectory, requestedWorkingDirectory)
        XCTAssertEqual(store.focusedOpenWithContext?.scope, .local)
    }

    func test_focused_open_with_context_is_nil_when_only_metadata_cwd_exists() throws {
        let worklaneID = WorklaneID("worklane-main")
        let paneID = PaneID("worklane-main-shell")
        let worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "ssh",
                        sessionRequest: TerminalSessionRequest(
                            inheritFromPaneID: PaneID("source-pane"),
                            surfaceContext: .window
                        )
                    )
                ],
                focusedPaneID: paneID
            )
        )
        let store = WorklaneStore(worklanes: [worklane], activeWorklaneID: worklaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "ssh",
                currentWorkingDirectory: "/srv/remote-project",
                processName: "ssh",
                gitBranch: nil
            )
        )

        XCTAssertNil(store.focusedOpenWithContext)
    }
}
