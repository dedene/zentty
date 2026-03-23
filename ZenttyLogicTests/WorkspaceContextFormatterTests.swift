import XCTest
@testable import Zentty

final class WorkspaceContextFormatterTests: XCTestCase {
    func test_compact_workspace_path_prefers_two_segment_worktree_label() {
        let compact = WorkspaceContextFormatter.compactSidebarPath(
            "/Users/peter/Development/Personal/worktrees/feature/sidebar"
        )

        XCTAssertEqual(compact, "…/sidebar")
    }

    func test_compact_workspace_path_maps_home_to_tilde() {
        XCTAssertEqual(
            WorkspaceContextFormatter.compactSidebarPath(NSHomeDirectory()),
            "~"
        )
    }

    func test_pane_detail_line_combines_branch_and_compact_cwd() {
        let detail = WorkspaceContextFormatter.paneDetailLine(
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/git",
                processName: "zsh",
                gitBranch: "main"
            ),
            fallbackTitle: "shell"
        )

        XCTAssertEqual(detail, "main • …/git")
    }

    func test_pane_detail_line_drops_generated_split_fallback_when_only_directory_exists() {
        let detail = WorkspaceContextFormatter.paneDetailLine(
            metadata: TerminalMetadata(
                title: nil,
                currentWorkingDirectory: "/tmp/copy",
                processName: nil,
                gitBranch: nil
            ),
            fallbackTitle: "pane 1"
        )

        XCTAssertEqual(detail, "/tmp/copy")
    }

    func test_resolved_working_directory_prefers_more_specific_title_path_when_reported_cwd_is_stale() {
        let homePath = NSHomeDirectory()
        let resolved = WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: TerminalMetadata(
                title: "peter@m1-pro-peter:~/Development/Personal/automatic-api-docs",
                currentWorkingDirectory: homePath,
                processName: "zsh",
                gitBranch: nil
            )
        )

        XCTAssertEqual(resolved, "\(homePath)/Development/Personal/automatic-api-docs")
    }

    func test_resolved_working_directory_keeps_reported_cwd_when_title_path_is_not_descendant() {
        let resolved = WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: TerminalMetadata(
                title: "peter@m1-pro-peter:/tmp/other-project",
                currentWorkingDirectory: "/tmp/current-project",
                processName: "zsh",
                gitBranch: nil
            )
        )

        XCTAssertEqual(resolved, "/tmp/current-project")
    }

    func test_resolved_working_directory_prefers_more_specific_shell_context_path_when_metadata_is_home() {
        let projectPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Development/Personal/zentty"
        )
        let resolved = WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: NSHomeDirectory(),
                processName: "zsh",
                gitBranch: nil
            ),
            shellContext: PaneShellContext(
                scope: .local,
                path: projectPath,
                home: NSHomeDirectory(),
                user: "peter",
                host: "m1-pro-peter"
            )
        )

        XCTAssertEqual(resolved, projectPath)
    }
}
