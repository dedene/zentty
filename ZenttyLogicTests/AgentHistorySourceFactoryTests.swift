import Foundation
import XCTest
@testable import Zentty

final class AgentHistorySourceFactoryTests: XCTestCase {
    /// A fake home directory; nothing here ever reads the real `~/.claude`, `~/.codex`, … .
    private func makeHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeDirectory(_ relativePath: String, in base: URL) throws {
        let url = base.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func canonical(_ url: URL, _ relativePath: String) -> String {
        AgentHistoryPath.canonical(url.appendingPathComponent(relativePath).path)
    }

    func test_one_source_per_root_and_agent() throws {
        let home = try makeHome()
        try makeDirectory(".claude/projects", in: home)
        try makeDirectory(".claudex/projects", in: home)
        try makeDirectory(".codex", in: home)
        try makeDirectory(".grok", in: home)
        try makeDirectory(".local/share/opencode", in: home)
        let locator = AgentHistoryRootLocator(environment: [:], homeDirectory: home)

        let sources = AgentHistorySourceFactory.makeSources(locator: locator)

        XCTAssertEqual(sources.map(\.root), locator.allRoots())
        XCTAssertEqual(sources.map(\.agent), [.claude, .claude, .codex, .grok, .opencode])
        XCTAssertEqual(sources.map(\.root.path), [
            canonical(home, ".claude"),
            canonical(home, ".claudex"),
            canonical(home, ".codex"),
            canonical(home, ".grok"),
            canonical(home, ".local/share/opencode"),
        ])
        for source in sources {
            XCTAssertEqual(source.agent, source.root.agent)
        }
        XCTAssertTrue(sources[0] is ClaudeHistorySource)
        XCTAssertTrue(sources[1] is ClaudeHistorySource)
        XCTAssertTrue(sources[2] is CodexHistorySource)
        XCTAssertTrue(sources[3] is GrokHistorySource)
        XCTAssertTrue(sources[4] is OpenCodeHistorySource)

        // Each call builds fresh instances, so a root change on reconcile yields new sources.
        let again = AgentHistorySourceFactory.makeSources(locator: locator)
        XCTAssertEqual(again.count, sources.count)
        for (first, second) in zip(sources, again) {
            XCTAssertFalse(first === second)
        }
    }

    func test_missing_roots_produce_no_sources() throws {
        let home = try makeHome()
        let locator = AgentHistoryRootLocator(environment: [:], homeDirectory: home)

        XCTAssertTrue(AgentHistorySourceFactory.makeSources(locator: locator).isEmpty)

        // A Claude variant without `projects/` is not a root; only the Grok root exists.
        try makeDirectory(".claude-other", in: home)
        try makeDirectory(".grok", in: home)
        let sources = AgentHistorySourceFactory.makeSources(locator: locator)

        XCTAssertEqual(sources.map(\.agent), [.grok])
        XCTAssertEqual(sources.first?.root.path, canonical(home, ".grok"))
    }

    func test_sources_for_explicit_roots_match_their_agent() throws {
        let home = try makeHome()
        let roots = AgentHistoryAgent.allCases.map { agent in
            AgentHistorySourceRoot(agent: agent, path: canonical(home, agent.rawValue), isDefault: false)
        }

        let sources = AgentHistorySourceFactory.makeSources(roots: roots)

        XCTAssertEqual(sources.map(\.root), roots)
        XCTAssertEqual(sources.map(\.agent), roots.map(\.agent))
    }
}
