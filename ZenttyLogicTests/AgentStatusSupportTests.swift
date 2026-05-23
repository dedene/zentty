import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentStatusSupportTests: XCTestCase {
    func test_agent_interaction_classifier_recognizes_codex_attention_notifications() {
        let cases: [(message: String, kind: PaneAgentInteractionKind)] = [
            ("Approval requested: npm publish", .approval),
            ("Codex wants to edit Sources/App.swift", .approval),
            ("Approval requested by docs", .approval),
            ("Question requested: Choose deployment target", .decision),
            ("Questions requested: 2", .decision),
            ("Plan mode prompt: Implement this plan?", .approval),
        ]

        for testCase in cases {
            XCTAssertTrue(
                AgentInteractionClassifier.requiresHumanInput(message: testCase.message),
                "Expected Codex attention message to require human input: \(testCase.message)"
            )
            XCTAssertEqual(
                AgentInteractionClassifier.interactionKind(forWaitingMessage: testCase.message),
                testCase.kind,
                "Expected Codex attention message to infer the right interaction kind: \(testCase.message)"
            )
        }
    }

    func test_agent_interaction_classifier_recognizes_natural_language_question_prompts() {
        let decisionMessage = "What should I ask you about?\n[Code] [Product] [Random]"
        XCTAssertTrue(AgentInteractionClassifier.requiresHumanInput(message: decisionMessage))
        XCTAssertEqual(
            AgentInteractionClassifier.interactionKind(forWaitingMessage: decisionMessage),
            .decision
        )

        let questionMessage = "What should Codex do next?"
        XCTAssertTrue(AgentInteractionClassifier.requiresHumanInput(message: questionMessage))
        XCTAssertEqual(
            AgentInteractionClassifier.interactionKind(forWaitingMessage: questionMessage),
            .question
        )
    }

    func test_agent_interaction_classifier_recognizes_gemini_action_required_as_approval() {
        let message = "Action required"

        XCTAssertTrue(AgentInteractionClassifier.requiresHumanInput(message: message))
        XCTAssertEqual(
            AgentInteractionClassifier.interactionKind(forWaitingMessage: message),
            .approval
        )
    }

    func test_agent_interaction_classifier_prefers_specific_action_required_copy_over_generic_approval() {
        XCTAssertEqual(
            AgentInteractionClassifier.preferredWaitingMessage(
                existing: "Gemini needs your approval",
                candidate: "Action required: Allow WriteFile on project.yml?"
            ),
            "Action required: Allow WriteFile on project.yml?"
        )
    }

    func test_agent_tool_keeps_copilot_metadata_unrecognized_without_explicit_hook_payloads() {
        XCTAssertEqual(AgentTool.resolve(named: "copilot"), .copilot)
        XCTAssertNil(AgentTool.resolveKnown(named: "copilot"))
    }

    func test_agent_tool_recognizes_amp_only_as_leading_token() {
        XCTAssertEqual(AgentTool.resolve(named: "amp"), .amp)
        XCTAssertEqual(AgentTool.resolve(named: "amp - Greeting"), .amp)
        XCTAssertEqual(AgentTool.resolveKnown(named: "amp - Greeting"), .amp)
        XCTAssertEqual(AgentTool.resolve(named: "feature/amp"), .custom("feature/amp"))
        XCTAssertNil(AgentTool.resolveKnown(named: "/Users/peter/Development/worktrees/feature/amp"))
    }

    func test_agent_tool_recognizes_gemini_for_explicit_and_known_tool_resolution() {
        XCTAssertEqual(AgentTool.resolve(named: "gemini"), .gemini)
        XCTAssertEqual(AgentTool.resolve(named: "Gemini CLI"), .gemini)
        XCTAssertEqual(AgentTool.resolveKnown(named: "Gemini"), .gemini)
    }

    func test_agent_tool_recognizes_kimi_for_explicit_and_known_tool_resolution() {
        XCTAssertEqual(AgentTool.resolve(named: "kimi"), .kimi)
        XCTAssertEqual(AgentTool.resolve(named: "kimi-cli"), .kimi)
        XCTAssertEqual(AgentTool.resolve(named: "Kimi CLI"), .kimi)
        XCTAssertEqual(AgentTool.resolveKnown(named: "Kimi"), .kimi)
    }

    func test_agent_tool_recognizes_agy_for_explicit_and_known_tool_resolution() {
        XCTAssertEqual(AgentTool.resolve(named: "agy"), .agy)
        XCTAssertEqual(AgentTool.resolve(named: "Antigravity"), .agy)
        XCTAssertEqual(AgentTool.resolveKnown(named: "agy"), .agy)
        XCTAssertEqual(AgentTool.resolveKnown(named: "Antigravity"), .agy)
    }

    func test_agent_tool_recognizer_infers_codex_from_explicit_attention_title() {
        XCTAssertEqual(
            AgentToolRecognizer.recognize(metadata: TerminalMetadata(
                title: "[ ! ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )),
            .codex
        )
        XCTAssertNil(
            AgentToolRecognizer.recognize(metadata: TerminalMetadata(
                title: "Waiting for build",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            ))
        )
    }

    func test_agent_tool_recognizes_cursor() {
        XCTAssertEqual(AgentTool.resolve(named: "cursor"), .cursor)
        XCTAssertEqual(AgentTool.resolve(named: "Cursor Agent"), .cursor)
        XCTAssertNil(AgentTool.resolveKnown(named: "Cursor Agent"))
    }

    func test_agent_tool_recognizes_droid_for_explicit_and_known_tool_resolution() {
        XCTAssertEqual(AgentTool.resolve(named: "droid"), .droid)
        XCTAssertEqual(AgentTool.resolve(named: "Droid CLI"), .droid)
        XCTAssertEqual(AgentTool.resolveKnown(named: "Droid"), .droid)
    }

    func test_agent_tool_recognizes_pi_and_its_titlebar_variants() {
        XCTAssertEqual(AgentTool.resolve(named: "pi"), .pi)
        XCTAssertEqual(AgentTool.resolve(named: "Pi"), .pi)
        XCTAssertEqual(AgentTool.resolve(named: "π"), .pi)
        XCTAssertEqual(AgentTool.resolve(named: "π - myproject"), .pi)
        XCTAssertEqual(AgentTool.resolve(named: "⠋ π - myproject"), .pi)
        XCTAssertEqual(AgentTool.resolve(named: "pi - myproject"), .pi)
        XCTAssertEqual(AgentTool.resolveKnown(named: "Pi"), .pi)
        XCTAssertEqual(AgentTool.resolveKnown(named: "⠋ π - myproject"), .pi)
    }

    func test_agent_tool_does_not_confuse_pi_with_unrelated_words() {
        // Must not swallow strings that merely start with the letters "pi".
        XCTAssertEqual(AgentTool.resolve(named: "pip"), .custom("pip"))
        XCTAssertEqual(AgentTool.resolve(named: "pizza"), .custom("pizza"))
        XCTAssertEqual(AgentTool.resolve(named: "apipie"), .custom("apipie"))
        XCTAssertNil(AgentTool.resolveKnown(named: "pip"))
        XCTAssertNil(AgentTool.resolveKnown(named: "pizza"))
    }

    func test_agent_tool_does_not_match_pi_inside_dotted_tokens() {
        // Tokens like "pi.py" share a prefix with "pi" but aren't pi. The
        // matcher splits on whitespace and compares tokens exactly, so
        // "python pi.py" stays as a custom title.
        XCTAssertEqual(
            AgentTool.resolve(named: "python pi.py"),
            .custom("python pi.py")
        )
        XCTAssertNil(AgentTool.resolveKnown(named: "python pi.py"))
    }

    func test_agent_tool_prefers_copilot_and_opencode_over_pi_substring_match() {
        XCTAssertEqual(AgentTool.resolve(named: "copilot"), .copilot)
        XCTAssertEqual(AgentTool.resolve(named: "opencode"), .openCode)
    }

    func test_pi_passthrough_list_matches_pi_mono_subcommands_snapshot() throws {
        // Snapshot of `pi --help` verified 2026-04-19 against pi-mono's
        // packages/coding-agent/src/cli.ts. Purpose: make intentional drift
        // deliberate — if a maintainer adds/removes an item on one side,
        // this test nudges them to update the other.
        //
        // AgentToolLauncher lives in the ZenttyCLI target which tests don't
        // import, so we read the source file directly (same pattern as
        // test_pi_wrapper_delegates_via_zentty_launch).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherPath = repoRoot
            .appendingPathComponent("ZenttyCLI/AgentToolLauncher.swift")
            .path
        let source = try String(contentsOfFile: launcherPath, encoding: .utf8)

        for subcommand in ["install", "remove", "uninstall", "update", "list", "config"] {
            XCTAssertTrue(
                source.contains("\"\(subcommand)\""),
                "piPassthroughSubcommands should contain \(subcommand)"
            )
        }
        for flag in ["--help", "-h", "--version", "-v", "--list-models", "--export"] {
            XCTAssertTrue(
                source.contains("\"\(flag)\""),
                "piEarlyExitFlags should contain \(flag)"
            )
        }
    }

    func test_kimi_passthrough_list_matches_kimi_cli_help_snapshot() throws {
        // Snapshot of `kimi --help` verified 2026-04-20 against the locally
        // installed Kimi CLI. These subcommands and early-exit flags should
        // bypass Zentty's overlay/bootstrap path.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherPath = repoRoot
            .appendingPathComponent("ZenttyCLI/AgentToolLauncher.swift")
            .path
        let source = try String(contentsOfFile: launcherPath, encoding: .utf8)

        for subcommand in ["login", "logout", "term", "acp", "info", "export", "mcp", "plugin", "vis", "web"] {
            XCTAssertTrue(
                source.contains("\"\(subcommand)\""),
                "kimiPassthroughSubcommands should contain \(subcommand)"
            )
        }
        for flag in ["--help", "-h", "--version", "-V"] {
            XCTAssertTrue(
                source.contains("\"\(flag)\""),
                "kimiEarlyExitFlags should contain \(flag)"
            )
        }
    }

    func test_amp_passthrough_list_matches_management_commands_snapshot() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherPath = repoRoot
            .appendingPathComponent("ZenttyCLI/AgentToolLauncher.swift")
            .path
        let source = try String(contentsOfFile: launcherPath, encoding: .utf8)

        for subcommand in ["login", "logout", "mcp", "permission", "permissions", "review", "skill", "skills", "tool", "tools", "update", "up", "usage", "version"] {
            XCTAssertTrue(
                source.contains("\"\(subcommand)\""),
                "ampPassthroughSubcommands should contain \(subcommand)"
            )
        }
        for flag in ["--help", "-h", "--version", "-V", "--jetbrains"] {
            XCTAssertTrue(
                source.contains("\"\(flag)\""),
                "ampEarlyExitFlags should contain \(flag)"
            )
        }
    }

    func test_agent_tool_launcher_forwards_opencode_tui_and_xdg_environment() throws {
        // AgentToolLauncher lives in the ZenttyCLI target which tests don't
        // import, so read the source file directly to protect the bootstrap
        // environment forwarding contract.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherPath = repoRoot
            .appendingPathComponent("ZenttyCLI/AgentToolLauncher.swift")
            .path
        let source = try String(contentsOfFile: launcherPath, encoding: .utf8)

        for key in ["XDG_CONFIG_HOME", "XDG_STATE_HOME", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG"] {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "AgentToolLauncher should forward \(key) into the bootstrap request"
            )
        }
    }

    func test_agent_tool_launcher_forwards_amp_routing_environment() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherPath = repoRoot
            .appendingPathComponent("ZenttyCLI/AgentToolLauncher.swift")
            .path
        let source = try String(contentsOfFile: launcherPath, encoding: .utf8)

        for key in ["AMP_SETTINGS_FILE", "ZENTTY_AMP_HOOKS_DISABLED", "ZENTTY_AMP_PID"] {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "AgentToolLauncher should forward \(key) for AMP bootstrap and plugin events"
            )
        }
    }

    func test_agent_status_helper_returns_nil_when_resource_directories_are_missing() throws {
        let bundle = try makeTemporaryBundle(named: "MissingResources")

        XCTAssertNil(AgentStatusHelper.wrapperDirectoryPaths(in: bundle))
        XCTAssertNil(AgentStatusHelper.wrapperSupportDirectoryPath(in: bundle))
        XCTAssertNil(AgentStatusHelper.shellIntegrationDirectoryPath(in: bundle))
    }

    func test_agent_status_helper_requires_expected_wrapper_resource_layout() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "CompleteResources")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        for (dirName, fileName) in wrapperLayoutPairs {
            let wrapperDirectoryURL = binURL.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let fileURL = wrapperDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedWrapperURL = sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
        FileManager.default.createFile(atPath: sharedWrapperURL.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapperURL.path)
        let bundledCLIURL = sharedURL.appendingPathComponent("zentty", isDirectory: false)
        FileManager.default.createFile(atPath: bundledCLIURL.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLIURL.path)

        let shellURL = resourcesURL.appendingPathComponent("shell-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: shellURL, withIntermediateDirectories: true)
        for name in [".zshenv", "zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let fileURL = shellURL.appendingPathComponent(name, isDirectory: false)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("# test\n".utf8))
        }

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        XCTAssertEqual(
            AgentStatusHelper.wrapperDirectoryPaths(in: bundle),
            ["amp", "claude", "codex", "copilot", "cursor", "droid", "gemini", "grok", "kimi", "opencode", "pi", "agy"].map {
                binURL.appendingPathComponent($0, isDirectory: true).path
            }
        )
        XCTAssertEqual(AgentStatusHelper.wrapperSupportDirectoryPath(in: bundle), sharedURL.path)
        XCTAssertEqual(AgentStatusHelper.shellIntegrationDirectoryPath(in: bundle), shellURL.path)
    }

    func test_agent_status_helper_requires_executable_wrapper_files() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "NonExecutableWrappers")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        for (dirName, fileName) in wrapperLayoutPairs {
            let wrapperDirectoryURL = binURL.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let fileURL = wrapperDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try "#!/bin/sh\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(
            to: sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let shellURL = resourcesURL.appendingPathComponent("shell-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: shellURL, withIntermediateDirectories: true)
        for name in [".zshenv", "zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let fileURL = shellURL.appendingPathComponent(name, isDirectory: false)
            try "# test\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        XCTAssertNil(AgentStatusHelper.wrapperDirectoryPaths(in: bundle))
        XCTAssertNil(AgentStatusHelper.wrapperSupportDirectoryPath(in: bundle))
        XCTAssertEqual(AgentStatusHelper.shellIntegrationDirectoryPath(in: bundle), shellURL.path)
    }

    func test_agent_status_helper_requires_bundled_cli_binary_in_shared_support_directory() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "MissingBundledCLI")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        for (dirName, fileName) in wrapperLayoutPairs {
            let wrapperDirectoryURL = binURL.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let wrapperURL = wrapperDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try "#!/bin/sh\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        }

        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedWrapperURL = sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
        try "#!/bin/sh\n".write(to: sharedWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapperURL.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        XCTAssertNil(AgentStatusHelper.wrapperSupportDirectoryPath(in: bundle))
        XCTAssertNil(AgentStatusHelper.cliPath(in: bundle))

        let bundledCLIURL = sharedURL.appendingPathComponent("zentty", isDirectory: false)
        try "#!/bin/sh\n".write(to: bundledCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLIURL.path)

        XCTAssertEqual(AgentStatusHelper.wrapperSupportDirectoryPath(in: bundle), sharedURL.path)
        XCTAssertEqual(AgentStatusHelper.cliPath(in: bundle), bundledCLIURL.path)
    }

    func test_agent_status_helper_enables_only_wrappers_with_real_binaries_on_path() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "EnabledWrappers")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        for (dirName, fileName) in wrapperLayoutPairs {
            let wrapperDirectoryURL = binURL.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let wrapperURL = wrapperDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try "#!/bin/sh\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        }

        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedWrapperURL = sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
        try "#!/bin/sh\n".write(to: sharedWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapperURL.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let realBinURL = try makeTemporaryDirectory(named: "enabled-wrappers-real-bin")
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        // Real binaries Zentty's wrappers expect on PATH. Note cursor resolves to `cursor-agent`,
        // not `cursor` (which is the Cursor IDE launcher).
        for name in ["amp", "claude", "cursor-agent", "gemini", "kimi", "opencode", "agy"] {
            let fileURL = realBinURL.appendingPathComponent(name, isDirectory: false)
            try "#!/bin/sh\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }

        let environment = [
            "PATH": [
                binURL.appendingPathComponent("amp", isDirectory: true).path,
                binURL.appendingPathComponent("claude", isDirectory: true).path,
                binURL.appendingPathComponent("codex", isDirectory: true).path,
                binURL.appendingPathComponent("copilot", isDirectory: true).path,
                binURL.appendingPathComponent("cursor", isDirectory: true).path,
                binURL.appendingPathComponent("gemini", isDirectory: true).path,
                binURL.appendingPathComponent("kimi", isDirectory: true).path,
                binURL.appendingPathComponent("opencode", isDirectory: true).path,
                binURL.appendingPathComponent("pi", isDirectory: true).path,
                binURL.appendingPathComponent("agy", isDirectory: true).path,
                sharedURL.path,
                realBinURL.path,
                "/usr/bin",
                "/bin",
            ].joined(separator: ":")
        ]

        XCTAssertEqual(
            AgentStatusHelper.enabledWrapperDirectoryPaths(in: bundle, processEnvironment: environment),
            [
                binURL.appendingPathComponent("amp", isDirectory: true).path,
                binURL.appendingPathComponent("claude", isDirectory: true).path,
                binURL.appendingPathComponent("cursor", isDirectory: true).path,
                binURL.appendingPathComponent("gemini", isDirectory: true).path,
                binURL.appendingPathComponent("kimi", isDirectory: true).path,
                binURL.appendingPathComponent("opencode", isDirectory: true).path,
                binURL.appendingPathComponent("agy", isDirectory: true).path,
            ]
        )
    }

    func test_agent_status_helper_skips_cursor_wrapper_when_only_cursor_ide_launcher_is_on_path() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "CursorIDEOnlyPath")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        for (dirName, fileName) in wrapperLayoutPairs {
            let wrapperDirectoryURL = binURL.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let wrapperURL = wrapperDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try "#!/bin/sh\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        }
        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedWrapperURL = sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
        try "#!/bin/sh\n".write(to: sharedWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapperURL.path)

        let realBinURL = try makeTemporaryDirectory(named: "cursor-ide-only-real-bin")
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        // Only `cursor` (the IDE launcher) exists — `cursor-agent` (the CLI) is absent.
        let cursorIDE = realBinURL.appendingPathComponent("cursor", isDirectory: false)
        try "#!/bin/sh\n".write(to: cursorIDE, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursorIDE.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let environment = [
            "PATH": [realBinURL.path, "/usr/bin", "/bin"].joined(separator: ":"),
        ]

        XCTAssertFalse(
            AgentStatusHelper.enabledWrapperDirectoryPaths(in: bundle, processEnvironment: environment)
                .contains(binURL.appendingPathComponent("cursor", isDirectory: true).path),
            "cursor wrapper should only activate when cursor-agent is on PATH, not the Cursor IDE launcher"
        )
    }

    func test_agent_status_helper_enables_kimi_wrapper_when_only_kimi_cli_is_on_path() throws {
        let bundleRoot = try makeTemporaryBundleRoot(named: "KimiCliOnlyPath")
        let resourcesURL = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        for (dirName, fileName) in wrapperLayoutPairs {
            let wrapperDirectoryURL = binURL.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let wrapperURL = wrapperDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try "#!/bin/sh\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        }
        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedWrapperURL = sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
        try "#!/bin/sh\n".write(to: sharedWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapperURL.path)

        let realBinURL = try makeTemporaryDirectory(named: "kimi-cli-only-real-bin")
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        // Only `kimi-cli` exists — `kimi` is absent.
        let kimiCli = realBinURL.appendingPathComponent("kimi-cli", isDirectory: false)
        try "#!/bin/sh\n".write(to: kimiCli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kimiCli.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let environment = [
            "PATH": [realBinURL.path, "/usr/bin", "/bin"].joined(separator: ":"),
        ]

        XCTAssertTrue(
            AgentStatusHelper.enabledWrapperDirectoryPaths(in: bundle, processEnvironment: environment)
                .contains(binURL.appendingPathComponent("kimi", isDirectory: true).path),
            "kimi wrapper should activate when kimi-cli is on PATH"
        )
    }

    func test_repository_shell_integrations_emit_guarded_git_branch_signal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shellIntegrationDirectory = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)

        for filename in ["zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let scriptURL = shellIntegrationDirectory.appendingPathComponent(filename, isDirectory: false)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)

            XCTAssertTrue(script.contains("git rev-parse --git-dir >/dev/null 2>&1"), filename)
            XCTAssertTrue(script.contains("git branch --show-current"), filename)
            XCTAssertTrue(script.contains("--git-branch"), filename)
            XCTAssertTrue(script.contains("ipc agent-signal"), filename)
        }
    }

    func test_repository_shell_integrations_dedupe_shell_activity_signal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shellIntegrationDirectory = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)

        for filename in ["zentty-zsh-integration.zsh", "zentty-bash-integration.bash"] {
            let scriptURL = shellIntegrationDirectory.appendingPathComponent(filename, isDirectory: false)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)

            XCTAssertTrue(script.contains("_zentty_shell_activity_last"), filename)
            XCTAssertTrue(script.contains("[[ \"$_zentty_shell_activity_last\" == \"$key\" ]]"), filename)
        }
    }

    func test_repository_shell_integrations_tag_codex_shell_activity() throws {
        for shell in [ShellIntegrationTestShell.zsh, .bash] {
            let signals = try runShellIntegration(
                shell: shell,
                command: shell == .zsh
                    ? #"_zentty_preexec "codex""#
                    : #"codex 2>/dev/null || true"#
            )

            XCTAssertTrue(
                signals.contains(where: { $0.contains("shell-state running --tool Codex") }),
                "Expected \(shell) integration to tag codex shell activity, got: \(signals)"
            )
        }
    }

    func test_repository_shell_integrations_tag_amp_shell_activity() throws {
        for shell in [ShellIntegrationTestShell.zsh, .bash] {
            let signals = try runShellIntegration(
                shell: shell,
                command: shell == .zsh
                    ? #"_zentty_preexec "amp \"summarize this\"""#
                    : #"amp "summarize this" 2>/dev/null || true"#
            )

            XCTAssertTrue(
                signals.contains(where: { $0.contains("shell-state running --tool Amp") }),
                "Expected \(shell) integration to tag amp shell activity, got: \(signals)"
            )
        }
    }

    func test_repository_shell_integrations_include_running_command() throws {
        for shell in [ShellIntegrationTestShell.zsh, .bash] {
            let commandText = "pnpm start:staging -- --host 127.0.0.1"
            let signals = try runShellIntegration(
                shell: shell,
                command: shell == .zsh
                    ? #"_zentty_preexec "pnpm start:staging -- --host 127.0.0.1""#
                    : #"pnpm start:staging -- --host 127.0.0.1 2>/dev/null || true"#
            )

            XCTAssertTrue(
                signals.contains(where: { signal in
                    signal.contains("shell-state running")
                        && signal.contains("--command \(commandText)")
                }),
                "Expected \(shell) integration to include the full command, got: \(signals)"
            )
        }
    }

    func test_zsh_shell_integration_does_not_write_terminal_sequences_to_stdout_or_stderr_when_loaded() throws {
        let result = try runShellIntegrationCommand(shell: .zsh, command: ":", extraEnvironment: ["TTY": "/dev/null"])

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }

    func test_bash_shell_integration_does_not_write_terminal_sequences_to_stdout_or_stderr_when_loaded() throws {
        let result = try runShellIntegrationCommand(shell: .bash, command: ":", extraEnvironment: ["TTY": "/dev/null"])

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }

    func test_zsh_shell_integration_emits_updated_pane_context_before_next_command_after_cd() throws {
        let targetDirectory = try makeTemporaryDirectory(named: "shell-zsh-target")

        let signals = try runShellIntegration(
            shell: .zsh,
            command: "cd \(shellQuoted(targetDirectory.path)) && :"
        )

        XCTAssertTrue(
            signals.contains(where: { $0.contains("pane-context local --path \(targetDirectory.path)") }),
            "Expected zsh integration to emit pane context for \(targetDirectory.path), got: \(signals)"
        )
    }

    func test_bash_shell_integration_emits_updated_pane_context_before_next_command_after_cd() throws {
        let targetDirectory = try makeTemporaryDirectory(named: "shell-bash-target")

        let signals = try runShellIntegration(
            shell: .bash,
            command: "cd \(shellQuoted(targetDirectory.path)) && :"
        )

        XCTAssertTrue(
            signals.contains(where: { $0.contains("pane-context local --path \(targetDirectory.path)") }),
            "Expected bash integration to emit pane context for \(targetDirectory.path), got: \(signals)"
        )
    }

    func test_zsh_shell_integration_enables_wrapper_after_real_binary_appears_on_path() throws {
        let wrapperRoot = try makeTemporaryDirectory(named: "shell-zsh-wrapper-root")
        let wrapperDir = wrapperRoot.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        let wrapperURL = wrapperDir.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        let realBinDir = try makeTemporaryDirectory(named: "shell-zsh-real-bin")
        let realBinaryURL = realBinDir.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realBinaryURL.path)

        let result = try runShellIntegrationCommand(
            shell: .zsh,
            command: """
            PATH="/usr/bin:/bin"
            export PATH
            _zentty_ensure_wrapper_path
            PATH="${PATH}:\(realBinDir.path)"
            export PATH
            _zentty_ensure_wrapper_path
            command -v codex
            """,
            extraEnvironment: [
                "ZENTTY_ALL_WRAPPER_BIN_DIRS": wrapperDir.path,
            ]
        )

        XCTAssertEqual(lastAbsolutePath(in: result.stdout), wrapperURL.path)
    }

    func test_bash_shell_integration_enables_wrapper_after_real_binary_appears_on_path() throws {
        let wrapperRoot = try makeTemporaryDirectory(named: "shell-bash-wrapper-root")
        let wrapperDir = wrapperRoot.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        let wrapperURL = wrapperDir.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        let realBinDir = try makeTemporaryDirectory(named: "shell-bash-real-bin")
        let realBinaryURL = realBinDir.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realBinaryURL.path)

        let result = try runShellIntegrationCommand(
            shell: .bash,
            command: """
            PATH="/usr/bin:/bin"
            export PATH
            _zentty_ensure_wrapper_path
            PATH="${PATH}:\(realBinDir.path)"
            export PATH
            _zentty_ensure_wrapper_path
            command -v codex
            """,
            extraEnvironment: [
                "ZENTTY_ALL_WRAPPER_BIN_DIRS": wrapperDir.path,
            ]
        )

        XCTAssertEqual(lastAbsolutePath(in: result.stdout), wrapperURL.path)
    }

    func test_shell_integration_does_not_enable_amp_wrapper_when_wrapper_executable_is_missing() throws {
        for shell in [ShellIntegrationTestShell.zsh, .bash] {
            let wrapperRoot = try makeTemporaryDirectory(named: "shell-\(shell)-missing-amp-wrapper-root")
            let wrapperDir = wrapperRoot.appendingPathComponent("amp", isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)

            let realBinDir = try makeTemporaryDirectory(named: "shell-\(shell)-real-amp")
            let realBinaryURL = realBinDir.appendingPathComponent("amp", isDirectory: false)
            try "#!/bin/sh\nexit 0\n".write(to: realBinaryURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realBinaryURL.path)

            let result = try runShellIntegrationCommand(
                shell: shell,
                command: """
                PATH="\(realBinDir.path):/usr/bin:/bin"
                export PATH
                _zentty_ensure_wrapper_path
                printf 'active=<%s>\\n' "${ZENTTY_WRAPPER_BIN_DIRS-}"
                command -v amp
                """,
                extraEnvironment: [
                    "ZENTTY_ALL_WRAPPER_BIN_DIRS": wrapperDir.path,
                ]
            )

            XCTAssertTrue(result.stdout.contains("active=<>"), "\(shell) should not export a missing amp wrapper: \(result.stdout)")
            XCTAssertEqual(lastAbsolutePath(in: result.stdout), realBinaryURL.path)
        }
    }

    func test_zsh_shell_integration_prefers_tmux_shim_when_agent_teams_enabled() throws {
        let shimDir = try makeTemporaryDirectory(named: "shell-zsh-tmux-shim")
        let shimURL = shimDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        let realBinDir = try makeTemporaryDirectory(named: "shell-zsh-real-tmux")
        let realURL = realBinDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realURL.path)

        let result = try runShellIntegrationCommand(
            shell: .zsh,
            command: """
            PATH="\(realBinDir.path):/usr/bin:/bin"
            export PATH
            _zentty_ensure_wrapper_path
            command -v tmux
            """,
            extraEnvironment: [
                "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
                "ZENTTY_TMUX_SHIM_DIR": shimDir.path,
            ]
        )

        XCTAssertEqual(lastAbsolutePath(in: result.stdout), shimURL.path)
    }

    func test_bash_shell_integration_prefers_tmux_shim_when_agent_teams_enabled() throws {
        let shimDir = try makeTemporaryDirectory(named: "shell-bash-tmux-shim")
        let shimURL = shimDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        let realBinDir = try makeTemporaryDirectory(named: "shell-bash-real-tmux")
        let realURL = realBinDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realURL.path)

        let result = try runShellIntegrationCommand(
            shell: .bash,
            command: """
            PATH="\(realBinDir.path):/usr/bin:/bin"
            export PATH
            _zentty_ensure_wrapper_path
            command -v tmux
            """,
            extraEnvironment: [
                "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
                "ZENTTY_TMUX_SHIM_DIR": shimDir.path,
            ]
        )

        XCTAssertEqual(lastAbsolutePath(in: result.stdout), shimURL.path)
    }

    func test_zsh_shell_integration_leaves_real_tmux_first_without_agent_teams() throws {
        let shimDir = try makeTemporaryDirectory(named: "shell-zsh-inactive-tmux-shim")
        let shimURL = shimDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        let realBinDir = try makeTemporaryDirectory(named: "shell-zsh-inactive-real-tmux")
        let realURL = realBinDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realURL.path)

        let result = try runShellIntegrationCommand(
            shell: .zsh,
            command: """
            PATH="\(realBinDir.path):\(shimDir.path):/usr/bin:/bin"
            export PATH
            _zentty_ensure_wrapper_path
            command -v tmux
            """,
            extraEnvironment: [
                "ZENTTY_TMUX_SHIM_DIR": shimDir.path,
            ]
        )

        XCTAssertEqual(lastAbsolutePath(in: result.stdout), realURL.path)
    }

    func test_bash_shell_integration_leaves_real_tmux_first_without_agent_teams() throws {
        let shimDir = try makeTemporaryDirectory(named: "shell-bash-inactive-tmux-shim")
        let shimURL = shimDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        let realBinDir = try makeTemporaryDirectory(named: "shell-bash-inactive-real-tmux")
        let realURL = realBinDir.appendingPathComponent("tmux", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realURL.path)

        let result = try runShellIntegrationCommand(
            shell: .bash,
            command: """
            PATH="\(realBinDir.path):\(shimDir.path):/usr/bin:/bin"
            export PATH
            _zentty_ensure_wrapper_path
            command -v tmux
            """,
            extraEnvironment: [
                "ZENTTY_TMUX_SHIM_DIR": shimDir.path,
            ]
        )

        XCTAssertEqual(lastAbsolutePath(in: result.stdout), realURL.path)
    }

    func test_repository_codex_wrapper_delegates_to_launch_cli() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codexWrapperURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)

        let script = try String(contentsOf: codexWrapperURL, encoding: .utf8)
        XCTAssertTrue(script.contains("ZENTTY_AGENT_TOOL=\"codex\""))
        XCTAssertTrue(script.contains("zentty-agent-wrapper"))
        XCTAssertFalse(script.contains("python3"))
    }

    func test_repository_amp_wrapper_delegates_to_launch_cli() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wrapperURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: false)

        let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)

        XCTAssertTrue(wrapper.contains("ZENTTY_AGENT_TOOL=\"amp\""))
        XCTAssertTrue(wrapper.contains("zentty-agent-wrapper"))
        XCTAssertFalse(wrapper.contains("ZENTTY_AGENT_BIN"))
    }

    func test_copy_agent_resources_build_script_syncs_amp_support_directory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFileURL = repositoryRoot.appendingPathComponent("Zentty.xcodeproj/project.pbxproj", isDirectory: false)

        let project = try String(contentsOf: projectFileURL, encoding: .utf8)

        XCTAssertTrue(project.contains("${RESOURCES_DST}/amp/plugins"))
        XCTAssertTrue(project.contains("${RESOURCES_SRC}/amp/"))
        XCTAssertTrue(project.contains("${RESOURCES_DST}/amp/"))
    }

    func test_repository_amp_plugin_guards_routing_and_sanitizes_ipc_environment() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-amp-zentty.ts", isDirectory: false)

        let plugin = try String(contentsOf: pluginURL, encoding: .utf8)

        XCTAssertTrue(plugin.contains("ZENTTY_INSTANCE_SOCKET"))
        XCTAssertTrue(plugin.contains("ZENTTY_WORKLANE_ID"))
        XCTAssertTrue(plugin.contains("ZENTTY_PANE_ID"))
        XCTAssertTrue(plugin.contains("if (!hasZenttyRoutingEnvironment()) return"))
        XCTAssertTrue(plugin.contains("delete env.AMP_API_KEY"))
        XCTAssertTrue(plugin.contains("ampEvent.status !== 'done'"))
    }

    func test_copy_agent_resources_build_script_syncs_opencode_support_directory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFileURL = repositoryRoot.appendingPathComponent("Zentty.xcodeproj/project.pbxproj", isDirectory: false)

        let project = try String(contentsOf: projectFileURL, encoding: .utf8)

        XCTAssertTrue(project.contains("${RESOURCES_DST}/opencode/plugins"))
        XCTAssertTrue(project.contains("${RESOURCES_SRC}/opencode/"))
        XCTAssertTrue(project.contains("${RESOURCES_DST}/opencode/"))
    }

    func test_repository_opencode_plugin_exists_and_forwards_canonical_agent_events() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)

        let plugin = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(plugin.contains("process.env.ZENTTY_CLI_BIN"))
        XCTAssertTrue(plugin.contains("[resolvedCliBin, \"ipc\", \"agent-event\"]"))
        XCTAssertTrue(plugin.contains("event: \"task.progress\""))
        XCTAssertTrue(plugin.contains("stdio: [\"pipe\", \"ignore\", \"ignore\"]"))
    }

    func test_repository_opencode_plugin_maps_status_aliases_and_preserves_idle_progress() throws {
        guard let bunPath = try resolvedExecutable(named: "bun") else {
            throw XCTSkip("bun is not available")
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)
        let scratchDirectory = try makeTemporaryDirectory(named: "opencode-plugin-harness")
        let fakeCLIURL = scratchDirectory.appendingPathComponent("zentty", isDirectory: false)
        let captureURL = scratchDirectory.appendingPathComponent("canonical-events.jsonl", isDirectory: false)
        let eventsURL = scratchDirectory.appendingPathComponent("events.json", isDirectory: false)
        let harnessURL = scratchDirectory.appendingPathComponent("harness.mjs", isDirectory: false)

        try """
        #!/bin/sh
        cat >> "$ZENTTY_CAPTURE_LOG"
        printf '\\n' >> "$ZENTTY_CAPTURE_LOG"
        """.write(to: fakeCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLIURL.path)

        let events: [[String: Any]] = [
            [
                "type": "session.status",
                "properties": [
                    "sessionID": "session-1",
                    "cwd": "/tmp/project",
                    "status": ["type": "active"],
                ],
            ],
            [
                "type": "session.status",
                "properties": [
                    "sessionID": "session-1",
                    "cwd": "/tmp/project",
                    "status": "running",
                ],
            ],
            [
                "type": "todo.updated",
                "properties": [
                    "sessionID": "session-1",
                    "cwd": "/tmp/project",
                    "todos": [
                        ["content": "Inspect", "status": "completed"],
                        ["content": "Patch", "status": "in_progress"],
                        ["content": "Verify", "status": "pending"],
                    ],
                ],
            ],
            [
                "type": "session.idle",
                "properties": [
                    "sessionID": "session-1",
                    "cwd": "/tmp/project",
                ],
            ],
            [
                "type": "session.idle",
                "properties": [
                    "sessionID": "session-1",
                    "cwd": "/tmp/project",
                ],
            ],
        ]
        let eventsData = try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted])
        try eventsData.write(to: eventsURL)

        try """
        const { ZenttyOpenCodePlugin } = await import(process.env.ZENTTY_PLUGIN_URL)
        const events = await Bun.file(process.env.ZENTTY_EVENTS_JSON).json()
        const plugin = await ZenttyOpenCodePlugin({ directory: "/tmp/project" })
        for (const event of events) {
          await plugin.event({ event })
        }
        """.write(to: harnessURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bunPath)
        process.arguments = [harnessURL.path]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "ZENTTY_CLI_BIN": fakeCLIURL.path,
            "ZENTTY_CAPTURE_LOG": captureURL.path,
            "ZENTTY_EVENTS_JSON": eventsURL.path,
            "ZENTTY_INSTANCE_SOCKET": scratchDirectory.appendingPathComponent("zentty.sock").path,
            "ZENTTY_PANE_ID": "pane-under-test",
            "ZENTTY_PANE_TOKEN": "pane-token-under-test",
            "ZENTTY_PLUGIN_URL": pluginURL.absoluteString,
            "ZENTTY_WORKLANE_ID": "worklane-under-test",
        ]

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("OpenCode plugin harness failed: \(error)")
            return
        }

        let canonicalEvents = try String(contentsOf: captureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }

        XCTAssertEqual(canonicalEvents.compactMap { $0["event"] as? String }, [
            "agent.running",
            "agent.running",
            "task.progress",
            "agent.idle",
            "agent.idle",
        ])
        let idleWithProgress = try XCTUnwrap(canonicalEvents[3]["progress"] as? [String: Any])
        XCTAssertEqual(idleWithProgress["done"] as? Int, 1)
        XCTAssertEqual(idleWithProgress["total"] as? Int, 3)
        XCTAssertNil(canonicalEvents[4]["progress"])
    }

    func test_repository_claude_wrapper_delegates_to_launch_cli() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wrapperURL = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)

        let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)

        XCTAssertTrue(wrapper.contains("ZENTTY_AGENT_TOOL=\"claude\""))
        XCTAssertTrue(wrapper.contains("zentty-agent-wrapper"))
    }

    func test_repository_codex_and_copilot_wrappers_delegate_to_internal_launch_cli() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let codexWrapper = try String(contentsOf: repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false), encoding: .utf8)
        XCTAssertTrue(codexWrapper.contains("zentty-agent-wrapper"))
        XCTAssertFalse(codexWrapper.contains("ZENTTY_AGENT_BIN"))

        let copilotWrapper = try String(contentsOf: repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("copilot", isDirectory: true)
            .appendingPathComponent("copilot", isDirectory: false), encoding: .utf8)
        XCTAssertTrue(copilotWrapper.contains("zentty-agent-wrapper"))
        XCTAssertFalse(copilotWrapper.contains("ZENTTY_AGENT_BIN"))

        let sharedWrapper = try String(contentsOf: repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent("zentty-agent-wrapper", isDirectory: false), encoding: .utf8)
        XCTAssertTrue(sharedWrapper.contains("launch \"$tool_basename\""))
        XCTAssertTrue(sharedWrapper.contains("ZENTTY_CLI_BIN"))
    }

    func test_repository_gemini_wrapper_delegates_to_internal_launch_cli() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let geminiWrapper = try String(contentsOf: repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("gemini", isDirectory: true)
            .appendingPathComponent("gemini", isDirectory: false), encoding: .utf8)
        XCTAssertTrue(geminiWrapper.contains("ZENTTY_AGENT_TOOL=\"gemini\""))
        XCTAssertTrue(geminiWrapper.contains("zentty-agent-wrapper"))
        XCTAssertFalse(geminiWrapper.contains("ZENTTY_AGENT_BIN"))
    }

    func test_repository_kimi_wrapper_delegates_to_internal_launch_cli() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for name in ["kimi", "kimi-cli"] {
            let kimiWrapper = try String(contentsOf: repositoryRoot
                .appendingPathComponent("ZenttyResources", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("kimi", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false), encoding: .utf8)
            XCTAssertTrue(kimiWrapper.contains("ZENTTY_AGENT_TOOL=\"kimi\""), name)
            XCTAssertTrue(kimiWrapper.contains("zentty-agent-wrapper"), name)
            XCTAssertFalse(kimiWrapper.contains("ZENTTY_AGENT_BIN"), name)
        }
    }

    func test_repository_cursor_wrapper_exposes_cursor_agent_and_agent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cursorDir = repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cursor", isDirectory: true)

        let cursorAgentScript = cursorDir.appendingPathComponent("cursor-agent", isDirectory: false)
        let wrapper = try String(contentsOf: cursorAgentScript, encoding: .utf8)
        XCTAssertTrue(wrapper.contains("ZENTTY_AGENT_TOOL=\"cursor\""))
        XCTAssertTrue(wrapper.contains("zentty-agent-wrapper"))

        let agentLink = cursorDir.appendingPathComponent("agent", isDirectory: false)
        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: agentLink.path)
        XCTAssertEqual(resolved, "cursor-agent", "agent should be a symlink to cursor-agent in the same dir")
    }

    func test_copy_agent_resources_build_script_marks_gemini_wrapper_executable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectURL = repositoryRoot.appendingPathComponent("project.yml", isDirectory: false)
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("-o -path \"*/gemini/gemini\""))
        XCTAssertTrue(project.contains("-o -path \"*/cursor/cursor-agent\""))
    }

    func test_copy_agent_resources_build_script_marks_kimi_wrapper_executable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectURL = repositoryRoot.appendingPathComponent("project.yml", isDirectory: false)
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("-o -path \"*/kimi/kimi\""))
        XCTAssertTrue(project.contains("-o -path \"*/kimi/kimi-cli\""))
        XCTAssertTrue(project.contains("-o -path \"*/shared/zentty-agent-wrapper\""))
    }

    func test_agent_ipc_bridge_converts_agent_signal_message_to_payload() throws {
        let message = AgentIPCMessage(
            subcommand: "agent-signal",
            arguments: [
                "lifecycle",
                "needs-input",
                "--tool", "Codex",
                "--text", "Approval requested: edit Sources/App.swift",
                "--interaction-kind", "approval",
                "--session-id", "session-1",
            ],
            standardInput: nil,
            environment: [
                "ZENTTY_WINDOW_ID": "window-main",
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ]
        )

        var posted: [AgentStatusPayload] = []
        _ = try AgentIPCBridge.handle(
            data: try JSONEncoder().encode(message),
            post: { posted.append($0) }
        )

        XCTAssertEqual(posted, [
            AgentStatusPayload(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "Approval requested: edit Sources/App.swift",
                interactionKind: .approval,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
        ])
    }

    func test_agent_signal_shell_state_parses_command_option() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty",
                "agent-signal",
                "shell-state",
                "running",
                "--command", "pnpm start:staging\nnpm run smoke",
            ],
            environment: [
                "ZENTTY_WINDOW_ID": "window-main",
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .shellState)
        XCTAssertEqual(command.payload.shellActivityState, .commandRunning)
        XCTAssertEqual(command.payload.shellCommand, "pnpm start:staging\nnpm run smoke")
    }

    func test_agent_ipc_request_round_trips_bootstrap_payload() throws {
        let request = AgentIPCRequest(
            id: "request-1",
            kind: .bootstrap,
            arguments: ["hello", "--verbose"],
            standardInput: nil,
            environment: [
                "ZENTTY_WINDOW_ID": "window-main",
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
                "ZENTTY_PANE_TOKEN": "pane-token",
            ],
            expectsResponse: true,
            tool: .codex
        )

        let decoded = try JSONDecoder().decode(
            AgentIPCRequest.self,
            from: try JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    func test_agent_ipc_response_round_trips_launch_plan_result() throws {
        let response = AgentIPCResponse(
            id: "request-1",
            ok: true,
            result: AgentIPCResponseResult(
                launchPlan: AgentLaunchPlan(
                    executablePath: "/usr/bin/codex",
                    arguments: ["exec", "hello"],
                    setEnvironment: [
                        "CODEX_HOME": "/tmp/zentty-codex-home",
                        "ZENTTY_AGENT_TOOL": "codex",
                    ],
                    unsetEnvironment: ["CLAUDECODE"],
                    preLaunchActions: [
                        AgentLaunchAction(
                            subcommand: "agent-event",
                            arguments: ["--adapter=opencode", "session-start"],
                            standardInput: #"{"version":1,"event":"session.start"}"#
                        ),
                    ]
                )
            ),
            error: nil
        )

        let decoded = try JSONDecoder().decode(
            AgentIPCResponse.self,
            from: try JSONEncoder().encode(response)
        )

        XCTAssertEqual(decoded, response)
    }

    func test_agent_ipc_bridge_handles_ipc_request_for_agent_signal() throws {
        let request = AgentIPCRequest(
            id: "request-1",
            kind: .ipc,
            arguments: [
                "lifecycle",
                "needs-input",
                "--tool", "Codex",
                "--text", "Approval requested: edit Sources/App.swift",
                "--interaction-kind", "approval",
                "--session-id", "session-1",
            ],
            standardInput: nil,
            environment: [
                "ZENTTY_WINDOW_ID": "window-main",
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ],
            expectsResponse: false,
            subcommand: "agent-signal"
        )

        var posted: [AgentStatusPayload] = []
        let response = try AgentIPCBridge.handle(
            request: request,
            post: { posted.append($0) }
        )

        XCTAssertNil(response)
        XCTAssertEqual(posted, [
            AgentStatusPayload(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main"),
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "Approval requested: edit Sources/App.swift",
                interactionKind: .approval,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            ),
        ])
    }

    func test_agent_ipc_bridge_forwards_agent_pid_environment_to_codex_adapter() throws {
        let message = AgentIPCMessage(
            subcommand: "agent-event",
            arguments: ["--adapter=codex", "session-start"],
            standardInput: #"{"session_id":"session-codex","cwd":"/tmp/project"}"#,
            environment: [
                "ZENTTY_WINDOW_ID": "window-main",
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
                "ZENTTY_CODEX_PID": "4242",
            ]
        )

        var posted: [AgentStatusPayload] = []
        _ = try AgentIPCBridge.handle(
            data: try JSONEncoder().encode(message),
            post: { posted.append($0) }
        )

        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[0].signalKind, .pid)
        XCTAssertEqual(posted[0].pid, 4242)
        XCTAssertEqual(posted[0].pidEvent, .attach)
        XCTAssertEqual(posted[0].toolName, "Codex")
        XCTAssertEqual(posted[0].sessionID, "session-codex")

        XCTAssertEqual(posted[1].state, .starting)
        XCTAssertEqual(posted[1].toolName, "Codex")
        XCTAssertEqual(posted[1].sessionID, "session-codex")
        XCTAssertEqual(posted[1].agentWorkingDirectory, "/tmp/project")
    }

    func test_agent_launch_bootstrap_builds_claude_plan_with_session_id_and_settings() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-claude-runtime")
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/claude",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .claude
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/claude")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "claude")
        XCTAssertEqual(plan.unsetEnvironment, ["CLAUDECODE"])
        XCTAssertTrue(plan.arguments.contains("--settings"))
        XCTAssertTrue(plan.arguments.contains("--session-id"))
        XCTAssertEqual(plan.arguments.last, "hello")

        let settingsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--settings"))
        XCTAssertTrue(plan.arguments.indices.contains(settingsIndex + 1))
        let settingsData = try XCTUnwrap(plan.arguments[settingsIndex + 1].data(using: .utf8))
        let settingsObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settingsObject["hooks"] as? [String: Any])
        let sessionStartEntries = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(
            Set(sessionStartEntries.compactMap { $0["matcher"] as? String }),
            ["startup", "resume", "clear", "compact"]
        )
        let preToolUseEntries = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(
            preToolUseEntries.compactMap { $0["matcher"] as? String },
            ["AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit"]
        )
        XCTAssertNotNil(hooks["TaskCompleted"])
    }

    func test_agent_launch_bootstrap_builds_codex_hook_flags_and_notify_override() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-codex-runtime")
        let codexHome = try makeTemporaryDirectory(named: "agent-launch-codex-home")
        let cliPath = "/tmp/zentty\tbin"
        try """
        {"hooks":{"Existing":[{"hooks":[{"type":"command","command":"echo existing","timeout":3}]}],"SessionStart":[{"hooks":[{"type":"command","command":"echo user-session-start","timeout":3}]}]}}
        """.write(
            to: codexHome.appendingPathComponent("hooks.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let sourceConfigURL = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        try "model = \"gpt-5.1\"\n".write(
            to: sourceConfigURL,
            atomically: true,
            encoding: .utf8
        )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["exec", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "CODEX_HOME": codexHome.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                "ZENTTY_CLI_BIN": cliPath,
            ],
            expectsResponse: true,
            tool: .codex
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "codex")
        XCTAssertNil(plan.setEnvironment["CODEX_HOME"])
        XCTAssertFalse(plan.unsetEnvironment.contains("CODEX_HOME"))
        let hookConfigArguments = plan.arguments.filter { $0.hasPrefix("hooks.") || $0 == "features.hooks=true" }
        XCTAssertTrue(hookConfigArguments.contains("features.hooks=true"))
        XCTAssertTrue(hookConfigArguments.contains { $0.hasPrefix("hooks.SessionStart=") && $0.contains("session-start") })
        XCTAssertTrue(hookConfigArguments.contains { $0.hasPrefix("hooks.PreToolUse=") && $0.contains("pre-tool-use") })
        XCTAssertTrue(hookConfigArguments.contains { $0.hasPrefix("hooks.PermissionRequest=") && $0.contains("permission-request") })
        XCTAssertTrue(hookConfigArguments.contains { $0.hasPrefix("hooks.PostToolUse=") && $0.contains("post-tool-use") })
        XCTAssertTrue(hookConfigArguments.contains { $0.hasPrefix("hooks.UserPromptSubmit=") && $0.contains("prompt-submit") })
        XCTAssertTrue(hookConfigArguments.contains { $0.hasPrefix("hooks.Stop=") && $0.contains("stop") })
        XCTAssertFalse(hookConfigArguments.contains { $0.contains("\t") })
        let hookStateArgument = try XCTUnwrap(hookConfigArguments.first { $0.hasPrefix("hooks.state=") })
        XCTAssertTrue(hookStateArgument.contains(#""/<session-flags>/config.toml:session_start:0:0""#))
        XCTAssertTrue(hookStateArgument.contains(#""/<session-flags>/config.toml:pre_tool_use:0:0""#))
        XCTAssertTrue(hookStateArgument.contains(#""/<session-flags>/config.toml:permission_request:0:0""#))
        XCTAssertTrue(hookStateArgument.contains(#""/<session-flags>/config.toml:post_tool_use:0:0""#))
        XCTAssertTrue(hookStateArgument.contains(#""/<session-flags>/config.toml:user_prompt_submit:0:0""#))
        XCTAssertTrue(hookStateArgument.contains(#""/<session-flags>/config.toml:stop:0:0""#))
        XCTAssertEqual(hookStateArgument.components(separatedBy: "trusted_hash=\"sha256:").count - 1, 6)
        let sourceConfig = try String(contentsOf: sourceConfigURL, encoding: .utf8)
        XCTAssertFalse(sourceConfig.contains("hooks.state"))
        XCTAssertTrue(plan.arguments.contains("features.hooks=true"))
        XCTAssertFalse(plan.arguments.contains("features.codex_hooks=true"))
        XCTAssertTrue(plan.arguments.contains("tui.notification_method=osc9"))
        XCTAssertTrue(plan.arguments.contains(#"tui.terminal_title=["status","spinner","project","task-progress"]"#))
        let notifyArgument = try XCTUnwrap(
            plan.arguments.first(where: { $0.hasPrefix("notify=[") })
        )
        XCTAssertEqual(notifyArgument, #"notify=["/tmp/zentty\tbin","codex-notify"]"#)
        XCTAssertFalse(notifyArgument.contains("\t"))
        XCTAssertFalse(notifyArgument.contains(#"\/"#))
    }

    func test_agent_launch_bootstrap_unsets_nested_zentty_codex_home() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-codex-runtime-nested-home")
        let inheritedCodexHome = "\(NSHomeDirectory())/Library/Caches/Zentty/ipc-1/launch/worklane/pane/codex/home"

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "CODEX_HOME": inheritedCodexHome,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .codex
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertTrue(plan.unsetEnvironment.contains("CODEX_HOME"))
        XCTAssertNil(plan.setEnvironment["CODEX_HOME"])
    }

    func test_agent_launch_bootstrap_keeps_notify_hook_when_prompt_contains_notify_equals() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-codex-runtime-prompt")
        let codexHome = try makeTemporaryDirectory(named: "agent-launch-codex-home-prompt")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["exec", "please keep notify=me in the prompt"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "CODEX_HOME": codexHome.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .codex
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertTrue(plan.arguments.contains(#"notify=["/tmp/zentty","codex-notify"]"#))
        XCTAssertTrue(plan.arguments.contains { $0.hasPrefix("hooks.PermissionRequest=") && $0.contains("permission-request") })
    }

    func test_agent_launch_bootstrap_respects_explicit_codex_notify_override() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-codex-runtime-explicit-notify")
        let codexHome = try makeTemporaryDirectory(named: "agent-launch-codex-home-explicit-notify")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["-c", #"notify=["/tmp/custom-notify"]"#, "exec", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "CODEX_HOME": codexHome.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .codex
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertTrue(plan.arguments.contains(#"notify=["/tmp/custom-notify"]"#))
        XCTAssertFalse(plan.arguments.contains(#"notify=["/tmp/zentty","codex-notify"]"#))
    }

    func test_agent_launch_bootstrap_builds_copilot_overlay_and_strips_config_dir_override() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-copilot-runtime")
        let copilotHome = try makeTemporaryDirectory(named: "agent-launch-copilot-home")
        try """
        {
          // comment
          "version": 1,
          "hooks": {
            "sessionStart": [
              {"type":"command","bash":"echo existing","timeoutSec":10},
            ],
          },
        }
        """.write(
            to: copilotHome.appendingPathComponent("config.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--config-dir", copilotHome.path, "chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "ZENTTY_REAL_BINARY": "/usr/local/bin/copilot",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .copilot
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/copilot")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "copilot")
        XCTAssertFalse(plan.arguments.contains("--config-dir"))
        XCTAssertEqual(plan.arguments, ["chat", "hello"])
        let overlayHome = try XCTUnwrap(plan.setEnvironment["COPILOT_HOME"])
        let overlayConfigURL = URL(fileURLWithPath: overlayHome, isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        let overlayConfig = try String(contentsOf: overlayConfigURL, encoding: .utf8)
        XCTAssertTrue(overlayConfig.contains("session-start"))
        XCTAssertTrue(overlayConfig.contains("pre-tool-use"))
        XCTAssertTrue(overlayConfig.contains("echo existing"))
    }

    func test_agent_launch_bootstrap_adds_copilot_hooks_when_user_config_has_no_hooks() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-copilot-runtime-no-hooks")
        let copilotHome = try makeTemporaryDirectory(named: "agent-launch-copilot-home-no-hooks")
        try #"{"theme":"dark"}"#.write(
            to: copilotHome.appendingPathComponent("config.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--config-dir", copilotHome.path, "chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "ZENTTY_REAL_BINARY": "/usr/local/bin/copilot",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .copilot
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        let overlayHome = try XCTUnwrap(plan.setEnvironment["COPILOT_HOME"])
        let overlayConfigURL = URL(fileURLWithPath: overlayHome, isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        let overlayData = try Data(contentsOf: overlayConfigURL)
        let overlayConfig = try XCTUnwrap(JSONSerialization.jsonObject(with: overlayData) as? [String: Any])
        let hooks = try XCTUnwrap(overlayConfig["hooks"] as? [String: Any])

        XCTAssertEqual(overlayConfig["theme"] as? String, "dark")
        for event in ["sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse", "errorOccurred"] {
            XCTAssertNotNil(hooks[event], "Expected Copilot hook for \(event)")
        }
    }

    func test_agent_launch_bootstrap_sets_cursor_agent_tool_and_passthrough_arguments() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-cursor-runtime")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["agent", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/cursor",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .cursor
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/cursor")
        XCTAssertEqual(plan.arguments, ["agent", "hello"])
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "cursor")
    }

    func test_agent_launch_bootstrap_cursor_respects_hooks_disabled() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-cursor-disabled-runtime")
        let cursorHome = try makeTemporaryDirectory(named: "agent-launch-cursor-disabled-home")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["agent", "hello"],
            standardInput: nil,
            environment: [
                "HOME": cursorHome.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/cursor",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
                "ZENTTY_CURSOR_HOOKS_DISABLED": "1",
            ],
            expectsResponse: true,
            tool: .cursor
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/cursor")
        XCTAssertEqual(plan.arguments, ["agent", "hello"])
        XCTAssertTrue(plan.setEnvironment.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cursorHome.appendingPathComponent(".cursor/hooks.json").path
        ))
    }

    func test_agent_launch_bootstrap_cursor_installs_user_hooks_when_absent() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-cursor-install-runtime")
        let cursorHome = try makeTemporaryDirectory(named: "agent-launch-cursor-install-home")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["agent", "hello"],
            standardInput: nil,
            environment: [
                "HOME": cursorHome.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/cursor",
                "ZENTTY_CLI_BIN": "/opt/zentty/bin/zentty",
            ],
            expectsResponse: true,
            tool: .cursor
        )

        _ = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        let hooksURL = cursorHome
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        let data = try Data(contentsOf: hooksURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)

        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        for event in ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "stop", "beforeShellExecution", "afterShellExecution"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "\(event) should have one managed entry")
            let command = try XCTUnwrap(entries.first?["command"] as? String)
            XCTAssertTrue(command.contains("/opt/zentty/bin/zentty"))
            XCTAssertTrue(command.contains("ipc agent-event --adapter=cursor"))
            XCTAssertTrue(command.hasSuffix("--adapter=cursor"),
                          "hook command must end cleanly so Cursor's heredoc binds to zentty (not a trailing || clause)")
        }

        for event in ["preToolUse", "postToolUse"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "\(event) should have one managed TodoWrite entry")
            XCTAssertEqual(entries.first?["matcher"] as? String, "TodoWrite")
            let command = try XCTUnwrap(entries.first?["command"] as? String)
            XCTAssertTrue(command.contains("ipc agent-event --adapter=cursor"))
        }
    }

    func test_agent_launch_bootstrap_cursor_preserves_existing_user_hooks() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-cursor-merge-runtime")
        let cursorHome = try makeTemporaryDirectory(named: "agent-launch-cursor-merge-home")
        let cursorDir = cursorHome.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try #"""
        {
          "version": 1,
          "hooks": {
            "sessionStart": [
              { "command": "/Users/peter/.superset/hooks/cursor-hook.sh Start" }
            ],
            "beforeShellExecution": [
              { "command": "/Users/peter/.superset/hooks/cursor-hook.sh PermissionRequest" }
            ]
          }
        }
        """#.write(
            to: cursorDir.appendingPathComponent("hooks.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["agent", "hello"],
            standardInput: nil,
            environment: [
                "HOME": cursorHome.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/cursor",
                "ZENTTY_CLI_BIN": "/opt/zentty/bin/zentty",
            ],
            expectsResponse: true,
            tool: .cursor
        )

        _ = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        let data = try Data(contentsOf: cursorDir.appendingPathComponent("hooks.json", isDirectory: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        let sessionStart = try XCTUnwrap(hooks["sessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 2, "original sessionStart entry kept, Zentty entry appended")
        XCTAssertEqual(sessionStart.first?["command"] as? String, "/Users/peter/.superset/hooks/cursor-hook.sh Start")
        XCTAssertTrue((sessionStart.last?["command"] as? String ?? "").contains("/opt/zentty/bin/zentty"))

        let beforeShell = try XCTUnwrap(hooks["beforeShellExecution"] as? [[String: Any]])
        XCTAssertEqual(beforeShell.count, 2, "original beforeShellExecution entry kept, Zentty entry appended")
        XCTAssertEqual(beforeShell.first?["command"] as? String, "/Users/peter/.superset/hooks/cursor-hook.sh PermissionRequest")
        XCTAssertTrue((beforeShell.last?["command"] as? String ?? "").contains("/opt/zentty/bin/zentty"))
    }

    func test_agent_launch_bootstrap_cursor_install_is_idempotent_and_refreshes_cli_path() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-cursor-idempotent-runtime")
        let cursorHome = try makeTemporaryDirectory(named: "agent-launch-cursor-idempotent-home")

        func runPlan(cliPath: String) throws {
            let request = AgentIPCRequest(
                kind: .bootstrap,
                arguments: ["agent", "hello"],
                standardInput: nil,
                environment: [
                    "HOME": cursorHome.path,
                    "ZENTTY_REAL_BINARY": "/usr/local/bin/cursor",
                    "ZENTTY_CLI_BIN": cliPath,
                ],
                expectsResponse: true,
                tool: .cursor
            )
            _ = try AgentLaunchBootstrap.makePlan(
                request: request,
                target: AgentIPCTarget(
                    windowID: WindowID("window-main"),
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("pane-main")
                ),
                runtimeDirectoryURL: runtimeDirectory
            )
        }

        try runPlan(cliPath: "/opt/old/zentty")
        try runPlan(cliPath: "/opt/old/zentty")
        try runPlan(cliPath: "/opt/new/zentty")

        let hooksURL = cursorHome
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        let data = try Data(contentsOf: hooksURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])

        for event in ["sessionStart", "sessionEnd", "stop"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "\(event) should have exactly one managed entry after three installs")
            let command = try XCTUnwrap(entries.first?["command"] as? String)
            XCTAssertTrue(command.contains("/opt/new/zentty"), "stale cliPath should have been replaced")
            XCTAssertFalse(command.contains("/opt/old/zentty"))
        }
    }

    // MARK: - CursorHooksInstaller

    func test_cursor_hooks_installer_tolerates_jsonc_comments_and_trailing_commas() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-jsonc")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try #"""
        {
          // a comment — strict JSON would reject this
          "version": 1,
          "hooks": {
            "sessionStart": [
              { "command": "/custom/user-hook.sh", },
            ],
          },
        }
        """#.write(to: hooksURL, atomically: true, encoding: .utf8)

        try CursorHooksInstaller.install(at: hooksURL, cliPath: "/opt/zentty/bin/zentty")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["sessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 2, "user entry preserved plus Zentty entry appended")
        XCTAssertEqual(sessionStart.first?["command"] as? String, "/custom/user-hook.sh")
        XCTAssertTrue((sessionStart.last?["command"] as? String ?? "").contains("/opt/zentty/bin/zentty"))
    }

    func test_cursor_hooks_installer_throws_on_unrecoverable_malformed_json() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-malformed")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try "{ this is not json at all }".write(to: hooksURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CursorHooksInstaller.install(at: hooksURL, cliPath: "/opt/zentty/bin/zentty")
        )

        let unchanged = try String(contentsOf: hooksURL, encoding: .utf8)
        XCTAssertEqual(unchanged, "{ this is not json at all }", "user file is never rewritten when unrecoverable")
    }

    func test_cursor_hooks_installer_skips_write_when_content_unchanged() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-skip")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)

        try CursorHooksInstaller.install(at: hooksURL, cliPath: "/opt/zentty/bin/zentty")
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: hooksURL.path)
        let mtimeBefore = try XCTUnwrap(attributesBefore[.modificationDate] as? Date)

        // Ensure any mtime bump would be observable.
        Thread.sleep(forTimeInterval: 1.1)
        try CursorHooksInstaller.install(at: hooksURL, cliPath: "/opt/zentty/bin/zentty")

        let attributesAfter = try FileManager.default.attributesOfItem(atPath: hooksURL.path)
        let mtimeAfter = try XCTUnwrap(attributesAfter[.modificationDate] as? Date)
        XCTAssertEqual(mtimeBefore, mtimeAfter, "identical re-install should not touch the file")
    }

    func test_cursor_hooks_installer_uninstall_preserves_user_entries_and_removes_managed_events() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-uninstall")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try #"""
        {
          "version": 1,
          "hooks": {
            "sessionStart": [
              { "command": "/custom/start.sh" }
            ],
            "beforeShellExecution": [
              { "command": "/custom/permission.sh" }
            ]
          }
        }
        """#.write(to: hooksURL, atomically: true, encoding: .utf8)
        try CursorHooksInstaller.install(at: hooksURL, cliPath: "/opt/zentty/bin/zentty")

        try CursorHooksInstaller.uninstall(at: hooksURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["sessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 1)
        XCTAssertEqual(sessionStart.first?["command"] as? String, "/custom/start.sh")
        XCTAssertNotNil(hooks["beforeShellExecution"], "unmanaged events passed through untouched")
        XCTAssertNil(hooks["sessionEnd"], "managed event with no user entries should be removed")
        XCTAssertNil(hooks["beforeSubmitPrompt"])
        XCTAssertNil(hooks["stop"])
    }

    func test_cursor_hooks_installer_uninstall_deletes_file_when_nothing_user_owned_remains() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-uninstall-empty")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try CursorHooksInstaller.install(at: hooksURL, cliPath: "/opt/zentty/bin/zentty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.path))

        try CursorHooksInstaller.uninstall(at: hooksURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: hooksURL.path),
            "file should be deleted when only Zentty-managed entries were present"
        )
    }

    func test_cursor_hooks_installer_uninstall_on_missing_file_is_noop() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-uninstall-missing")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)

        XCTAssertNoThrow(try CursorHooksInstaller.uninstall(at: hooksURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }

    func test_cursor_hooks_installer_uninstall_leaves_unrelated_jsonc_content_unchanged() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-uninstall-jsonc")
        let hooksURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        // JSONC with comments + trailing commas — Zentty never installed anything.
        let original = #"""
        {
          // user-managed hooks, no Zentty entries
          "version": 1,
          "hooks": {
            "beforeShellExecution": [
              { "command": "/custom/permission.sh", },
            ],
          },
        }
        """#
        try original.write(to: hooksURL, atomically: true, encoding: .utf8)
        let mtimeBefore = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: hooksURL.path)[.modificationDate] as? Date
        )

        Thread.sleep(forTimeInterval: 1.1)
        try CursorHooksInstaller.uninstall(at: hooksURL)

        let after = try String(contentsOf: hooksURL, encoding: .utf8)
        XCTAssertEqual(after, original, "uninstall must not rewrite files it has no entries to remove from")
        let mtimeAfter = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: hooksURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(mtimeBefore, mtimeAfter, "mtime should be preserved when there is nothing to remove")
    }

    func test_cursor_hooks_installer_install_if_possible_treats_whitespace_env_as_blank() throws {
        let directory = try makeTemporaryDirectory(named: "cursor-hooks-installer-blank-env")
        let hooksURL = directory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)

        // Whitespace-only HOME / cli path should be ignored — no file should be created.
        CursorHooksInstaller.installIfPossible(environment: [
            "HOME": "   ",
            "ZENTTY_CLI_BIN": "\t",
        ])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: hooksURL.path),
            "installIfPossible must reject whitespace-only env values"
        )
    }

    // MARK: - DroidHooksInstaller — suppressHookOutput

    func test_droid_suppress_hook_output_sets_false_on_fresh_file() throws {
        let directory = try makeTemporaryDirectory(named: "droid-suppress-fresh")
        let hooksConfigURL = directory.appendingPathComponent("hooks.json", isDirectory: false)

        try DroidHooksInstaller.suppressHookOutput(at: hooksConfigURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hooksConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(object["showHookOutput"] as? Bool, false)
    }

    func test_droid_suppress_hook_output_preserves_existing_entries() throws {
        let directory = try makeTemporaryDirectory(named: "droid-suppress-existing")
        let hooksConfigURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try #"{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}"#
            .write(to: hooksConfigURL, atomically: true, encoding: .utf8)

        try DroidHooksInstaller.suppressHookOutput(at: hooksConfigURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hooksConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(object["showHookOutput"] as? Bool, false)
        XCTAssertNotNil(object["Stop"], "existing hook entries must be preserved")
    }

    func test_droid_suppress_hook_output_respects_user_true() throws {
        let directory = try makeTemporaryDirectory(named: "droid-suppress-user-true")
        let hooksConfigURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try #"{"showHookOutput":true}"#
            .write(to: hooksConfigURL, atomically: true, encoding: .utf8)

        try DroidHooksInstaller.suppressHookOutput(at: hooksConfigURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hooksConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(object["showHookOutput"] as? Bool, true, "user's explicit true must not be overwritten")
    }

    func test_droid_suppress_hook_output_respects_user_false() throws {
        let directory = try makeTemporaryDirectory(named: "droid-suppress-user-false")
        let hooksConfigURL = directory.appendingPathComponent("hooks.json", isDirectory: false)
        try #"{"showHookOutput":false}"#
            .write(to: hooksConfigURL, atomically: true, encoding: .utf8)

        let mtimeBefore = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: hooksConfigURL.path)[.modificationDate] as? Date
        )
        Thread.sleep(forTimeInterval: 1.1)

        try DroidHooksInstaller.suppressHookOutput(at: hooksConfigURL)

        let mtimeAfter = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: hooksConfigURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(mtimeBefore, mtimeAfter, "file should not be rewritten when key already exists")
    }

    // MARK: - KimiHooksInstaller

    func test_kimi_hooks_installer_appends_managed_block_and_preserves_existing_content() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-append")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
        let original = """
        default_model = "kimi-k2"

        [[hooks]]
        event = "SessionStart"
        command = "echo user"
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/zentty/bin/zentty")

        let after = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(original))
        XCTAssertTrue(after.contains("### BEGIN ZENTTY KIMI HOOKS"))
        XCTAssertFalse(after.contains(#"matcher = "permission_prompt""#))
        XCTAssertFalse(after.contains(#"matcher = "AskUserQuestion""#))
        XCTAssertTrue(after.contains(#"event = "SessionStart""#))
        XCTAssertTrue(after.contains(#"event = "SessionEnd""#))
        XCTAssertTrue(after.contains(#"event = "UserPromptSubmit""#))
        XCTAssertTrue(after.contains(#"event = "Stop""#))
        XCTAssertTrue(after.contains(#"event = "Notification""#))
        XCTAssertTrue(after.contains(#"event = "PreToolUse""#))
        XCTAssertTrue(after.contains(#"event = "PostToolUse""#))
        XCTAssertTrue(after.contains(#"command = "\"/opt/zentty/bin/zentty\" ipc agent-event --adapter=kimi""#))
        XCTAssertFalse(after.contains(#"command = ""/opt/zentty/bin/zentty""#))
    }

    func test_kimi_hooks_installer_reinstall_replaces_managed_block_in_place() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-reinstall")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)

        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/old/zentty")
        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/old/zentty")
        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/new/zentty")

        let after = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(after.components(separatedBy: "### BEGIN ZENTTY KIMI HOOKS").count, 2)
        XCTAssertTrue(after.contains("/opt/new/zentty"))
        XCTAssertFalse(after.contains("/opt/old/zentty"))
    }

    func test_kimi_hooks_installer_uninstall_removes_only_managed_block() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-uninstall")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
        let original = """
        default_model = "kimi-k2"

        [[hooks]]
        event = "SessionStart"
        command = "echo user"
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/zentty/bin/zentty")

        try KimiHooksInstaller.uninstall(at: configURL)

        let after = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(after, original)
    }

    func test_kimi_hooks_installer_uninstall_deletes_file_when_only_managed_block_remains() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-uninstall-empty")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/zentty/bin/zentty")

        try KimiHooksInstaller.uninstall(at: configURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func test_kimi_hooks_installer_install_if_possible_treats_whitespace_env_as_blank() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-blank-env")
        let configURL = directory
            .appendingPathComponent(".kimi", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)

        KimiHooksInstaller.installIfPossible(environment: [
            "HOME": "  ",
            "ZENTTY_CLI_BIN": "\t",
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func test_kimi_hooks_installer_replaces_empty_hooks_placeholder_and_restores_it_on_uninstall() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-placeholder")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
        let original = """
        default_model = "kimi-k2"
        hooks = []
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/zentty/bin/zentty")

        let installed = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(installed.contains("\nhooks = []\n"))
        XCTAssertTrue(installed.contains(#"hooks = ["#))
        XCTAssertTrue(installed.contains(#"{ event = "Notification", command = "\"/opt/zentty/bin/zentty\" ipc agent-event --adapter=kimi""#))
        XCTAssertFalse(installed.contains(#"[[hooks]]"#))

        try KimiHooksInstaller.uninstall(at: configURL)

        let uninstalled = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(uninstalled, original)
    }

    func test_kimi_hooks_installer_merges_nonempty_inline_hooks_array_and_restores_original_on_uninstall() throws {
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-inline-array")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
        let original = """
        default_model = "kimi-k2"
        hooks = [{ event = "SessionStart", command = "echo user" }]
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/zentty/bin/zentty")

        let installed = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(installed.components(separatedBy: "hooks = [").count, 2)
        XCTAssertTrue(installed.contains(#"command = "echo user""#))
        XCTAssertTrue(installed.contains(#"{ event = "Notification", command = "\"/opt/zentty/bin/zentty\" ipc agent-event --adapter=kimi""#))
        XCTAssertFalse(installed.contains("[[hooks]]"))

        try KimiHooksInstaller.uninstall(at: configURL)

        let uninstalled = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(uninstalled, original)
    }

    func test_kimi_hooks_installer_ignores_markers_embedded_in_toml_string_values() throws {
        // Regression guard: marker detection is line-anchored. A BEGIN/END
        // marker smuggled into a TOML string value on a line with other content
        // must not be treated as a managed block; install should append a fresh
        // block, and uninstall should leave the string value intact.
        let directory = try makeTemporaryDirectory(named: "kimi-hooks-installer-embedded-marker")
        let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
        let original = """
        default_model = "kimi-k2"
        quirky = "prefix ### BEGIN ZENTTY KIMI HOOKS suffix ### END ZENTTY KIMI HOOKS tail"
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        try KimiHooksInstaller.install(at: configURL, cliPath: "/opt/zentty/bin/zentty")

        let installed = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(installed.contains(original), "embedded-marker line should be preserved verbatim")
        XCTAssertEqual(
            installed.components(separatedBy: "\n### BEGIN ZENTTY KIMI HOOKS\n").count, 2,
            "install should add exactly one managed block"
        )

        try KimiHooksInstaller.uninstall(at: configURL)

        let uninstalled = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(uninstalled, original)
    }

    // MARK: - GrokHooksInstaller

    /// Creates `<root>/.grok/hooks/` under a fresh tmp dir and returns (grokRoot, hooksRoot).
    /// Sibling files (user-settings.json, hooks-paths, plugins/) are written under grokRoot.
    private func makeGrokHooksRoot() throws -> (grokRoot: URL, hooksRoot: URL) {
        let directory = try makeTemporaryDirectory(named: "grok-hooks-installer")
        let grokRoot = directory.appendingPathComponent(".grok", isDirectory: true)
        let hooksRoot = grokRoot.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksRoot, withIntermediateDirectories: true)
        return (grokRoot, hooksRoot)
    }

    private func defaultManagedEvents() -> [String] {
        GrokHooksInstaller.defaultManagedEvents
    }

    private func toolUseEventNames() -> Set<String> {
        ["PreToolUse", "PostToolUse"]
    }

    private func forwarderScriptURL(under hooksRoot: URL) -> URL {
        hooksRoot
            .appendingPathComponent("zentty-status", isDirectory: true)
            .appendingPathComponent("01-zentty-status.sh", isDirectory: false)
    }

    private func hookConfigURL(under hooksRoot: URL) -> URL {
        hooksRoot.appendingPathComponent("zentty-status.json", isDirectory: false)
    }

    func test_grok_hooks_installer_writes_single_json_config_at_always_trusted_location() throws {
        // Grok's "Always trusted" hook source is `~/.grok/hooks/*.json`. The
        // installer must write exactly one JSON file there listing every
        // managed event, pointing at the single forwarder script.
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let configURL = hookConfigURL(under: hooksRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path), "config JSON missing")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: configURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(parsed["hooks"] as? [String: Any])
        let forwarder = forwarderScriptURL(under: hooksRoot).path
        for event in defaultManagedEvents() {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing entry for \(event)")
            let firstEntry = try XCTUnwrap(entries.first)
            let nested = try XCTUnwrap(firstEntry["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(nested.first?["command"] as? String)
            XCTAssertEqual(command, forwarder, "\(event) must point at the single forwarder script")
        }
    }

    func test_grok_hooks_installer_lifecycle_events_have_no_matcher_field() throws {
        // Regression for the schema bug: lifecycle events MUST NOT specify a
        // `matcher` field (binary string: "lifecycle hooks () must not specify
        // a matcher in v0"). Including one silently invalidates the entry.
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hookConfigURL(under: hooksRoot))) as? [String: Any]
        )
        let hooks = try XCTUnwrap(parsed["hooks"] as? [String: Any])

        let toolEvents = toolUseEventNames()
        for event in defaultManagedEvents() where !toolEvents.contains(event) {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            for entry in entries {
                XCTAssertNil(entry["matcher"], "lifecycle event \(event) must not have a matcher field")
            }
        }
    }

    func test_grok_hooks_installer_tool_use_events_have_matcher_dot_star() throws {
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hookConfigURL(under: hooksRoot))) as? [String: Any]
        )
        let hooks = try XCTUnwrap(parsed["hooks"] as? [String: Any])

        for event in toolUseEventNames() {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing tool-use entry for \(event)")
            let firstEntry = try XCTUnwrap(entries.first)
            XCTAssertEqual(firstEntry["matcher"] as? String, ".*", "\(event) must specify matcher .*")
        }
    }

    func test_grok_hooks_installer_writes_executable_forwarder_script_with_marker() throws {
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let scriptURL = forwarderScriptURL(under: hooksRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path), "forwarder script missing")

        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o755, "forwarder must be executable (0o755)")

        let content = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(content.contains(GrokHooksInstaller.hookMarker), "forwarder must carry the uninstall marker")
        XCTAssertTrue(
            content.contains("exec \"$ZENTTY_BIN\" ipc agent-event --adapter=grok"),
            "forwarder must be a thin exec into the Swift CLI"
        )
    }

    func test_grok_hooks_installer_does_not_write_legacy_user_settings_or_plugin() throws {
        // Regression for the wrong-file bug: we used to write user-settings.json,
        // hooks-paths, and a plugin manifest. None of those are hook sources for
        // Grok — the only thing that actually fires is the JSON under
        // ~/.grok/hooks/. On a fresh install nothing else should be created.
        let (grokRoot, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let userSettingsURL = grokRoot.appendingPathComponent("user-settings.json", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userSettingsURL.path), "must not write user-settings.json — Grok ignores it")
        let hooksPathsURL = grokRoot.appendingPathComponent("hooks-paths", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksPathsURL.path), "must not write hooks-paths — unrelated to hook discovery")
        let pluginDir = grokRoot.appendingPathComponent("plugins").appendingPathComponent("zentty-status")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginDir.path), "must not install plugin manifest — disabled by default in TUI")
    }

    func test_grok_hooks_installer_is_idempotent() throws {
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: hookConfigURL(under: hooksRoot))) as? [String: Any]
        )
        let hooks = try XCTUnwrap(parsed["hooks"] as? [String: Any])
        // Every event should still have exactly one entry — re-installing must
        // not multiply registrations.
        for event in defaultManagedEvents() {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "\(event) must have exactly one entry after repeated installs")
        }
    }

    func test_grok_hooks_installer_scripts_have_no_external_runtime_dependencies() throws {
        // Regression guard: the generated forwarder must be a thin shell exec.
        // Parsing lives in Swift (`GrokCanonicalReEmitter`) so the script must
        // not reach for `jq`, `yq`, `gron`, `awk`, etc.
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        let script = try String(contentsOf: forwarderScriptURL(under: hooksRoot), encoding: .utf8)
        for forbidden in ["jq ", "yq ", "gron ", "awk ", " sed "] {
            XCTAssertFalse(
                script.contains(forbidden),
                "forwarder must not depend on \(forbidden.trimmingCharacters(in: .whitespaces)); parsing lives in GrokCanonicalReEmitter"
            )
        }
        XCTAssertTrue(
            script.contains("exec \"$ZENTTY_BIN\" ipc agent-event --adapter=grok"),
            "forwarder must be a thin forwarder"
        )
    }

    // MARK: - GrokCanonicalReEmitter

    func test_grok_canonical_reemitter_emits_task_progress_for_todowrite() throws {
        let payload = """
        {
          "hook_event_name": "PreToolUse",
          "tool_name": "TodoWrite",
          "tool_input": {
            "todos": [
              {"status": "completed"},
              {"status": "in_progress"},
              {"status": "pending"}
            ]
          }
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        XCTAssertEqual(emissions.count, 1, "TodoWrite payload should emit exactly one canonical task.progress event")
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"event\":\"task.progress\""))
        XCTAssertTrue(envelope.contains("\"done\":1"))
        XCTAssertTrue(envelope.contains("\"total\":3"))
    }

    func test_grok_canonical_reemitter_handles_grok_nested_tool_use_shape() throws {
        // Grok nests the tool call under tool_use.input (vs Claude's tool_input).
        let payload = """
        {
          "hook_event_name": "PreToolUse",
          "tool_use": {
            "name": "todo_write",
            "input": {
              "todos": [
                {"status": "done"},
                {"status": "done"},
                {"status": "pending"}
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"event\":\"task.progress\""))
        XCTAssertTrue(envelope.contains("\"done\":2"))
        XCTAssertTrue(envelope.contains("\"total\":3"))
    }

    func test_grok_canonical_reemitter_emits_needs_input_for_notification() throws {
        let payload = """
        {
          "hook_event_name": "Notification",
          "notification_type": "permission",
          "message": "Permission required to run rm -rf /tmp/foo"
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"event\":\"agent.needs-input\""))
        XCTAssertTrue(envelope.contains("\"text\":\"Permission required to run rm -rf /tmp/foo\""))
        XCTAssertTrue(envelope.contains("\"kind\":\"approval\""))
    }

    func test_grok_canonical_reemitter_classifies_question_notifications() throws {
        let payload = """
        {
          "hook_event_name": "Notification",
          "notification_type": "question",
          "message": "Which approach should we take?"
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"kind\":\"question\""))
    }

    func test_grok_canonical_reemitter_does_not_emit_needs_input_for_info_notifications() throws {
        // Regression for the old shell regex that matched "ask" inside "task" —
        // routine messages like "Task completed" must not produce a needs-input
        // record. The structured allowlist gates this: notification_type=info
        // with no input-related words → no emission.
        let payload = """
        {
          "hook_event_name": "Notification",
          "notification_type": "info",
          "message": "Task completed"
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        XCTAssertTrue(emissions.isEmpty, "info-type notification with no input-request signal must not emit needs-input")
    }

    func test_grok_canonical_reemitter_emits_question_for_trailing_question_mark() throws {
        // Permission-typed notifications still emit, and a trailing "?" tilts
        // the kind from "approval" to "question".
        let payload = """
        {
          "hook_event_name": "Notification",
          "notification_type": "permission",
          "message": "Should I rerun the migration?"
        }
        """.data(using: .utf8)!

        let envelope = try XCTUnwrap(GrokCanonicalReEmitter.reEmissions(forHookPayload: payload).first)
        XCTAssertTrue(envelope.contains("\"kind\":\"question\""))
    }

    func test_grok_canonical_reemitter_emits_session_start_with_nested_id() throws {
        let payload = """
        {
          "hook_event_name": "SessionStart",
          "context": {
            "session_id": "ses_abc123"
          }
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"event\":\"session.start\""))
        XCTAssertTrue(envelope.contains("\"id\":\"ses_abc123\""))
    }

    func test_grok_canonical_reemitter_resolves_session_id_under_data_id() throws {
        let payload = """
        {
          "hook_event_name": "session_start",
          "data": {
            "id": "ses_data_id"
          }
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"id\":\"ses_data_id\""))
    }

    func test_grok_canonical_reemitter_skips_already_canonical_payloads() throws {
        // Canonical v1 payloads should pass through the adapter directly — re-emitting
        // would duplicate the record.
        let payload = """
        {"version":1,"event":"task.progress","progress":{"done":1,"total":2}}
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        XCTAssertTrue(emissions.isEmpty, "already-canonical payloads must not be re-emitted")
    }

    func test_grok_canonical_reemitter_escapes_message_text() throws {
        let payload = """
        {
          "hook_event_name": "Notification",
          "notification_type": "permission",
          "message": "Quote \\"this\\"\\nand a newline"
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        // The envelope itself must be valid JSON when the message contains quotes/newlines.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: envelope.data(using: .utf8)!))
    }

    func test_grok_canonical_reemitter_falls_through_to_nested_when_primary_todos_is_empty() throws {
        // Defensive: a payload where the primary `todos` location is an empty
        // array but a fallback nesting carries the real list must still produce
        // a task.progress emission. Earlier the candidate scan returned `.first`
        // non-nil unconditionally and stopped on the empty array.
        let payload = """
        {
          "hook_event_name": "PreToolUse",
          "tool_name": "TodoWrite",
          "tool_input": {
            "todos": [],
            "input": {
              "todos": [
                {"status": "completed"},
                {"status": "in_progress"}
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let emissions = GrokCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        XCTAssertTrue(envelope.contains("\"event\":\"task.progress\""))
        XCTAssertTrue(envelope.contains("\"done\":1"))
        XCTAssertTrue(envelope.contains("\"total\":2"))
    }

    func test_grok_canonical_reemitter_returns_nothing_for_unrelated_events() throws {
        let payload = """
        {"hook_event_name": "PostToolUse", "tool_name": "Bash"}
        """.data(using: .utf8)!

        XCTAssertTrue(GrokCanonicalReEmitter.reEmissions(forHookPayload: payload).isEmpty)
    }

    func test_grok_adapter_ignores_raw_ask_user_tool_lifecycle() throws {
        let events = ["PreToolUse", "PostToolUse"]

        for event in events {
            let payloads = try AgentEventBridge.grokAdapter(
                data: Data("""
                {"hook_event_name":"\(event)","session_id":"session-1","cwd":"/tmp/project","tool_name":"AskUserQuestion","tool_input":{"question":"Ship this?"}}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            )

            XCTAssertTrue(payloads.isEmpty, "\(event) for AskUserQuestion must not overwrite canonical needs-input")
        }
    }

    // MARK: - AgyHooksInstaller
    //
    // Full coverage of the installer behaviour lives in
    // `AgyHooksInstallerTests`; the case below stays here as a smoke check
    // that the installer is wired up against the same temp-home helper as
    // the rest of this file (the bootstrap test below depends on it not
    // littering the real ~/.gemini).

    func test_agent_launch_bootstrap_agy_auto_installs_hooks_and_emits_wrapper_lifecycle() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-agy-runtime")
        let home = try makeTemporaryDirectory(named: "agent-launch-agy-home")
        let fakeBinDir = try makeTemporaryDirectory(named: "agent-launch-agy-bin")
        let fakeAgy = fakeBinDir.appendingPathComponent("agy", isDirectory: false)
        let logURL = fakeBinDir.appendingPathComponent("agy.log", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s|HOME=%s\\n' "$*" "$HOME" >> "$AGY_LOG"
        exit 0
        """.write(to: fakeAgy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgy.path)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--print", "--prompt", "hello"],
            standardInput: nil,
            environment: [
                "HOME": home.path,
                "AGY_LOG": logURL.path,
                "ZENTTY_REAL_BINARY": fakeAgy.path,
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .agy
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, fakeAgy.path)
        XCTAssertEqual(plan.arguments, ["--print", "--prompt", "hello"])
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "agy")
        XCTAssertEqual(plan.preLaunchActions.count, 2)
        XCTAssertEqual(plan.preLaunchActions.first?.arguments, ["--adapter=agy"])
        XCTAssertTrue(plan.preLaunchActions[0].standardInput?.contains(#""event":"session.start""#) == true)
        XCTAssertTrue(plan.preLaunchActions[1].standardInput?.contains(#""event":"agent.running""#) == true)

        // The placeholder session id is `zentty-placeholder-<uuid>`,
        // exported via env and embedded in both pre-launch events. The
        // prefix is what the resume builder uses to recognise this id and
        // fall back to `agy --continue` if no real conversation_id ever
        // arrives. Both events share the same placeholder so downstream
        // consumers can match them up before supersession.
        let placeholder = try XCTUnwrap(plan.setEnvironment["ZENTTY_AGY_PLACEHOLDER_SESSION_ID"], "missing placeholder session id env")
        XCTAssertTrue(placeholder.hasPrefix("zentty-placeholder-"), "placeholder must carry the recognition prefix, got \(placeholder)")
        let uuidPart = String(placeholder.dropFirst("zentty-placeholder-".count))
        XCTAssertNotNil(UUID(uuidString: uuidPart), "placeholder must end in a valid UUID, got \(placeholder)")
        XCTAssertTrue(plan.preLaunchActions[0].standardInput?.contains(#""id":"\#(placeholder)""#) == true, "session.start must use the placeholder")
        XCTAssertTrue(plan.preLaunchActions[1].standardInput?.contains(#""id":"\#(placeholder)""#) == true, "agent.running must use the same placeholder")
        XCTAssertFalse(plan.preLaunchActions[0].standardInput?.contains("pane-antigravity") == true, "Old hard-coded session id must be gone")

        // agy can't redirect its hooks path, so the launch plan auto-installs
        // the status hooks into the launching session's ~/.gemini/config/.
        let hooksURL = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.path), "agyPlan must auto-install hooks.json")
        let hooksData = try Data(contentsOf: hooksURL)
        let hooksRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
        XCTAssertNotNil(hooksRoot["zentty"], "auto-installed hooks must live under the zentty group")

        // The real agy binary must not have been executed by makePlan itself.
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        // We never touch the antigravity-cli subtree.
        let settingsURL = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    // MARK: - Agy adapter — added event coverage

    func test_agy_adapter_keeps_unresolved_stop_when_background_work_is_pending() throws {
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data(#"""
            {
              "hook_event_name": "Stop",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "fullyIdle": false,
              "terminationReason": "background work in progress"
            }
            """#.utf8),
            environment: agyAdapterEnvironment(pid: "4242")
        )

        // `fullyIdle: false` means tools are still running; we surface
        // `.unresolvedStop` so the UI doesn't flap into idle. The PID is
        // intentionally not cleared.
        XCTAssertEqual(payloads.map(\.state), [.unresolvedStop])
        XCTAssertEqual(payloads.first?.text, "background work in progress")
        XCTAssertTrue(payloads.allSatisfy { $0.pidEvent == nil })
    }

    func test_agy_adapter_treats_turn_completion_like_stop() throws {
        // `turn-completion` is an alias for `Stop` that the Antigravity CLI
        // emits at turn boundaries.
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data(#"""
            {
              "hook_event_name": "turn-completion",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "fullyIdle": true
            }
            """#.utf8),
            environment: agyAdapterEnvironment(pid: "4242")
        )

        XCTAssertEqual(payloads.map(\.state), [.idle])
    }

    func test_agy_adapter_emits_session_end_and_pid_clear_for_sessionend() throws {
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data(#"""
            {
              "hook_event_name": "SessionEnd",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d"
            }
            """#.utf8),
            environment: agyAdapterEnvironment(pid: "4242")
        )

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads.first?.signalKind, .lifecycle)
        XCTAssertEqual(payloads.last?.signalKind, .pid)
        XCTAssertEqual(payloads.last?.pidEvent, .clear)
    }

    func test_agy_adapter_treats_notification_as_needs_input() throws {
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data(#"""
            {
              "hook_event_name": "Notification",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "message": "Approve deploy to production?"
            }
            """#.utf8),
            environment: agyAdapterEnvironment()
        )

        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Approve deploy to production?")
    }

    func test_agy_adapter_prefers_explicit_event_positional_over_payload_field() throws {
        // The installed shell hook passes the event name as the positional
        // after `--adapter=agy`. When both arrive the explicit positional
        // wins so we are not at the mercy of which JSON key Antigravity
        // happens to use.
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data(#"""
            {
              "hook_event_name": "something-unknown",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "fullyIdle": true
            }
            """#.utf8),
            defaultEventName: "stop",
            environment: agyAdapterEnvironment(pid: "4242")
        )

        XCTAssertEqual(payloads.map(\.state), [.idle])
    }

    // MARK: - Agy canonical re-emitter — added event coverage

    func test_agy_reemitter_emits_idle_only_when_fully_idle() throws {
        let idlePayload = Data(#"""
        {
          "hook_event_name": "Stop",
          "conversationId": "CBEC30AA-F6C2-4B1C-AA7F-F6569C2E0C1D",
          "fullyIdle": true
        }
        """#.utf8)
        let pendingPayload = Data(#"""
        {
          "hook_event_name": "Stop",
          "conversationId": "CBEC30AA-F6C2-4B1C-AA7F-F6569C2E0C1D",
          "fullyIdle": false
        }
        """#.utf8)

        let idleEmissions = AgyCanonicalReEmitter.reEmissions(forHookPayload: idlePayload)
        let pendingEmissions = AgyCanonicalReEmitter.reEmissions(forHookPayload: pendingPayload)

        XCTAssertEqual(idleEmissions.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(idleEmissions.first).utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "agent.idle")

        XCTAssertTrue(pendingEmissions.isEmpty, "Stop with fullyIdle:false must not mint a canonical idle event")
    }

    func test_agy_reemitter_emits_session_end_envelope() throws {
        let payload = Data(#"""
        {
          "hook_event_name": "SessionEnd",
          "conversationId": "CBEC30AA-F6C2-4B1C-AA7F-F6569C2E0C1D"
        }
        """#.utf8)

        let emissions = AgyCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "session.end")
    }

    func test_agy_reemitter_emits_needs_input_from_notification_with_text() throws {
        let payload = Data(#"""
        {
          "hook_event_name": "Notification",
          "conversationId": "CBEC30AA-F6C2-4B1C-AA7F-F6569C2E0C1D",
          "message": "Approve deploy to production?"
        }
        """#.utf8)

        let emissions = AgyCanonicalReEmitter.reEmissions(forHookPayload: payload)
        let envelope = try XCTUnwrap(emissions.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "agent.needs-input")
    }

    // MARK: - AgyCanonicalReEmitter

    func test_agy_canonical_reemitter_emits_session_start_from_preinvocation() throws {
        let payload = Data("""
        {
          "hook_event_name": "PreInvocation",
          "conversationId": "CBEC30AA-F6C2-4B1C-AA7F-F6569C2E0C1D",
          "workspacePaths": ["/tmp/project"]
        }
        """.utf8)

        let emissions = AgyCanonicalReEmitter.reEmissions(forHookPayload: payload)

        let envelope = try XCTUnwrap(emissions.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "session.start")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["id"] as? String, "CBEC30AA-F6C2-4B1C-AA7F-F6569C2E0C1D")
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        XCTAssertEqual(context["workingDirectory"] as? String, "/tmp/project")
    }

    // MARK: - Agy adapter

    func test_agy_adapter_maps_preinvocation_to_running_with_official_fields() throws {
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data("""
            {
              "hook_event_name": "PreInvocation",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "workspacePaths": ["/tmp/project"],
              "transcriptPath": "/tmp/project/transcript.jsonl"
            }
            """.utf8),
            environment: agyAdapterEnvironment(pid: "4242")
        )

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].pid, 4242)
        XCTAssertEqual(payloads[0].pidEvent, .attach)
        XCTAssertEqual(payloads[1].state, .running)
        XCTAssertEqual(payloads[1].sessionID, "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d")
        XCTAssertEqual(payloads[1].agentWorkingDirectory, "/tmp/project")
        XCTAssertEqual(payloads[1].agentTranscriptPath, "/tmp/project/transcript.jsonl")
    }

    func test_agy_adapter_maps_stop_fully_idle_to_idle_without_clearing_pid() throws {
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data("""
            {
              "hook_event_name": "Stop",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "workspacePaths": ["/tmp/project"],
              "fullyIdle": true
            }
            """.utf8),
            environment: agyAdapterEnvironment(pid: "4242")
        )

        XCTAssertEqual(payloads.map(\.state), [.idle])
        XCTAssertTrue(payloads.allSatisfy { $0.pidEvent == nil })
        XCTAssertEqual(payloads.first?.sessionID, "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d")
    }

    func test_agy_adapter_maps_ask_tool_to_needs_input() throws {
        let payloads = try AgentEventBridge.agyAdapter(
            data: Data("""
            {
              "hook_event_name": "PreToolUse",
              "conversationId": "cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
              "toolCall": {
                "name": "ask_question",
                "args": { "question": "Choose a deploy target?" }
              }
            }
            """.utf8),
            environment: agyAdapterEnvironment()
        )

        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Choose a deploy target?")
    }

    func test_grok_hooks_installer_uninstall_removes_new_layout() throws {
        let (_, hooksRoot) = try makeGrokHooksRoot()
        try GrokHooksInstaller.install(at: hooksRoot, cliPath: "/opt/zentty/bin/zentty")

        try GrokHooksInstaller.uninstall(at: hooksRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hookConfigURL(under: hooksRoot).path), "JSON config must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: forwarderScriptURL(under: hooksRoot).path), "forwarder script must be removed")
        let forwarderDir = hooksRoot.appendingPathComponent("zentty-status", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forwarderDir.path), "forwarder subdir must be removed when empty")
    }

    func test_grok_hooks_installer_uninstall_cleans_up_legacy_per_event_scripts() throws {
        // Users upgrading from earlier Zentty versions have the broken
        // per-event-subdir layout. Uninstall must mop those up so they don't
        // linger as dead files.
        let (_, hooksRoot) = try makeGrokHooksRoot()
        let legacyDir = hooksRoot.appendingPathComponent("PreToolUse", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyScript = legacyDir.appendingPathComponent("01-zentty-status.sh", isDirectory: false)
        let legacyContent = "#!/usr/bin/env bash\n# Marker: \(GrokHooksInstaller.hookMarker)\nexec foo\n"
        try legacyContent.write(to: legacyScript, atomically: true, encoding: .utf8)

        try GrokHooksInstaller.uninstall(at: hooksRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyScript.path), "legacy per-event script must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path), "empty legacy event dir must be removed")
    }

    func test_grok_hooks_installer_uninstall_preserves_user_scripts_in_legacy_event_dir() throws {
        // Even when cleaning up legacy artifacts, non-Zentty scripts that happen
        // to live alongside ours under `~/.grok/hooks/<Event>/` must survive.
        let (_, hooksRoot) = try makeGrokHooksRoot()
        let legacyDir = hooksRoot.appendingPathComponent("Stop", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let ourScript = legacyDir.appendingPathComponent("01-zentty-status.sh", isDirectory: false)
        try "#!/usr/bin/env bash\n# Marker: \(GrokHooksInstaller.hookMarker)\n".write(to: ourScript, atomically: true, encoding: .utf8)
        let userScript = legacyDir.appendingPathComponent("99-user-cleanup.sh", isDirectory: false)
        try "#!/usr/bin/env bash\necho user\n".write(to: userScript, atomically: true, encoding: .utf8)

        try GrokHooksInstaller.uninstall(at: hooksRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ourScript.path), "our marker-tagged script must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: userScript.path), "user-managed sibling script must survive")
    }

    func test_grok_hooks_installer_uninstall_strips_legacy_user_settings_entries_preserving_user_entries() throws {
        let (grokRoot, hooksRoot) = try makeGrokHooksRoot()
        let settingsURL = grokRoot.appendingPathComponent("user-settings.json", isDirectory: false)
        // Seed the legacy shape with one of our entries (recognised by marker)
        // alongside a user-managed entry.
        let legacyZenttyCommand = hooksRoot
            .appendingPathComponent("Stop", isDirectory: true)
            .appendingPathComponent("01-zentty-status.sh", isDirectory: false)
            .path
        let seeded: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "Stop": [
                    ["matcher": ".*", "hooks": [["type": "command", "command": legacyZenttyCommand]]],
                    ["matcher": ".*", "hooks": [["type": "command", "command": "/custom/user-stop.sh"]]],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: seeded, options: [.prettyPrinted]).write(to: settingsURL)

        try GrokHooksInstaller.uninstall(at: hooksRoot)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(object["theme"] as? String, "dark", "unrelated key must survive uninstall")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let stopEntries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = stopEntries.compactMap { entry -> String? in
            (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String ?? entry["command"] as? String
        }
        XCTAssertEqual(commands, ["/custom/user-stop.sh"], "only user-managed Stop entry should remain")
    }

    func test_grok_hooks_installer_uninstall_removes_legacy_plugin_directory() throws {
        let (grokRoot, hooksRoot) = try makeGrokHooksRoot()
        let pluginDir = grokRoot
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("zentty-status", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try "{}".write(
            to: pluginDir.appendingPathComponent("plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        try GrokHooksInstaller.uninstall(at: hooksRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginDir.path), "legacy plugin directory must be removed on uninstall")
    }

    func test_grok_hooks_installer_uninstall_legacy_hooks_paths_line_exact_not_substring() throws {
        // Unrelated lines that *contain* our hooks path as a prefix must
        // survive a legacy hooks-paths cleanup.
        let (grokRoot, hooksRoot) = try makeGrokHooksRoot()
        let pathsURL = grokRoot.appendingPathComponent("hooks-paths", isDirectory: false)
        let unrelatedPath = hooksRoot.path + "-extra"
        try (hooksRoot.path + "\n" + unrelatedPath + "\n").write(to: pathsURL, atomically: true, encoding: .utf8)

        try GrokHooksInstaller.uninstall(at: hooksRoot)

        if FileManager.default.fileExists(atPath: pathsURL.path) {
            let remaining = try String(contentsOf: pathsURL, encoding: .utf8).components(separatedBy: .newlines)
            XCTAssertTrue(remaining.contains(unrelatedPath), "unrelated path with our prefix must be preserved by uninstall")
            XCTAssertFalse(remaining.contains(hooksRoot.path), "our line must be removed")
        }
    }

    func test_agent_launch_bootstrap_builds_kimi_overlay_from_default_user_config() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-runtime")
        let homeDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-home")
        let userConfigURL = homeDirectory
            .appendingPathComponent(".kimi", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        try FileManager.default.createDirectory(
            at: userConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        default_model = "kimi-code/kimi-for-coding"
        hooks = []
        """
        try original.write(to: userConfigURL, atomically: true, encoding: .utf8)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": homeDirectory.path,
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kimi",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .kimi
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/kimi")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "kimi")
        XCTAssertEqual(plan.unsetEnvironment, [])
        XCTAssertEqual(plan.preLaunchActions, [])
        XCTAssertEqual(plan.arguments.count, 4)
        XCTAssertEqual(plan.arguments[0], "--config-file")
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["chat", "hello"])

        let overlayConfigURL = URL(fileURLWithPath: plan.arguments[1], isDirectory: false)
        XCTAssertTrue(overlayConfigURL.path.hasPrefix(runtimeDirectory.path))

        let overlayConfig = try String(contentsOf: overlayConfigURL, encoding: .utf8)
        XCTAssertTrue(overlayConfig.contains(#"default_model = "kimi-code/kimi-for-coding""#))
        XCTAssertTrue(overlayConfig.contains(#"hooks = ["#))
        XCTAssertTrue(overlayConfig.contains(#"command = "\"/tmp/zentty\" ipc agent-event --adapter=kimi""#))
        XCTAssertTrue(overlayConfig.contains(#"{ event = "Notification", command = "\"/tmp/zentty\" ipc agent-event --adapter=kimi""#))
        XCTAssertFalse(overlayConfig.contains(#"command = ""/tmp/zentty""#))

        let sourceConfig = try String(contentsOf: userConfigURL, encoding: .utf8)
        XCTAssertEqual(sourceConfig, original)
    }

    func test_agent_launch_bootstrap_builds_kimi_overlay_from_explicit_config_file() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-explicit-runtime")
        let sourceDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-explicit-source")
        let sourceConfigURL = sourceDirectory.appendingPathComponent("kimi.toml", isDirectory: false)
        let sourceConfig = """
        default_model = "kimi-k2"

        [[hooks]]
        event = "SessionStart"
        command = "echo existing"
        """
        try sourceConfig.write(to: sourceConfigURL, atomically: true, encoding: .utf8)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--config-file", sourceConfigURL.path, "chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kimi",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .kimi
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/kimi")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "kimi")
        XCTAssertEqual(plan.arguments.count, 4)
        XCTAssertEqual(plan.arguments[0], "--config-file")
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["chat", "hello"])
        XCTAssertNotEqual(plan.arguments[1], sourceConfigURL.path)

        let overlayConfig = try String(
            contentsOf: URL(fileURLWithPath: plan.arguments[1], isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(overlayConfig.contains(#"command = "echo existing""#))
        XCTAssertTrue(overlayConfig.contains(#"event = "SessionEnd""#))
        XCTAssertTrue(overlayConfig.contains(#"command = "\"/tmp/zentty\" ipc agent-event --adapter=kimi""#))
    }

    func test_agent_launch_bootstrap_builds_kimi_overlay_from_inline_config_argument() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-inline-runtime")
        let inlineConfig = """
        default_model = "kimi-code/kimi-for-coding"
        hooks = []
        """

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--config", inlineConfig, "chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kimi",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .kimi
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.arguments.count, 4)
        XCTAssertEqual(plan.arguments[0], "--config-file")
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["chat", "hello"])

        let overlayConfig = try String(
            contentsOf: URL(fileURLWithPath: plan.arguments[1], isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(overlayConfig.contains(#"default_model = "kimi-code/kimi-for-coding""#))
        XCTAssertTrue(overlayConfig.contains(#"hooks = ["#))
        XCTAssertTrue(overlayConfig.contains(#"command = "\"/tmp/zentty\" ipc agent-event --adapter=kimi""#))
    }

    func test_agent_launch_bootstrap_merges_kimi_overlay_into_existing_nonempty_inline_hooks_array() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-inline-hooks-runtime")
        let inlineConfig = """
        default_model = "kimi-code/kimi-for-coding"
        hooks = [{ event = "SessionStart", command = "echo user" }]
        """

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--config", inlineConfig, "chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kimi",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .kimi
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        let overlayConfig = try String(
            contentsOf: URL(fileURLWithPath: plan.arguments[1], isDirectory: false),
            encoding: .utf8
        )
        XCTAssertEqual(overlayConfig.components(separatedBy: "hooks = [").count, 2)
        XCTAssertTrue(overlayConfig.contains(#"command = "echo user""#))
        XCTAssertTrue(overlayConfig.contains(#"{ event = "SessionEnd", command = "\"/tmp/zentty\" ipc agent-event --adapter=kimi""#))
        XCTAssertFalse(overlayConfig.contains("[[hooks]]"))
    }

    func test_agent_launch_bootstrap_throws_for_missing_explicit_kimi_config_file() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-kimi-missing-runtime")
        let missingConfigURL = runtimeDirectory.appendingPathComponent("missing.toml", isDirectory: false)
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--config-file", missingConfigURL.path, "chat", "hello"],
            standardInput: nil,
            environment: [
                "HOME": NSHomeDirectory(),
                "ZENTTY_REAL_BINARY": "/usr/local/bin/kimi",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .kimi
        )

        XCTAssertThrowsError(
            try AgentLaunchBootstrap.makePlan(
                request: request,
                target: AgentIPCTarget(
                    windowID: WindowID("window-main"),
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("pane-main")
                ),
                runtimeDirectoryURL: runtimeDirectory
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, CocoaError.fileNoSuchFile.rawValue)
        }
    }

    func test_agent_launch_bootstrap_builds_gemini_system_settings_overlay_and_forces_notifications() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-gemini-runtime")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--model", "gemini-2.5-pro"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/gemini",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
            ],
            expectsResponse: true,
            tool: .gemini
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/gemini")
        XCTAssertEqual(plan.arguments, ["--model", "gemini-2.5-pro"])
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "gemini")

        let overlayPath = try XCTUnwrap(plan.setEnvironment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"])
        let overlayURL = URL(fileURLWithPath: overlayPath, isDirectory: false)
        let data = try Data(contentsOf: overlayURL)
        let jsonObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let general = try XCTUnwrap(jsonObject["general"] as? [String: Any])
        XCTAssertEqual(general["enableNotifications"] as? Bool, true)

        let hooks = try XCTUnwrap(jsonObject["hooks"] as? [String: Any])
        for eventName in ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "Notification", "BeforeTool"] {
            let groups = try XCTUnwrap(hooks[eventName] as? [[String: Any]], eventName)
            XCTAssertFalse(groups.isEmpty, eventName)
            let commands = groups.flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
            XCTAssertEqual(commands.count, 1, eventName)
            XCTAssertTrue(commands[0].contains(#""/tmp/zentty" gemini-hook"#), eventName)
        }
    }

    func test_agent_launch_bootstrap_escapes_special_shell_characters_in_gemini_hook_command() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-gemini-runtime-escaped")

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["chat"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/gemini",
                "ZENTTY_CLI_BIN": #"/tmp/Zentty $CLI `beta`"#,
            ],
            expectsResponse: true,
            tool: .gemini
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        let overlayPath = try XCTUnwrap(plan.setEnvironment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"])
        let data = try Data(contentsOf: URL(fileURLWithPath: overlayPath, isDirectory: false))
        let jsonObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(jsonObject["hooks"] as? [String: Any])
        let sessionStartGroups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = sessionStartGroups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(
            commands[0],
            #""/tmp/Zentty \$CLI \`beta\`" gemini-hook || echo '{}'"#
        )
    }

    func test_agent_launch_bootstrap_merges_existing_gemini_system_settings_without_duplicate_hook_commands() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-gemini-runtime-merge")
        let existingSettingsURL = runtimeDirectory.appendingPathComponent("enterprise-settings.json", isDirectory: false)
        try """
        {
          "general": {
            "vimMode": true
          },
          "hooks": {
            "SessionStart": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo existing",
                    "timeout": 1234
                  },
                  {
                    "type": "command",
                    "command": "\\\"/tmp/zentty\\\" gemini-hook || echo '{}'",
                    "timeout": 10000
                  }
                ]
              }
            ],
            "Notification": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo notify"
                  }
                ]
              }
            ]
          }
        }
        """.write(to: existingSettingsURL, atomically: true, encoding: .utf8)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["chat"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/gemini",
                "ZENTTY_CLI_BIN": "/tmp/zentty",
                "GEMINI_CLI_SYSTEM_SETTINGS_PATH": existingSettingsURL.path,
            ],
            expectsResponse: true,
            tool: .gemini
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )

        let overlayPath = try XCTUnwrap(plan.setEnvironment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"])
        let overlayURL = URL(fileURLWithPath: overlayPath, isDirectory: false)
        let data = try Data(contentsOf: overlayURL)
        let jsonObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let general = try XCTUnwrap(jsonObject["general"] as? [String: Any])
        XCTAssertEqual(general["vimMode"] as? Bool, true)
        XCTAssertEqual(general["enableNotifications"] as? Bool, true)

        let hooks = try XCTUnwrap(jsonObject["hooks"] as? [String: Any])
        let sessionStartGroups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let sessionStartCommands = sessionStartGroups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        XCTAssertEqual(sessionStartCommands.filter { $0 == "\"/tmp/zentty\" gemini-hook || echo '{}'" }.count, 1)
        XCTAssertTrue(sessionStartCommands.contains("echo existing"))

        let notificationGroups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let notificationCommands = notificationGroups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        XCTAssertTrue(notificationCommands.contains("echo notify"))
        XCTAssertEqual(notificationCommands.filter { $0 == "\"/tmp/zentty\" gemini-hook || echo '{}'" }.count, 1)
    }

    func test_agent_launch_bootstrap_builds_opencode_overlay_and_prelaunch_event() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-runtime")
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-opencode-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let sourceConfigDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-source")
        try FileManager.default.createDirectory(
            at: sourceConfigDirectory.appendingPathComponent("markers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "user-config".write(
            to: sourceConfigDirectory
                .appendingPathComponent("markers", isDirectory: true)
                .appendingPathComponent("user.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/opencode",
                "ZENTTY_OPENCODE_BASE_CONFIG_DIR": sourceConfigDirectory.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot))
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/opencode")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "opencode")
        let overlayConfigDirectory = try XCTUnwrap(plan.setEnvironment["OPENCODE_CONFIG_DIR"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: overlayConfigDirectory, isDirectory: true)
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: overlayConfigDirectory, isDirectory: true)
                    .appendingPathComponent("markers", isDirectory: true)
                    .appendingPathComponent("user.txt", isDirectory: false)
                    .path
            )
        )
        let action = try XCTUnwrap(plan.preLaunchActions.first)
        XCTAssertEqual(action.subcommand, "agent-event")
        XCTAssertTrue(action.standardInput?.contains(AgentIPCProtocol.selfPIDPlaceholder) == true)
    }

    func test_agent_launch_bootstrap_resolves_real_opencode_binary_from_node_shim() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-real-binary-runtime")
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-opencode-real-binary-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let wrapperRoot = try makeTemporaryDirectory(named: "agent-launch-opencode-real-binary-wrapper-root")
        let binDirectory = wrapperRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let shimURL = binDirectory.appendingPathComponent("opencode", isDirectory: false)
        try "#!/usr/bin/env node\n".write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        let realBinaryURL = binDirectory.appendingPathComponent(".opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realBinaryURL.path)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": shimURL.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot))
        )

        XCTAssertEqual(plan.executablePath, realBinaryURL.path)
    }

    func test_agent_launch_bootstrap_resolves_real_opencode_binary_from_symlink() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-symlink-runtime")
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-opencode-symlink-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let shimRoot = try makeTemporaryDirectory(named: "agent-launch-opencode-symlink-shim-root")
        let binDirectory = shimRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let realRoot = try makeTemporaryDirectory(named: "agent-launch-opencode-symlink-real-root")
        let realBinDirectory = realRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: realBinDirectory, withIntermediateDirectories: true)

        let realShimURL = realBinDirectory.appendingPathComponent("opencode", isDirectory: false)
        try "#!/usr/bin/env node\n".write(to: realShimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realShimURL.path)

        let realBinaryURL = realBinDirectory.appendingPathComponent(".opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: realBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realBinaryURL.path)

        let shimURL = binDirectory.appendingPathComponent("opencode", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: shimURL, withDestinationURL: realShimURL)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": shimURL.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot))
        )

        XCTAssertEqual(plan.executablePath, realBinaryURL.path)
    }

    func test_agent_launch_bootstrap_isolates_opencode_xdg_config_and_state_when_sync_enabled() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-sync-runtime")
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-opencode-sync-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let sourceConfigDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-sync-source")
        try FileManager.default.createDirectory(
            at: sourceConfigDirectory.appendingPathComponent("markers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "user-config".write(
            to: sourceConfigDirectory
                .appendingPathComponent("markers", isDirectory: true)
                .appendingPathComponent("user.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let sourceStateHomeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-sync-state-home")
        let sourceStateDirectory = sourceStateHomeDirectory.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceStateDirectory, withIntermediateDirectories: true)
        let kvData = try XCTUnwrap(
            try? JSONSerialization.data(
                withJSONObject: [
                    "theme": "dracula",
                    "theme_mode": "dark",
                    "theme_mode_lock": true,
                    "unrelated": "preserved",
                ],
                options: [.sortedKeys]
            )
        )
        try kvData.write(
            to: sourceStateDirectory.appendingPathComponent("kv.json", isDirectory: false),
            options: .atomic
        )

        var appConfig = AppConfig.default
        appConfig.appearance.syncOpenCodeThemeWithTerminal = true

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/opencode",
                "ZENTTY_OPENCODE_BASE_CONFIG_DIR": sourceConfigDirectory.path,
                "XDG_STATE_HOME": sourceStateHomeDirectory.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            appConfigProvider: { appConfig }
        )

        let overlayConfigDirectory = URL(
            fileURLWithPath: try XCTUnwrap(plan.setEnvironment["OPENCODE_CONFIG_DIR"]),
            isDirectory: true
        )
        let xdgConfigHome: String = try XCTUnwrap(plan.setEnvironment["XDG_CONFIG_HOME"])
        let xdgStateHome: String = try XCTUnwrap(plan.setEnvironment["XDG_STATE_HOME"])
        let opencodeConfigDirectory: String = try XCTUnwrap(plan.setEnvironment["OPENCODE_CONFIG_DIR"])
        let opencodeTUIConfig: String = try XCTUnwrap(plan.setEnvironment["OPENCODE_TUI_CONFIG"])
        XCTAssertEqual(overlayConfigDirectory.path, URL(fileURLWithPath: xdgConfigHome, isDirectory: true).appendingPathComponent("opencode", isDirectory: true).path)
        XCTAssertEqual(opencodeConfigDirectory, overlayConfigDirectory.path)
        XCTAssertEqual(
            opencodeTUIConfig,
            overlayConfigDirectory.appendingPathComponent("tui.json", isDirectory: false).path
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("markers", isDirectory: true)
                    .appendingPathComponent("user.txt", isDirectory: false)
                    .path
            )
        )

        let overlayStateDirectory = URL(fileURLWithPath: xdgStateHome, isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        let overlayKVData = try Data(contentsOf: overlayStateDirectory.appendingPathComponent("kv.json", isDirectory: false))
        let overlayKV = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: overlayKVData) as? [String: Any]
        )
        XCTAssertNil(overlayKV["theme"])
        XCTAssertNil(overlayKV["theme_mode"])
        XCTAssertNil(overlayKV["theme_mode_lock"])
        XCTAssertEqual(overlayKV["unrelated"] as? String, "preserved")
    }

    func test_agent_launch_bootstrap_uses_xdg_config_home_as_default_opencode_source() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-xdg-source-runtime")
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-opencode-xdg-source-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let xdgConfigHome = try makeTemporaryDirectory(named: "agent-launch-opencode-xdg-config-home")
        let sourceConfigDirectory = xdgConfigHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceConfigDirectory.appendingPathComponent("markers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "from-xdg".write(
            to: sourceConfigDirectory
                .appendingPathComponent("markers", isDirectory: true)
                .appendingPathComponent("user.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var appConfig = AppConfig.default
        appConfig.appearance.syncOpenCodeThemeWithTerminal = true

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/opencode",
                "XDG_CONFIG_HOME": xdgConfigHome.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            appConfigProvider: { appConfig }
        )

        let overlayConfigDirectory = URL(
            fileURLWithPath: try XCTUnwrap(plan.setEnvironment["OPENCODE_CONFIG_DIR"]),
            isDirectory: true
        )
        XCTAssertEqual(plan.setEnvironment["ZENTTY_OPENCODE_BASE_CONFIG_DIR"], sourceConfigDirectory.path)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("markers", isDirectory: true)
                    .appendingPathComponent("user.txt", isDirectory: false)
                    .path
            )
        )
    }

    func test_agent_launch_bootstrap_excludes_source_opencode_themes_when_sync_enabled() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-theme-quarantine-runtime")
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-opencode-theme-quarantine-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: pluginDirectory.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let sourceConfigDirectory = try makeTemporaryDirectory(named: "agent-launch-opencode-theme-quarantine-source")
        try FileManager.default.createDirectory(
            at: sourceConfigDirectory.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"{"theme": {}}"#.write(
            to: sourceConfigDirectory
                .appendingPathComponent("themes", isDirectory: true)
                .appendingPathComponent("stale-user-theme.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: sourceConfigDirectory.appendingPathComponent("markers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "preserved".write(
            to: sourceConfigDirectory
                .appendingPathComponent("markers", isDirectory: true)
                .appendingPathComponent("user.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var appConfig = AppConfig.default
        appConfig.appearance.syncOpenCodeThemeWithTerminal = true

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["run", "hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/opencode",
                "ZENTTY_OPENCODE_BASE_CONFIG_DIR": sourceConfigDirectory.path,
            ],
            expectsResponse: true,
            tool: .opencode
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            appConfigProvider: { appConfig }
        )

        let overlayConfigDirectory = URL(
            fileURLWithPath: try XCTUnwrap(plan.setEnvironment["OPENCODE_CONFIG_DIR"]),
            isDirectory: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent("stale-user-theme.json", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("themes", isDirectory: true)
                    .appendingPathComponent("zentty-synced.json", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: overlayConfigDirectory
                    .appendingPathComponent("markers", isDirectory: true)
                    .appendingPathComponent("user.txt", isDirectory: false)
                    .path
            )
        )
    }

    func test_agent_launch_bootstrap_builds_amp_plan_with_plugin_and_launch_snapshot() throws {
        let home = try makeTemporaryDirectory(named: "agent-launch-amp-home")
        let userPluginURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("user-plugin.ts", isDirectory: false)
        try FileManager.default.createDirectory(at: userPluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// user plugin\n".write(to: userPluginURL, atomically: true, encoding: .utf8)
        let userSettingsURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        try #"{"amp.notifications.enabled":false}"#
            .write(to: userSettingsURL, atomically: true, encoding: .utf8)
        let userAgentsURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("AGENTS.md", isDirectory: false)
        try "personal amp guidance\n".write(to: userAgentsURL, atomically: true, encoding: .utf8)
        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-amp-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        let pluginURL = pluginDirectory.appendingPathComponent(AmpPluginInstaller.pluginFileName, isDirectory: false)
        try "// \(AmpPluginInstaller.ownershipMarker)\nexport default function ampPlugin() {}\n"
            .write(to: pluginURL, atomically: true, encoding: .utf8)

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--mode", "smart", "--execute", "ignored"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/amp",
                "HOME": home.path,
            ],
            expectsResponse: true,
            tool: .amp
        )

        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-amp-runtime")
        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory,
            bundle: try XCTUnwrap(Bundle(url: bundleRoot))
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/amp")
        XCTAssertEqual(plan.arguments, ["--mode", "smart", "--execute", "ignored"])
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "amp")
        XCTAssertEqual(plan.setEnvironment["PLUGINS"], "all")
        XCTAssertNil(plan.setEnvironment["HOME"])
        XCTAssertNil(plan.setEnvironment["XDG_CONFIG_HOME"])
        XCTAssertNil(plan.setEnvironment["AMP_SETTINGS_FILE"])
        XCTAssertNil(plan.setEnvironment["ZENTTY_AMP_RESUME_ARGUMENTS_JSON"])
        XCTAssertEqual(plan.preLaunchActions.count, 2)
        XCTAssertEqual(plan.preLaunchActions.map(\.subcommand), ["agent-event", "agent-event"])
        XCTAssertTrue(plan.preLaunchActions[0].standardInput?.contains("\"event\":\"session.start\"") == true)
        XCTAssertTrue(plan.preLaunchActions[1].standardInput?.contains("\"event\":\"agent.running\"") == true)
        XCTAssertTrue(plan.preLaunchActions[0].standardInput?.contains("\"name\":\"Amp\"") == true)
        XCTAssertTrue(plan.preLaunchActions[1].standardInput?.contains("\"arguments\":[]") == true)

        let installedPluginURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(AmpPluginInstaller.pluginFileName, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedPluginURL.path))
        XCTAssertTrue(try String(contentsOf: installedPluginURL, encoding: .utf8).contains(AmpPluginInstaller.ownershipMarker))
        let userPluginStillPresentURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("user-plugin.ts", isDirectory: false)
        XCTAssertEqual(try String(contentsOf: userPluginStillPresentURL, encoding: .utf8), "// user plugin\n")

        let settingsStillPresentURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        XCTAssertEqual(try String(contentsOf: settingsStillPresentURL, encoding: .utf8), try String(contentsOf: userSettingsURL, encoding: .utf8))

        let agentsStillPresentURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("AGENTS.md", isDirectory: false)
        XCTAssertEqual(try String(contentsOf: agentsStillPresentURL, encoding: .utf8), try String(contentsOf: userAgentsURL, encoding: .utf8))
    }

    func test_agent_launch_bootstrap_amp_refuses_to_overwrite_unmarked_plugin() throws {
        let home = try makeTemporaryDirectory(named: "agent-launch-amp-conflict-home")
        let installedPluginURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(AmpPluginInstaller.pluginFileName, isDirectory: false)
        try FileManager.default.createDirectory(at: installedPluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// user-owned plugin\n".write(to: installedPluginURL, atomically: true, encoding: .utf8)

        let bundleRoot = try makeTemporaryBundleRoot(named: "agent-launch-amp-conflict-bundle")
        let pluginDirectory = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try "// \(AmpPluginInstaller.ownershipMarker)\n"
            .write(
                to: pluginDirectory.appendingPathComponent(AmpPluginInstaller.pluginFileName, isDirectory: false),
                atomically: true,
                encoding: .utf8
            )

        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["hello"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/amp",
                "HOME": home.path,
            ],
            expectsResponse: true,
            tool: .amp
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: try makeTemporaryDirectory(named: "agent-launch-amp-conflict-runtime"),
            bundle: try XCTUnwrap(Bundle(url: bundleRoot))
        )

        XCTAssertEqual(try String(contentsOf: installedPluginURL, encoding: .utf8), "// user-owned plugin\n")
        XCTAssertNil(plan.setEnvironment["PLUGINS"])
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "amp")
    }

    func test_agent_launch_bootstrap_amp_respects_hooks_disabled() throws {
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: ["--mode", "smart"],
            standardInput: nil,
            environment: [
                "ZENTTY_REAL_BINARY": "/usr/local/bin/amp",
                "ZENTTY_AMP_HOOKS_DISABLED": "1",
            ],
            expectsResponse: true,
            tool: .amp
        )

        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: try makeTemporaryDirectory(named: "agent-launch-amp-disabled-runtime"),
            bundle: try makeTemporaryBundle(named: "agent-launch-amp-disabled-bundle")
        )

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/amp")
        XCTAssertEqual(plan.arguments, ["--mode", "smart"])
        XCTAssertTrue(plan.setEnvironment.isEmpty)
        XCTAssertTrue(plan.preLaunchActions.isEmpty)
    }

    func test_agent_ipc_authentication_is_pane_scoped() {
        let authentication = AgentIPCAuthentication(secret: "unit-test-secret")

        let token = authentication.token(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main")
        )

        XCTAssertTrue(authentication.isValid(
            token: token,
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main")
        ))
        XCTAssertFalse(authentication.isValid(
            token: token,
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-other")
        ))
    }

    func test_agent_ipc_message_canonicalized_for_target_overwrites_routing_environment_and_arguments() {
        let message = AgentIPCMessage(
            subcommand: "agent-signal",
            arguments: [
                "lifecycle",
                "idle",
                "--window-id", "window-spoofed",
                "--worklane-id", "worklane-spoofed",
                "--pane-id", "pane-spoofed",
                "--tool", "Codex",
            ],
            standardInput: nil,
            environment: [
                "ZENTTY_WINDOW_ID": "window-spoofed",
                "ZENTTY_WORKLANE_ID": "worklane-spoofed",
                "ZENTTY_PANE_ID": "pane-spoofed",
                "ZENTTY_CODEX_PID": "4242",
                "UNRELATED_FLAG": "preserved",
            ]
        )

        let canonical = message.canonicalized(for: AgentIPCTarget(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("pane-main")
        ))

        XCTAssertEqual(canonical.environment["ZENTTY_WINDOW_ID"], "window-main")
        XCTAssertEqual(canonical.environment["ZENTTY_WORKLANE_ID"], "worklane-main")
        XCTAssertEqual(canonical.environment["ZENTTY_PANE_ID"], "pane-main")
        XCTAssertEqual(canonical.environment["ZENTTY_CODEX_PID"], "4242")
        XCTAssertEqual(canonical.environment["UNRELATED_FLAG"], "preserved")
        XCTAssertFalse(canonical.arguments.contains("window-spoofed"))
        XCTAssertFalse(canonical.arguments.contains("worklane-spoofed"))
        XCTAssertFalse(canonical.arguments.contains("pane-spoofed"))
        XCTAssertEqual(Array(canonical.arguments.suffix(6)), [
            "--window-id", "window-main",
            "--worklane-id", "worklane-main",
            "--pane-id", "pane-main",
        ])
    }

    func test_agent_status_command_uses_env_defaults_and_round_trips_notification_payload() throws {
        let command = try AgentStatusCommand.parse(
            arguments: [
                "zentty-agent",
                "needs-input",
                "--tool", "Claude Code",
                "--text", "Claude is waiting for your input",
                "--artifact-kind", "pull-request",
                "--artifact-label", "PR #42",
                "--artifact-url", "https://example.com/pr/42",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.worklaneID, WorklaneID("worklane-main"))
        XCTAssertEqual(command.payload.paneID, PaneID("worklane-main-shell"))
        XCTAssertEqual(command.payload.state, .needsInput)
        XCTAssertEqual(command.payload.toolName, "Claude Code")
        XCTAssertEqual(command.payload.text, "Claude is waiting for your input")
        XCTAssertEqual(command.payload.artifactKind, .pullRequest)

        let userInfo = try XCTUnwrap(command.payload.notificationUserInfo)
        let decodedPayload = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decodedPayload, command.payload)
    }

    func test_agent_signal_command_parses_lifecycle_interaction_kind() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "lifecycle",
                "needs-input",
                "--tool", "Codex",
                "--text", "Plan mode prompt: Implement this plan?",
                "--interaction-kind", "approval",
                "--session-id", "session-1",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.state, .needsInput)
        XCTAssertEqual(command.payload.toolName, "Codex")
        XCTAssertEqual(command.payload.text, "Plan mode prompt: Implement this plan?")
        XCTAssertEqual(command.payload.interactionKind, .approval)
        XCTAssertEqual(command.payload.sessionID, "session-1")
    }

    func test_agent_status_payload_decodes_legacy_notification_defaults_when_kind_and_origin_are_omitted() throws {
        let payload = try AgentStatusPayload(
            userInfo: [
                "worklaneID": "worklane-main",
                "paneID": "worklane-main-shell",
                "state": "running",
                "toolName": "Claude Code",
            ]
        )

        XCTAssertEqual(payload.signalKind, .lifecycle)
        XCTAssertEqual(payload.origin, .compatibility)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Claude Code")
    }

    func test_agent_status_payload_decodes_legacy_completed_state_as_idle() throws {
        let payload = try AgentStatusPayload(
            userInfo: [
                "worklaneID": "worklane-main",
                "paneID": "worklane-main-shell",
                "state": "completed",
                "toolName": "Codex",
            ]
        )

        XCTAssertEqual(payload.state, .idle)
    }

    func test_agent_status_command_accepts_legacy_completed_alias() throws {
        let command = try AgentStatusCommand.parse(
            arguments: ["agent-status", "completed", "--tool", "Codex"],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.state, .idle)
        XCTAssertEqual(command.payload.toolName, "Codex")
    }

    func test_agent_signal_command_accepts_legacy_completed_alias_and_session_id() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "agent-signal",
                "lifecycle",
                "completed",
                "--tool", "Codex",
                "--session-id", "session-1",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.state, .idle)
        XCTAssertEqual(command.payload.toolName, "Codex")
        XCTAssertEqual(command.payload.sessionID, "session-1")
    }

    func test_agent_signal_command_parses_local_pane_context_payload() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "local",
                "--path", "/Users/peter/src/zentty",
                "--home", "/Users/peter",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertEqual(
            command.payload.paneContext,
            PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: nil,
                host: nil
            )
        )
    }

    func test_agent_signal_command_parses_local_pane_context_git_branch() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "local",
                "--path", "/Users/peter/src/zentty",
                "--home", "/Users/peter",
                "--git-branch", "feature/review-band",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertEqual(
            command.payload.paneContext,
            PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: nil,
                host: nil,
                gitBranch: "feature/review-band"
            )
        )
    }

    func test_agent_status_payload_round_trips_pane_context_git_branch() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .paneContext,
            state: nil,
            paneContext: PaneShellContext(
                scope: .local,
                path: "/Users/peter/src/zentty",
                home: "/Users/peter",
                user: "peter",
                host: "mbp",
                gitBranch: "feature/review-band"
            ),
            origin: .shell,
            toolName: nil,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decodedPayload = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decodedPayload, payload)
    }

    func test_agent_signal_command_parses_remote_pane_context_payload() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "remote",
                "--path", "/home/peter/project",
                "--home", "/home/peter",
                "--user", "peter",
                "--host", "gilfoyle",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertEqual(
            command.payload.paneContext,
            PaneShellContext(
                scope: .remote,
                path: "/home/peter/project",
                home: "/home/peter",
                user: "peter",
                host: "gilfoyle"
            )
        )
    }

    func test_agent_signal_command_parses_pane_context_clear_payload() throws {
        let command = try AgentSignalCommand.parse(
            arguments: [
                "zentty-agent",
                "agent-signal",
                "pane-context",
                "clear",
            ],
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(command.payload.signalKind, .paneContext)
        XCTAssertNil(command.payload.paneContext)
        XCTAssertTrue(command.payload.clearsPaneContext)
    }

    func test_agent_signal_command_rejects_missing_pane_context_scope() {
        XCTAssertThrowsError(
            try AgentSignalCommand.parse(
                arguments: [
                    "zentty-agent",
                    "agent-signal",
                    "pane-context",
                ],
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            )
        )
    }

    func test_notification_coordinator_fires_once_per_attention_state_entry() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        let needsInputWorklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .needsInput,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        coordinator.update(
            windowID: windowID,
            worklanes: [needsInputWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        coordinator.update(
            windowID: windowID,
            worklanes: [needsInputWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)

        let clearedWorklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )
        coordinator.update(
            windowID: windowID,
            worklanes: [clearedWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        coordinator.update(
            windowID: windowID,
            worklanes: [needsInputWorklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 2)
    }

    func test_claude_hook_notification_maps_to_needs_input_payload() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(
            payload,
            AgentStatusPayload(
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("worklane-main-shell"),
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Claude Code",
                text: "Claude is waiting for your input",
                lifecycleEvent: .update,
                interactionKind: .genericInput,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
    }

    func test_claude_parse_input_preserves_transcript_path() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project","transcript_path":"/tmp/claude/session-1.jsonl"}
            """.utf8)
        )

        XCTAssertEqual(input.sessionID, "session-1")
        XCTAssertEqual(input.cwd, "/tmp/project")
        XCTAssertEqual(input.transcriptPath, "/tmp/claude/session-1.jsonl")
    }

    func test_claude_hook_notification_stays_generic_input_when_message_mentions_approval() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your approval"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .genericInput)
        XCTAssertNotEqual(payload.interactionKind, .approval)
    }

    func test_claude_hook_parse_input_reads_notification_type() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input","notification_type":"idle_prompt"}
            """.utf8)
        )

        XCTAssertEqual(input.hookEventName, "Notification")
        XCTAssertEqual(input.sessionID, "session-1")
        XCTAssertEqual(input.message, "Claude is waiting for your input")
        XCTAssertEqual(input.notificationType, "idle_prompt")
    }

    func test_claude_hook_idle_prompt_notification_transitions_to_idle() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input","notification_type":"idle_prompt"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertEqual(payloads.count, 1)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.lifecycleEvent, .update)
        XCTAssertEqual(payload.sessionID, "session-1")
    }

    func test_claude_hook_permission_request_maps_to_needs_input_payload() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"PermissionRequest","session_id":"session-1","message":"Allow file write?"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "Claude Code")
        XCTAssertEqual(payload.text, "Allow file write?")
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.confidence, .explicit)
    }

    func test_claude_hook_ask_user_question_with_options_maps_to_decision_payload() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?",
                    "options":[
                      {"label":"Yes"},
                      {"label":"No"}
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
    }

    func test_claude_hook_ask_user_question_without_options_maps_to_decision_payload() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?"
                  }
                ]
              }
            }
            """.utf8)
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?")
    }

    func test_claude_hook_permission_request_for_ask_user_question_stays_decision() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let preToolUse = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?",
                    "options":[
                      {"label":"Yes"},
                      {"label":"No"}
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )
        _ = try AgentEventBridge.claudeMakePayloads(
            from: preToolUse,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        let permissionRequest = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PermissionRequest",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion"
            }
            """.utf8)
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: permissionRequest,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
    }

    func test_claude_hook_generic_notification_does_not_replace_permission_request_copy() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let permissionRequest = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"PermissionRequest","session_id":"session-1","message":"Claude needs your approval"}
            """.utf8)
        )
        let notification = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your attention"}
            """.utf8)
        )

        let permissionPayload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: permissionRequest,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )
        let notificationPayload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: notification,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(permissionPayload.text, "Claude needs your approval")
        XCTAssertEqual(notificationPayload.text, "Claude needs your approval")
    }

    func test_claude_hook_generic_approval_notification_does_not_relabel_explicit_decision_prompt() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242,
            lastHumanMessage: "Choose one",
            lastInteractionKind: .decision
        )

        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your approval before continuing"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Choose one")
    }

    func test_claude_hook_ask_user_question_replaces_prior_explicit_approval_copy_when_kind_changes() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242,
            lastHumanMessage: "Claude needs your approval",
            lastInteractionKind: .approval
        )

        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?",
                    "options":[
                      {"label":"Yes"},
                      {"label":"No"}
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
    }

    func test_claude_hook_session_start_records_mapping_and_emits_pid_attach() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project","transcript_path":"/tmp/claude/session-1.jsonl"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()

        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "ZENTTY_CLAUDE_PID": "4242",
            ],
            sessionStore: store
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: 4242,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: "Claude Code",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
            ]
        )

        let record = try XCTUnwrap(store.lookup(sessionID: "session-1"))
        XCTAssertEqual(record.worklaneID, WorklaneID("worklane-main"))
        XCTAssertEqual(record.paneID, PaneID("worklane-main-shell"))
        XCTAssertEqual(record.cwd, "/tmp/project")
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.transcriptPath, "/tmp/claude/session-1.jsonl")
    }

    func test_claude_hook_notification_uses_persisted_session_target_not_current_env() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude is waiting for your input"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-a"),
            paneID: PaneID("pane-a"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-b",
                    "ZENTTY_PANE_ID": "pane-b",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.worklaneID, WorklaneID("worklane-a"))
        XCTAssertEqual(payload.paneID, PaneID("pane-a"))
    }

    func test_claude_hook_pre_tool_use_ask_user_question_with_options_emits_explicit_decision_payload_and_persists_richer_message() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let preToolUse = try AgentEventBridge.claudeParseInput(
            Data("""
            {
              "hook_event_name":"PreToolUse",
              "session_id":"session-1",
              "tool_name":"AskUserQuestion",
              "tool_input":{
                "questions":[
                  {
                    "question":"Ship this?",
                    "options":[
                      {"label":"Yes"},
                      {"label":"No"}
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )

        let preToolUsePayload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
            from: preToolUse,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        ).first
        )

        XCTAssertEqual(preToolUsePayload.state, .needsInput)
        XCTAssertEqual(preToolUsePayload.interactionKind, .decision)
        XCTAssertEqual(preToolUsePayload.text, "Ship this?\n[Yes] [No]")

        let notification = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Claude needs your input"}
            """.utf8)
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: notification,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.text, "Ship this?\n[Yes] [No]")
        XCTAssertEqual(payload.interactionKind, .decision)
    }

    func test_agent_status_center_delivers_payloads_on_main_actor() {
        let instanceID = "instance-\(UUID().uuidString.lowercased())"
        let center = AgentStatusCenter(instanceID: instanceID)
        // Use test-only IDs to avoid leaking a real distributed notification
        // into a running Zentty instance (which uses "worklane-main" by default).
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("test-status-center"),
            paneID: PaneID("test-status-center-shell"),
            state: .needsInput,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: "Claude needs your approval",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        let deliveredOnMain = expectation(description: "payload delivered on main actor")

        center.onPayload = { receivedPayload in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(receivedPayload, payload)
            deliveredOnMain.fulfill()
        }
        center.start()

        DispatchQueue.global(qos: .userInitiated).async {
            DistributedNotificationCenter.default().postNotificationName(
                AgentStatusTransport.notificationName(instanceID: instanceID),
                object: nil,
                userInfo: payload.notificationUserInfo,
                deliverImmediately: true
            )
        }

        wait(for: [deliveredOnMain], timeout: 2)
    }

    func test_agent_status_center_filters_notifications_by_instance_id() {
        let instanceID = "instance-\(UUID().uuidString.lowercased())"
        let otherInstanceID = "instance-\(UUID().uuidString.lowercased())"
        let center = AgentStatusCenter(instanceID: instanceID)
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("test-status-scope"),
            paneID: PaneID("test-status-scope-shell"),
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: "Working",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
        let unexpectedDelivery = expectation(description: "other scoped notification ignored")
        unexpectedDelivery.isInverted = true
        let expectedDelivery = expectation(description: "matching scoped notification delivered")

        center.onPayload = { receivedPayload in
            XCTAssertEqual(receivedPayload, payload)
            expectedDelivery.fulfill()
            unexpectedDelivery.fulfill()
        }
        center.start()

        DistributedNotificationCenter.default().postNotificationName(
            AgentStatusTransport.notificationName(instanceID: otherInstanceID),
            object: nil,
            userInfo: payload.notificationUserInfo,
            deliverImmediately: true
        )

        wait(for: [unexpectedDelivery], timeout: 0.3)

        DistributedNotificationCenter.default().postNotificationName(
            AgentStatusTransport.notificationName(instanceID: instanceID),
            object: nil,
            userInfo: payload.notificationUserInfo,
            deliverImmediately: true
        )

        wait(for: [expectedDelivery], timeout: 2)
    }

    func test_worklane_session_environment_sets_agent_status_instance_id() {
        let windowID = WindowID("window-main")
        let worklaneID = WorklaneID("worklane-main")
        let paneID = PaneID("pane-main")

        let environment = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            processEnvironment: [:]
        )

        XCTAssertEqual(
            environment[AgentStatusTransport.instanceIDEnvironmentKey],
            AgentIPCServer.shared.instanceID
        )
    }

    func test_claude_hook_pre_tool_use_clears_waiting_and_restores_running() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"PreToolUse","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.worklaneID, WorklaneID("worklane-main"))
        XCTAssertEqual(payload.paneID, PaneID("worklane-main-shell"))
    }

    func test_claude_hook_prompt_submit_maps_to_running_payload() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"UserPromptSubmit","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Claude Code")
    }

    func test_claude_hook_stop_maps_to_idle_without_clearing_pid_mapping() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Stop","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: 4242
        )

        let payload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: input,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ],
                sessionStore: store
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.lifecycleEvent, .update)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Claude Code")
        XCTAssertEqual(try store.lookup(sessionID: "session-1")?.pid, 4242)
    }

    func test_codex_hook_prompt_submit_maps_to_running_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.codexAdapter(
                data: Data("""
                {"hook_event_name":"UserPromptSubmit","session_id":"session-1","cwd":"/tmp/project"}
                """.utf8),
                defaultEventName: nil,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.lifecycleEvent, .toolActivity)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_codex_hook_pre_tool_use_maps_to_running_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.codexAdapter(
                data: Data("""
                {"hook_event_name":"PreToolUse","session_id":"session-1","cwd":"/tmp/project"}
                """.utf8),
                defaultEventName: nil,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.lifecycleEvent, .toolActivity)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_codex_hook_post_tool_use_maps_to_running_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.codexAdapter(
                data: Data("""
                {"hook_event_name":"PostToolUse","session_id":"session-1","cwd":"/tmp/project"}
                """.utf8),
                defaultEventName: nil,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.lifecycleEvent, .toolActivity)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_codex_hook_permission_request_for_ask_user_question_maps_to_question_text() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.codexAdapter(
                data: Data("""
                {"hook_event_name":"PermissionRequest","session_id":"session-1","tool_name":"askuserquestion","tool_input":{"questions":[{"question":"Which season do you like most?","options":[{"label":"Spring"},{"label":"Autumn"}]}]}}
                """.utf8),
                defaultEventName: nil,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.lifecycleEvent, .update)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
        XCTAssertEqual(payload.text, "Which season do you like most?\n[Spring] [Autumn]")
        XCTAssertEqual(payload.interactionKind, .decision)
    }

    func test_codex_hook_permission_request_for_bash_stays_approval() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.codexAdapter(
                data: Data("""
                {"hook_event_name":"PermissionRequest","session_id":"session-1","tool_name":"Bash","tool_input":{"command":"printf ok"}}
                """.utf8),
                defaultEventName: nil,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.text, "Codex needs your approval")
        XCTAssertEqual(payload.interactionKind, .approval)
    }

    func test_codex_hook_session_start_emits_session_scoped_pid_attach_and_starting_payloads() throws {
        let payloads = try AgentEventBridge.codexAdapter(
            data: Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project"}
            """.utf8),
            defaultEventName: nil,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "ZENTTY_CODEX_PID": "4242",
            ]
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: 4242,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: "Codex",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .lifecycle,
                    state: .starting,
                    origin: .explicitHook,
                    toolName: "Codex",
                    text: nil,
                    lifecycleEvent: .update,
                    confidence: .explicit,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: "/tmp/project"
                ),
            ]
        )
    }

    func test_codex_hook_stop_maps_to_idle_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.codexAdapter(
                data: Data("""
                {"hook_event_name":"Stop","session_id":"session-1","last_assistant_message":"Done"}
                """.utf8),
                defaultEventName: nil,
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.lifecycleEvent, .turnComplete)
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
    }

    func test_gemini_hook_session_start_emits_pid_attach_and_starting_payloads() throws {
        let payloads = try AgentEventBridge.geminiAdapter(
            data: Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project"}
            """.utf8),
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "ZENTTY_GEMINI_PID": "4242",
            ]
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: 4242,
                    pidEvent: .attach,
                    origin: .explicitHook,
                    toolName: "Gemini",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .lifecycle,
                    state: .starting,
                    origin: .explicitHook,
                    toolName: "Gemini",
                    text: nil,
                    lifecycleEvent: .update,
                    confidence: .explicit,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil,
                    agentWorkingDirectory: "/tmp/project"
                ),
            ]
        )
    }

    func test_gemini_hook_before_agent_maps_to_running_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.geminiAdapter(
                data: Data("""
                {"hook_event_name":"BeforeAgent","session_id":"session-1","cwd":"/tmp/project"}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Gemini")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_gemini_hook_before_tool_restores_running_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.geminiAdapter(
                data: Data("""
                {"hook_event_name":"BeforeTool","session_id":"session-1","cwd":"/tmp/project","tool_name":"WriteFile"}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Gemini")
        XCTAssertEqual(payload.sessionID, "session-1")
    }

    func test_gemini_hook_after_agent_maps_to_idle_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.geminiAdapter(
                data: Data("""
                {"hook_event_name":"AfterAgent","session_id":"session-1","cwd":"/tmp/project"}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.toolName, "Gemini")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_gemini_hook_session_end_clears_status_and_pid_mapping() throws {
        let payloads = try AgentEventBridge.geminiAdapter(
            data: Data("""
            {"hook_event_name":"SessionEnd","session_id":"session-1"}
            """.utf8),
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(
            payloads,
            [
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .lifecycle,
                    state: nil,
                    origin: .explicitHook,
                    toolName: "Gemini",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
                AgentStatusPayload(
                    worklaneID: WorklaneID("worklane-main"),
                    paneID: PaneID("worklane-main-shell"),
                    signalKind: .pid,
                    state: nil,
                    pid: nil,
                    pidEvent: .clear,
                    origin: .explicitHook,
                    toolName: "Gemini",
                    text: nil,
                    sessionID: "session-1",
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                ),
            ]
        )
    }

    func test_gemini_hook_tool_permission_notification_maps_to_needs_input_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.geminiAdapter(
                data: Data("""
                {"hook_event_name":"Notification","session_id":"session-1","cwd":"/tmp/project","notification_type":"ToolPermission","message":"Allow editing project.yml?"}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "Gemini")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Allow editing project.yml?")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_gemini_hook_tool_permission_notification_is_case_insensitive() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.geminiAdapter(
                data: Data("""
                {"hook_event_name":"Notification","session_id":"session-1","notification_type":"toolpermission"}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Gemini needs your approval")
    }

    func test_gemini_hook_tool_permission_notification_uses_structured_details_when_summary_is_generic() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.geminiAdapter(
                data: Data("""
                {"hook_event_name":"Notification","session_id":"session-1","notification_type":"ToolPermission","message":"Action required","details":{"tool_name":"WriteFile","file_path":"project.yml"}}
                """.utf8),
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.text, "Allow WriteFile on project.yml?")
    }

    func test_copilot_hook_session_start_emits_pid_attach_and_idle_seed_payloads() throws {
        let payloads = try AgentEventBridge.copilotAdapter(
            data: Data("""
            {"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd":"/tmp/project"}
            """.utf8),
            defaultEventName: "sessionStart",
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "ZENTTY_COPILOT_PID": "4242",
            ]
        )

        XCTAssertEqual(payloads.count, 2)
        let pidPayload = payloads[0]
        XCTAssertEqual(pidPayload.signalKind, .pid)
        XCTAssertEqual(pidPayload.pid, 4242)
        XCTAssertEqual(pidPayload.pidEvent, .attach)
        XCTAssertEqual(pidPayload.toolName, "Copilot")
        XCTAssertEqual(pidPayload.origin, .explicitHook)
        XCTAssertEqual(pidPayload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")

        // Seed at .idle — the normalizer's copilot OSC fallthrough promotes
        // to .running based on terminal-progress activity, then drops back
        // to .idle when quiet. Seeding at .starting would short-circuit that.
        let lifecyclePayload = payloads[1]
        XCTAssertEqual(lifecyclePayload.signalKind, .lifecycle)
        XCTAssertEqual(lifecyclePayload.state, .idle)
        XCTAssertEqual(lifecyclePayload.toolName, "Copilot")
        XCTAssertEqual(lifecyclePayload.origin, .explicitHook)
        XCTAssertEqual(lifecyclePayload.confidence, .explicit)
        XCTAssertNil(lifecyclePayload.interactionKind)
        XCTAssertEqual(lifecyclePayload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
        XCTAssertEqual(lifecyclePayload.agentWorkingDirectory, "/tmp/project")
    }

    func test_copilot_hook_user_prompt_submitted_marks_session_running() throws {
        let payloads = try AgentEventBridge.copilotAdapter(
            data: Data("""
            {"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd":"/tmp/project","prompt":"fix the bug"}
            """.utf8),
            defaultEventName: "userPromptSubmitted",
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "Copilot")
        XCTAssertEqual(payload.interactionKind, .none)
        XCTAssertEqual(payload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_copilot_hook_pre_tool_use_ask_user_question_emits_needs_input() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.copilotAdapter(
                data: Data("""
                {"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd":"/tmp/project","toolName":"askuserquestiontool","toolArgs":"{\\"question\\":\\"Which option do you want?\\"}"}
                """.utf8),
                defaultEventName: "preToolUse",
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "Copilot")
        XCTAssertEqual(payload.text, "Which option do you want?")
        XCTAssertEqual(payload.interactionKind, .question)
        XCTAssertEqual(payload.confidence, .explicit)
        XCTAssertEqual(payload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_copilot_hook_pre_tool_use_non_question_tool_is_noop() throws {
        let payloads = try AgentEventBridge.copilotAdapter(
            data: Data("""
            {"cwd":"/tmp/project","toolName":"bash","toolArgs":"{\\"command\\":\\"ls\\"}"}
            """.utf8),
            defaultEventName: "preToolUse",
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_copilot_hook_post_tool_use_ask_user_question_clears_needs_input() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.copilotAdapter(
                data: Data("""
                {"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd":"/tmp/project","toolName":"askUserQuestion","toolArgs":"{}"}
                """.utf8),
                defaultEventName: "postToolUse",
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertNil(payload.interactionKind)
        XCTAssertEqual(payload.toolName, "Copilot")
        XCTAssertEqual(payload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
    }

    func test_copilot_hook_session_end_emits_clear_status_and_pid_payloads() throws {
        let payloads = try AgentEventBridge.copilotAdapter(
            data: Data("""
            {"sessionId":"ffed296c-1964-4fc6-b831-efd206b7399f","cwd":"/tmp/project","reason":"user-quit"}
            """.utf8),
            defaultEventName: "sessionEnd",
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(payloads.count, 2)
        let payload = payloads[0]
        XCTAssertEqual(payload.signalKind, .lifecycle)
        XCTAssertNil(payload.state)
        XCTAssertTrue(payload.clearsStatus)
        XCTAssertEqual(payload.toolName, "Copilot")
        XCTAssertEqual(payload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")

        let pidPayload = payloads[1]
        XCTAssertEqual(pidPayload.signalKind, .pid)
        XCTAssertEqual(pidPayload.pidEvent, .clear)
        XCTAssertEqual(pidPayload.sessionID, "ffed296c-1964-4fc6-b831-efd206b7399f")
    }

    func test_copilot_hook_parse_input_rejects_unknown_event() {
        XCTAssertThrowsError(
            try AgentEventBridge.copilotAdapter(
                data: Data("{}".utf8),
                defaultEventName: "permissionRequest",
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            )
        )
    }

    func test_opencode_canonical_running_event() throws {
        let input = try AgentEventBridge.parseInput(Data("""
        {"version":1,"event":"agent.running","agent":{"name":"OpenCode"},"session":{"id":"session-1"},"context":{"workingDirectory":"/tmp/project"}}
        """.utf8))
        let payload = try XCTUnwrap(
            AgentEventBridge.makePayloads(from: input, environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_opencode_canonical_running_with_task_progress() throws {
        let input = try AgentEventBridge.parseInput(Data("""
        {"version":1,"event":"agent.running","agent":{"name":"OpenCode"},"session":{"id":"session-1"},"progress":{"done":2,"total":5},"context":{"workingDirectory":"/tmp/project"}}
        """.utf8))
        let payload = try XCTUnwrap(
            AgentEventBridge.makePayloads(from: input, environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]).first
        )

        XCTAssertEqual(payload.taskProgress, PaneAgentTaskProgress(doneCount: 2, totalCount: 5))
    }

    func test_opencode_canonical_needs_input_approval() throws {
        let input = try AgentEventBridge.parseInput(Data("""
        {"version":1,"event":"agent.needs-input","agent":{"name":"OpenCode"},"session":{"id":"session-1"},"state":{"interaction":{"kind":"approval","text":"Allow file write?"}},"context":{"workingDirectory":"/tmp/project"}}
        """.utf8))
        let payload = try XCTUnwrap(
            AgentEventBridge.makePayloads(from: input, environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.text, "Allow file write?")
        XCTAssertEqual(payload.interactionKind, .approval)
        XCTAssertEqual(payload.confidence, .explicit)
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_opencode_canonical_needs_input_decision() throws {
        let input = try AgentEventBridge.parseInput(Data("""
        {"version":1,"event":"agent.needs-input","agent":{"name":"OpenCode"},"session":{"id":"session-1"},"state":{"interaction":{"kind":"decision","text":"Choose environment\\n[Staging] [Production]"}},"context":{"workingDirectory":"/tmp/project"}}
        """.utf8))
        let payload = try XCTUnwrap(
            AgentEventBridge.makePayloads(from: input, environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]).first
        )

        XCTAssertEqual(payload.state, .needsInput)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.text, "Choose environment\n[Staging] [Production]")
        XCTAssertEqual(payload.interactionKind, .decision)
        XCTAssertEqual(payload.confidence, .explicit)
    }

    func test_opencode_canonical_input_resolved() throws {
        let input = try AgentEventBridge.parseInput(Data("""
        {"version":1,"event":"agent.input-resolved","agent":{"name":"OpenCode"},"session":{"id":"session-1"},"context":{"workingDirectory":"/tmp/project"}}
        """.utf8))
        let payload = try XCTUnwrap(
            AgentEventBridge.makePayloads(from: input, environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]).first
        )

        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_opencode_canonical_idle() throws {
        let input = try AgentEventBridge.parseInput(Data("""
        {"version":1,"event":"agent.idle","agent":{"name":"OpenCode"},"session":{"id":"session-1"},"context":{"workingDirectory":"/tmp/project"}}
        """.utf8))
        let payload = try XCTUnwrap(
            AgentEventBridge.makePayloads(from: input, environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]).first
        )

        XCTAssertEqual(payload.state, .idle)
        XCTAssertEqual(payload.toolName, "OpenCode")
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
    }

    func test_claude_hook_task_lifecycle_updates_session_progress() throws {
        let store = try makeClaudeHookSessionStore()
        let environment = [
            "ZENTTY_WORKLANE_ID": "worklane-main",
            "ZENTTY_PANE_ID": "worklane-main-shell",
        ]

        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        let createdInput = try AgentEventBridge.claudeParseInput(
            Data(
                """
                {"hook_event_name":"TaskCreated","session_id":"session-1","task_id":"task-1","task":"Write regression test"}
                """.utf8
            )
        )
        let createdPayload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: createdInput,
                environment: environment,
                sessionStore: store
            ).first
        )

        XCTAssertEqual(createdPayload.state, .running)
        XCTAssertEqual(createdPayload.taskProgress, PaneAgentTaskProgress(doneCount: 0, totalCount: 1))

        let completedInput = try AgentEventBridge.claudeParseInput(
            Data(
                """
                {"hook_event_name":"TaskCompleted","session_id":"session-1","task_id":"task-1"}
                """.utf8
            )
        )
        let completedPayload = try XCTUnwrap(
            AgentEventBridge.claudeMakePayloads(
                from: completedInput,
                environment: environment,
                sessionStore: store
            ).first
        )

        XCTAssertEqual(completedPayload.state, .running)
        XCTAssertEqual(completedPayload.taskProgress, PaneAgentTaskProgress(doneCount: 1, totalCount: 1))
    }

    func test_claude_hook_task_created_resets_when_prior_batch_all_completed() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        for index in 1...5 {
            _ = try store.updateTask(sessionID: "session-1", taskID: "task-\(index)", isCompleted: false)
        }
        for index in 1...5 {
            _ = try store.updateTask(sessionID: "session-1", taskID: "task-\(index)", isCompleted: true)
        }

        let priorProgress = try store.taskProgress(sessionID: "session-1")
        XCTAssertEqual(priorProgress, PaneAgentTaskProgress(doneCount: 5, totalCount: 5))

        let firstNew = try store.updateTask(sessionID: "session-1", taskID: "task-6", isCompleted: false)
        XCTAssertEqual(firstNew, PaneAgentTaskProgress(doneCount: 0, totalCount: 1))

        _ = try store.updateTask(sessionID: "session-1", taskID: "task-7", isCompleted: false)
        let thirdNew = try store.updateTask(sessionID: "session-1", taskID: "task-8", isCompleted: false)
        XCTAssertEqual(thirdNew, PaneAgentTaskProgress(doneCount: 0, totalCount: 3))
    }

    func test_claude_hook_task_created_does_not_reset_mid_batch() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        _ = try store.updateTask(sessionID: "session-1", taskID: "task-1", isCompleted: false)
        _ = try store.updateTask(sessionID: "session-1", taskID: "task-2", isCompleted: false)
        _ = try store.updateTask(sessionID: "session-1", taskID: "task-1", isCompleted: true)

        let progress = try store.updateTask(sessionID: "session-1", taskID: "task-3", isCompleted: false)
        XCTAssertEqual(progress, PaneAgentTaskProgress(doneCount: 1, totalCount: 3))
    }

    func test_claude_hook_task_created_for_existing_id_does_not_reset() throws {
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        _ = try store.updateTask(sessionID: "session-1", taskID: "task-1", isCompleted: false)
        _ = try store.updateTask(sessionID: "session-1", taskID: "task-2", isCompleted: false)
        _ = try store.updateTask(sessionID: "session-1", taskID: "task-1", isCompleted: true)
        _ = try store.updateTask(sessionID: "session-1", taskID: "task-2", isCompleted: true)

        let progress = try store.updateTask(sessionID: "session-1", taskID: "task-1", isCompleted: false)
        XCTAssertEqual(progress, PaneAgentTaskProgress(doneCount: 1, totalCount: 2))
    }

    func test_claude_hook_session_end_clears_status_pid_and_mapping() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"SessionEnd","session_id":"session-1"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )

        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].signalKind, .lifecycle)
        XCTAssertNil(payloads[0].state)
        XCTAssertEqual(payloads[0].sessionID, "session-1")
        XCTAssertEqual(payloads[1].signalKind, .pid)
        XCTAssertEqual(payloads[1].pidEvent, .clear)
        XCTAssertEqual(payloads[1].sessionID, "session-1")
        XCTAssertNil(try store.lookup(sessionID: "session-1"))
    }

    func test_claude_hook_session_end_without_session_id_does_not_clear_ambiguous_pane_sessions() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"SessionEnd"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-parent",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4242
        )
        try store.upsert(
            sessionID: "session-child",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: "/tmp/project",
            pid: 4343
        )

        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNotNil(try store.lookup(sessionID: "session-parent"))
        XCTAssertNotNil(try store.lookup(sessionID: "session-child"))
    }

    func test_claude_hook_non_action_notification_is_ignored() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"Notification","session_id":"session-1","message":"Doing well, thanks!"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_claude_hook_ignores_unknown_events() throws {
        let input = try AgentEventBridge.claudeParseInput(
            Data("""
            {"hook_event_name":"PostToolUse","session_id":"session-1","message":"tool finished"}
            """.utf8)
        )
        let store = try makeClaudeHookSessionStore()
        try store.upsert(
            sessionID: "session-1",
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            cwd: nil,
            pid: nil
        )

        let payloads = try AgentEventBridge.claudeMakePayloads(
            from: input,
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ],
            sessionStore: store
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func test_notification_coordinator_fires_for_unresolved_stop_when_pane_is_not_actively_viewed() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        let worklane = WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            agentStatusByPaneID: [
                paneID: PaneAgentStatus(
                    tool: .claudeCode,
                    state: .unresolvedStop,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [worklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(
            recorder.requests,
            [
                .init(
                    identifier: recorder.requests.first?.identifier ?? "",
                    title: "Stopped early",
                    subtitle: nil,
                    body: "Agent stopped early.",
                    windowID: "window-main",
                    soundName: ""
                )
            ]
        )
    }

    func test_notification_coordinator_fires_for_ready_when_pane_is_not_actively_viewed() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        coordinator.update(
            windowID: windowID,
            worklanes: [makeReadyWorklane(worklaneID: worklaneID, paneID: paneID, primaryText: "Implement push notifications")],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(
            recorder.requests,
            [
                .init(
                    identifier: recorder.requests.first?.identifier ?? "",
                    title: "Agent ready",
                    subtitle: nil,
                    body: "Implement push notifications",
                    windowID: "window-main",
                    soundName: ""
                )
            ]
        )
    }

    func test_notification_coordinator_does_not_fire_for_ready_when_pane_is_actively_viewed() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [makeReadyWorklane(worklaneID: worklaneID, paneID: paneID, primaryText: "Implement push notifications")],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func test_notification_coordinator_tracks_ready_and_stopped_notifications_per_pane() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let store = NotificationStore(debounceInterval: 0.01)
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: store)
        let readyPaneID = PaneID("worklane-main-ready")
        let stoppedPaneID = PaneID("worklane-main-stopped")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        let committed = expectation(description: "notifications committed")
        committed.expectedFulfillmentCount = 2
        store.onChange = { committed.fulfill() }

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: readyPaneID,
                    attentions: [
                        .init(
                            paneID: readyPaneID,
                            title: "Implement notifications",
                            state: .ready,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                        .init(
                            paneID: stoppedPaneID,
                            title: "Fix failure handling",
                            state: .unresolvedStop,
                            updatedAt: Date(timeIntervalSince1970: 100)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )

        await fulfillment(of: [committed], timeout: 2)

        XCTAssertEqual(Set(store.notifications.map(\.paneID)), [readyPaneID, stoppedPaneID])
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Stopped early")
        XCTAssertEqual(recorder.requests.first?.soundName, "")
    }

    func test_notification_coordinator_resolves_live_notification_when_pane_becomes_focused() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let store = NotificationStore(debounceInterval: 0.01)
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: store)
        let readyPaneID = PaneID("worklane-main-ready")
        let otherPaneID = PaneID("worklane-main-other")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        let committed = expectation(description: "notification committed")
        store.onChange = { committed.fulfill() }
        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: otherPaneID,
                    attentions: [
                        .init(
                            paneID: otherPaneID,
                            title: "Keep working",
                            state: .running,
                            updatedAt: Date(timeIntervalSince1970: 10)
                        ),
                        .init(
                            paneID: readyPaneID,
                            title: "Implement notifications",
                            state: .ready,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )
        await fulfillment(of: [committed], timeout: 2)

        let resolved = expectation(description: "notification resolved")
        store.onChange = { resolved.fulfill() }
        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: readyPaneID,
                    attentions: [
                        .init(
                            paneID: readyPaneID,
                            title: "Implement notifications",
                            state: .ready,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertTrue(store.notifications[0].isResolved)
    }

    func test_notification_coordinator_uses_sound_only_for_needs_input() throws {
        let recorder = WorklaneAttentionNotificationRecorder()
        let configURL = AppConfigStore.temporaryFileURL(prefix: "agent-notification-sound-tests")
        let configStore = AppConfigStore(fileURL: configURL)
        try configStore.update { config in
            config.notifications.soundName = "Glass"
        }
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            configStore: configStore
        )
        let paneID = PaneID("worklane-main-input")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: paneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .needsInput,
                            interactionKind: .decision,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.soundName, "Glass")
    }

    func test_notification_coordinator_debounces_transient_needs_input_system_notification() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            needsInputSystemNotificationDelay: 0.05
        )
        let paneID = PaneID("worklane-main-input")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: paneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .needsInput,
                            interactionKind: .approval,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        XCTAssertTrue(recorder.requests.isEmpty)

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: paneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .running,
                            updatedAt: Date(timeIntervalSince1970: 51)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func test_notification_coordinator_cancels_pending_needs_input_when_focused() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            needsInputSystemNotificationDelay: 0.05
        )
        let paneID = PaneID("worklane-main-input")
        let otherPaneID = PaneID("worklane-main-other")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: otherPaneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .needsInput,
                            interactionKind: .approval,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )
        XCTAssertTrue(recorder.requests.isEmpty)

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: paneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .needsInput,
                            interactionKind: .approval,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: true
        )

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func test_notification_coordinator_delivers_persistent_needs_input_system_notification_after_debounce() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            needsInputSystemNotificationDelay: 0.01
        )
        let paneID = PaneID("worklane-main-input")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeAttentionWorklane(
                    worklaneID: worklaneID,
                    focusedPaneID: paneID,
                    attentions: [
                        .init(
                            paneID: paneID,
                            title: "Review plan",
                            state: .needsInput,
                            interactionKind: .approval,
                            updatedAt: Date(timeIntervalSince1970: 50)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        XCTAssertTrue(recorder.requests.isEmpty)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Claude Code needs approval")
    }

    func test_notification_coordinator_uses_explicit_needs_input_text_and_compact_location_for_system_notification() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty/Zentty/UI/Chrome",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "Which notification format should I implement? [Compact] [Detailed]",
                    desktopNotificationText: "Codex needs input"
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Codex requires a decision")
        XCTAssertEqual(
            recorder.requests.first?.body,
            "zentty • Zentty/UI/Chrome — Which notification format should I implement? [Compact] [Detailed]"
        )
    }

    func test_notification_coordinator_falls_back_to_desktop_notification_text_for_needs_input() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .approval,
                    explicitText: nil,
                    desktopNotificationText: "Allow edits to project.yml?"
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Codex needs approval")
        XCTAssertEqual(recorder.requests.first?.body, "zentty — Allow edits to project.yml?")
    }

    func test_notification_coordinator_ignores_codex_action_required_title_as_question_preview() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Codex",
                    interactionKind: .genericInput,
                    explicitText: "[ . ] Action Required | running-server-detection-recovery",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Codex needs input")
        XCTAssertEqual(recorder.requests.first?.body, "zentty — Input required.")
    }

    func test_notification_coordinator_logs_unclassified_needs_input_without_public_message_text() throws {
        let recorder = WorklaneAttentionNotificationRecorder()
        var logRecords: [WorklaneAttentionUnclassifiedNeedsInputLogRecord] = []
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            unclassifiedNeedsInputLogger: { logRecords.append($0) }
        )
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")
        let sensitiveText = "Use token sk-live-private-value to continue?"

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Codex",
                    interactionKind: .genericInput,
                    explicitText: sensitiveText,
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        let record = try XCTUnwrap(logRecords.first)
        XCTAssertEqual(logRecords.count, 1)
        XCTAssertEqual(record.classification, .genericInput)
        XCTAssertEqual(record.messageLength, sensitiveText.count)
        XCTAssertEqual(record.messageHash.count, 64)
        XCTAssertFalse(record.publicDescription.contains(sensitiveText))
        XCTAssertFalse(record.publicDescription.contains("sk-live-private-value"))
        XCTAssertTrue(record.publicDescription.contains("classification=generic-input"))
        XCTAssertTrue(record.publicDescription.contains("messageHash=\(record.messageHash)"))
        XCTAssertTrue(record.publicDescription.contains("messageLength=\(sensitiveText.count)"))
    }

    func test_notification_coordinator_uses_gemini_action_required_as_approval_notification() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .gemini,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Gemini",
                    interactionKind: .approval,
                    explicitText: nil,
                    desktopNotificationText: "Action required"
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.title, "Gemini needs approval")
        XCTAssertEqual(recorder.requests.first?.body, "zentty — Approval required.")
    }

    func test_notification_coordinator_replaces_needs_input_when_prompt_changes_without_state_change() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let store = NotificationStore(debounceInterval: 0.01)
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: store)
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        let firstCommit = expectation(description: "first needs-input committed")
        store.onChange = { firstCommit.fulfill() }
        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty/Zentty/UI/Chrome",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "Choose compact or detailed",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        await fulfillment(of: [firstCommit], timeout: 2)

        let replacement = expectation(description: "replacement committed")
        replacement.expectedFulfillmentCount = 2
        store.onChange = { replacement.fulfill() }
        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty/Zentty/UI/Chrome",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "Use the new two-line row?",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        await fulfillment(of: [replacement], timeout: 2)

        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertEqual(store.notifications[0].primaryText, "Use the new two-line row?")
        XCTAssertFalse(store.notifications[0].isResolved)
        XCTAssertEqual(store.notifications[1].primaryText, "Choose compact or detailed")
        XCTAssertTrue(store.notifications[1].isResolved)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertNotEqual(recorder.requests.first?.identifier, recorder.requests.last?.identifier)
        XCTAssertEqual(
            recorder.requests.last?.body,
            "zentty • Zentty/UI/Chrome — Use the new two-line row?"
        )
    }

    func test_notification_coordinator_replaces_codex_action_required_title_with_enriched_question() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let store = NotificationStore(debounceInterval: 0.01)
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: store)
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        let firstCommit = expectation(description: "generic codex title committed")
        store.onChange = { firstCommit.fulfill() }
        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "[ . ] Action Required | zentty",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        await fulfillment(of: [firstCommit], timeout: 2)

        let replacement = expectation(description: "enriched question committed")
        replacement.expectedFulfillmentCount = 2
        store.onChange = { replacement.fulfill() }
        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "Should CLI notifications include the agent question?\n[Yes] [No]",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        await fulfillment(of: [replacement], timeout: 2)

        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertEqual(
            store.notifications[0].primaryText,
            "Should CLI notifications include the agent question?\n[Yes] [No]"
        )
        XCTAssertTrue(store.notifications[1].isResolved)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(
            recorder.requests.last?.body,
            "zentty — Should CLI notifications include the agent question?\n[Yes] [No]"
        )
    }

    func test_notification_coordinator_replaces_pending_codex_generic_prompt_before_system_delivery() async {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            needsInputSystemNotificationDelay: 0.05
        )
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")
        let windowID = WindowID("window-main")

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "[ . ] Action Required | zentty",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
        XCTAssertTrue(recorder.requests.isEmpty)

        coordinator.update(
            windowID: windowID,
            worklanes: [
                makeNeedsInputWorklane(
                    worklaneID: worklaneID,
                    paneID: paneID,
                    tool: .codex,
                    cwd: "/Users/peter/Development/Personal/zentty",
                    repoRoot: "/Users/peter/Development/Personal/zentty",
                    rememberedTitle: "Implement notifications",
                    interactionKind: .decision,
                    explicitText: "Should CLI notifications include the agent question?\n[Yes] [No]",
                    desktopNotificationText: nil
                ),
            ],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(
            recorder.requests.first?.body,
            "zentty — Should CLI notifications include the agent question?\n[Yes] [No]"
        )
    }

    func test_notification_coordinator_does_not_fire_for_generic_codex_waiting_title() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try! XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try! XCTUnwrap(store.activeWorklane?.id)

        store.knownNonRepositoryPaths.insert("/tmp/project")
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Waiting · zentty main",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [try! XCTUnwrap(store.activeWorklane)],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func test_codex_action_required_title_promotes_running_sidebar_state_to_needs_input() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let cwd = "/tmp/codex-action-required"
        store.knownNonRepositoryPaths.insert(cwd)

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: "session-1",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .genericInput)
        XCTAssertEqual(presentation.statusText, "Needs input")
    }

    func test_amp_running_payload_updates_pane_and_sidebar_status() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Amp",
            text: nil,
            sessionID: "amp-session-1",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        let worklane = try XCTUnwrap(store.activeWorklane)
        let presentation = try XCTUnwrap(worklane.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool, .amp)
        XCTAssertEqual(presentation.recognizedTool, .amp)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
        let row = try XCTUnwrap(summary.paneRows.first)
        XCTAssertEqual(row.statusText, "Running")
        XCTAssertEqual(row.attentionState, .running)
        XCTAssertTrue(row.isWorking)
    }

    func test_amp_command_finished_promotes_stale_idle_status_to_ready() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        var worklane = try XCTUnwrap(store.activeWorklane)
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            agentStatus: PaneAgentStatus(
                tool: .amp,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                source: .explicit,
                origin: .explicitHook,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                hasObservedRunning: true,
                sessionID: "amp-session-1"
            )
        )
        store.activeWorklane = worklane

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 0, durationNanoseconds: 250_000_000)
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertEqual(presentation.statusText, "Agent ready")
        XCTAssertTrue(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true)
    }

    func test_amp_idle_status_clears_when_non_agent_command_starts() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        var worklane = try XCTUnwrap(store.activeWorklane)
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            agentStatus: PaneAgentStatus(
                tool: .amp,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                source: .explicit,
                origin: .explicitHook,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                hasObservedRunning: true,
                sessionID: "amp-session-1"
            )
        )
        worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus = true
        store.activeWorklane = worklane

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .shellState,
            state: nil,
            shellActivityState: .commandRunning,
            shellCommand: "pwd",
            origin: .shell,
            toolName: nil,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertFalse(auxiliaryState.raw.showsReadyStatus)
        XCTAssertNil(auxiliaryState.presentation.statusText)
    }

    func test_amp_unresolved_stop_status_clears_when_non_agent_command_starts() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        var worklane = try XCTUnwrap(store.activeWorklane)
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            agentStatus: PaneAgentStatus(
                tool: .amp,
                state: .unresolvedStop,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(),
                source: .explicit,
                origin: .explicitHook,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                hasObservedRunning: true,
                sessionID: "amp-session-1"
            )
        )
        store.activeWorklane = worklane

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            signalKind: .shellState,
            state: nil,
            shellActivityState: .commandRunning,
            shellCommand: "ls",
            origin: .shell,
            toolName: nil,
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertNil(auxiliaryState.presentation.statusText)
    }

    func test_amp_unresolved_stop_command_finished_does_not_refresh_status() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)

        var worklane = try XCTUnwrap(store.activeWorklane)
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            agentStatus: PaneAgentStatus(
                tool: .amp,
                state: .unresolvedStop,
                text: nil,
                artifactLink: nil,
                updatedAt: oldDate,
                source: .explicit,
                origin: .explicitHook,
                interactionKind: PaneAgentInteractionKind.none,
                confidence: .explicit,
                hasObservedRunning: true,
                sessionID: "amp-session-1"
            )
        )
        store.activeWorklane = worklane

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 0, durationNanoseconds: 100_000_000)
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .unresolvedStop)
        XCTAssertEqual(status.updatedAt, oldDate)
    }

    func test_codex_action_required_title_survives_passive_progress_activity() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let cwd = "/tmp/codex-action-required-progress"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .genericInput)
        XCTAssertEqual(presentation.statusText, "Needs input")
    }

    func test_codex_interrupt_clears_stale_question_context_and_notification_text() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let cwd = "/tmp/codex-action-required-interrupt"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        var worklane = try XCTUnwrap(store.activeWorklane)
        worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationText = "Plan mode prompt: Random"
        worklane.auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationDate = Date()
        worklane.auxiliaryStateByPaneID[paneID]?.raw.codexTranscriptContext = PaneCodexTranscriptContext(
            sessionID: "session-1",
            path: "/tmp/codex-session.jsonl"
        )
        store.activeWorklane = worklane

        store.handleTerminalEvent(paneID: paneID, event: .userInterrupted)

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertNil(auxiliaryState.raw.lastDesktopNotificationText)
        XCTAssertNil(auxiliaryState.raw.lastDesktopNotificationDate)
        XCTAssertNil(auxiliaryState.raw.codexTranscriptContext)
        XCTAssertTrue(auxiliaryState.raw.codexInterruptSuppressionIsActive())
        XCTAssertEqual(auxiliaryState.presentation.runtimePhase, .idle)
    }

    func test_codex_running_title_clears_weak_action_required_title_state() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let cwd = "/tmp/codex-action-required-running"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.interactionKind, .none)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_running_title_does_not_clear_enriched_question_state() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let cwd = "/tmp/codex-enriched-question-running"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .needsInput,
            origin: .heuristic,
            toolName: "Codex",
            text: "Which option should Zentty use?",
            interactionKind: .decision,
            confidence: .strong,
            sessionID: "session-1",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .decision)
        XCTAssertEqual(presentation.statusText, "Needs decision")
    }

    func test_codex_ready_title_clears_action_required_title_state() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let cwd = "/tmp/codex-action-required-ready"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertEqual(presentation.interactionKind, .none)
    }

    func test_codex_needs_input_title_uses_generic_input_status_text() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let cwd = "/tmp/codex-needs-input-title"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Main needs input | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .genericInput)
        XCTAssertEqual(presentation.statusText, "Needs input")
    }

    func test_codex_approval_survives_running_hook_until_user_submits_input() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let sessionID = "session-approval"

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .needsInput,
            origin: .explicitHook,
            toolName: "Codex",
            text: "Codex needs your approval",
            interactionKind: .approval,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        var presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .approval)
        XCTAssertEqual(presentation.statusText, "Requires approval")

        let worklaneIndex = try XCTUnwrap(store.worklanes.firstIndex { $0.id == worklaneID })
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]?.agentStatus?.updatedAt =
            Date(timeIntervalSinceNow: -1)
        store.handleTerminalEvent(paneID: paneID, event: .userSubmittedInput)

        presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_tool_activity_clears_prior_explicit_approval() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let sessionID = "session-approval-tool-activity"

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .needsInput,
            origin: .explicitHook,
            toolName: "Codex",
            text: "Codex needs your approval",
            interactionKind: .approval,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            lifecycleEvent: .toolActivity,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_turn_complete_does_not_clear_current_action_required_title() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let cwd = "/tmp/codex-action-required-turn-complete"
        let sessionID = "session-action-required-turn-complete"
        store.knownNonRepositoryPaths.insert(cwd)

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | codex-question",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .idle,
            origin: .explicitAPI,
            toolName: "Codex",
            text: nil,
            lifecycleEvent: .turnComplete,
            interactionKind: .none,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.statusText, "Needs input")
    }

    func test_codex_approval_survives_passive_progress_activity_until_user_submits_input() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let sessionID = "session-approval-progress"

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .needsInput,
            origin: .explicitHook,
            toolName: "Codex",
            text: "Codex needs your approval",
            interactionKind: .approval,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        var presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.interactionKind, .approval)
        XCTAssertEqual(presentation.statusText, "Requires approval")

        let worklaneIndex = try XCTUnwrap(store.worklanes.firstIndex { $0.id == worklaneID })
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]?.agentStatus?.updatedAt =
            Date(timeIntervalSinceNow: -1)
        store.handleTerminalEvent(paneID: paneID, event: .userSubmittedInput)

        presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_approval_clears_when_working_title_and_progress_resume_after_approval() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let cwd = "/tmp/codex-approval-working-progress"
        let sessionID = "session-approval-working-progress"
        store.knownNonRepositoryPaths.insert(cwd)

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .needsInput,
            origin: .explicitHook,
            toolName: "Codex",
            text: "Codex needs your approval",
            interactionKind: .approval,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ codex-approval-working-progress",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_recognized_process_progress_surfaces_running_without_hook_status() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let cwd = "/tmp/codex-progress-only"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "codex-progress-only",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.handleTerminalEvent(
            paneID: paneID,
            event: .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_running_title_restarts_after_prior_explicit_hook_idle() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let cwd = "/tmp/codex-restart"
        let sessionID = "session-restart"
        store.knownNonRepositoryPaths.insert(cwd)

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .idle,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))

        guard let worklaneIndex = store.worklanes.firstIndex(where: { $0.id == worklaneID }) else {
            XCTFail("missing worklane")
            return
        }
        store.worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]?.agentStatus?.updatedAt =
            Date(timeIntervalSinceNow: -5)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ codex-restart",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.origin, .inferred)
        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_codex_running_title_restarts_in_same_pane_after_non_codex_prompt_title() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)
        let cwd = "/tmp/codex-restart-prompt"
        let sessionID = "session-restart-prompt"
        store.knownNonRepositoryPaths.insert(cwd)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ codex-restart-prompt",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID,
            paneID: paneID,
            state: .idle,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            sessionID: sessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        ))
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: cwd,
                processName: "zsh",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ codex-restart-prompt",
                currentWorkingDirectory: cwd,
                processName: "codex",
                gitBranch: "main"
            )
        )

        let presentation = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation)
        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_notification_coordinator_records_origin_window_id_on_system_notification() {
        let recorder = WorklaneAttentionNotificationRecorder()
        let coordinator = WorklaneAttentionNotificationCoordinator(center: recorder, notificationStore: NotificationStore())
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-origin"),
            worklanes: [makeReadyWorklane(worklaneID: worklaneID, paneID: paneID, primaryText: "Implement push notifications")],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(recorder.requests.first?.windowID, "window-origin")
    }

    func test_notification_coordinator_default_center_is_safe_under_xctest() {
        let store = NotificationStore()
        let coordinator = WorklaneAttentionNotificationCoordinator(notificationStore: store)
        let paneID = PaneID("worklane-main-shell")
        let worklaneID = WorklaneID("worklane-main")

        coordinator.update(
            windowID: WindowID("window-main"),
            worklanes: [makeReadyWorklane(
                worklaneID: worklaneID,
                paneID: paneID,
                primaryText: "Implement push notifications"
            )],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )

        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertEqual(store.notifications.first?.statusText, "Agent ready")
    }

    private func makeClaudeHookSessionStore() throws -> ClaudeHookSessionStore {
        let directoryURL = try makeTemporaryDirectory(named: "claude-hook-session-store")
        return ClaudeHookSessionStore(stateURL: directoryURL.appendingPathComponent("claude-hook-sessions.json"))
    }

    private func makeTemporaryBundle(named name: String) throws -> Bundle {
        let bundleRoot = try makeTemporaryBundleRoot(named: name)
        return try XCTUnwrap(Bundle(url: bundleRoot))
    }

    private func makeNeedsInputWorklane(
        worklaneID: WorklaneID,
        paneID: PaneID,
        tool: AgentTool,
        cwd: String,
        repoRoot: String,
        rememberedTitle: String,
        interactionKind: PaneInteractionKind,
        explicitText: String?,
        desktopNotificationText: String?
    ) -> WorklaneState {
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.raw = PaneRawState(
            metadata: TerminalMetadata(
                title: rememberedTitle,
                currentWorkingDirectory: cwd,
                processName: tool.displayName,
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: tool,
                state: .needsInput,
                text: explicitText,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: cwd,
                repositoryRoot: repoRoot,
                reference: .branch("main")
            ),
            lastDesktopNotificationText: desktopNotificationText,
            lastDesktopNotificationDate: desktopNotificationText == nil ? nil : Date(timeIntervalSince1970: 101)
        )
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: auxiliaryState.raw,
            previous: nil
        )
        auxiliaryState.presentation = PanePresentationState(
            cwd: auxiliaryState.presentation.cwd,
            repoRoot: auxiliaryState.presentation.repoRoot,
            branch: auxiliaryState.presentation.branch,
            branchDisplayText: auxiliaryState.presentation.branchDisplayText,
            lookupBranch: auxiliaryState.presentation.lookupBranch,
            branchURL: auxiliaryState.presentation.branchURL,
            identityText: auxiliaryState.presentation.identityText,
            contextText: auxiliaryState.presentation.contextText,
            rememberedTitle: auxiliaryState.presentation.rememberedTitle,
            recognizedTool: tool,
            runtimePhase: .needsInput,
            statusText: auxiliaryState.presentation.statusText,
            pullRequest: auxiliaryState.presentation.pullRequest,
            reviewChips: auxiliaryState.presentation.reviewChips,
            attentionArtifactLink: auxiliaryState.presentation.attentionArtifactLink,
            updatedAt: Date(timeIntervalSince1970: 100),
            isWorking: false,
            isReady: false,
            statusSymbolName: auxiliaryState.presentation.statusSymbolName,
            interactionKind: interactionKind,
            interactionLabel: interactionKind.defaultLabel,
            interactionSymbolName: interactionKind.defaultSymbolName,
            taskProgress: nil
        )

        return WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )
    }

    private func makeReadyWorklane(
        worklaneID: WorklaneID,
        paneID: PaneID,
        primaryText: String
    ) -> WorklaneState {
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.raw = PaneRawState(
            metadata: TerminalMetadata(
                title: primaryText,
                currentWorkingDirectory: "/Users/peter/Development/Personal/zentty",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 100),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/Users/peter/Development/Personal/zentty",
                repositoryRoot: "/Users/peter/Development/Personal/zentty",
                reference: .branch("main")
            ),
            showsReadyStatus: true,
            lastDesktopNotificationText: "Agent ready",
            lastDesktopNotificationDate: Date(timeIntervalSince1970: 100)
        )
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: auxiliaryState.raw,
            previous: nil
        )

        return WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )
    }

    private struct AttentionFixture {
        let paneID: PaneID
        let title: String
        let state: WorklaneAttentionState
        var interactionKind: PaneInteractionKind? = nil
        let updatedAt: Date
    }

    private func makeAttentionWorklane(
        worklaneID: WorklaneID,
        focusedPaneID: PaneID,
        attentions: [AttentionFixture]
    ) -> WorklaneState {
        var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
        let panes = attentions.map { attention in
            PaneState(id: attention.paneID, title: attention.title)
        }

        for attention in attentions {
            var auxiliaryState = PaneAuxiliaryState()
            auxiliaryState.presentation = PanePresentationState(
                cwd: "/tmp/project",
                repoRoot: "/tmp/project",
                branch: "main",
                branchDisplayText: "main",
                lookupBranch: "main",
                identityText: attention.title,
                contextText: "main · /tmp/project",
                rememberedTitle: attention.title,
                recognizedTool: .claudeCode,
                runtimePhase: runtimePhase(for: attention.state),
                statusText: statusText(for: attention.state, interactionKind: attention.interactionKind),
                pullRequest: nil,
                reviewChips: [],
                attentionArtifactLink: nil,
                updatedAt: attention.updatedAt,
                isWorking: false,
                isReady: attention.state == .ready,
                interactionKind: attention.interactionKind,
                interactionLabel: attention.interactionKind?.defaultLabel,
                interactionSymbolName: attention.interactionKind?.defaultSymbolName
            )
            auxiliaryStateByPaneID[attention.paneID] = auxiliaryState
        }

        return WorklaneState(
            id: worklaneID,
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: panes,
                focusedPaneID: focusedPaneID
            ),
            auxiliaryStateByPaneID: auxiliaryStateByPaneID
        )
    }

    private func runtimePhase(for state: WorklaneAttentionState) -> PanePresentationPhase {
        switch state {
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        case .ready:
            return .idle
        case .running:
            return .running
        }
    }

    private func statusText(
        for state: WorklaneAttentionState,
        interactionKind: PaneInteractionKind?
    ) -> String {
        switch state {
        case .needsInput:
            return interactionKind?.defaultLabel ?? "Needs input"
        case .unresolvedStop:
            return "Stopped early"
        case .ready:
            return "Agent ready"
        case .running:
            return "Running"
        }
    }

    private func makeTemporaryBundleRoot(named name: String) throws -> URL {
        let rootURL = try makeTemporaryDirectory(named: name)
            .appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>be.zenjoy.zentty.tests.\(name)</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        let executableURL = macOSURL.appendingPathComponent(name, isDirectory: false)
        FileManager.default.createFile(atPath: executableURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return rootURL
    }

    func test_agent_status_payload_round_trips_agent_working_directory() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentWorkingDirectory: "/Users/peter/Development/my-project"
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decoded.agentWorkingDirectory, "/Users/peter/Development/my-project")
        XCTAssertEqual(decoded, payload)
    }

    func test_agent_status_payload_round_trips_nil_agent_working_directory() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertNil(decoded.agentWorkingDirectory)
        XCTAssertEqual(decoded, payload)
    }

    func test_agent_status_payload_round_trips_agent_transcript_path() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Codex",
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentTranscriptPath: "/Users/peter/.codex/sessions/session.jsonl"
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decoded.agentTranscriptPath, "/Users/peter/.codex/sessions/session.jsonl")
        XCTAssertEqual(decoded, payload)
    }

    func test_agent_status_payload_round_trips_agent_launch_snapshot() throws {
        let payload = AgentStatusPayload(
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Amp",
            text: nil,
            sessionID: "T-ZenttyBenchRestore",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil,
            agentLaunchSnapshot: AgentLaunchSnapshot(arguments: ["--mode", "smart"])
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decoded.agentLaunchSnapshot, AgentLaunchSnapshot(arguments: ["--mode", "smart"]))
        XCTAssertEqual(decoded, payload)
    }

    func test_agent_status_payload_round_trips_window_id() throws {
        let payload = AgentStatusPayload(
            windowID: WindowID("window-main"),
            worklaneID: WorklaneID("worklane-main"),
            paneID: PaneID("worklane-main-shell"),
            signalKind: .lifecycle,
            state: .running,
            origin: .explicitHook,
            toolName: "Claude Code",
            text: nil,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )

        let userInfo = try XCTUnwrap(payload.notificationUserInfo)
        let decoded = try AgentStatusPayload(userInfo: userInfo)

        XCTAssertEqual(decoded.windowID, WindowID("window-main"))
        XCTAssertEqual(decoded, payload)
    }

    private func agyAdapterEnvironment(pid: String? = nil) -> [String: String] {
        var environment = [
            "ZENTTY_WORKLANE_ID": "worklane-main",
            "ZENTTY_PANE_ID": "worklane-main-shell",
            "ZENTTY_PANE_TOKEN": "pane-token",
        ]
        if let pid {
            environment["ZENTTY_AGY_PID"] = pid
        }
        return environment
    }

    private func runShellIntegration(
        shell: ShellIntegrationTestShell,
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> [String] {
        let result = try runShellIntegrationCommand(shell: shell, command: command, extraEnvironment: extraEnvironment)
        let logURL = URL(fileURLWithPath: result.logPath)
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }

        let log = try String(contentsOf: logURL, encoding: .utf8)
        return log
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func runShellIntegrationCommand(
        shell: ShellIntegrationTestShell,
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> ShellIntegrationCommandResult {
        let scratchDirectory = try makeTemporaryDirectory(named: "shell-integration-scratch")
        let fakeCLIURL = scratchDirectory.appendingPathComponent("zentty", isDirectory: false)
        let logURL = scratchDirectory.appendingPathComponent("signals.log", isDirectory: false)

        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$LOG_FILE"
        """.write(to: fakeCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLIURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.executablePath)
        process.arguments = shell.arguments(
            for: "source \(shellQuoted(shell.integrationScriptURL.path)); \(command)"
        )
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LOG_FILE": logURL.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? "peter",
            "ZENTTY_CLI_BIN": fakeCLIURL.path,
            "ZENTTY_INSTANCE_SOCKET": scratchDirectory.appendingPathComponent("zentty.sock", isDirectory: false).path,
            "ZENTTY_PANE_ID": "pane-under-test",
            "ZENTTY_PANE_TOKEN": "pane-token-under-test",
            "ZENTTY_SHELL_INTEGRATION": "1",
            "ZENTTY_WORKLANE_ID": "worklane-under-test",
        ]
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderrText)

        return ShellIntegrationCommandResult(
            stdout: stdoutText,
            stderr: stderrText,
            logPath: logURL.path
        )
    }

    /// Wrapper dirs and the canonical binary filename each must contain so that
    /// AgentStatusHelper accepts the bundle layout. For most tools dir == file name;
    /// cursor wraps the Cursor CLI binary `cursor-agent` (the `cursor` name belongs to
    /// the Cursor IDE launcher, which we do not want to intercept).
    private var wrapperLayoutPairs: [(dirName: String, fileName: String)] {
        [
            ("claude", "claude"),
            ("codex", "codex"),
            ("copilot", "copilot"),
            ("cursor", "cursor-agent"),
            ("droid", "droid"),
            ("gemini", "gemini"),
            ("grok", "grok"),
            ("kimi", "kimi"),
            ("kimi", "kimi-cli"),
            ("opencode", "opencode"),
            ("amp", "amp"),
            ("pi", "pi"),
            ("agy", "agy"),
        ]
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func resolvedExecutable(named name: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "command -v \(shellQuoted(name))"]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func lastAbsolutePath(in output: String) -> String {
        let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let regex = try? NSRegularExpression(pattern: #"/[^\s]+"#)
        let matches = regex?.matches(in: output, range: nsRange) ?? []
        guard let match = matches.last, let range = Range(match.range, in: output) else {
            return ""
        }
        return String(output[range])
    }
}

private struct ShellIntegrationCommandResult {
    let stdout: String
    let stderr: String
    let logPath: String
}

private final class WorklaneAttentionNotificationRecorder: WorklaneAttentionUserNotificationCenter {
    struct RequestRecord: Equatable {
        let identifier: String
        let title: String
        let subtitle: String?
        let body: String
        let windowID: String
        let soundName: String?
    }

    private(set) var requests: [RequestRecord] = []

    func requestAuthorizationIfNeeded() {}

    func add(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String?
    ) {
        requests.append(
            RequestRecord(
                identifier: identifier,
                title: title,
                subtitle: subtitle,
                body: body,
                windowID: windowID,
                soundName: soundName
            )
        )
    }
}

private enum ShellIntegrationTestShell: Equatable {
    case zsh
    case bash

    var executablePath: String {
        switch self {
        case .zsh:
            return "/bin/zsh"
        case .bash:
            return "/bin/bash"
        }
    }

    var integrationScriptURL: URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let filename: String
        switch self {
        case .zsh:
            filename = "zentty-zsh-integration.zsh"
        case .bash:
            filename = "zentty-bash-integration.bash"
        }
        return repositoryRoot
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    func arguments(for command: String) -> [String] {
        switch self {
        case .zsh:
            return ["-f", "-c", command]
        case .bash:
            return ["--noprofile", "--norc", "-c", command]
        }
    }
}
