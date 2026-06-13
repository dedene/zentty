import Foundation
import XCTest
@testable import Zentty

final class VibeHooksInstallerTests: XCTestCase {

    private var temporaryHomeURL: URL!
    private var hooksFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryHomeURL = try makeTemporaryDirectory()
        hooksFileURL = VibeHooksInstaller.defaultUserHooksFileURL(home: temporaryHomeURL.path)
    }

    override func tearDownWithError() throws {
        if let url = temporaryHomeURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Install

    func test_install_writes_all_managed_hooks() throws {
        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        let content = try String(contentsOf: hooksFileURL, encoding: .utf8)
        
        // Check that all hook types are present
        XCTAssertTrue(content.contains("post_agent_turn"), "Must contain post_agent_turn hook")
        XCTAssertTrue(content.contains("before_tool"), "Must contain before_tool hook")
        XCTAssertTrue(content.contains("after_tool"), "Must contain after_tool hook")
        
        // Check that all hook names are present
        XCTAssertTrue(content.contains("zentty-post-agent-turn"), "Must contain post_agent_turn hook name")
        XCTAssertTrue(content.contains("zentty-before-tool"), "Must contain before_tool hook name")
        XCTAssertTrue(content.contains("zentty-after-tool"), "Must contain after_tool hook name")
    }

    func test_install_writes_hooks_with_correct_command() throws {
        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        let content = try String(contentsOf: hooksFileURL, encoding: .utf8)
        
        // Check that the command contains the hook marker
        XCTAssertTrue(content.contains(VibeHooksInstaller.hookMarker), "Command must carry the install marker")
        
        // Check that the command contains the CLI path
        XCTAssertTrue(content.contains("/opt/zentty/zentty"), "Command must reference the installed CLI path")
    }

    func test_install_preserves_existing_user_hooks() throws {
        // Write existing user hooks
        let existingContent = """
[[hooks]]
name = "user-hook"
type = "post_agent_turn"
command = "echo user hook"
timeout = 5.0
"""
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try existingContent.write(to: hooksFileURL, atomically: true, encoding: .utf8)

        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        let content = try String(contentsOf: hooksFileURL, encoding: .utf8)
        
        // Check that user hook is preserved
        XCTAssertTrue(content.contains("user-hook"), "User hook must be preserved")
        XCTAssertTrue(content.contains("echo user hook"), "User hook command must be preserved")
        
        // Check that Zentty hooks are added
        XCTAssertTrue(content.contains("zentty-post-agent-turn"), "Zentty hooks must be added")
    }

    func test_install_removes_existing_zentty_block() throws {
        // Write existing content with old Zentty block
        let existingContent = """
[[hooks]]
name = "user-hook"
type = "post_agent_turn"
command = "echo user hook"
timeout = 5.0

# [Zentty Managed Hooks - Begin]
# DO NOT EDIT: These hooks are managed by Zentty.
# Run `zentty uninstall vibe-hooks` to remove.
# Marker: ipc agent-event --adapter=vibe

[[hooks]]
name = "zentty-post-agent-turn-old"
type = "post_agent_turn"
command = "$ZENTTY_CLI_BIN ipc agent-event --adapter=vibe"
timeout = 15.0

# [Zentty Managed Hooks - End]
"""
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try existingContent.write(to: hooksFileURL, atomically: true, encoding: .utf8)

        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        let content = try String(contentsOf: hooksFileURL, encoding: .utf8)
        
        // Check that old Zentty hook is removed
        XCTAssertFalse(content.contains("zentty-post-agent-turn-old"), "Old Zentty hook must be removed")
        
        // Check that new Zentty hooks are present
        XCTAssertTrue(content.contains("zentty-post-agent-turn"), "New Zentty hooks must be present")
        
        // Check that user hook is preserved
        XCTAssertTrue(content.contains("user-hook"), "User hook must be preserved")
    }

    func test_install_returns_true_on_first_write() throws {
        let first = try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )
        XCTAssertTrue(first, "First install must write")
    }

    func test_install_returns_false_on_identical_reinstall() throws {
        _ = try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )
        let second = try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )
        XCTAssertFalse(second, "Identical re-install must not rewrite")
    }

    func test_install_returns_true_when_cli_path_changes() throws {
        _ = try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )
        let changed = try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty-v2",
            fileManager: .default
        )
        XCTAssertTrue(changed, "A CLI path change must rewrite")
    }

    // MARK: - Uninstall

    func test_uninstall_removes_zentty_managed_block() throws {
        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        try VibeHooksInstaller.uninstall(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        )

        // A Zentty-only file is deleted entirely on uninstall (see
        // test_uninstall_removes_file_when_only_zentty_hooks_present); either
        // way the managed block and its hooks must be gone.
        let content = (try? String(contentsOf: hooksFileURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(content.contains("zentty-post-agent-turn"), "Zentty hooks must be removed")
        XCTAssertFalse(content.contains(VibeHooksInstaller.zenttyBlockMarker), "Zentty marker must be removed")
    }

    func test_uninstall_preserves_user_hooks() throws {
        // Write existing user hooks
        let existingContent = """
[[hooks]]
name = "user-hook"
type = "post_agent_turn"
command = "echo user hook"
timeout = 5.0

# [Zentty Managed Hooks - Begin]
# DO NOT EDIT: These hooks are managed by Zentty.

[[hooks]]
name = "zentty-post-agent-turn"
type = "post_agent_turn"
command = "$ZENTTY_CLI_BIN ipc agent-event --adapter=vibe"
timeout = 15.0

# [Zentty Managed Hooks - End]
"""
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try existingContent.write(to: hooksFileURL, atomically: true, encoding: .utf8)

        try VibeHooksInstaller.uninstall(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        )

        let content = try String(contentsOf: hooksFileURL, encoding: .utf8)
        
        // Check that user hook is preserved
        XCTAssertTrue(content.contains("user-hook"), "User hook must be preserved")
        XCTAssertTrue(content.contains("echo user hook"), "User hook command must be preserved")
        
        // Check that Zentty hooks are removed
        XCTAssertFalse(content.contains("zentty-post-agent-turn"), "Zentty hooks must be removed")
    }

    func test_uninstall_removes_file_when_only_zentty_hooks_present() throws {
        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        try VibeHooksInstaller.uninstall(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksFileURL.path), "File must be removed when only Zentty hooks present")
    }

    func test_uninstall_is_noop_when_file_missing() throws {
        XCTAssertNoThrow(try VibeHooksInstaller.uninstall(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        ))
    }

    // MARK: - isInstalled

    func test_isInstalled_returns_false_when_file_missing() throws {
        XCTAssertFalse(VibeHooksInstaller.isInstalled(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        ))
    }

    func test_isInstalled_returns_false_when_file_empty() throws {
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: hooksFileURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(VibeHooksInstaller.isInstalled(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        ))
    }

    func test_isInstalled_returns_true_when_zentty_block_present() throws {
        try VibeHooksInstaller.install(
            hooksFileURL: hooksFileURL,
            cliPath: "/opt/zentty/zentty",
            fileManager: .default
        )

        XCTAssertTrue(VibeHooksInstaller.isInstalled(
            hooksFileURL: hooksFileURL,
            fileManager: .default
        ))
    }

    // MARK: - ensureInstalledForCurrentUser

    func test_ensureInstalledForCurrentUser_writes_hooks() throws {
        let announced = try VibeHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path,
            fileManager: .default
        )

        XCTAssertTrue(announced, "First ensure-install must report the one-time announcement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksFileURL.path))
    }

    func test_ensureInstalledForCurrentUser_second_call_does_not_reannounce() throws {
        _ = try VibeHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path,
            fileManager: .default
        )
        let secondAnnounced = try VibeHooksInstaller.ensureInstalledForCurrentUser(
            cliPath: "/opt/zentty/zentty",
            home: temporaryHomeURL.path,
            fileManager: .default
        )
        XCTAssertFalse(secondAnnounced, "marker present must not re-announce")
    }

    // MARK: - Paths

    func test_defaultUserVibeHomeURL() {
        let home = "/test/home"
        let url = VibeHooksInstaller.defaultUserVibeHomeURL(home: home)
        XCTAssertEqual(url.path, "/test/home/.vibe")
    }

    func test_defaultUserHooksFileURL() {
        let home = "/test/home"
        let url = VibeHooksInstaller.defaultUserHooksFileURL(home: home)
        XCTAssertEqual(url.path, "/test/home/.vibe/hooks.toml")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeHooksInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
