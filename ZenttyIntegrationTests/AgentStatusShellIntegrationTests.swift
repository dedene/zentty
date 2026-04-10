import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentStatusShellIntegrationTests: XCTestCase {
    func test_zsh_shell_integration_emits_git_branch_for_local_repository() throws {
        let repositoryURL = try makeTemporaryGitRepository(branch: "feature/test-branch")
        let signals = try recordedShellCalls(
            shellExecutable: "/bin/zsh",
            arguments: ["-lc", "source '\(repositoryShellIntegrationURL(filename: "zentty-zsh-integration.zsh").path)'"],
            currentDirectoryURL: repositoryURL
        )

        XCTAssertTrue(
            signals.contains { signal in
                signal.starts(with: ["ipc", "agent-signal", "pane-context", "local"])
                    && signal.enumerated().contains { index, value in
                        value == "--git-branch"
                            && signal.indices.contains(index + 1)
                            && signal[index + 1] == "feature/test-branch"
                    }
            },
            signals.map { $0.joined(separator: " ") }.joined(separator: "\n")
        )
    }

    // MARK: - Private helpers

    private func repositoryShellIntegrationURL(filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private func makeTemporaryGitRepository(branch: String) throws -> URL {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        _ = try runProcess("/usr/bin/git", arguments: ["init"], currentDirectoryURL: repositoryURL)
        _ = try runProcess("/usr/bin/git", arguments: ["config", "user.name", "Zentty Tests"], currentDirectoryURL: repositoryURL)
        _ = try runProcess("/usr/bin/git", arguments: ["config", "user.email", "tests@example.com"], currentDirectoryURL: repositoryURL)

        let trackedFileURL = repositoryURL.appendingPathComponent("README.md", isDirectory: false)
        try "test\n".write(to: trackedFileURL, atomically: true, encoding: .utf8)
        _ = try runProcess("/usr/bin/git", arguments: ["add", "README.md"], currentDirectoryURL: repositoryURL)
        _ = try runProcess(
            "/usr/bin/git",
            arguments: ["commit", "-m", "Initial commit"],
            currentDirectoryURL: repositoryURL
        )
        _ = try runProcess(
            "/usr/bin/git",
            arguments: ["checkout", "-b", branch],
            currentDirectoryURL: repositoryURL
        )

        return repositoryURL
    }

    private func recordedShellCalls(
        shellExecutable: String,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> [[String]] {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        let logURL = tempDirectoryURL.appendingPathComponent("signals.log", isDirectory: false)
        let cliURL = tempDirectoryURL.appendingPathComponent("zentty", isDirectory: false)
        try """
        #!/bin/sh
        [ -n "${ZENTTY_INSTANCE_SOCKET:-}" ] || exit 0
        [ -n "${ZENTTY_PANE_TOKEN:-}" ] || exit 0
        [ -n "${ZENTTY_WORKLANE_ID:-}" ] || exit 0
        [ -n "${ZENTTY_PANE_ID:-}" ] || exit 0
        {
          printf '%s\n' '--call--'
          for arg in "$@"; do
            printf '%s\n' "$arg"
          done
        } >> "$ZENTTY_TEST_LOG"
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        _ = try runProcess(
            shellExecutable,
            arguments: arguments,
            environment: [
                "ZENTTY_TEST_LOG": logURL.path,
                "ZENTTY_CLI_BIN": cliURL.path,
                "ZENTTY_INSTANCE_SOCKET": tempDirectoryURL.appendingPathComponent("zentty.sock", isDirectory: false).path,
                "ZENTTY_SHELL_INTEGRATION": "1",
                "ZENTTY_WORKLANE_ID": "worklane-under-test",
                "ZENTTY_PANE_ID": "pane-under-test",
                "ZENTTY_PANE_TOKEN": "pane-token-under-test",
                "ZENTTY_WRAPPER_BIN_DIR": "",
            ],
            currentDirectoryURL: currentDirectoryURL
        )

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        return parseArgumentCalls(lines)
    }

    @discardableResult
    private func runProcess(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AgentStatusShellIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr]
            )
        }

        return (process.terminationStatus, stdout, stderr)
    }

    private func parseArgumentCalls(_ lines: [String]) -> [[String]] {
        var calls: [[String]] = []
        var current: [String] = []

        for line in lines {
            if line == "--call--" {
                if !current.isEmpty {
                    calls.append(current)
                    current = []
                }
                continue
            }
            current.append(line)
        }

        if !current.isEmpty {
            calls.append(current)
        }

        return calls
    }
}
