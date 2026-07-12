import Foundation
import XCTest
@testable import Zentty

final class AgyHooksInstallerTests: XCTestCase {

    private var temporaryHomeURL: URL!
    private var hooksFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryHomeURL = try makeTemporaryDirectory()
        hooksFileURL = AgyHooksInstaller.defaultUserHooksFileURL(home: temporaryHomeURL.path)
    }

    override func tearDownWithError() throws {
        if let url = temporaryHomeURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Install

    func test_install_writes_zentty_group_with_expected_event_keys() throws {
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        let group = try loadZenttyGroup()
        XCTAssertEqual(
            Set(group.keys),
            Set([
                "SessionStart",
                "PreInvocation",
                "Stop",
                "turn-completion",
                "Notification",
                "SessionEnd",
                "PreToolUse",
                "PostToolUse",
            ])
        )
    }

    func test_install_writes_matcher_wrapper_only_for_tool_use_events() throws {
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        let group = try loadZenttyGroup()

        for event in ["PreToolUse", "PostToolUse"] {
            guard let entries = group[event] as? [[String: Any]], let entry = entries.first else {
                XCTFail("Expected one entry for \(event)")
                return
            }
            XCTAssertEqual(entry["matcher"] as? String, "*")
            let hooks = entry["hooks"] as? [[String: Any]]
            XCTAssertEqual(hooks?.count, 1)
            XCTAssertEqual(hooks?.first?["type"] as? String, "command")
            XCTAssertEqual(hooks?.first?["timeout"] as? Int, 120)
        }

        for event in ["SessionStart", "PreInvocation", "Stop", "turn-completion", "Notification", "SessionEnd"] {
            guard let entries = group[event] as? [[String: Any]], let entry = entries.first else {
                XCTFail("Expected one entry for \(event)")
                return
            }
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertEqual(entry["timeout"] as? Int, 15)
            XCTAssertNil(entry["matcher"], "Lifecycle hook \(event) must not be matcher-wrapped")
        }
    }

    func test_install_command_carries_marker_and_resolves_to_cli_path() throws {
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        let group = try loadZenttyGroup()
        guard let entries = group["SessionStart"] as? [[String: Any]],
              let command = entries.first?["command"] as? String else {
            XCTFail("Missing SessionStart command")
            return
        }
        XCTAssertTrue(command.contains(AgyHooksInstaller.hookMarker), "Command must carry the install marker")
        XCTAssertTrue(command.contains("/opt/zentty/zentty"), "Command must reference the installed CLI path")
        XCTAssertTrue(command.contains("agy-hook session-start"), "Command must forward the event positional")
        XCTAssertTrue(command.contains("ZENTTY_AGY_HOOKS_DISABLED"), "Command must honor the disable env var")
    }

    func test_install_preserves_foreign_top_level_groups() throws {
        let existing: [String: Any] = [
            "some-other-tool": [
                "SessionStart": [
                    ["type": "command", "command": "echo external", "timeout": 5],
                ],
            ],
        ]
        try writeRawHooksFile(existing)

        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        let parsed = try loadFullHooksFile()
        XCTAssertNotNil(parsed["zentty"])
        XCTAssertNotNil(parsed["some-other-tool"])
        let foreign = parsed["some-other-tool"] as? [String: Any]
        let foreignEvents = foreign?["SessionStart"] as? [[String: Any]]
        XCTAssertEqual(foreignEvents?.first?["command"] as? String, "echo external")
    }

    func test_install_rewrites_existing_zentty_group_in_place() throws {
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty-v2",
            home: temporaryHomeURL.path
        )

        let group = try loadZenttyGroup()
        guard let entries = group["SessionStart"] as? [[String: Any]],
              let command = entries.first?["command"] as? String else {
            XCTFail("Missing SessionStart command")
            return
        }
        XCTAssertTrue(command.contains("/opt/zentty/zentty-v2"), "Re-install must update the CLI path")
        XCTAssertFalse(command.contains("/opt/zentty/zentty\""), "Re-install must drop the previous CLI path")
    }

    func test_install_throws_when_hooks_file_is_not_json() throws {
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not valid json".write(to: hooksFileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )) { error in
            guard let installerError = error as? AgyHooksInstallerError,
                  case .existingFileNotJSON = installerError else {
                XCTFail("Expected AgyHooksInstallerError.existingFileNotJSON, got \(error)")
                return
            }
        }
    }

    // MARK: - Idempotence

    func test_install_returns_true_on_first_write_and_false_on_identical_reinstall() throws {
        let first = try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        XCTAssertTrue(first, "first install must write")

        let second = try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        XCTAssertFalse(second, "identical re-install must not rewrite")
    }

    func test_install_returns_true_when_cli_path_changes() throws {
        _ = try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        let changed = try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty-v2",
            home: temporaryHomeURL.path
        )
        XCTAssertTrue(changed, "a CLI path change must rewrite")
    }

    // MARK: - ensureInstalledForCurrentUser

    func test_ensure_installed_writes_hooks_and_marker_on_first_call() throws {
        let announced = try AgyHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        XCTAssertTrue(announced, "first ensure-install must report the one-time announcement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksFileURL.path))
        let markerURL = hooksFileURL.deletingLastPathComponent()
            .appendingPathComponent(AgyHooksInstaller.firstRunMarkerName, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "marker must be written")
        XCTAssertNotNil(try? loadZenttyGroup())
    }

    func test_ensure_installed_second_call_does_not_reannounce() throws {
        _ = try AgyHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        let secondAnnounced = try AgyHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        XCTAssertFalse(secondAnnounced, "marker present → no re-announcement")
    }

    func test_ensure_installed_does_not_rewrite_hooks_when_unchanged() throws {
        _ = try AgyHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        let before = try FileManager.default.attributesOfItem(atPath: hooksFileURL.path)[.modificationDate] as? Date

        // A second ensure-install with the same CLI path must leave the file
        // byte-identical (we only assert content equality, not mtime, to stay
        // robust on fast filesystems).
        let contentsBefore = try Data(contentsOf: hooksFileURL)
        _ = try AgyHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        let contentsAfter = try Data(contentsOf: hooksFileURL)
        XCTAssertEqual(contentsBefore, contentsAfter, "unchanged ensure-install must not rewrite hooks.json")
        _ = before  // mtime captured for debugging; content equality is the real assertion
    }

    func test_uninstall_clears_first_run_marker() throws {
        _ = try AgyHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )
        let markerURL = hooksFileURL.deletingLastPathComponent()
            .appendingPathComponent(AgyHooksInstaller.firstRunMarkerName, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        try AgyHooksInstaller.uninstall(hooksFileURL: hooksFileURL, home: temporaryHomeURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "uninstall must clear the marker so a later auto-install re-announces")
    }

    // MARK: - Uninstall

    func test_uninstall_removes_only_zentty_group() throws {
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        // Inject a foreign group after install so we can verify it survives.
        var contents = try loadFullHooksFile()
        contents["other-tool"] = ["SessionStart": [["type": "command", "command": "echo other", "timeout": 5]]]
        try writeRawHooksFile(contents)

        try AgyHooksInstaller.uninstall(hooksFileURL: hooksFileURL, home: temporaryHomeURL.path)

        let parsed = try loadFullHooksFile()
        XCTAssertNil(parsed["zentty"])
        XCTAssertNotNil(parsed["other-tool"])
    }

    func test_uninstall_removes_hooks_file_when_only_zentty_group_present() throws {
        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        try AgyHooksInstaller.uninstall(hooksFileURL: hooksFileURL, home: temporaryHomeURL.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksFileURL.path))
    }

    func test_uninstall_leaves_unowned_zentty_group_untouched() throws {
        // A different tool might legitimately own the "zentty" top-level
        // key. Our uninstaller must not delete it.
        let foreign: [String: Any] = [
            "zentty": [
                "SessionStart": [["type": "command", "command": "echo foreign", "timeout": 5]],
            ],
        ]
        try writeRawHooksFile(foreign)

        try AgyHooksInstaller.uninstall(hooksFileURL: hooksFileURL, home: temporaryHomeURL.path)

        let parsed = try loadFullHooksFile()
        guard let group = parsed["zentty"] as? [String: Any],
              let events = group["SessionStart"] as? [[String: Any]] else {
            XCTFail("Foreign zentty group should be preserved")
            return
        }
        XCTAssertEqual(events.first?["command"] as? String, "echo foreign")
    }

    func test_uninstall_is_noop_when_hooks_file_is_absent() throws {
        XCTAssertNoThrow(try AgyHooksInstaller.uninstall(
            hooksFileURL: hooksFileURL,
            home: temporaryHomeURL.path
        ))
    }

    // MARK: - Legacy plugin cleanup

    func test_install_removes_legacy_plugin_directory_carrying_marker() throws {
        let legacyURL = AgyHooksInstaller.defaultUserConfigPluginsURL(home: temporaryHomeURL.path)
            .appendingPathComponent("zentty", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let legacyScript = legacyURL.appendingPathComponent("hook.sh", isDirectory: false)
        // The marker string the old plugin layout carried.
        try "#!/bin/sh\n# agy-hook\n".write(to: legacyScript, atomically: true, encoding: .utf8)

        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func test_install_leaves_legacy_plugin_directory_without_marker_alone() throws {
        let legacyURL = AgyHooksInstaller.defaultUserConfigPluginsURL(home: temporaryHomeURL.path)
            .appendingPathComponent("zentty", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let foreignScript = legacyURL.appendingPathComponent("hook.sh", isDirectory: false)
        try "#!/bin/sh\necho not ours\n".write(to: foreignScript, atomically: true, encoding: .utf8)

        try AgyHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignScript.path))
    }

    // MARK: - HooksInstalling conformance: HOME resolution (behavior preservation)
    //
    // The pre-refactor call site (AgentLaunchBootstrap) resolved home via
    // `environment["HOME"]?.nilIfBlank ?? NSHomeDirectory()`. A blank-but-present
    // HOME must fall back to NSHomeDirectory(), not resolve to a path under the
    // current working directory. Table-driven over the two ways HOME can be
    // "missing": present-but-blank, and absent from the dictionary entirely.
    // `integrationConfigURL(environment:)` is used because it is pure path
    // resolution with no disk I/O, so these cases can be checked without writing
    // into the real user home.

    func test_HooksInstalling_home_resolution_falls_back_to_NSHomeDirectory() {
        let cases: [(name: String, environment: [String: String])] = [
            ("blank HOME", ["HOME": ""]),
            ("missing HOME", [:]),
        ]

        for testCase in cases {
            let resolved = AgyHooksInstaller.integrationConfigURL(environment: testCase.environment)
            let expected = AgyHooksInstaller.defaultUserHooksFileURL(home: NSHomeDirectory())

            XCTAssertEqual(resolved, expected, "\(testCase.name): expected fallback to NSHomeDirectory()")
            XCTAssertTrue(
                resolved?.path.hasPrefix(NSHomeDirectory()) == true,
                "\(testCase.name): resolved path \(resolved?.path ?? "nil") must live under NSHomeDirectory(), not CWD or be empty"
            )
        }
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgyHooksInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadFullHooksFile() throws -> [String: Any] {
        let data = try Data(contentsOf: hooksFileURL)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgyHooksInstallerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "hooks.json is not a JSON object"])
        }
        return parsed
    }

    private func loadZenttyGroup() throws -> [String: Any] {
        let parsed = try loadFullHooksFile()
        guard let group = parsed["zentty"] as? [String: Any] else {
            throw NSError(domain: "AgyHooksInstallerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing zentty group"])
        }
        return group
    }

    private func writeRawHooksFile(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: hooksFileURL, options: .atomic)
    }
}
