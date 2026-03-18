import XCTest
@testable import Zentty

final class WorkspaceContextFormatterTests: XCTestCase {
    func test_compact_workspace_path_prefers_two_segment_worktree_label() {
        let compact = WorkspaceContextFormatter.compactSidebarPath(
            "/Users/peter/Development/Personal/worktrees/feature/sidebar"
        )

        XCTAssertEqual(compact, "feature/sidebar")
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

        XCTAssertEqual(detail, "main • git")
    }
}
