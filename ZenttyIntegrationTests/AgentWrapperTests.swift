import Foundation
import XCTest

@MainActor
final class AgentWrapperTests: XCTestCase {
    func test_claude_wrapper_passes_through_when_integration_env_is_missing() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["claude"])
        try harness.installRealBinary(
            named: "claude",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )

        let result = try harness.run(tool: "claude", arguments: ["hello"])

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readLines(named: "real-args.log"), ["hello"])
    }

    func test_claude_wrapper_injects_hooks_and_preserves_foreground_pid() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["claude"])
        try harness.installRealBinary(
            named: "claude",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            printf '%s\n' "${ZENTTY_CLAUDE_PID:-}" > "$WRAPPER_PID_LOG"
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )
        try harness.installHelperStub()

        let result = try harness.run(
            tool: "claude",
            arguments: ["hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let realArgs = try harness.readLines(named: "real-args.log")
        XCTAssertTrue(realArgs.contains("--settings"))
        XCTAssertTrue(realArgs.contains("--session-id"))
        XCTAssertEqual(realArgs.last, "hello")

        let settingsIndex = try XCTUnwrap(realArgs.firstIndex(of: "--settings"))
        let settingsJSON = try XCTUnwrap(realArgs[safe: settingsIndex + 1])
        let settingsData = try XCTUnwrap(settingsJSON.data(using: .utf8))
        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["PreToolUse"])
        let preToolUseHooks = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let preToolUseEntry = try XCTUnwrap(preToolUseHooks.first)
        let nestedPreToolUseHooks = try XCTUnwrap(preToolUseEntry["hooks"] as? [[String: Any]])
        let preToolUseCommandHook = try XCTUnwrap(nestedPreToolUseHooks.first)
        XCTAssertNotEqual(preToolUseCommandHook["async"] as? Bool, true)

        let realPID = try XCTUnwrap(try harness.readLines(named: "real-pid.log").first)
        let wrapperPID = try XCTUnwrap(try harness.readLines(named: "wrapper-pid.log").first)
        XCTAssertEqual(wrapperPID, realPID)
    }

    func test_claude_wrapper_launches_without_arguments_when_integration_is_enabled() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["claude"])
        try harness.installRealBinary(
            named: "claude",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            printf '%s\n' "${ZENTTY_CLAUDE_PID:-}" > "$WRAPPER_PID_LOG"
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )
        try harness.installHelperStub()

        let result = try harness.run(
            tool: "claude",
            arguments: [],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let realArgs = try harness.readLines(named: "real-args.log")
        XCTAssertTrue(realArgs.contains("--settings"))
        XCTAssertTrue(realArgs.contains("--session-id"))

        let realPID = try XCTUnwrap(try harness.readLines(named: "real-pid.log").first)
        let wrapperPID = try XCTUnwrap(try harness.readLines(named: "wrapper-pid.log").first)
        XCTAssertEqual(wrapperPID, realPID)
    }

    func test_generic_wrapper_attaches_running_pid_without_supervising_exit() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "opencode",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            exit 0
            """
        )
        try harness.installHelperStub()

        let result = try harness.run(
            tool: "zentty-agent-wrapper",
            arguments: ["exec"],
            extraEnvironment: [
                "ZENTTY_AGENT_TOOL": "opencode",
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let signalLines = try waitForLines(named: "helper-args.log", in: harness)
        XCTAssertEqual(signalLines.count, 1)

        let realPID = try XCTUnwrap(try harness.readLines(named: "real-pid.log").first)
        XCTAssertEqual(
            try XCTUnwrap(signalLines[safe: 0]),
            "agent-signal pid attach \(realPID) --origin explicit-api --tool OpenCode"
        )
    }

    func test_opencode_wrapper_sets_overlay_config_dir_with_zentty_plugin() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["zentty-agent-wrapper"])
        try harness.installHelperStub()

        let supportPluginsURL = try harness.createDirectory(named: "opencode")
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: supportPluginsURL, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: supportPluginsURL.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let configDirLog = harness.logDirectoryURL.appendingPathComponent("opencode-config-dir.log", isDirectory: false)
        let pluginLog = harness.logDirectoryURL.appendingPathComponent("opencode-plugin.log", isDirectory: false)

        try harness.installRealBinary(
            named: "opencode",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "${OPENCODE_CONFIG_DIR:-}" > "$OPENCODE_CONFIG_DIR_LOG"
            if [[ -f "${OPENCODE_CONFIG_DIR:-}/plugins/zentty-opencode-zentty.js" ]]; then
              printf '%s\n' present > "$OPENCODE_PLUGIN_LOG"
            fi
            """
        )

        let result = try harness.run(
            tool: "zentty-agent-wrapper",
            arguments: ["run", "hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_TOOL": "opencode",
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "OPENCODE_CONFIG_DIR_LOG": configDirLog.path,
                "OPENCODE_PLUGIN_LOG": pluginLog.path,
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let configDir = try XCTUnwrap(try String(contentsOf: configDirLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        XCTAssertNotEqual(configDir, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginLog.path))
    }

    func test_opencode_wrapper_preserves_existing_opencode_config_dir_contents_in_overlay() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["zentty-agent-wrapper"])
        try harness.installHelperStub()

        let supportPluginsURL = try harness.createDirectory(named: "opencode")
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: supportPluginsURL, withIntermediateDirectories: true)
        try "export const ZenttyOpenCodePlugin = async () => ({})\n".write(
            to: supportPluginsURL.appendingPathComponent("zentty-opencode-zentty.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let sourceConfigURL = try harness.createDirectory(named: "source-opencode-config")
        let sourceMarkersURL = sourceConfigURL.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceMarkersURL, withIntermediateDirectories: true)
        try "user-config".write(
            to: sourceMarkersURL.appendingPathComponent("user.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let configDirLog = harness.logDirectoryURL.appendingPathComponent("opencode-config-dir.log", isDirectory: false)
        let markerLog = harness.logDirectoryURL.appendingPathComponent("opencode-marker.log", isDirectory: false)

        try harness.installRealBinary(
            named: "opencode",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "${OPENCODE_CONFIG_DIR:-}" > "$OPENCODE_CONFIG_DIR_LOG"
            if [[ -f "${OPENCODE_CONFIG_DIR:-}/markers/user.txt" ]]; then
              cat "${OPENCODE_CONFIG_DIR}/markers/user.txt" > "$OPENCODE_MARKER_LOG"
            fi
            """
        )

        let result = try harness.run(
            tool: "zentty-agent-wrapper",
            arguments: ["run", "hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_TOOL": "opencode",
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
                "OPENCODE_CONFIG_DIR": sourceConfigURL.path,
                "OPENCODE_CONFIG_DIR_LOG": configDirLog.path,
                "OPENCODE_MARKER_LOG": markerLog.path,
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let configDir = try XCTUnwrap(try String(contentsOf: configDirLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        XCTAssertNotEqual(configDir, sourceConfigURL.path)
        XCTAssertEqual(try String(contentsOf: markerLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "user-config")
    }

    func test_generic_wrapper_suppresses_helper_killed_message_when_signal_helper_dies() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "opencode",
            script: """
            #!/bin/bash
            set -euo pipefail
            exit 0
            """
        )

        try """
        #!/bin/bash
        kill -9 $$
        """.write(to: harness.helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.helperURL.path)

        let result = try harness.run(
            tool: "zentty-agent-wrapper",
            arguments: ["exec"],
            extraEnvironment: [
                "ZENTTY_AGENT_TOOL": "opencode",
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertFalse(result.stderr.contains("Killed: 9"))
    }

    func test_codex_wrapper_injects_notify_hook_and_notify_helper_emits_completion_signal() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "codex-notify", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            printf '%s\n' "${CODEX_HOME:-}" > "$CODEX_HOME_LOG"
            if [[ -n "${CODEX_HOME:-}" ]] && [[ -f "${CODEX_HOME}/hooks.json" ]]; then
              cat "${CODEX_HOME}/hooks.json" > "$HOOKS_LOG"
            fi
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )
        try harness.installHelperStub()

        let result = try harness.run(
            tool: "codex",
            arguments: ["exec", "hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")

        let realArgs = try harness.readLines(named: "real-args.log")
        XCTAssertTrue(realArgs.contains("-c"))
        XCTAssertFalse(try harness.readLines(named: "codex-home.log").isEmpty)
        let hooksJSON = try harness.readLines(named: "hooks.json.log").joined(separator: "\n")
        XCTAssertTrue(hooksJSON.contains("\"SessionStart\""))
        XCTAssertTrue(hooksJSON.contains("\"UserPromptSubmit\""))
        XCTAssertTrue(hooksJSON.contains("\"Stop\""))
        XCTAssertTrue(hooksJSON.contains("codex-hook session-start"))
        XCTAssertTrue(hooksJSON.contains("codex-hook prompt-submit"))
        XCTAssertTrue(hooksJSON.contains("codex-hook stop"))

        let configIndex = try XCTUnwrap(realArgs.firstIndex(of: "-c"))
        let configValue = try XCTUnwrap(realArgs[safe: configIndex + 1])
        XCTAssertTrue(configValue.contains("notify=["))
        XCTAssertTrue(configValue.contains("codex-notify"))

        try harness.clearLog(named: "helper-args.log")

        let helperResult = try harness.run(
            tool: "codex-notify",
            arguments: [
                "{\"type\":\"agent-turn-complete\",\"turn-id\":\"turn-1\",\"session_id\":\"session-1\",\"input-messages\":[],\"last-assistant-message\":\"Done\"}"
            ],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(helperResult.exitCode, 0, "\(helperResult.stderr)\n\(helperResult.stdout)")

        let helperSignals = try harness.readLines(named: "helper-args.log")
        XCTAssertEqual(helperSignals.count, 1)
        XCTAssertEqual(
            helperSignals[0],
            "agent-signal lifecycle idle --origin explicit-api --tool Codex --session-id session-1"
        )
    }

    func test_codex_notify_reads_payload_from_standard_input_when_no_argument_is_provided() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex-notify"])
        try harness.installHelperStub()

        let helperResult = try harness.run(
            tool: "codex-notify",
            arguments: [],
            stdin: "{\"type\":\"agent-turn-complete\",\"turn-id\":\"turn-1\",\"session_id\":\"session-stdin\"}",
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(helperResult.exitCode, 0, "\(helperResult.stderr)\n\(helperResult.stdout)")

        let helperSignals = try harness.readLines(named: "helper-args.log")
        XCTAssertEqual(helperSignals, [
            "agent-signal lifecycle idle --origin explicit-api --tool Codex --session-id session-stdin"
        ])
    }

    func test_codex_notify_emits_approval_needs_input_signal() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex-notify"])
        try harness.installHelperStub()

        let helperResult = try harness.run(
            tool: "codex-notify",
            arguments: [
                "{\"type\":\"permission-requested\",\"session_id\":\"session-approval\",\"title\":\"Approval requested: edit Sources/App.swift\"}"
            ],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(helperResult.exitCode, 0, "\(helperResult.stderr)\n\(helperResult.stdout)")

        let helperSignals = try harness.readLines(named: "helper-args.log")
        XCTAssertEqual(helperSignals, [
            "agent-signal lifecycle needs-input --origin explicit-api --tool Codex --text Approval requested: edit Sources/App.swift --interaction-kind approval --session-id session-approval"
        ])
    }

    func test_codex_notify_emits_decision_needs_input_signal_for_question_prompt() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex-notify"])
        try harness.installHelperStub()

        let helperResult = try harness.run(
            tool: "codex-notify",
            arguments: [
                "{\"type\":\"question-requested\",\"session_id\":\"session-question\",\"title\":\"What should Codex do next? [Implement the plan] [Stay in Plan mode]\"}"
            ],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(helperResult.exitCode, 0, "\(helperResult.stderr)\n\(helperResult.stdout)")

        let helperSignals = try harness.readLines(named: "helper-args.log")
        XCTAssertEqual(helperSignals, [
            "agent-signal lifecycle needs-input --origin explicit-api --tool Codex --text What should Codex do next? [Implement the plan] [Stay in Plan mode] --interaction-kind decision --session-id session-question"
        ])
    }

    func test_codex_wrapper_preserves_existing_hooks_and_appends_zentty_hooks() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "zentty-agent-wrapper"])
        try harness.installHelperStub()
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            if [[ -n "${CODEX_HOME:-}" ]] && [[ -f "${CODEX_HOME}/hooks.json" ]]; then
              cat "${CODEX_HOME}/hooks.json" > "$HOOKS_LOG"
            fi
            """
        )

        let sourceCodexHome = try harness.createDirectory(named: "source-codex-home")
        try """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop","timeout":3}]}],"CustomEvent":[{"hooks":[{"type":"command","command":"echo custom","timeout":7}]}]},"topLevelFlag":true}
        """.write(
            to: sourceCodexHome.appendingPathComponent("hooks.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let result = try harness.run(
            tool: "codex",
            arguments: ["exec"],
            extraEnvironment: [
                "CODEX_HOME": sourceCodexHome.path,
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")

        let hooksData = try XCTUnwrap(
            try harness.readLines(named: "hooks.json.log").joined(separator: "\n").data(using: .utf8)
        )
        let hooksJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: hooksData) as? [String: Any]
        )
        XCTAssertEqual(hooksJSON["topLevelFlag"] as? Bool, true)

        let hooks = try XCTUnwrap(hooksJSON["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["CustomEvent"])
        let stopHooks = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(stopHooks.count, 2)

        let serialized = String(data: hooksData, encoding: .utf8) ?? ""
        XCTAssertTrue(serialized.contains("echo user-stop"))
        XCTAssertTrue(serialized.contains("codex-hook stop"))
        XCTAssertTrue(serialized.contains("codex-hook session-start"))
        XCTAssertTrue(serialized.contains("codex-hook prompt-submit"))
    }

    func test_codex_wrapper_preserves_invalid_existing_hooks_json_without_clobbering() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "zentty-agent-wrapper"])
        try harness.installHelperStub()
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            if [[ -n "${CODEX_HOME:-}" ]] && [[ -f "${CODEX_HOME}/hooks.json" ]]; then
              cat "${CODEX_HOME}/hooks.json" > "$HOOKS_LOG"
            fi
            """
        )

        let sourceCodexHome = try harness.createDirectory(named: "invalid-codex-home")
        let invalidHooks = "{not valid json"
        try invalidHooks.write(
            to: sourceCodexHome.appendingPathComponent("hooks.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let result = try harness.run(
            tool: "codex",
            arguments: ["exec"],
            extraEnvironment: [
                "CODEX_HOME": sourceCodexHome.path,
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")

        let hooksJSON = try harness.readLines(named: "hooks.json.log").joined(separator: "\n")
        XCTAssertEqual(hooksJSON, invalidHooks)
        XCTAssertFalse(hooksJSON.contains("codex-hook stop"))
    }

    func test_copilot_wrapper_preserves_existing_config_and_appends_zentty_hooks() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["copilot", "zentty-agent-wrapper"])
        try harness.installHelperStub()
        try harness.installRealBinary(
            named: "copilot",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            printf '%s\n' "${COPILOT_HOME:-}" > "$COPILOT_HOME_LOG"
            if [[ -n "${COPILOT_HOME:-}" ]] && [[ -f "${COPILOT_HOME}/config.json" ]]; then
              cat "${COPILOT_HOME}/config.json" > "$CONFIG_LOG"
            fi
            """
        )

        let sourceCopilotHome = try harness.createDirectory(named: "source-copilot-home")
        try """
        {
          // user comment
          "model": "gpt-5.4",
          "hooks": {
            "userPromptSubmitted": [
              {
                "type": "command",
                "bash": "echo user-prompt-submitted",
                "timeoutSec": 3
              }
            ]
          }
        }
        """.write(
            to: sourceCopilotHome.appendingPathComponent("config.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let result = try harness.run(
            tool: "copilot",
            arguments: ["--prompt", "hello"],
            extraEnvironment: [
                "COPILOT_HOME": sourceCopilotHome.path,
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let copilotHome = try XCTUnwrap(
            try String(contentsOf: harness.logDirectoryURL.appendingPathComponent("copilot-home.log"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
        XCTAssertNotEqual(copilotHome, sourceCopilotHome.path)

        let configData = try XCTUnwrap(
            try String(contentsOf: harness.logDirectoryURL.appendingPathComponent("config.json.log"), encoding: .utf8)
                .data(using: .utf8)
        )
        let configJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: configData) as? [String: Any])
        XCTAssertEqual(configJSON["model"] as? String, "gpt-5.4")
        XCTAssertEqual(configJSON["version"] as? Int, 1)
        XCTAssertNil(configJSON["disableAllHooks"])

        let hooks = try XCTUnwrap(configJSON["hooks"] as? [String: Any])
        let userPromptHooks = try XCTUnwrap(hooks["userPromptSubmitted"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(userPromptHooks.count, 2)

        let serialized = String(data: configData, encoding: .utf8) ?? ""
        XCTAssertTrue(serialized.contains("echo user-prompt-submitted"))
        XCTAssertTrue(serialized.contains("copilot-hook session-start"))
        XCTAssertTrue(serialized.contains("copilot-hook session-end"))
        XCTAssertTrue(serialized.contains("copilot-hook user-prompt-submitted"))
        XCTAssertTrue(serialized.contains("copilot-hook pre-tool-use"))
        XCTAssertTrue(serialized.contains("copilot-hook post-tool-use"))
        XCTAssertTrue(serialized.contains("copilot-hook error-occurred"))
        XCTAssertFalse(serialized.contains("copilot-hook notification"))
        XCTAssertFalse(serialized.contains("copilot-hook permission-request"))
        XCTAssertFalse(serialized.contains("copilot-hook agent-stop"))
        XCTAssertFalse(serialized.contains("copilot-hook subagent-stop"))

        // Copilot's lifecycle is driven by its own hook bridge (sessionStart
        // emits pidPayload), so the wrapper must NOT send an agent-signal
        // pid attach — that path is reserved for tools without a hook bridge.
        let signalLines = try harness.readLines(named: "helper-args.log")
        XCTAssertTrue(
            signalLines.isEmpty,
            "expected no agent-signal pid attach for copilot, got: \(signalLines)"
        )
    }

    func test_copilot_wrapper_uses_config_dir_override_as_overlay_source() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["copilot", "zentty-agent-wrapper"])
        try harness.installHelperStub()
        try harness.installRealBinary(
            named: "copilot",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "${COPILOT_HOME:-}" > "$COPILOT_HOME_LOG"
            if [[ -n "${COPILOT_HOME:-}" ]] && [[ -f "${COPILOT_HOME}/config.json" ]]; then
              cat "${COPILOT_HOME}/config.json" > "$CONFIG_LOG"
            fi
            printf '%s\n' "$*" > "$REAL_ARGS_LOG"
            """
        )

        let sourceCopilotHome = try harness.createDirectory(named: "config-dir-override-home")
        try #"{"theme":"dark"}"#.write(
            to: sourceCopilotHome.appendingPathComponent("config.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let result = try harness.run(
            tool: "copilot",
            arguments: ["--config-dir", sourceCopilotHome.path, "--prompt", "hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")

        let configData = try XCTUnwrap(
            try String(contentsOf: harness.logDirectoryURL.appendingPathComponent("config.json.log"), encoding: .utf8)
                .data(using: .utf8)
        )
        let configJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: configData) as? [String: Any])
        XCTAssertEqual(configJSON["theme"] as? String, "dark")
        XCTAssertFalse((try harness.readLines(named: "real-args.log").first ?? "").contains("--config-dir"))
    }

    func test_copilot_wrapper_preserves_invalid_existing_config_without_clobbering() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["copilot", "zentty-agent-wrapper"])
        try harness.installHelperStub()
        try harness.installRealBinary(
            named: "copilot",
            script: """
            #!/bin/bash
            set -euo pipefail
            if [[ -n "${COPILOT_HOME:-}" ]] && [[ -f "${COPILOT_HOME}/config.json" ]]; then
              cat "${COPILOT_HOME}/config.json" > "$CONFIG_LOG"
            fi
            """
        )

        let sourceCopilotHome = try harness.createDirectory(named: "invalid-copilot-home")
        let invalidConfig = "{not valid json"
        try invalidConfig.write(
            to: sourceCopilotHome.appendingPathComponent("config.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let result = try harness.run(
            tool: "copilot",
            arguments: ["--prompt", "hello"],
            extraEnvironment: [
                "COPILOT_HOME": sourceCopilotHome.path,
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let configJSON = try String(
            contentsOf: harness.logDirectoryURL.appendingPathComponent("config.json.log"),
            encoding: .utf8
        )
        XCTAssertEqual(configJSON, invalidConfig)
        XCTAssertFalse(configJSON.contains("copilot-hook session-start"))
    }

    private func waitForLines(named logName: String, in harness: WrapperHarness, timeout: TimeInterval = 2) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = try harness.readLines(named: logName)
            if !lines.isEmpty {
                return lines
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try harness.readLines(named: logName)
    }
}

private struct WrapperHarness {
    let rootURL: URL
    let wrapperBinURL: URL
    let realBinURL: URL
    let helperURL: URL
    let logDirectoryURL: URL

    init(copyingScriptsNamed scriptNames: [String]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        wrapperBinURL = rootURL.appendingPathComponent("wrapper-bin", isDirectory: true)
        realBinURL = rootURL.appendingPathComponent("real-bin", isDirectory: true)
        logDirectoryURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        helperURL = rootURL.appendingPathComponent("zentty-agent", isDirectory: false)

        try FileManager.default.createDirectory(at: wrapperBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        for scriptName in scriptNames {
            let sourceURL = Self.repoRootURL
                .appendingPathComponent("ZenttyResources/bin", isDirectory: true)
                .appendingPathComponent(Self.scriptRelativePath(for: scriptName), isDirectory: false)
            let destinationURL = wrapperBinURL
                .appendingPathComponent(Self.scriptRelativePath(for: scriptName), isDirectory: false)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        }
    }

    var helperPath: String {
        helperURL.path
    }

    func installRealBinary(named name: String, script: String) throws {
        let fileURL = realBinURL.appendingPathComponent(name, isDirectory: false)
        try script.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    }

    func installHelperStub() throws {
        try """
        #!/bin/bash
        set -euo pipefail
        printf '%s\n' "$*" >> "$HELPER_ARGS_LOG"
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    @discardableResult
    func run(
        tool: String,
        arguments: [String],
        stdin: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executableURL(for: tool).path] + arguments

        var environment = ProcessInfo.processInfo.environment
        let wrapperPaths = publicWrapperDirectories.map(\.path)
        environment["PATH"] = (wrapperPaths + [realBinURL.path, "/usr/bin", "/bin"]).joined(separator: ":")
        if let firstWrapperPath = wrapperPaths.first {
            environment["ZENTTY_WRAPPER_BIN_DIR"] = firstWrapperPath
        }
        if !wrapperPaths.isEmpty {
            environment["ZENTTY_WRAPPER_BIN_DIRS"] = wrapperPaths.joined(separator: ":")
        }
        environment["REAL_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("real-args.log", isDirectory: false).path
        environment["REAL_PID_LOG"] = logDirectoryURL.appendingPathComponent("real-pid.log", isDirectory: false).path
        environment["WRAPPER_PID_LOG"] = logDirectoryURL.appendingPathComponent("wrapper-pid.log", isDirectory: false).path
        environment["HELPER_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("helper-args.log", isDirectory: false).path
        environment["CODEX_HOME_LOG"] = logDirectoryURL.appendingPathComponent("codex-home.log", isDirectory: false).path
        environment["HOOKS_LOG"] = logDirectoryURL.appendingPathComponent("hooks.json.log", isDirectory: false).path
        environment["COPILOT_HOME_LOG"] = logDirectoryURL.appendingPathComponent("copilot-home.log", isDirectory: false).path
        environment["CONFIG_LOG"] = logDirectoryURL.appendingPathComponent("config.json.log", isDirectory: false).path
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func readLines(named logName: String) throws -> [String] {
        let logURL = logDirectoryURL.appendingPathComponent(logName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }

        return try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func clearLog(named logName: String) throws {
        let logURL = logDirectoryURL.appendingPathComponent(logName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return
        }

        try "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    func createDirectory(named name: String) throws -> URL {
        let directoryURL = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var publicWrapperDirectories: [URL] {
        ["claude", "codex", "copilot", "opencode"]
            .map { wrapperBinURL.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func executableURL(for scriptName: String) -> URL {
        wrapperBinURL.appendingPathComponent(Self.scriptRelativePath(for: scriptName), isDirectory: false)
    }

    private static func scriptRelativePath(for scriptName: String) -> String {
        switch scriptName {
        case "claude":
            return "claude/claude"
        case "codex":
            return "codex/codex"
        case "codex-notify":
            return "shared/codex-notify"
        case "copilot":
            return "copilot/copilot"
        case "opencode":
            return "opencode/opencode"
        case "zentty-agent-wrapper":
            return "shared/zentty-agent-wrapper"
        default:
            return scriptName
        }
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
