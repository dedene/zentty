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

    func test_agent_tool_recognizes_gemini_for_explicit_and_known_tool_resolution() {
        XCTAssertEqual(AgentTool.resolve(named: "gemini"), .gemini)
        XCTAssertEqual(AgentTool.resolve(named: "Gemini CLI"), .gemini)
        XCTAssertEqual(AgentTool.resolveKnown(named: "Gemini"), .gemini)
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
        for name in ["claude", "codex", "copilot", "gemini", "opencode"] {
            let wrapperDirectoryURL = binURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let fileURL = wrapperDirectoryURL.appendingPathComponent(name, isDirectory: false)
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
            ["claude", "codex", "copilot", "gemini", "opencode"].map {
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
        for name in ["claude", "codex", "copilot", "gemini", "opencode"] {
            let wrapperDirectoryURL = binURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let fileURL = wrapperDirectoryURL.appendingPathComponent(name, isDirectory: false)
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
        for name in ["claude", "codex", "copilot", "gemini", "opencode"] {
            let wrapperDirectoryURL = binURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let wrapperURL = wrapperDirectoryURL.appendingPathComponent(name, isDirectory: false)
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

        for name in ["claude", "codex", "copilot", "gemini", "opencode"] {
            let wrapperDirectoryURL = binURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
            let wrapperURL = wrapperDirectoryURL.appendingPathComponent(name, isDirectory: false)
            try "#!/bin/sh\n".write(to: wrapperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        }

        let sharedURL = binURL.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedWrapperURL = sharedURL.appendingPathComponent("zentty-agent-wrapper", isDirectory: false)
        try "#!/bin/sh\n".write(to: sharedWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedWrapperURL.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let realBinURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        for name in ["claude", "gemini", "opencode"] {
            let fileURL = realBinURL.appendingPathComponent(name, isDirectory: false)
            try "#!/bin/sh\n".write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }

        let environment = [
            "PATH": [
                binURL.appendingPathComponent("claude", isDirectory: true).path,
                binURL.appendingPathComponent("codex", isDirectory: true).path,
                binURL.appendingPathComponent("copilot", isDirectory: true).path,
                binURL.appendingPathComponent("gemini", isDirectory: true).path,
                binURL.appendingPathComponent("opencode", isDirectory: true).path,
                sharedURL.path,
                realBinURL.path,
                "/usr/bin",
                "/bin",
            ].joined(separator: ":")
        ]

        XCTAssertEqual(
            AgentStatusHelper.enabledWrapperDirectoryPaths(in: bundle, processEnvironment: environment),
            [
                binURL.appendingPathComponent("claude", isDirectory: true).path,
                binURL.appendingPathComponent("gemini", isDirectory: true).path,
                binURL.appendingPathComponent("opencode", isDirectory: true).path,
            ]
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
            XCTAssertTrue(script.contains("[[ \"$_zentty_shell_activity_last\" == \"$state\" ]]"), filename)
        }
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

    func test_copy_agent_resources_build_script_marks_gemini_wrapper_executable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectURL = repositoryRoot.appendingPathComponent("project.yml", isDirectory: false)
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("-o -path \"*/gemini/gemini\""))
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
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["TaskCompleted"])
    }

    func test_agent_launch_bootstrap_builds_codex_overlay_and_notify_override() throws {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-codex-runtime")
        let codexHome = try makeTemporaryDirectory(named: "agent-launch-codex-home")
        try """
        {"hooks":{"Existing":[{"hooks":[{"type":"command","command":"echo existing","timeout":3}]}]}}
        """.write(
            to: codexHome.appendingPathComponent("hooks.json", isDirectory: false),
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

        XCTAssertEqual(plan.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "codex")
        let overlayHome = try XCTUnwrap(plan.setEnvironment["CODEX_HOME"])
        let overlayHooksURL = URL(fileURLWithPath: overlayHome, isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        let overlayHooks = try String(contentsOf: overlayHooksURL, encoding: .utf8)
        XCTAssertTrue(overlayHooks.contains("session-start"))
        XCTAssertTrue(overlayHooks.contains("prompt-submit"))
        XCTAssertTrue(overlayHooks.contains("echo existing"))
        XCTAssertTrue(plan.arguments.contains("tui.notification_method=osc9"))
        XCTAssertTrue(plan.arguments.contains(#"tui.terminal_title=["status","spinner","project"]"#))
        let notifyArgument = try XCTUnwrap(
            plan.arguments.first(where: { $0.contains("notify=[") && $0.contains(#""/tmp/zentty""#) })
        )
        XCTAssertEqual(notifyArgument, #"notify=["/tmp/zentty","codex-notify"]"#)
        XCTAssertFalse(notifyArgument.contains(#"\/"#))
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
        XCTAssertEqual(overlayConfigDirectory.path, URL(fileURLWithPath: xdgConfigHome, isDirectory: true).appendingPathComponent("opencode", isDirectory: true).path)

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
            {"hook_event_name":"SessionStart","session_id":"session-1","cwd":"/tmp/project"}
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
        let center = AgentStatusCenter()
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
                AgentStatusTransport.notificationName,
                object: nil,
                userInfo: payload.notificationUserInfo,
                deliverImmediately: true
            )
        }

        wait(for: [deliveredOnMain], timeout: 2)
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
        XCTAssertEqual(payload.sessionID, "session-1")
        XCTAssertEqual(payload.toolName, "Codex")
        XCTAssertEqual(payload.agentWorkingDirectory, "/tmp/project")
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
        XCTAssertEqual(payload.lifecycleEvent, .update)
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
            {"cwd":"/tmp/project"}
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
        XCTAssertEqual(lifecyclePayload.agentWorkingDirectory, "/tmp/project")
    }

    func test_copilot_hook_user_prompt_submitted_is_noop() throws {
        let payloads = try AgentEventBridge.copilotAdapter(
            data: Data("""
            {"cwd":"/tmp/project","prompt":"fix the bug"}
            """.utf8),
            defaultEventName: "userPromptSubmitted",
            environment: [
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        // Running state is driven by OSC 9;4 progress, not by this hook.
        XCTAssertTrue(payloads.isEmpty)
    }

    func test_copilot_hook_pre_tool_use_ask_user_question_emits_needs_input() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.copilotAdapter(
                data: Data("""
                {"cwd":"/tmp/project","toolName":"askuserquestiontool","toolArgs":"{\\"question\\":\\"Which option do you want?\\"}"}
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
                {"cwd":"/tmp/project","toolName":"askUserQuestion","toolArgs":"{}"}
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
    }

    func test_copilot_hook_session_end_emits_clear_status_payload() throws {
        let payload = try XCTUnwrap(
            AgentEventBridge.copilotAdapter(
                data: Data("""
                {"cwd":"/tmp/project","reason":"user-quit"}
                """.utf8),
                defaultEventName: "sessionEnd",
                environment: [
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "worklane-main-shell",
                ]
            ).first
        )

        XCTAssertEqual(payload.signalKind, .lifecycle)
        XCTAssertNil(payload.state)
        XCTAssertTrue(payload.clearsStatus)
        XCTAssertEqual(payload.toolName, "Copilot")
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
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
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
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
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
        let body: String
        let windowID: String
        let soundName: String
    }

    private(set) var requests: [RequestRecord] = []

    func requestAuthorizationIfNeeded() {}

    func add(identifier: String, title: String, body: String, windowID: String, worklaneID: String, paneID: String, soundName: String) {
        requests.append(RequestRecord(identifier: identifier, title: title, body: body, windowID: windowID, soundName: soundName))
    }
}

private enum ShellIntegrationTestShell {
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
