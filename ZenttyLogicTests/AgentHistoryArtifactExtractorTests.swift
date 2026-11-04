import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryArtifactExtractorTests: XCTestCase {
    func test_commands_are_one_line_and_capped() {
        XCTAssertEqual(AgentHistoryArtifactExtractor.command("  git status \n"), "git status")
        XCTAssertEqual(AgentHistoryArtifactExtractor.command("cat <<'EOF'\nhello\n  world\nEOF"), "cat <<'EOF' hello world EOF")
        XCTAssertNil(AgentHistoryArtifactExtractor.command(" \n\t "))

        let long = String(repeating: "x", count: 500)
        let capped = AgentHistoryArtifactExtractor.command("echo " + long)
        XCTAssertEqual(capped?.count, AgentHistoryArtifactExtractor.maxCommandLength)
        XCTAssertEqual(capped?.last, "…")
    }

    func test_command_redacts_before_capping() {
        let token = AgentHistoryFixtures.fakeGitHubToken()
        let prefix = String(repeating: "a", count: AgentHistoryArtifactExtractor.maxCommandLength - 10)
        let command = AgentHistoryArtifactExtractor.command(prefix + " " + token)
        XCTAssertFalse(command?.contains("gh" + "p_") ?? true, "a secret cut by the cap is never left partially visible")
    }

    func test_apply_patch_headers() {
        let patch = """
        *** Begin Patch
        *** Add File: Sources/New.swift
        +let x = 1
        *** Update File: Sources/Old.swift
        *** Move to: Sources/Renamed.swift
        @@
        -a
        +b
        *** Delete File: Sources/Gone.swift
        *** Update File: Sources/Old.swift
        *** End Patch
        """
        XCTAssertEqual(
            AgentHistoryArtifactExtractor.applyPatchPaths(patch),
            ["Sources/New.swift", "Sources/Old.swift", "Sources/Renamed.swift", "Sources/Gone.swift"]
        )
        XCTAssertEqual(AgentHistoryArtifactExtractor.applyPatchPaths("no headers here"), [])
    }

    func test_git_commit_detection() {
        XCTAssertTrue(AgentHistoryArtifactExtractor.isGitCommitCommand("git commit -m 'x'"))
        XCTAssertTrue(AgentHistoryArtifactExtractor.isGitCommitCommand("git -C repo commit --amend"))
        XCTAssertTrue(AgentHistoryArtifactExtractor.isGitCommitCommand("git add . && git commit -m wip"))
        XCTAssertFalse(AgentHistoryArtifactExtractor.isGitCommitCommand("git log | grep commit"))
        XCTAssertFalse(AgentHistoryArtifactExtractor.isGitCommitCommand("echo commit; git status"))
        XCTAssertFalse(AgentHistoryArtifactExtractor.isGitCommitCommand("legit commit"))
    }

    func test_commit_hashes_from_git_output() {
        let output = """
        [main 1a2b3c4] fix the thing
         2 files changed, 3 insertions(+)
        [feat/x (root-commit) 0123456789abcdef0123456789abcdef01234567] first
        [main 1a2b3c4] fix the thing
        [notes] nothing
        [main XYZ1234] not hex
        """
        XCTAssertEqual(
            AgentHistoryArtifactExtractor.commitHashes(inGitOutput: output),
            ["1a2b3c4", "0123456789abcdef0123456789abcdef01234567"]
        )
    }

    func test_pull_request_urls() {
        let text = """
        Opened https://github.com/zenjoy/zentty/pull/174 and see
        (https://gitlab.com/group/sub/project/-/merge_requests/12).
        Again https://github.com/zenjoy/zentty/pull/174, not https://github.com/zenjoy/zentty/issues/3
        or https://github.com/zenjoy/zentty/pull/abc. Self-hosted: http://git.example.com:8080/team/app/-/merge_requests/7
        """
        XCTAssertEqual(AgentHistoryArtifactExtractor.pullRequestURLs(in: text), [
            "https://github.com/zenjoy/zentty/pull/174",
            "https://gitlab.com/group/sub/project/-/merge_requests/12",
            "http://git.example.com:8080/team/app/-/merge_requests/7",
        ])
    }

    func test_path_relativization() {
        let root = "/Users/me/src/app"
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("/Users/me/src/app/Sources/A.swift", relativeTo: root), "Sources/A.swift")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("/Users/me/src/app/./Sources/../B.swift", relativeTo: root + "/"), "B.swift")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("/Users/me/src/appendix/C.swift", relativeTo: root), "/Users/me/src/appendix/C.swift")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("/Users/me/src/app", relativeTo: root), "/Users/me/src/app")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("/etc//hosts", relativeTo: nil), "/etc/hosts")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("/etc/hosts", relativeTo: "/"), "/etc/hosts")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("./Sources/A.swift", relativeTo: root), "Sources/A.swift")
        XCTAssertEqual(AgentHistoryArtifactExtractor.path("Sources/A.swift", relativeTo: nil), "Sources/A.swift")
        XCTAssertNil(AgentHistoryArtifactExtractor.path("  ", relativeTo: root))
        XCTAssertNil(AgentHistoryArtifactExtractor.path("./", relativeTo: root))
        XCTAssertNil(AgentHistoryArtifactExtractor.path("a\nb", relativeTo: root))
    }
}
