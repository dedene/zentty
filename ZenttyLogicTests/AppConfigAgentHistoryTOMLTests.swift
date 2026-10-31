import Foundation
import XCTest
@testable import Zentty

final class AppConfigAgentHistoryTOMLTests: XCTestCase {

    func test_missing_section_decodes_to_defaults() {
        let decoded = AppConfigTOML.decode("""
            [agents]
            fork_destination = "new_worklane"
            """)

        XCTAssertEqual(decoded?.agentHistory, .default)
        XCTAssertEqual(decoded?.agentHistory.excludedFolders, [])
        XCTAssertEqual(decoded?.agentHistory.allowAgentsAllProjects, false)
    }

    func test_round_trip() {
        var config = AppConfig.default
        config.agentHistory.excludedFolders = ["/Volumes/Secrets", "/opt/clients/acme"]
        config.agentHistory.allowAgentsAllProjects = true

        let decoded = AppConfigTOML.decode(AppConfigTOML.encode(config))

        XCTAssertEqual(decoded?.agentHistory, config.agentHistory)
    }

    func test_encode_always_writes_section() {
        let encoded = AppConfigTOML.encode(.default)

        XCTAssertTrue(encoded.contains("[agent_history]\nexcluded_folders = []\nallow_agents_all_projects = false\n"))
    }

    func test_paths_under_home_are_written_with_tilde_and_read_back_absolute() {
        let home = NSHomeDirectory()
        var config = AppConfig.default
        config.agentHistory.excludedFolders = ["\(home)/Clients/acme", "/srv/shared"]

        let encoded = AppConfigTOML.encode(config)

        XCTAssertTrue(encoded.contains(#"excluded_folders = ["~/Clients/acme", "/srv/shared"]"#))
        XCTAssertFalse(encoded.contains(home + "/Clients"))
        XCTAssertEqual(
            AppConfigTOML.decode(encoded)?.agentHistory.excludedFolders,
            ["\(home)/Clients/acme", "/srv/shared"]
        )
    }

    func test_paths_with_quotes_and_backslashes_round_trip() {
        let odd = [#"/tmp/with "quotes""#, #"/tmp/back\slash"#, #"/tmp/trailing\"#, "/tmp/comma, and # hash"]
        var config = AppConfig.default
        config.agentHistory.excludedFolders = odd

        let decoded = AppConfigTOML.decode(AppConfigTOML.encode(config))

        XCTAssertEqual(decoded?.agentHistory.excludedFolders, odd)
    }

    func test_empty_array() {
        let decoded = AppConfigTOML.decode("""
            [agent_history]
            excluded_folders = []
            allow_agents_all_projects = true
            """)

        XCTAssertEqual(decoded?.agentHistory.excludedFolders, [])
        XCTAssertEqual(decoded?.agentHistory.allowAgentsAllProjects, true)
    }

    func test_rejects_non_bool_allow_flag() {
        XCTAssertNil(AppConfigTOML.decode("""
            [agent_history]
            allow_agents_all_projects = "yes"
            """))
        XCTAssertNil(AppConfigTOML.decode("""
            [agent_history]
            allow_agents_all_projects = 1
            """))
    }

    func test_rejects_non_array_excluded_folders() {
        XCTAssertNil(AppConfigTOML.decode("""
            [agent_history]
            excluded_folders = "/tmp/secrets"
            """))
        XCTAssertNil(AppConfigTOML.decode("""
            [agent_history]
            excluded_folders = [/tmp/secrets]
            """))
    }

    func test_unknown_key_survives_save() throws {
        let config = try XCTUnwrap(AppConfigTOML.decode("""
            [agent_history]
            excluded_folders = ["/srv/a"]
            future_flag = true
            """))
        XCTAssertEqual(config.agentHistory.excludedFolders, ["/srv/a"])

        let encoded = AppConfigTOML.encode(config)
        XCTAssertTrue(encoded.contains("""
            [agent_history]
            excluded_folders = ["/srv/a"]
            allow_agents_all_projects = false
            future_flag = true
            """))
        XCTAssertEqual(AppConfigTOML.decode(encoded)?.agentHistory.excludedFolders, ["/srv/a"])
    }

    func test_normalized_dedupes_strips_trailing_slash_and_drops_relative() {
        let home = NSHomeDirectory()
        let raw = AppConfig.AgentHistory(
            excludedFolders: [
                "  /srv/a/  ",
                "/srv/a",
                "",
                "   ",
                "relative/path",
                "./dot",
                "~/Clients",
                "\(home)/Clients/",
                "/srv/b/../c/./d//",
                "/",
                "//",
            ],
            allowAgentsAllProjects: true
        )

        let normalized = raw.normalized()

        XCTAssertEqual(normalized.excludedFolders, ["/srv/a", "\(home)/Clients", "/srv/c/d", "/"])
        XCTAssertTrue(normalized.allowAgentsAllProjects)
        XCTAssertEqual(normalized.normalized(), normalized, "idempotent")

        var config = AppConfig.default
        config.agentHistory = raw
        XCTAssertEqual(config.normalized().agentHistory, normalized)
    }

    func test_normalized_keeps_symlinks_unresolved() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.path)

        let normalized = AppConfig.AgentHistory(excludedFolders: [link + "/"], allowAgentsAllProjects: false)
            .normalized()

        XCTAssertEqual(normalized.excludedFolders, [link])
    }

    /// The Swift matcher built from config and the SQL purge over its canonical folders must
    /// select the same rows (stored `cwd`s are always `AgentHistoryPath.canonical`).
    func test_exclusion_matcher_from_config_agrees_with_sql_purge() throws {
        let fileManager = FileManager.default
        // `temporaryDirectory` lives under `/var/folders`, a symlink to `/private/var/folders`.
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        for folder in ["proj/sub", "projX", "other"] {
            try fileManager.createDirectory(
                at: real.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
            )
        }
        let link = base.appendingPathComponent("link").path
        try fileManager.createSymbolicLink(atPath: link, withDestinationPath: real.path)
        // Never created: canonicalizing resolves `/tmp` to `/private/tmp` without touching the folder.
        let tmpName = "agent-history-\(UUID().uuidString)"

        var config = AppConfig.default
        config.agentHistory.excludedFolders = [
            link + "/proj/",                 // symlink + trailing slash + /var prefix
            "/tmp/\(tmpName)/excluded",      // /tmp vs /private/tmp
        ]
        let decoded = try XCTUnwrap(AppConfigTOML.decode(AppConfigTOML.encode(config.normalized())))
        let matcher = decoded.normalized().agentHistory.exclusionMatcher

        let cwds: [String: String] = [
            "proj": real.path + "/proj",
            "projSub": real.path + "/proj/sub",
            "projViaLink": link + "/proj/sub",
            "sibling": real.path + "/projX",
            "caseVariant": real.path + "/PROJ",
            "other": real.path + "/other",
            "tmpExcluded": "/private/tmp/\(tmpName)/excluded/a",
            "tmpExcludedRaw": "/tmp/\(tmpName)/excluded",
            "tmpSibling": "/tmp/\(tmpName)/excluded-not",
        ]
        let expectedExcluded: Set<String> = ["proj", "projSub", "projViaLink", "tmpExcluded", "tmpExcludedRaw"]
        // Matching is case-sensitive (D5). Whether `/PROJ` canonicalizes to `/proj` depends on the
        // volume, so only agreement between Swift and SQL is asserted for it.
        let caseVariant = "caseVariant"

        let index = AgentHistoryTestIndex(testCase: self)
        let store = try index.makeStore()
        let sourceID = try index.makeSource()
        var rowIDs: [String: Int64] = [:]
        var swiftExcluded: Set<String> = []
        for (name, raw) in cwds {
            let canonical = AgentHistoryPath.canonical(raw)
            rowIDs[name] = try store.upsertSession(
                sourceID: sourceID, unitKey: name, AgentHistoryFixtures.session(name, cwd: canonical)
            )
            XCTAssertEqual(matcher.excludes(raw), matcher.excludesCanonical(canonical), "raw and canonical agree: \(name)")
            if matcher.excludesCanonical(canonical) {
                swiftExcluded.insert(name)
            }
        }
        XCTAssertEqual(swiftExcluded.subtracting([caseVariant]), expectedExcluded, "Swift matcher")
        XCTAssertEqual(
            swiftExcluded.contains(caseVariant),
            AgentHistoryPath.canonical(cwds[caseVariant]!) == AgentHistoryPath.canonical(real.path + "/proj"),
            "a case variant matches only when it canonicalizes to the excluded spelling"
        )

        let removed = try store.deleteSessions(underFolders: matcher.canonicalFolders)

        XCTAssertEqual(Set(removed.map(\.rowID)), Set(swiftExcluded.compactMap { rowIDs[$0] }), "SQL purge agrees")
        XCTAssertEqual(
            try store.indexedNativeIDs(sourceID: sourceID),
            Set(cwds.keys).subtracting(swiftExcluded)
        )
    }
}
