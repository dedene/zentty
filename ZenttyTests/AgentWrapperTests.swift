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
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
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
                "ZENTTY_WORKSPACE_ID": "workspace-main",
                "ZENTTY_PANE_ID": "workspace-main-shell",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        let signalLines = try harness.readLines(named: "helper-args.log")
        XCTAssertEqual(signalLines.count, 2)
        XCTAssertEqual(try XCTUnwrap(signalLines[safe: 0]), "agent-signal lifecycle running --origin explicit-api --tool Codex")

        let realPID = try XCTUnwrap(try harness.readLines(named: "real-pid.log").first)
        XCTAssertEqual(
            try XCTUnwrap(signalLines[safe: 1]),
            "agent-signal pid attach \(realPID) --origin explicit-api --tool Codex"
        )
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
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
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
