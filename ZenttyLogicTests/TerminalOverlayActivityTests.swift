import XCTest
@testable import Zentty

/// Overlays live outside the worklane store, so their sidebar line only moves
/// when the overlay itself follows the shell: `cd`, commands, and exits.
@MainActor
final class TerminalOverlayActivityTests: XCTestCase {
    private let overlayID = PaneID("ov_test")

    func test_shell_integration_signals_move_the_overlay_to_the_new_directory_and_branch() async {
        let activity = TerminalOverlayActivity(
            command: "", workingDirectory: "/tmp/zentty", gitContextResolver: BranchPerDirectoryStub()
        )
        activity.start()
        XCTAssertEqual(activity.workingDirectory, "/tmp/zentty")

        let moved = expectation(description: "branch of the new directory resolves")
        activity.onChange = {
            if activity.branch == "nimbu-branch" { moved.fulfill() }
        }
        activity.apply(paneContext(path: "/tmp/nimbu"))
        XCTAssertEqual(activity.workingDirectory, "/tmp/nimbu")
        await fulfillment(of: [moved], timeout: 2)
        activity.onChange = nil

        activity.apply(shellState(.commandRunning, command: "ls -la"))
        XCTAssertEqual(activity.runningCommand, "ls -la")
        activity.apply(shellState(.promptIdle))
        XCTAssertNil(activity.runningCommand)
    }

    func test_command_overlay_reports_running_then_how_it_ended() {
        let activity = TerminalOverlayActivity(
            command: "make test", workingDirectory: "/tmp/project", gitContextResolver: BranchPerDirectoryStub()
        )
        XCTAssertEqual(activity.runningCommand, "make test")

        activity.observe(event: .commandFinished(exitCode: 2, durationNanoseconds: 1))
        XCTAssertNil(activity.runningCommand)
        XCTAssertEqual(activity.exitCode, 2)

        activity.observe(event: .userSubmittedInput)
        XCTAssertNil(activity.exitCode, "a new command clears the previous exit")
    }

    func test_stopped_activity_ignores_late_signals() {
        let activity = TerminalOverlayActivity(
            command: "", workingDirectory: "/tmp/zentty", gitContextResolver: BranchPerDirectoryStub()
        )
        activity.stop()
        activity.apply(paneContext(path: "/tmp/nimbu"))
        XCTAssertEqual(activity.workingDirectory, "/tmp/zentty")
    }

    // MARK: - Sidebar line

    func test_shell_overlay_line_follows_its_icon_with_location_and_running_command() {
        let shell = overlay(command: "", workingDirectory: "/tmp/zentty/", branch: "main")
        let row = shell.sidebarRow(anchorWorkingDirectory: "/tmp/zentty")
        XCTAssertEqual(row.primaryText, "zentty main", "a bare icon reads as empty, even in the pane's directory")
        XCTAssertNil(row.trailingText)
        XCTAssertEqual(overlay(command: "").sidebarRow(anchorWorkingDirectory: nil).primaryText, "")
        XCTAssertTrue(row.isOverlay)
        XCTAssertNil(row.overlayOwnerPaneID, "worklane overlays end the card")

        let moved = overlay(command: "", workingDirectory: "/tmp/nimbu", branch: "main", runningCommand: "ls")
        let movedRow = moved.sidebarRow(anchorWorkingDirectory: "/tmp/zentty")
        XCTAssertEqual(movedRow.primaryText, "nimbu main · ls", "details follow the icon directly")
        XCTAssertNil(movedRow.trailingText)
    }

    func test_command_overlay_line_shows_status_and_hangs_under_its_pane() {
        let running = overlay(command: "htop", isPaneOverlay: true, runningCommand: "htop", isVisible: false)
        let row = running.sidebarRow(anchorWorkingDirectory: nil)
        XCTAssertEqual(row.primaryText, "htop")
        XCTAssertEqual(row.trailingText, "running")
        XCTAssertEqual(row.overlayOwnerPaneID, PaneID("pane"))
        XCTAssertTrue(row.isOverlayHidden)
        XCTAssertEqual(
            overlay(command: "htop", workingDirectory: "/tmp/zentty", branch: "main", runningCommand: "htop")
                .sidebarRow(anchorWorkingDirectory: "/tmp/zentty").trailingText,
            "running",
            "the command names it; the pane above already shows the location"
        )

        XCTAssertEqual(overlay(command: "make", exitCode: 0).statusText, "done")
        XCTAssertEqual(overlay(command: "make", exitCode: 2).statusText, "exit 2")
        XCTAssertNil(overlay(command: "", exitCode: 2).statusText, "a shell's last exit is noise")
    }

    // MARK: - Environment

    func test_overlay_environment_reports_under_the_overlay_id_without_pane_agent_plumbing() {
        let environment = WorklaneSessionEnvironment.overlay(
            windowID: WindowID("wd_test"),
            worklaneID: WorklaneID("wl_test"),
            overlayID: overlayID,
            processEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(environment["ZENTTY_PANE_ID"], overlayID.rawValue)
        XCTAssertEqual(environment["ZENTTY_WORKLANE_ID"], "wl_test")
        for key in ["ZENTTY_ALL_WRAPPER_BIN_DIRS", "ZENTTY_WRAPPER_SUPPORT_DIR", "ZENTTY_AGENT_MANIFEST_TABLE", "TMUX"] {
            XCTAssertNil(environment[key], key)
        }
        XCTAssertNil(environment["PATH"], "agent wrappers stay off the overlay's PATH")
    }

    // MARK: - Helpers

    private func overlay(
        command: String,
        isPaneOverlay: Bool = false,
        workingDirectory: String? = nil,
        branch: String? = nil,
        runningCommand: String? = nil,
        exitCode: Int? = nil,
        isVisible: Bool = true
    ) -> WorklaneSidebarOverlay {
        WorklaneSidebarOverlay(
            id: overlayID, anchorPaneID: PaneID("pane"), isPaneOverlay: isPaneOverlay,
            command: command, runningCommand: runningCommand, exitCode: exitCode,
            workingDirectory: workingDirectory, branch: branch,
            isFocused: false, isVisible: isVisible
        )
    }

    private func paneContext(path: String) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("wl_test"), paneID: overlayID, signalKind: .paneContext, state: nil,
            paneContext: PaneShellContext(scope: .local, path: path, home: "/Users/test", user: "test", host: "mbp"),
            origin: .shell, toolName: nil, text: nil, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        )
    }

    private func shellState(_ state: PaneShellActivityState, command: String? = nil) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: WorklaneID("wl_test"), paneID: overlayID, signalKind: .shellState, state: nil,
            shellActivityState: state, shellCommand: command, origin: .shell,
            toolName: nil, text: nil, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        )
    }
}

private struct BranchPerDirectoryStub: PaneGitContextResolving {
    func resolve(for workingDirectory: String) async -> PaneGitContext {
        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return PaneGitContext(
            workingDirectory: workingDirectory, repositoryRoot: workingDirectory, reference: .branch("\(name)-branch")
        )
    }
}
