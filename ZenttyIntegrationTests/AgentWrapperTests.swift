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
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf '%s\n' "$$" > "$REAL_PID_LOG"
            exit 0
            """
        )
        try harness.installHelperStub()

        let result = try harness.run(
            tool: "codex",
            arguments: ["exec"],
            extraEnvironment: [
                "ZENTTY_AGENT_BIN": harness.helperPath,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "worklane-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let signalLines = try harness.readLines(named: "helper-args.log")
        XCTAssertEqual(signalLines.count, 1)

        let realPID = try XCTUnwrap(try harness.readLines(named: "real-pid.log").first)
        XCTAssertEqual(
            try XCTUnwrap(signalLines[safe: 0]),
            "agent-signal pid attach \(realPID) --origin explicit-api --tool Codex"
        )
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
                .appendingPathComponent(scriptName, isDirectory: false)
            let destinationURL = wrapperBinURL.appendingPathComponent(scriptName, isDirectory: false)
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
        process.arguments = [wrapperBinURL.appendingPathComponent(tool, isDirectory: false).path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(wrapperBinURL.path):\(realBinURL.path):/usr/bin:/bin"
        environment["REAL_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("real-args.log", isDirectory: false).path
        environment["REAL_PID_LOG"] = logDirectoryURL.appendingPathComponent("real-pid.log", isDirectory: false).path
        environment["WRAPPER_PID_LOG"] = logDirectoryURL.appendingPathComponent("wrapper-pid.log", isDirectory: false).path
        environment["HELPER_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("helper-args.log", isDirectory: false).path
        environment["CODEX_HOME_LOG"] = logDirectoryURL.appendingPathComponent("codex-home.log", isDirectory: false).path
        environment["HOOKS_LOG"] = logDirectoryURL.appendingPathComponent("hooks.json.log", isDirectory: false).path
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
