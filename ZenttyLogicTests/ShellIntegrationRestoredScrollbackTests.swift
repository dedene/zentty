import Foundation
import XCTest

/// The shell integration prints a restored pane's saved output before the first
/// prompt and drops `ZENTTY_RESTORED_SCROLLBACK_FILE`, so the text is only ever
/// printed: never typed into the shell, never left for child processes.
final class ShellIntegrationRestoredScrollbackTests: XCTestCase {
    private static let environmentKey = "ZENTTY_RESTORED_SCROLLBACK_FILE"
    private static let marker = "zentty-after-integration"

    private var shellIntegrationDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
    }

    func test_zsh_prints_the_saved_output_and_unsets_the_variable() throws {
        let script = shellIntegrationDirectoryURL.appendingPathComponent("zentty-zsh-integration.zsh").path
        try assertReplays(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "source \(quoted(script)); \(childEnvCheck)"]
        )
    }

    func test_bash_prints_the_saved_output_and_unsets_the_variable() throws {
        let script = shellIntegrationDirectoryURL.appendingPathComponent("zentty-bash-integration.bash").path
        try assertReplays(
            executable: "/bin/bash",
            arguments: ["--norc", "--noprofile", "-c", "source \(quoted(script)); \(childEnvCheck)"]
        )
    }

    func test_fish_prints_the_saved_output_and_unsets_the_variable() throws {
        guard let fish = executablePath("fish") else { throw XCTSkip("fish is not installed") }
        let script = shellIntegrationDirectoryURL
            .appendingPathComponent("fish/vendor_conf.d/zentty-shell-integration.fish").path
        try assertReplays(
            executable: fish,
            arguments: ["--no-config", "-c", "source \(quoted(script)); \(childEnvCheck)"],
            extraEnvironment: ["ZENTTY_FORCE_SHELL_INTEGRATION": "1"]
        )
    }

    func test_nushell_prints_the_saved_output_and_unsets_the_variable() throws {
        guard let nu = executablePath("nu") else { throw XCTSkip("nushell is not installed") }
        let script = shellIntegrationDirectoryURL
            .appendingPathComponent("nushell/vendor/autoload/zentty.nu").path
        try assertReplays(
            executable: nu,
            arguments: [
                "--no-config-file", "-c",
                "source \(quoted(script)); print $'\(Self.marker) ($env | get -o \(Self.environmentKey) | default 0)'",
            ]
        )
    }

    func test_missing_file_prints_nothing() throws {
        let script = shellIntegrationDirectoryURL.appendingPathComponent("zentty-zsh-integration.zsh").path
        let result = try run(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "source \(quoted(script)); \(childEnvCheck)"],
            environment: baseEnvironment(file: "/nonexistent/pn_1.txt")
        )

        XCTAssertEqual(result.status, 0, "stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "\(Self.marker) 0\n")
    }

    // MARK: - Helpers

    /// Prints the marker plus how many child processes still see the variable.
    private var childEnvCheck: String {
        "echo \(Self.marker) $(/usr/bin/env | /usr/bin/grep -c \(Self.environmentKey))"
    }

    private func assertReplays(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = try makeScrollbackTemporaryDirectory()
        // A path with a space and a payload that would do damage if evaluated.
        let saved = directory.appendingPathComponent("saved output.txt")
        let payload = "$ echo $(touch pwned)\nold output\n\u{1B}[2m── restored from previous session ──\u{1B}[0m\n"
        try payload.write(to: saved, atomically: true, encoding: .utf8)

        var environment = baseEnvironment(file: saved.path)
        environment.merge(extraEnvironment) { _, new in new }
        let result = try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: directory
        )

        XCTAssertEqual(result.status, 0, "stderr=\(result.stderr)", file: file, line: line)
        XCTAssertEqual(result.stdout, payload + "\(Self.marker) 0\n", file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path),
            "saved output must be printed, never evaluated",
            file: file,
            line: line
        )
    }

    private func baseEnvironment(file: String) -> [String: String] {
        [
            "HOME": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
            "TERM": "xterm-256color",
            Self.environmentKey: file,
        ]
    }

    private func executablePath(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = XCTestExpectation(description: "shell process completed")
        process.terminationHandler = { _ in completion.fulfill() }
        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if XCTWaiter().wait(for: [completion], timeout: timeout) != .completed {
            process.terminate()
            XCTFail("shell process timed out: \(executable) \(arguments)")
        }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self)
        )
    }
}
