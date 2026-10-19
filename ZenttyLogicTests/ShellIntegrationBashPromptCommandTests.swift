import Foundation
import XCTest

/// Zentty loads the bash integration through PROMPT_COMMAND, and the user's rc
/// files add their own hooks around that entry (mise, zoxide, fnox, ...). Once
/// loaded, the integration takes over PROMPT_COMMAND and must keep running those
/// hooks on every prompt, exactly once each (dedene/zentty#162).
final class ShellIntegrationBashPromptCommandTests: XCTestCase {
    private var integrationScriptPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent("zentty-bash-integration.bash", isDirectory: false)
            .path
    }

    func test_hooks_added_around_the_integration_entry_run_on_every_prompt() throws {
        let counts = try runInteractiveBash(
            "/bin/bash",
            profile: """
            PROMPT_COMMAND="hook before${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            PROMPT_COMMAND="${PROMPT_COMMAND};hook after"
            """
        )

        assertEveryPrompt(ran: ["before", "after"], in: counts)
    }

    func test_newline_separated_hook_and_inherited_command_run_on_every_prompt() throws {
        let counts = try runInteractiveBash(
            "/bin/bash",
            profile: #"PROMPT_COMMAND="$PROMPT_COMMAND"$'\n'"hook newline""#,
            inheritedPromptCommand: "hook inherited"
        )

        assertEveryPrompt(ran: ["newline", "inherited"], in: counts)
    }

    func test_saving_the_prompt_command_in_bash_profile_does_not_run_hooks_twice() throws {
        // The workaround from #162: copy PROMPT_COMMAND, our entry included, into
        // ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND at the end of ~/.bash_profile.
        let counts = try runInteractiveBash(
            "/bin/bash",
            profile: """
            PROMPT_COMMAND="hook saved;$PROMPT_COMMAND"
            ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND=$PROMPT_COMMAND
            """
        )

        assertEveryPrompt(ran: ["saved"], in: counts)
    }

    func test_array_prompt_command_hooks_run_on_every_prompt() throws {
        guard let bash = try modernBashPath() else {
            throw XCTSkip("Array PROMPT_COMMAND needs bash 5.1 or newer")
        }
        let counts = try runInteractiveBash(
            bash,
            profile: #"PROMPT_COMMAND=("hook first" "$PROMPT_COMMAND" "hook last")"#
        )

        assertEveryPrompt(ran: ["first", "last"], in: counts)
    }

    // MARK: - Helpers

    private static let promptMarker = "prompt"

    private func assertEveryPrompt(
        ran hooks: [String],
        in counts: [String: Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prompts = counts[Self.promptMarker] ?? 0
        XCTAssertGreaterThanOrEqual(prompts, 3, "log=\(counts)", file: file, line: line)
        for hook in hooks {
            XCTAssertEqual(counts[hook], prompts, "hook \(hook) per prompt, log=\(counts)", file: file, line: line)
        }
    }

    /// Runs a login, interactive bash the way a Zentty pane starts one, feeds it a
    /// few commands and returns how often each hook and each prompt was logged.
    private func runInteractiveBash(
        _ bash: String,
        profile: String,
        inheritedPromptCommand: String? = nil
    ) throws -> [String: Int] {
        let home = try makeTemporaryDirectory()
        let log = home.appendingPathComponent("log")
        try """
        set -u
        hook() { echo "$1" >> "$HOME/log"; }
        PS1='$(echo \(Self.promptMarker) >> "$HOME/log")$ '
        \(profile)

        """.write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)

        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "TERM": "dumb",
            "PROMPT_COMMAND": ". \"\(integrationScriptPath)\"",
        ]
        environment["ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND"] = inheritedPromptCommand

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bash)
        process.arguments = ["--login", "-i"]
        process.environment = environment
        process.currentDirectoryURL = home
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        let completion = XCTestExpectation(description: "bash exited")
        process.terminationHandler = { _ in completion.fulfill() }
        try process.run()
        stdin.fileHandleForWriting.write(Data("true\ntrue\ntrue\n".utf8))
        try stdin.fileHandleForWriting.close()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if XCTWaiter().wait(for: [completion], timeout: 30) != .completed {
            process.terminate()
            XCTFail("bash timed out")
        }
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))

        let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return lines.split(separator: "\n").reduce(into: [:]) { $0[String($1), default: 0] += 1 }
    }

    private func modernBashPath() throws -> String? {
        for path in ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-c", "(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))"]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return path }
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bash-prompt-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
