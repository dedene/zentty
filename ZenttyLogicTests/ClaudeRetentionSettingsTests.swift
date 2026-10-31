import Foundation
import XCTest
@testable import Zentty

final class ClaudeRetentionSettingsTests: XCTestCase {
    private var root: URL!
    private var configDirectory: URL!
    private var settingsURL: URL!
    private var missingManagedURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        self.root = root
        self.configDirectory = configDirectory
        self.settingsURL = configDirectory.appendingPathComponent("settings.json")
        self.missingManagedURL = root.appendingPathComponent("managed-settings.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - status

    func test_status_defaults_to_30_days_when_file_missing() {
        let status = status()

        XCTAssertEqual(status.effectiveDays, 30)
        XCTAssertEqual(status.source, .defaultValue)
        XCTAssertNil(status.readError)
        XCTAssertTrue(status.isNudgeEligible)
        XCTAssertEqual(status.settingsFileURL, settingsURL)
        XCTAssertEqual(status.configDirectory, configDirectory)
    }

    func test_status_reads_user_value() throws {
        try write(#"{"theme": "dark", "cleanupPeriodDays": 90}"#)
        XCTAssertEqual(status().effectiveDays, 90)
        XCTAssertEqual(status().source, .userSettings)
        XCTAssertTrue(status().isNudgeEligible)

        try write(#"{"cleanupPeriodDays": 120.0}"#)
        XCTAssertEqual(status().effectiveDays, 120)
        XCTAssertEqual(status().source, .userSettings)

        try write(#"{"cleanupPeriodDays": 365}"#)
        XCTAssertFalse(status().isNudgeEligible)

        try write(#"{"theme": "dark"}"#)
        XCTAssertEqual(status().effectiveDays, 30)
        XCTAssertEqual(status().source, .defaultValue)
    }

    func test_status_managed_override_wins_and_is_not_eligible() throws {
        try write(#"{"cleanupPeriodDays": 400}"#)
        let managedURL = root.appendingPathComponent("managed.json")
        try Data(#"{"cleanupPeriodDays": 14}"#.utf8).write(to: managedURL)

        let status = ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: managedURL)

        XCTAssertEqual(status.effectiveDays, 14)
        XCTAssertEqual(status.source, .managedSettings)
        XCTAssertFalse(status.isNudgeEligible)
    }

    /// A managed file that doesn't decide retention (other keys only, malformed, a non-number
    /// value, unreadable) is ignored: the user's file, or the default, decides.
    func test_status_managed_file_without_usable_value_falls_through_to_user_file() throws {
        let managedURL = root.appendingPathComponent("managed.json")
        let managedContents: [(label: String, text: String)] = [
            ("other keys only", #"{"permissions": {}}"#),
            ("invalid JSON", #"{"cleanupPeriodDays": 14,"#),
            ("boolean value", #"{"cleanupPeriodDays": true}"#),
        ]

        for (label, text) in managedContents {
            try Data(text.utf8).write(to: managedURL)

            try write(#"{"cleanupPeriodDays": 90}"#)
            var status = ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: managedURL)
            XCTAssertEqual(status.source, .userSettings, label)
            XCTAssertEqual(status.effectiveDays, 90, label)
            XCTAssertNil(status.readError, label)
            XCTAssertTrue(status.isNudgeEligible, label)

            try write(#"{"cleanupPeriodDays": 400}"#)
            status = ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: managedURL)
            XCTAssertEqual(status.source, .userSettings, label)
            XCTAssertEqual(status.effectiveDays, 400, label)
            XCTAssertFalse(status.isNudgeEligible, label)

            try write(#"{"theme": "dark"}"#)
            status = ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: managedURL)
            XCTAssertEqual(status.source, .defaultValue, label)
            XCTAssertEqual(status.effectiveDays, 30, label)
            XCTAssertNil(status.readError, label)
            XCTAssertTrue(status.isNudgeEligible, label)
        }
    }

    func test_status_unreadable_managed_file_falls_through_to_user_file() throws {
        let managedURL = root.appendingPathComponent("managed.json")
        try Data(#"{"cleanupPeriodDays": 14}"#.utf8).write(to: managedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: managedURL.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: managedURL.path)
        }
        guard !FileManager.default.isReadableFile(atPath: managedURL.path) else {
            throw XCTSkip("running with privileges that ignore file permissions")
        }
        try write(#"{"cleanupPeriodDays": 90}"#)

        let status = ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: managedURL)

        XCTAssertEqual(status.source, .userSettings)
        XCTAssertEqual(status.effectiveDays, 90)
        XCTAssertNil(status.readError)
        XCTAssertTrue(status.isNudgeEligible)
    }

    func test_status_invalid_json_reports_error_and_is_not_eligible() throws {
        try write(#"{"cleanupPeriodDays": 90,"#)

        let status = status()

        XCTAssertEqual(status.readError, .invalidJSON(path: settingsURL.path))
        XCTAssertFalse(status.isNudgeEligible)
    }

    func test_status_rejects_oversized_file() throws {
        try Data(repeating: UInt8(ascii: " "), count: 5 * 1024 * 1024 + 1).write(to: settingsURL)

        XCTAssertEqual(status().readError, .tooLarge(path: settingsURL.path))
        XCTAssertFalse(status().isNudgeEligible)
    }

    func test_status_zero_days_is_not_eligible() throws {
        try write(#"{"cleanupPeriodDays": 0}"#)

        let status = status()

        XCTAssertEqual(status.effectiveDays, 0)
        XCTAssertEqual(status.source, .userSettings)
        XCTAssertNil(status.readError)
        XCTAssertFalse(status.isNudgeEligible)
    }

    func test_status_boolean_value_is_unexpected_type() throws {
        try write(#"{"cleanupPeriodDays": true}"#)
        XCTAssertEqual(status().readError, .unexpectedValueType(path: settingsURL.path))
        XCTAssertFalse(status().isNudgeEligible)

        try write(#"{"cleanupPeriodDays": "90"}"#)
        XCTAssertEqual(status().readError, .unexpectedValueType(path: settingsURL.path))

        try write(#"{"cleanupPeriodDays": 90.5}"#)
        XCTAssertEqual(status().readError, .unexpectedValueType(path: settingsURL.path))
    }

    func test_status_non_object_top_level_is_reported() throws {
        try write("[1, 2]")

        XCTAssertEqual(status().readError, .notAnObject(path: settingsURL.path))
        XCTAssertFalse(status().isNudgeEligible)
    }

    // MARK: - defaultConfigDirectory

    func test_default_config_directory_prefers_CLAUDE_CONFIG_DIR() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

        XCTAssertEqual(
            ClaudeRetentionSettings.defaultConfigDirectory(
                environment: ["CLAUDE_CONFIG_DIR": "/opt/claude-config"],
                homeDirectoryURL: home
            ).path,
            "/opt/claude-config"
        )
        XCTAssertEqual(
            ClaudeRetentionSettings.defaultConfigDirectory(
                environment: ["CLAUDE_CONFIG_DIR": "~/custom-claude"],
                homeDirectoryURL: home
            ).path,
            "/Users/someone/custom-claude"
        )
    }

    func test_default_config_directory_falls_back_to_dot_claude() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

        XCTAssertEqual(
            ClaudeRetentionSettings.defaultConfigDirectory(environment: [:], homeDirectoryURL: home).path,
            "/Users/someone/.claude"
        )
        XCTAssertEqual(
            ClaudeRetentionSettings.defaultConfigDirectory(
                environment: ["CLAUDE_CONFIG_DIR": "  "],
                homeDirectoryURL: home
            ).path,
            "/Users/someone/.claude"
        )
    }

    // MARK: - raiseRetention

    func test_raise_inserts_key_and_keeps_other_bytes() throws {
        let cases: [(original: String, expected: String)] = [
            (
                "{\n  \"theme\": \"dark\",\n  \"env\": {\"A\": \"1\"}\n}\n",
                "{\n  \"cleanupPeriodDays\": 365,\n  \"theme\": \"dark\",\n  \"env\": {\"A\": \"1\"}\n}\n"
            ),
            (
                "{\n    \"theme\": \"dark\"\n}",
                "{\n    \"cleanupPeriodDays\": 365,\n    \"theme\": \"dark\"\n}"
            ),
            (
                "{\n\t\"theme\": \"dark\",\n\t\"model\": \"opus\"\n}\n",
                "{\n\t\"cleanupPeriodDays\": 365,\n\t\"theme\": \"dark\",\n\t\"model\": \"opus\"\n}\n"
            ),
        ]

        for (original, expected) in cases {
            try write(original)

            let outcome = try raise()

            guard case .written = outcome else {
                return XCTFail("expected a write for \(original.debugDescription), got \(outcome)")
            }
            XCTAssertEqual(try read(), expected)
            XCTAssertEqual(status().effectiveDays, 365)
        }
    }

    func test_raise_replaces_smaller_value_in_place() throws {
        try write("{\n  \"theme\": \"dark\",\n  \"cleanupPeriodDays\": 30,\n  \"model\": \"opus\"\n}\n")

        try raise()

        XCTAssertEqual(try read(), "{\n  \"theme\": \"dark\",\n  \"cleanupPeriodDays\": 365,\n  \"model\": \"opus\"\n}\n")
    }

    func test_raise_never_lowers_larger_value() throws {
        let original = "{ \"cleanupPeriodDays\": 1000 }"
        try write(original)

        let outcome = try raise()

        XCTAssertEqual(outcome, .alreadySufficient(currentDays: 1000))
        XCTAssertEqual(try read(), original)
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_raise_writes_backup_with_original_bytes() throws {
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try write(original)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T09:08:07Z"))

        let outcome = try ClaudeRetentionSettings.raiseRetention(configDirectory: configDirectory, now: now)

        let expectedBackup = configDirectory.appendingPathComponent("settings.json.zentty-backup-20261031T090807Z")
        XCTAssertEqual(outcome, .written(backupURL: expectedBackup))
        XCTAssertEqual(try String(contentsOf: expectedBackup, encoding: .utf8), original)
    }

    func test_raise_refuses_invalid_json_and_changes_nothing() throws {
        let original = "{\n  \"theme\": \"dark\",\n}\n"
        try write(original)

        XCTAssertThrowsError(try raise()) { error in
            XCTAssertEqual(error as? ClaudeRetentionSettingsError, .invalidJSON(path: self.settingsURL.path))
        }
        XCTAssertEqual(try read(), original)
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_trailing_commas_are_invalid_json() throws {
        for text in ["{\"theme\": \"dark\",}", "{\"list\": [1, 2,]}", "{\"env\": {\"A\": \"1\" , }}"] {
            try write(text)

            XCTAssertEqual(status().readError, .invalidJSON(path: settingsURL.path), text)
            XCTAssertThrowsError(try raise(), text)
            XCTAssertEqual(try read(), text)
        }

        try write("{\"note\": \",}\", \"list\": [\",]\"]}")
        XCTAssertNil(status().readError)
    }

    func test_raise_refuses_non_object_top_level() throws {
        try write("[\"theme\"]")

        XCTAssertThrowsError(try raise()) { error in
            XCTAssertEqual(error as? ClaudeRetentionSettingsError, .notAnObject(path: self.settingsURL.path))
        }
        XCTAssertEqual(try read(), "[\"theme\"]")
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_raise_refuses_boolean_value() throws {
        try write(#"{"cleanupPeriodDays": false}"#)

        XCTAssertThrowsError(try raise()) { error in
            XCTAssertEqual(error as? ClaudeRetentionSettingsError, .unexpectedValueType(path: self.settingsURL.path))
        }
        XCTAssertEqual(try read(), #"{"cleanupPeriodDays": false}"#)
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_raise_creates_file_when_missing() throws {
        let outcome = try raise()

        XCTAssertEqual(outcome, .written(backupURL: nil))
        XCTAssertEqual(try read(), "{\n  \"cleanupPeriodDays\": 365\n}\n")
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_raise_writes_through_symlink() throws {
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realFile = dotfiles.appendingPathComponent("claude-settings.json")
        try Data("{\n  \"theme\": \"dark\"\n}\n".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: realFile)

        try raise()

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: settingsURL.path),
            realFile.path
        )
        XCTAssertEqual(
            try String(contentsOf: realFile, encoding: .utf8),
            "{\n  \"cleanupPeriodDays\": 365,\n  \"theme\": \"dark\"\n}\n"
        )
        XCTAssertEqual(status().effectiveDays, 365)
    }

    func test_raise_ignores_nested_and_string_occurrences() throws {
        let original = """
            {
              "note": "\\"cleanupPeriodDays\\": 5, {",
              "nested": {"cleanupPeriodDays": 7, "list": ["cleanupPeriodDays", {"cleanupPeriodDays": 9}]},
              "cleanupPeriodDays": 10
            }

            """
        try write(original)

        try raise()

        XCTAssertEqual(try read(), original.replacingOccurrences(of: "\"cleanupPeriodDays\": 10", with: "\"cleanupPeriodDays\": 365"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual((object["nested"] as? [String: Any])?["cleanupPeriodDays"] as? Int, 7)
        XCTAssertEqual(object["note"] as? String, "\"cleanupPeriodDays\": 5, {")
    }

    func test_raise_patches_duplicate_top_level_keys() throws {
        try write("{\"cleanupPeriodDays\": 10, \"theme\": \"dark\", \"cleanupPeriodDays\": 20}")

        try raise()

        XCTAssertEqual(try read(), "{\"cleanupPeriodDays\": 365, \"theme\": \"dark\", \"cleanupPeriodDays\": 365}")
    }

    // Claude Code reads settings with JSON.parse, so the last duplicate key wins.

    func test_status_reads_last_duplicate_key_like_claude_code() throws {
        try write(#"{"cleanupPeriodDays": 30, "theme": "dark", "cleanupPeriodDays": 400}"#)
        XCTAssertEqual(status().effectiveDays, 400)
        XCTAssertEqual(status().source, .userSettings)
        XCTAssertFalse(status().isNudgeEligible)

        try write(#"{"cleanupPeriodDays": 400, "theme": "dark", "cleanupPeriodDays": 30}"#)
        XCTAssertEqual(status().effectiveDays, 30)
        XCTAssertTrue(status().isNudgeEligible)

        try write(#"{"cleanupPeriodDays": true, "cleanupPeriodDays": 90}"#)
        XCTAssertNil(status().readError)
        XCTAssertEqual(status().effectiveDays, 90)

        try write(#"{"cleanupPeriodDays": 90, "cleanupPeriodDays": true}"#)
        XCTAssertEqual(status().readError, .unexpectedValueType(path: settingsURL.path))
        XCTAssertFalse(status().isNudgeEligible)
    }

    func test_raise_never_lowers_when_last_duplicate_is_larger() throws {
        let original = #"{"cleanupPeriodDays": 30, "theme": "dark", "cleanupPeriodDays": 400}"#
        try write(original)

        let outcome = try raise()

        XCTAssertEqual(outcome, .alreadySufficient(currentDays: 400))
        XCTAssertEqual(try read(), original)
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_raise_raises_when_last_duplicate_is_smaller() throws {
        try write(#"{"cleanupPeriodDays": 400, "theme": "dark", "cleanupPeriodDays": 30}"#)

        let outcome = try raise()

        guard case .written = outcome else {
            return XCTFail("expected a write, got \(outcome)")
        }
        XCTAssertEqual(try read(), #"{"cleanupPeriodDays": 365, "theme": "dark", "cleanupPeriodDays": 365}"#)
        XCTAssertEqual(status().effectiveDays, 365)
    }

    func test_status_managed_file_reads_last_duplicate_key() throws {
        let managedURL = root.appendingPathComponent("managed.json")
        try Data(#"{"cleanupPeriodDays": 400, "cleanupPeriodDays": 14}"#.utf8).write(to: managedURL)

        let status = ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: managedURL)

        XCTAssertEqual(status.effectiveDays, 14)
        XCTAssertEqual(status.source, .managedSettings)
    }

    func test_last_top_level_value_text_skips_nested_and_string_occurrences() {
        XCTAssertEqual(
            ClaudeRetentionSettings.lastTopLevelValueText(
                in: #"{"cleanupPeriodDays": 1, "nested": {"cleanupPeriodDays": 2}, "cleanupPeriodDays": 3.0, "s": "cleanupPeriodDays"}"#
            ),
            "3.0"
        )
        XCTAssertNil(ClaudeRetentionSettings.lastTopLevelValueText(in: #"{"nested": {"cleanupPeriodDays": 2}}"#))
        XCTAssertNil(ClaudeRetentionSettings.lastTopLevelValueText(in: "[1]"))
    }

    func test_raise_handles_empty_and_single_line_objects() throws {
        try write("{}")
        try raise()
        XCTAssertEqual(try read(), "{\n  \"cleanupPeriodDays\": 365\n}")

        try write("{ }\n")
        try raise()
        XCTAssertEqual(try read(), "{\n  \"cleanupPeriodDays\": 365\n}\n")

        try write("{\"theme\": \"dark\"}")
        try raise()
        XCTAssertEqual(try read(), "{\"cleanupPeriodDays\": 365, \"theme\": \"dark\"}")

        try write("{ \"theme\": \"dark\" }")
        try raise()
        XCTAssertEqual(try read(), "{ \"cleanupPeriodDays\": 365, \"theme\": \"dark\" }")
    }

    func test_updated_json_text_returns_nil_for_non_object_text() {
        XCTAssertNil(ClaudeRetentionSettings.updatedJSONText("[1]", settingDays: 365))
        XCTAssertNil(ClaudeRetentionSettings.updatedJSONText("{\"a\": ", settingDays: 365))
        XCTAssertEqual(
            ClaudeRetentionSettings.updatedJSONText("{\"cleanup\\u0050eriodDays\": 3}", settingDays: 365),
            "{\"cleanup\\u0050eriodDays\": 365}"
        )
    }

    func test_raise_preserves_posix_permissions() throws {
        try write("{\n  \"theme\": \"dark\"\n}\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)

        let outcome = try raise()

        XCTAssertEqual(try permissions(settingsURL), 0o600)
        guard case let .written(backupURL?) = outcome else {
            return XCTFail("expected a backup, got \(outcome)")
        }
        XCTAssertEqual(try permissions(backupURL), 0o600)
    }

    func test_backup_name_collision_gets_numeric_suffix() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T09:08:07Z"))
        let base = "settings.json.zentty-backup-20261031T090807Z"
        try write("{\"cleanupPeriodDays\": 30}")
        try Data("taken".utf8).write(to: configDirectory.appendingPathComponent(base))
        try Data("taken".utf8).write(to: configDirectory.appendingPathComponent("\(base)-2"))

        let outcome = try ClaudeRetentionSettings.raiseRetention(configDirectory: configDirectory, now: now)

        let expected = configDirectory.appendingPathComponent("\(base)-3")
        XCTAssertEqual(outcome, .written(backupURL: expected))
        XCTAssertEqual(try String(contentsOf: expected, encoding: .utf8), "{\"cleanupPeriodDays\": 30}")
        XCTAssertEqual(try String(contentsOf: configDirectory.appendingPathComponent(base), encoding: .utf8), "taken")
    }

    func test_raise_throws_directory_missing() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)

        XCTAssertThrowsError(try ClaudeRetentionSettings.raiseRetention(configDirectory: missing)) { error in
            XCTAssertEqual(error as? ClaudeRetentionSettingsError, .directoryMissing(path: missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func test_concurrent_change_between_read_and_write_retries_then_fails() throws {
        try write("{\"cleanupPeriodDays\": 30}")
        var calls = 0

        XCTAssertThrowsError(
            try ClaudeRetentionSettings.raiseRetention(configDirectory: configDirectory, beforeWrite: {
                calls += 1
                try? Data("{\"cleanupPeriodDays\": \(30 + calls)}".utf8).write(to: self.settingsURL)
            })
        ) { error in
            XCTAssertEqual(error as? ClaudeRetentionSettingsError, .changedDuringWrite(path: self.settingsURL.path))
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try read(), "{\"cleanupPeriodDays\": 32}")
        XCTAssertEqual(try listing(), ["settings.json"])
    }

    func test_concurrent_change_once_is_retried_and_succeeds() throws {
        try write("{\"cleanupPeriodDays\": 30}")
        var calls = 0

        let outcome = try ClaudeRetentionSettings.raiseRetention(configDirectory: configDirectory, beforeWrite: {
            calls += 1
            if calls == 1 {
                try? Data("{\"cleanupPeriodDays\": 60, \"theme\": \"dark\"}".utf8).write(to: self.settingsURL)
            }
        })

        XCTAssertEqual(calls, 2)
        guard case let .written(backupURL?) = outcome else {
            return XCTFail("expected a backup, got \(outcome)")
        }
        XCTAssertEqual(try read(), "{\"cleanupPeriodDays\": 365, \"theme\": \"dark\"}")
        XCTAssertEqual(
            try String(contentsOf: backupURL, encoding: .utf8),
            "{\"cleanupPeriodDays\": 60, \"theme\": \"dark\"}"
        )
    }

    // MARK: - Helpers

    private func status() -> ClaudeRetentionStatus {
        ClaudeRetentionSettings.status(configDirectory: configDirectory, managedSettingsURL: missingManagedURL)
    }

    @discardableResult
    private func raise() throws -> ClaudeRetentionWriteOutcome {
        try ClaudeRetentionSettings.raiseRetention(configDirectory: configDirectory)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: settingsURL)
        // Each raise in a multi-case test writes a backup; keep the directory listing about this case.
        for name in try FileManager.default.contentsOfDirectory(atPath: configDirectory.path)
        where name.hasPrefix("settings.json.zentty-backup-") {
            try FileManager.default.removeItem(at: configDirectory.appendingPathComponent(name))
        }
    }

    private func read() throws -> String {
        try String(contentsOf: settingsURL, encoding: .utf8)
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: configDirectory.path).sorted()
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}
