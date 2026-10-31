import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryPathTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - Canonical

    func test_canonical_strips_trailing_slash_and_expands_tilde() {
        let home = "/Users/someone"
        XCTAssertEqual(AgentHistoryPath.canonical("/nonexistent-zentty/a/b/", homeDirectory: home), "/nonexistent-zentty/a/b")
        XCTAssertEqual(AgentHistoryPath.canonical("/nonexistent-zentty/a/./b/../c", homeDirectory: home), "/nonexistent-zentty/a/c")
        XCTAssertEqual(AgentHistoryPath.canonical("/", homeDirectory: home), "/")
        XCTAssertEqual(AgentHistoryPath.canonical("~", homeDirectory: home), home)
        XCTAssertEqual(AgentHistoryPath.canonical("~/Code/zentty/", homeDirectory: home), "\(home)/Code/zentty")
        XCTAssertEqual(AgentHistoryPath.canonical(""), "")
        XCTAssertEqual(AgentHistoryPath.canonical("relative/dir/"), "relative/dir")

        let realHome = NSHomeDirectory()
        XCTAssertEqual(AgentHistoryPath.canonical("~/"), AgentHistoryPath.canonical(realHome))
    }

    func test_is_path_inside_respects_component_boundary() {
        XCTAssertTrue(AgentHistoryPath.isPath("/nonexistent-zentty/a/foo", inside: "/nonexistent-zentty/a/foo"))
        XCTAssertTrue(AgentHistoryPath.isPath("/nonexistent-zentty/a/foo/bar", inside: "/nonexistent-zentty/a/foo"))
        XCTAssertTrue(AgentHistoryPath.isPath("/nonexistent-zentty/a/foo/bar", inside: "/nonexistent-zentty/a/foo/"))
        XCTAssertTrue(AgentHistoryPath.isPath("/nonexistent-zentty/a/foo/", inside: "/nonexistent-zentty/a/foo"))
        XCTAssertFalse(AgentHistoryPath.isPath("/nonexistent-zentty/a/foobar", inside: "/nonexistent-zentty/a/foo"))
        XCTAssertFalse(AgentHistoryPath.isPath("/nonexistent-zentty/a", inside: "/nonexistent-zentty/a/foo"))
        XCTAssertTrue(AgentHistoryPath.isPath("/nonexistent-zentty/a", inside: "/"))
        XCTAssertFalse(AgentHistoryPath.isPath("relative/a", inside: "/"))
    }

    func test_symlinked_folder_and_private_tmp_agree() throws {
        let directory = try makeDirectory().resolvingSymlinksInPath()
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(AgentHistoryPath.canonical(link.path), AgentHistoryPath.canonical(real.path))
        XCTAssertEqual(
            AgentHistoryPath.canonical(link.appendingPathComponent("sub").path + "/"),
            AgentHistoryPath.canonical(real.appendingPathComponent("sub").path)
        )
        XCTAssertTrue(AgentHistoryPath.isPath(link.appendingPathComponent("sub").path, inside: real.path))

        XCTAssertEqual(AgentHistoryPath.canonical("/tmp"), AgentHistoryPath.canonical("/private/tmp"))
        XCTAssertTrue(AgentHistoryPath.isPath("/private/tmp/x", inside: "/tmp"))
        XCTAssertTrue(AgentHistoryPath.isPath("/tmp/x", inside: "/private/tmp"))

        let matcher = AgentHistoryExclusionMatcher(folders: [link.path])
        XCTAssertTrue(matcher.excludes(real.appendingPathComponent("sub").path))
        XCTAssertEqual(matcher.canonicalFolders, [AgentHistoryPath.canonical(real.path)])
    }

    func test_case_sensitive() {
        XCTAssertFalse(AgentHistoryPath.isPath("/nonexistent-zentty/Repo/x", inside: "/nonexistent-zentty/repo"))
        let matcher = AgentHistoryExclusionMatcher(folders: ["/nonexistent-zentty/Secret"])
        XCTAssertFalse(matcher.excludes("/nonexistent-zentty/secret/x"))
        XCTAssertTrue(matcher.excludes("/nonexistent-zentty/Secret/x"))
    }

    func test_protected_prefixes_are_lexical_only() throws {
        let fakeHome = try makeDirectory().resolvingSymlinksInPath()
        let documents = fakeHome.appendingPathComponent("Documents", isDirectory: true)
        let target = fakeHome.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let protectedLink = documents.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: protectedLink, withDestinationURL: target)
        let openLink = fakeHome.appendingPathComponent("open-link")
        try FileManager.default.createSymbolicLink(at: openLink, withDestinationURL: target)

        let home = fakeHome.path
        // Under ~/Documents: lexical only, the symlink is kept.
        XCTAssertEqual(AgentHistoryPath.canonical(protectedLink.path + "/", homeDirectory: home), protectedLink.path)
        XCTAssertEqual(AgentHistoryPath.canonical(protectedLink.path + "/../link", homeDirectory: home), protectedLink.path)
        XCTAssertEqual(AgentHistoryPath.canonical("~/Documents/link", homeDirectory: home), protectedLink.path)
        // Outside the protected prefixes: resolved.
        XCTAssertEqual(AgentHistoryPath.canonical(openLink.path, homeDirectory: home), target.path)

        XCTAssertTrue(AgentHistoryPath.isProtected("\(home)/Desktop/x", homeDirectory: home))
        XCTAssertTrue(AgentHistoryPath.isProtected("\(home)/Downloads", homeDirectory: home))
        XCTAssertTrue(AgentHistoryPath.isProtected("\(home)/Library/Mobile Documents/com~apple~CloudDocs", homeDirectory: home))
        XCTAssertTrue(AgentHistoryPath.isProtected("\(home)/Library/CloudStorage/Drive", homeDirectory: home))
        XCTAssertTrue(AgentHistoryPath.isProtected("/Volumes/External/repo", homeDirectory: home))
        XCTAssertTrue(AgentHistoryPath.isProtected("/net/host/share", homeDirectory: home))
        XCTAssertTrue(AgentHistoryPath.isProtected("/Network/Servers/x", homeDirectory: home))
        XCTAssertFalse(AgentHistoryPath.isProtected("\(home)/DocumentsArchive", homeDirectory: home))
        XCTAssertFalse(AgentHistoryPath.isProtected("\(home)/Code/repo", homeDirectory: home))
        XCTAssertFalse(AgentHistoryPath.isProtected("/VolumesX/repo", homeDirectory: home))
    }

    // MARK: - Exclusion matcher

    func test_matcher_drops_relative_and_nil_path_never_excluded() {
        let matcher = AgentHistoryExclusionMatcher(folders: ["relative/dir", "", "/nonexistent-zentty/secret/", "~nobody-zentty-x/y"])
        XCTAssertEqual(matcher.canonicalFolders, ["/nonexistent-zentty/secret"])
        XCTAssertFalse(matcher.isEmpty)
        XCTAssertFalse(matcher.excludes(nil))
        XCTAssertFalse(matcher.excludes("relative/dir"))
        XCTAssertTrue(matcher.excludes("/nonexistent-zentty/secret"))
        XCTAssertTrue(matcher.excludes("/nonexistent-zentty/secret/a/b"))
        XCTAssertFalse(matcher.excludes("/nonexistent-zentty/secrets"))
        XCTAssertTrue(matcher.excludesCanonical("/nonexistent-zentty/secret/a"))
        XCTAssertFalse(matcher.excludesCanonical(nil))

        let empty = AgentHistoryExclusionMatcher(folders: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.excludes("/anything"))
        XCTAssertEqual(AgentHistoryExclusionMatcher(folders: ["/a/", "/a"]).canonicalFolders.count, 1)
    }

    // MARK: - Admission

    func test_admission_tombstone_matches_agent_and_id_only() {
        let id = "0b6c1d8e-4b1a-4c55-9a1e-3f4b2c6d7e8f"
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: []),
            tombstones: [AgentHistorySessionKey(agent: .claude, nativeID: id)]
        )
        XCTAssertEqual(admission.decide(agent: .claude, nativeID: id, cwd: "/nonexistent-zentty/repo"), .tombstoned)
        XCTAssertEqual(admission.decide(agent: .codex, nativeID: id, cwd: "/nonexistent-zentty/repo"), .admit)
        XCTAssertEqual(admission.decide(agent: .claude, nativeID: "other", cwd: "/nonexistent-zentty/repo"), .admit)
        XCTAssertEqual(AgentHistoryAdmission.admitAll.decide(agent: .claude, nativeID: id, cwd: "/x"), .admit)
    }

    func test_admission_nil_cwd_admitted_unless_tombstoned() {
        let admission = AgentHistoryAdmission(
            exclusions: AgentHistoryExclusionMatcher(folders: ["/nonexistent-zentty/secret"]),
            tombstones: [AgentHistorySessionKey(agent: .grok, nativeID: "gone1234")]
        )
        XCTAssertEqual(admission.decide(agent: .grok, nativeID: "kept1234", cwd: nil), .admit)
        XCTAssertEqual(admission.decide(agent: .grok, nativeID: "gone1234", cwd: nil), .tombstoned)
        XCTAssertEqual(admission.decide(agent: .grok, nativeID: "kept1234", cwd: "/nonexistent-zentty/secret/x"), .excludedFolder)
        XCTAssertEqual(admission.decide(agent: .grok, nativeID: "kept1234", cwd: "/nonexistent-zentty/secretive"), .admit)
    }
}
