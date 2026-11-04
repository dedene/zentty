import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryRootLocatorTests: XCTestCase {
    /// A fake home directory; nothing here ever reads the real `~/.claude`, `~/.codex`, … .
    private func makeHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func makeDirectory(_ relativePath: String, in base: URL) throws -> URL {
        let url = base.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func canonical(_ url: URL) -> String {
        AgentHistoryPath.canonical(url.path)
    }

    private func locator(home: URL, environment: [String: String] = [:]) -> AgentHistoryRootLocator {
        AgentHistoryRootLocator(environment: environment, homeDirectory: home)
    }

    // MARK: - Defaults

    func test_defaults() throws {
        let home = try makeHome()
        try makeDirectory(".claude/projects", in: home)
        try makeDirectory(".codex", in: home)
        try makeDirectory(".grok", in: home)
        try makeDirectory(".local/share/opencode", in: home)

        let subject = locator(home: home)

        XCTAssertEqual(subject.claudeRoots(), [
            AgentHistorySourceRoot(agent: .claude, path: canonical(home.appendingPathComponent(".claude")), isDefault: true),
        ])
        XCTAssertEqual(subject.codexRoots(), [
            AgentHistorySourceRoot(agent: .codex, path: canonical(home.appendingPathComponent(".codex")), isDefault: true),
        ])
        XCTAssertEqual(subject.grokRoots(), [
            AgentHistorySourceRoot(agent: .grok, path: canonical(home.appendingPathComponent(".grok")), isDefault: true),
        ])
        XCTAssertEqual(subject.openCodeRoots(), [
            AgentHistorySourceRoot(
                agent: .opencode,
                path: canonical(home.appendingPathComponent(".local/share/opencode")),
                isDefault: true
            ),
        ])
        XCTAssertEqual(subject.allRoots().map(\.agent), [.claude, .codex, .grok, .opencode])
    }

    // MARK: - Claude

    func test_claude_config_dir_non_default() throws {
        let home = try makeHome()
        try makeDirectory(".claude/projects", in: home)
        let alternate = try makeDirectory("accounts/work-claude", in: home)
        try makeDirectory("projects", in: alternate)

        let roots = locator(home: home, environment: ["CLAUDE_CONFIG_DIR": alternate.path]).claudeRoots()

        XCTAssertEqual(roots, [
            AgentHistorySourceRoot(agent: .claude, path: canonical(alternate), isDefault: false),
            AgentHistorySourceRoot(agent: .claude, path: canonical(home.appendingPathComponent(".claude")), isDefault: true),
        ])
    }

    func test_claude_config_dir_without_projects_is_ignored() throws {
        let home = try makeHome()
        try makeDirectory(".claude/projects", in: home)
        let alternate = try makeDirectory("accounts/empty-claude", in: home)

        let subject = locator(home: home, environment: ["CLAUDE_CONFIG_DIR": alternate.path])

        XCTAssertEqual(subject.claudeRoots().map(\.path), [canonical(home.appendingPathComponent(".claude"))])
        XCTAssertTrue(subject.candidatePaths(for: .claude).contains(canonical(alternate)))
    }

    func test_claude_config_dir_pointing_at_default_is_default_and_deduped() throws {
        let home = try makeHome()
        let defaultRoot = try makeDirectory(".claude", in: home)
        try makeDirectory("projects", in: defaultRoot)

        let roots = locator(home: home, environment: ["CLAUDE_CONFIG_DIR": defaultRoot.path + "/"]).claudeRoots()

        XCTAssertEqual(roots, [
            AgentHistorySourceRoot(agent: .claude, path: canonical(defaultRoot), isDefault: true),
        ])
    }

    func test_dot_claude_variants_with_projects_only() throws {
        let home = try makeHome()
        try makeDirectory(".claude/projects", in: home)
        try makeDirectory(".claudex/projects", in: home)
        try makeDirectory(".claude-work/projects", in: home)
        try makeDirectory(".claude-empty", in: home)
        try makeDirectory(".claude-history-viewer/projects", in: home)
        try makeDirectory(".clau/projects", in: home)
        try makeDirectory("claude-visible/projects", in: home)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json.backup"))
        // A symlinked variant of the default root collapses into it.
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude-link"),
            withDestinationURL: home.appendingPathComponent(".claude")
        )

        let roots = locator(home: home).claudeRoots()

        XCTAssertEqual(roots, [
            AgentHistorySourceRoot(agent: .claude, path: canonical(home.appendingPathComponent(".claude")), isDefault: true),
            AgentHistorySourceRoot(agent: .claude, path: canonical(home.appendingPathComponent(".claude-work")), isDefault: false),
            AgentHistorySourceRoot(agent: .claude, path: canonical(home.appendingPathComponent(".claudex")), isDefault: false),
        ])
    }

    func test_dot_claude_variant_without_default_root() throws {
        let home = try makeHome()
        try makeDirectory(".claudex/projects", in: home)

        let roots = locator(home: home).claudeRoots()

        XCTAssertEqual(roots, [
            AgentHistorySourceRoot(agent: .claude, path: canonical(home.appendingPathComponent(".claudex")), isDefault: false),
        ])
    }

    // MARK: - Codex, Grok, opencode

    func test_codex_home_ignores_zentty_cache_path() throws {
        let home = try makeHome()
        try makeDirectory(".codex", in: home)
        let cache = try makeDirectory("Library/Caches/Zentty/agent-launch/codex-home", in: home)

        let cached = locator(home: home, environment: ["CODEX_HOME": cache.path]).codexRoots()
        XCTAssertEqual(cached, [
            AgentHistorySourceRoot(agent: .codex, path: canonical(home.appendingPathComponent(".codex")), isDefault: true),
        ])

        let custom = try makeDirectory("work/codex-home", in: home)
        let customRoots = locator(home: home, environment: ["CODEX_HOME": custom.path]).codexRoots()
        XCTAssertEqual(customRoots, [
            AgentHistorySourceRoot(agent: .codex, path: canonical(custom), isDefault: false),
        ])

        let blank = locator(home: home, environment: ["CODEX_HOME": "  "]).codexRoots()
        XCTAssertEqual(blank.map(\.path), [canonical(home.appendingPathComponent(".codex"))])
    }

    func test_grok_home() throws {
        let home = try makeHome()
        try makeDirectory(".grok", in: home)
        let custom = try makeDirectory("work/grok-home", in: home)

        let roots = locator(home: home, environment: ["GROK_HOME": custom.path]).grokRoots()

        XCTAssertEqual(roots, [
            AgentHistorySourceRoot(agent: .grok, path: canonical(custom), isDefault: false),
        ])
    }

    func test_xdg_data_home() throws {
        let home = try makeHome()
        try makeDirectory(".local/share/opencode", in: home)
        let dataHome = try makeDirectory("xdg-data", in: home)
        try makeDirectory("opencode", in: dataHome)

        let roots = locator(home: home, environment: ["XDG_DATA_HOME": dataHome.path]).openCodeRoots()
        XCTAssertEqual(roots, [
            AgentHistorySourceRoot(agent: .opencode, path: canonical(dataHome.appendingPathComponent("opencode")), isDefault: false),
        ])

        // A relative XDG_DATA_HOME is invalid per the XDG spec and falls back to the default.
        let relative = locator(home: home, environment: ["XDG_DATA_HOME": "relative/data"]).openCodeRoots()
        XCTAssertEqual(relative.map(\.path), [canonical(home.appendingPathComponent(".local/share/opencode"))])
    }

    // MARK: - Missing roots

    func test_missing_roots_omitted_but_listed_as_candidates() throws {
        let home = try makeHome()
        let claudeDir = home.appendingPathComponent("alt-claude").path
        let codexDir = home.appendingPathComponent("alt-codex").path
        let grokDir = home.appendingPathComponent("alt-grok").path
        let dataDir = home.appendingPathComponent("alt-data").path

        let empty = locator(home: home)
        XCTAssertEqual(empty.allRoots(), [])
        XCTAssertEqual(empty.candidatePaths(for: .claude), [canonical(home.appendingPathComponent(".claude"))])
        XCTAssertEqual(empty.candidatePaths(for: .codex), [canonical(home.appendingPathComponent(".codex"))])
        XCTAssertEqual(empty.candidatePaths(for: .grok), [canonical(home.appendingPathComponent(".grok"))])
        XCTAssertEqual(
            empty.candidatePaths(for: .opencode),
            [canonical(home.appendingPathComponent(".local/share/opencode"))]
        )

        let overridden = locator(home: home, environment: [
            "CLAUDE_CONFIG_DIR": claudeDir,
            "CODEX_HOME": codexDir,
            "GROK_HOME": grokDir,
            "XDG_DATA_HOME": dataDir,
        ])
        XCTAssertEqual(overridden.allRoots(), [])
        XCTAssertEqual(
            overridden.candidatePaths(for: .claude),
            [AgentHistoryPath.canonical(claudeDir), canonical(home.appendingPathComponent(".claude"))]
        )
        XCTAssertEqual(overridden.candidatePaths(for: .codex), [AgentHistoryPath.canonical(codexDir)])
        XCTAssertEqual(overridden.candidatePaths(for: .grok), [AgentHistoryPath.canonical(grokDir)])
        XCTAssertEqual(overridden.candidatePaths(for: .opencode), [AgentHistoryPath.canonical(dataDir + "/opencode")])

        // A file where a root directory should be does not count as a root.
        try Data().write(to: home.appendingPathComponent(".grok"))
        XCTAssertEqual(empty.grokRoots(), [])
    }
}
