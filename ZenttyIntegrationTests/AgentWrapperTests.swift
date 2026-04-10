import Darwin
import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentWrapperTests: XCTestCase {
    func test_real_cli_help_hides_internal_commands_and_shows_public_version_command() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["--help"]
        process.standardInput = Pipe()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrString)
        XCTAssertTrue(stdoutString.contains("version"), stdoutString)
        XCTAssertFalse(stdoutString.contains("codex-notify"), stdoutString)
        XCTAssertFalse(stdoutString.contains("\nipc"), stdoutString)
        XCTAssertFalse(stdoutString.contains("\n  ipc"), stdoutString)
        XCTAssertFalse(stdoutString.contains("launch"), stdoutString)
    }

    func test_real_cli_version_reports_marketing_version_and_git_commit() throws {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundleURL = productsURL.appendingPathComponent("Zentty.app", isDirectory: true)
        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        let metadata = AboutMetadata.load(from: appBundle)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["version"]
        process.standardInput = Pipe()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrString)
        XCTAssertEqual(
            stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            "zentty \(metadata.version) (\(metadata.commit))"
        )
    }

    func test_bare_command_zentty_version_reports_marketing_version_and_git_commit() throws {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundleURL = productsURL.appendingPathComponent("Zentty.app", isDirectory: true)
        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        let metadata = AboutMetadata.load(from: appBundle)
        let bundledCLI = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "zentty version"]
        process.standardInput = Pipe()

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([bundledCLI, environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment.removeValue(forKey: "ZENTTY_CLI_BIN")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrString)
        XCTAssertEqual(
            stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            "zentty \(metadata.version) (\(metadata.commit))"
        )
    }

    func test_real_cli_launch_accepts_dash_prefixed_tool_arguments() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )

        let result = try harness.run(
            tool: "codex",
            arguments: ["--yolo"],
            extraEnvironment: [
                "ZENTTY_CLI_BIN": try builtCLIPath(),
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readLines(named: "real-args.log"), ["--yolo"])
    }

    func test_real_cli_ipc_accepts_dash_prefixed_passthrough_arguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["ipc", "agent-event", "--adapter=codex"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = ""
        environment["ZENTTY_PANE_TOKEN"] = ""
        environment["ZENTTY_WORKLANE_ID"] = ""
        environment["ZENTTY_PANE_ID"] = ""
        process.environment = environment

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.standardInput = Pipe()

        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(data: stderrData, encoding: .utf8) ?? "")
    }

    func test_real_cli_codex_notify_forwards_payload_to_codex_notify_adapter() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"type":"agent-turn-complete","session_id":"session-1"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["codex-notify", payload]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .ipc)
        XCTAssertEqual(request.subcommand, "agent-event")
        XCTAssertEqual(request.arguments, ["--adapter=codex-notify"])
        XCTAssertEqual(request.standardInput, payload)
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "pane-token-under-test")
        XCTAssertEqual(request.environment["ZENTTY_WORKLANE_ID"], "worklane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
    }

    func test_real_cli_codex_notify_reads_payload_from_standard_input_when_argument_is_omitted() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"type":"agent-turn-complete","session_id":"session-stdin"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["codex-notify"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .ipc)
        XCTAssertEqual(request.subcommand, "agent-event")
        XCTAssertEqual(request.arguments, ["--adapter=codex-notify"])
        XCTAssertEqual(request.standardInput, payload)
    }

    func test_claude_wrapper_falls_back_to_real_binary_when_cli_is_missing() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["claude", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "claude",
            script: """
            #!/bin/bash
            set -euo pipefail
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )

        let result = try harness.run(tool: "claude", arguments: ["hello"])

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readLines(named: "real-args.log"), ["hello"])
        XCTAssertTrue(try harness.readArgumentCalls(named: "cli-args.log").isEmpty)
    }

    func test_tool_wrappers_delegate_to_launch_command_when_cli_is_available() throws {
        for tool in ["claude", "codex", "copilot", "opencode"] {
            let harness = try WrapperHarness(copyingScriptsNamed: [tool, "zentty-agent-wrapper"])
            try harness.installRealBinary(
                named: tool,
                script: """
                #!/bin/bash
                set -euo pipefail
                printf 'unexpected\n' >> "$REAL_ARGS_LOG"
                """
            )
            try harness.installCliStub()

            let result = try harness.run(
                tool: tool,
                arguments: ["hello"],
                extraEnvironment: [
                    "ZENTTY_CLI_BIN": harness.cliPath,
                    "ZENTTY_INSTANCE_SOCKET": harness.socketPath,
                    "ZENTTY_PANE_TOKEN": harness.paneToken,
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "pane-main",
                ]
            )

            XCTAssertEqual(result.exitCode, 0, "\(tool): \(result.stderr)\n\(result.stdout)")
            XCTAssertEqual(try harness.readArgumentCalls(named: "cli-args.log"), [["launch", tool, "hello"]], tool)
            XCTAssertTrue(try harness.readLines(named: "real-args.log").isEmpty, tool)
        }
    }

    func test_generic_wrapper_delegates_selected_tool_to_launch_command() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "opencode",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf 'unexpected\n' >> "$REAL_ARGS_LOG"
            """
        )
        try harness.installCliStub()

        let result = try harness.run(
            tool: "zentty-agent-wrapper",
            arguments: ["run", "hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_TOOL": "opencode",
                "ZENTTY_CLI_BIN": harness.cliPath,
                "ZENTTY_INSTANCE_SOCKET": harness.socketPath,
                "ZENTTY_PANE_TOKEN": harness.paneToken,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readArgumentCalls(named: "cli-args.log"), [["launch", "opencode", "run", "hello"]])
        XCTAssertTrue(try harness.readLines(named: "real-args.log").isEmpty)
    }

    private func builtCLIPath() throws -> String {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cliURL = productsURL.appendingPathComponent("zentty", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw XCTSkip("Built zentty CLI not found at \(cliURL.path)")
        }
        return cliURL.path
    }
}

private final class IPCRequestCaptureServer {
    let socketPath: String
    private let rootURL: URL
    private var fileDescriptor: Int32

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        socketPath = rootURL.appendingPathComponent("zentty.sock", isDirectory: false).path

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = socketPath.utf8CString
        guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fileDescriptor)
            throw POSIXError(.ENAMETOOLONG)
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in
                memcpy(pointer, buffer.baseAddress, buffer.count)
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fileDescriptor)
            throw error
        }

        guard listen(fileDescriptor, 1) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fileDescriptor)
            throw error
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        unlink(socketPath)
        try? FileManager.default.removeItem(at: rootURL)
    }

    func receiveOneRequest(timeout: TimeInterval = 5) throws -> AgentIPCRequest {
        let expectation = XCTestExpectation(description: "receive IPC request")
        let lock = NSLock()
        var capturedRequest: AgentIPCRequest?
        var capturedError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            defer { expectation.fulfill() }
            let client = accept(self.fileDescriptor, nil, nil)
            guard client >= 0 else {
                lock.lock()
                capturedError = POSIXError(.init(rawValue: errno) ?? .EIO)
                lock.unlock()
                return
            }
            defer { close(client) }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(client, &buffer, buffer.count, 0)
                if count > 0 {
                    data.append(buffer, count: count)
                    if data.contains(UInt8(ascii: "\n")) {
                        break
                    }
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                lock.lock()
                capturedError = POSIXError(.init(rawValue: errno) ?? .EIO)
                lock.unlock()
                return
            }

            let requestData: Data
            if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                requestData = data.prefix(upTo: newlineIndex)
            } else {
                requestData = data
            }

            do {
                let request = try JSONDecoder().decode(AgentIPCRequest.self, from: requestData)
                lock.lock()
                capturedRequest = request
                lock.unlock()
            } catch {
                lock.lock()
                capturedError = error
                lock.unlock()
            }
        }

        let waiterResult = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if waiterResult != .completed {
            throw NSError(
                domain: "AgentWrapperTests.IPCRequestCaptureServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for IPC request"]
            )
        }

        lock.lock()
        defer { lock.unlock() }
        if let capturedError {
            throw capturedError
        }
        return try XCTUnwrap(capturedRequest)
    }
}

private struct WrapperHarness {
    let rootURL: URL
    let wrapperBinURL: URL
    let realBinURL: URL
    let cliURL: URL
    let logDirectoryURL: URL

    init(copyingScriptsNamed scriptNames: [String]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        wrapperBinURL = rootURL.appendingPathComponent("wrapper-bin", isDirectory: true)
        realBinURL = rootURL.appendingPathComponent("real-bin", isDirectory: true)
        logDirectoryURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        cliURL = rootURL
            .appendingPathComponent("cli-bin", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: false)

        try FileManager.default.createDirectory(at: wrapperBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cliURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

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

    var cliPath: String {
        cliURL.path
    }

    var socketPath: String {
        rootURL.appendingPathComponent("zentty.sock", isDirectory: false).path
    }

    var paneToken: String {
        "pane-token-under-test"
    }

    func installRealBinary(named name: String, script: String) throws {
        let fileURL = realBinURL.appendingPathComponent(name, isDirectory: false)
        try script.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    }

    func installCliStub() throws {
        try """
        #!/bin/bash
        set -euo pipefail
        if [[ -n "${CLI_STDIN_LOG:-}" && "${1:-}" == "ipc" && "${2:-}" == "agent-event" ]]; then
          cat > "$CLI_STDIN_LOG"
        fi
        if [[ -n "${CLI_ARGS_LOG:-}" ]]; then
          {
            printf '%s\n' '--call--'
            for arg in "$@"; do
              printf '%s\n' "$arg"
            done
          } >> "$CLI_ARGS_LOG"
        fi
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
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
        environment["PATH"] = ([cliURL.deletingLastPathComponent().path] + wrapperPaths + [realBinURL.path, "/usr/bin", "/bin"]).joined(separator: ":")
        if let firstWrapperPath = wrapperPaths.first {
            environment["ZENTTY_WRAPPER_BIN_DIR"] = firstWrapperPath
        }
        if !wrapperPaths.isEmpty {
            environment["ZENTTY_WRAPPER_BIN_DIRS"] = wrapperPaths.joined(separator: ":")
        }
        environment["REAL_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("real-args.log", isDirectory: false).path
        environment["CLI_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("cli-args.log", isDirectory: false).path
        environment["CLI_STDIN_LOG"] = logDirectoryURL.appendingPathComponent("cli-stdin.log", isDirectory: false).path
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

    func readArgumentCalls(named logName: String) throws -> [[String]] {
        var calls: [[String]] = []
        var current: [String] = []

        for line in try readLines(named: logName) {
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
