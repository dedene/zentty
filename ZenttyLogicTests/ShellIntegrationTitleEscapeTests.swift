import Foundation
import XCTest

/// Directory names and command lines reach the terminal inside an OSC 2 title. A raw ESC or BEL in
/// one must not end that title early and start a sequence of its own, such as an OSC 52 clipboard
/// write, and a literal backslash sequence must stay text.
final class ShellIntegrationTitleEscapeTests: XCTestCase {
    /// Raw BEL ends the OSC 2, then a raw OSC 52 writes "Hello" to the clipboard.
    private static let rawInjection = "x\u{07}\u{1B}]52;c;SGVsbG8=\u{07}"
    /// The same payload spelled with backslashes, which `print` without -r would expand.
    private static let literalInjection = #"y\a\e]52;c;SGVsbG8=\a"#
    private static let commandInjection = "echo \u{07}\u{1B}]52;c;SGVsbG8=\u{07} done"

    private enum Shell: String {
        case zsh, bash, fish, nu
    }

    private var shellIntegrationDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
    }

    // MARK: - Working directory title

    func test_zsh_cwd_title_strips_control_bytes_from_directory_name() throws {
        try assertCwdTitlesAreSafe(shell: .zsh)
    }

    func test_bash_cwd_title_strips_control_bytes_from_directory_name() throws {
        try assertCwdTitlesAreSafe(shell: .bash)
    }

    func test_fish_cwd_title_strips_control_bytes_from_directory_name() throws {
        try assertCwdTitlesAreSafe(shell: .fish)
    }

    func test_nushell_cwd_title_strips_control_bytes_from_directory_name() throws {
        try assertCwdTitlesAreSafe(shell: .nu)
    }

    // MARK: - Command title

    func test_zsh_command_title_strips_control_bytes() throws {
        try assertCommandTitleIsSafe(shell: .zsh, command: #"_zentty_preexec "$ZENTTY_TEST_COMMAND""#)
    }

    func test_bash_command_title_strips_control_bytes() throws {
        // The preexec hook reads $BASH_COMMAND, which a test cannot inject; it titles through this.
        try assertCommandTitleIsSafe(shell: .bash, command: #"_zentty_set_title "$ZENTTY_TEST_COMMAND""#)
    }

    func test_fish_command_title_strips_control_bytes() throws {
        try assertCommandTitleIsSafe(shell: .fish, command: #"_zentty_fish_preexec_hook "$ZENTTY_TEST_COMMAND""#)
    }

    func test_nushell_command_title_strips_control_bytes() throws {
        try assertCommandTitleIsSafe(shell: .nu, command: "_zentty_pre_execution_for_command $env.ZENTTY_TEST_COMMAND")
    }

    // MARK: - Assertions

    private func assertCwdTitlesAreSafe(shell: Shell, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try makeTemporaryDirectory()
        for (name, expectedSuffix) in [
            (Self.rawInjection, "/x]52;c;SGVsbG8="),
            (Self.literalInjection, "/" + Self.literalInjection),
        ] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

            let output = try runTitleCommand(
                shell: shell,
                command: "_zentty_reset_title_to_cwd",
                home: root,
                currentDirectory: directory
            )

            let titles = try assertWellFormedTitles(output, file: file, line: line)
            XCTAssertTrue(
                titles.last?.hasSuffix(expectedSuffix) == true,
                "\(shell) title \(titles.last.debugDescription) should end in \(expectedSuffix.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    private func assertCommandTitleIsSafe(
        shell: Shell,
        command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try makeTemporaryDirectory()
        let output = try runTitleCommand(
            shell: shell,
            command: command,
            home: root,
            currentDirectory: root,
            extraEnvironment: ["ZENTTY_TEST_COMMAND": Self.commandInjection]
        )

        let titles = try assertWellFormedTitles(output, file: file, line: line)
        XCTAssertEqual(titles.last, "echo ]52;c;SGVsbG8= done", "\(shell)", file: file, line: line)
    }

    /// Every byte written must belong to an `ESC ] 2 ; <printable> BEL` frame. An injected BEL
    /// would close a frame early and leave the rest outside any frame.
    @discardableResult
    private func assertWellFormedTitles(_ output: Data, file: StaticString, line: UInt) throws -> [String] {
        let bytes = [UInt8](output)
        XCTAssertNil(
            output.range(of: Data("\u{1B}]52".utf8)),
            "output must not contain an OSC 52: \(bytes)",
            file: file,
            line: line
        )

        let opener: [UInt8] = [0x1B, 0x5D, 0x32, 0x3B]
        var titles: [String] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index...].starts(with: opener),
                  let end = bytes[(index + opener.count)...].firstIndex(of: 0x07) else {
                XCTFail("bytes outside an OSC 2 frame at offset \(index): \(bytes)", file: file, line: line)
                return titles
            }
            let payload = bytes[(index + opener.count)..<end]
            XCTAssertFalse(
                payload.contains { $0 < 0x20 || $0 == 0x7F },
                "control byte inside OSC 2 payload: \(Array(payload))",
                file: file,
                line: line
            )
            titles.append(String(decoding: payload, as: UTF8.self))
            index = end + 1
        }
        XCTAssertFalse(titles.isEmpty, "no title written", file: file, line: line)
        return titles
    }

    // MARK: - Helpers

    private func runTitleCommand(
        shell: Shell,
        command: String,
        home: URL,
        currentDirectory: URL,
        extraEnvironment: [String: String] = [:]
    ) throws -> Data {
        // The integrations write titles to $TTY; point it at a file to capture them.
        let ttyFile = home.appendingPathComponent("tty-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: ttyFile.path, contents: Data())

        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
            "TERM": "xterm-256color",
            "TTY": ttyFile.path,
            "ZENTTY_TEST_TTY": ttyFile.path,
            "ZENTTY_FORCE_SHELL_INTEGRATION": "1",
        ]
        environment.merge(extraEnvironment) { _, new in new }

        let (executable, arguments) = try invocation(for: shell, command: command)
        let status = try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        )
        XCTAssertEqual(status.code, 0, "\(shell) stderr=\(status.stderr)")
        return try Data(contentsOf: ttyFile)
    }

    private func invocation(for shell: Shell, command: String) throws -> (String, [String]) {
        let directory = shellIntegrationDirectoryURL
        switch shell {
        case .zsh:
            let script = directory.appendingPathComponent("zentty-zsh-integration.zsh").path
            // zsh owns $TTY as a special parameter, so it is assigned after startup.
            return ("/bin/zsh", ["-f", "-c", "source \(quoted(script)); TTY=$ZENTTY_TEST_TTY; \(command)"])
        case .bash:
            let script = directory.appendingPathComponent("zentty-bash-integration.bash").path
            return ("/bin/bash", ["--norc", "--noprofile", "-c", "source \(quoted(script)); \(command)"])
        case .fish:
            guard let fish = executablePath("fish") else { throw XCTSkip("fish is not installed") }
            let script = directory.appendingPathComponent("fish/vendor_conf.d/zentty-shell-integration.fish").path
            return (fish, ["--no-config", "-c", "source \(quoted(script)); \(command)"])
        case .nu:
            guard let nu = executablePath("nu") else { throw XCTSkip("nushell is not installed") }
            let script = directory.appendingPathComponent("nushell/vendor/autoload/zentty.nu").path
            return (nu, ["--no-config-file", "-c", "source \(quoted(script)); \(command)"])
        }
    }

    private func executablePath(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-title-escape-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval = 30
    ) throws -> (code: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        let completion = XCTestExpectation(description: "shell process completed")
        process.terminationHandler = { _ in completion.fulfill() }
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if XCTWaiter().wait(for: [completion], timeout: timeout) != .completed {
            process.terminate()
            XCTFail("shell process timed out: \(executable) \(arguments)")
        }
        return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
    }
}
