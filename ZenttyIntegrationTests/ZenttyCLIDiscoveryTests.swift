import Darwin
import Foundation
import XCTest
@testable import Zentty

final class ZenttyCLIDiscoveryTests: XCTestCase {
    func test_capture_server_rejects_overlong_socket_path() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-capture-server-" + String(repeating: "x", count: 96), isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertThrowsError(
            try RequestCaptureServer(
                response: AgentIPCResponse(id: "overlong", ok: true, result: nil),
                tempDirectoryURL: rootURL
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENAMETOOLONG)
        }
    }

    func test_real_cli_pane_list_uses_discovery_and_defaults_to_current_worklane() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "discover-1",
                ok: true,
                result: AgentIPCResponseResult(discoveredPanes: [])
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["pane", "list", "--json"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .discover)
        XCTAssertEqual(request.subcommand, "panes")
        XCTAssertEqual(
            request.arguments,
            ["--window-id", "window-main", "--worklane-id", "worklane-main"]
        )
        XCTAssertEqual(stderrPipe.fileHandleForReading.availableData, Data())
        let output = try JSONSerialization.jsonObject(
            with: stdoutPipe.fileHandleForReading.availableData
        )
        XCTAssertEqual((output as? [Any])?.count, 0)
    }

    func test_real_cli_list_subcommands_honor_json_before_or_after_subcommand() throws {
        let cases: [(subcommand: String, arguments: [String], result: AgentIPCResponseResult)] = [
            ("windows", ["list", "--json", "windows"], AgentIPCResponseResult(discoveredWindows: [])),
            ("windows", ["list", "windows", "--json"], AgentIPCResponseResult(discoveredWindows: [])),
            ("worklanes", ["list", "--json", "worklanes"], AgentIPCResponseResult(discoveredWorklanes: [])),
            ("worklanes", ["list", "worklanes", "--json"], AgentIPCResponseResult(discoveredWorklanes: [])),
            ("panes", ["list", "--json", "panes"], AgentIPCResponseResult(discoveredPanes: [])),
            ("panes", ["list", "panes", "--json"], AgentIPCResponseResult(discoveredPanes: [])),
        ]

        for testCase in cases {
            try assertRealCLIListOutputsJSON(
                arguments: testCase.arguments,
                subcommand: testCase.subcommand,
                result: testCase.result
            )
        }
    }

    func test_real_cli_list_aliases_output_json() throws {
        let cases: [(subcommand: String, arguments: [String], result: AgentIPCResponseResult)] = [
            ("windows", ["window", "list", "--json"], AgentIPCResponseResult(discoveredWindows: [])),
            ("worklanes", ["worklane", "list", "--json"], AgentIPCResponseResult(discoveredWorklanes: [])),
        ]

        for testCase in cases {
            try assertRealCLIListOutputsJSON(
                arguments: testCase.arguments,
                subcommand: testCase.subcommand,
                result: testCase.result
            )
        }
    }

    func test_real_cli_split_forwards_explicit_targeting_arguments() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "pane-1",
                ok: true,
                result: AgentIPCResponseResult()
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "split",
            "right",
            "--window-id", "window-main",
            "--worklane-id", "worklane-main",
            "--pane-id", "pane-main",
            "--pane-token", "token-main",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "split")
        XCTAssertEqual(
            request.arguments,
            [
                "right",
                "--window-id", "window-main",
                "--worklane-id", "worklane-main",
                "--pane-id", "pane-main",
                "--pane-token", "token-main",
            ]
        )
    }

    func test_real_cli_notify_forwards_pane_local_notification_request() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "notify-1",
                ok: true,
                result: AgentIPCResponseResult()
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "notify",
            "--title", "Build done",
            "--subtitle", "Tests passed",
            "--no-inbox",
            "--silent",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment["ZENTTY_PANE_TOKEN"] = "token-main"
        process.environment = environment
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdoutPipe.fileHandleForReading.availableData, Data())
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "notify")
        XCTAssertEqual(
            request.arguments,
            [
                "--title", "Build done",
                "--subtitle", "Tests passed",
                "--no-inbox",
                "--silent",
            ]
        )
        XCTAssertEqual(request.environment["ZENTTY_WINDOW_ID"], "window-main")
        XCTAssertEqual(request.environment["ZENTTY_WORKLANE_ID"], "worklane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "token-main")
    }

    func test_real_cli_notify_fails_without_pane_token() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["notify", "--title", "Build done"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = "/tmp/zentty.sock"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment.removeValue(forKey: "ZENTTY_PANE_TOKEN")
        process.environment = environment
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let stderr = String(
            data: stderrPipe.fileHandleForReading.availableData,
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            stderr.contains("Not running inside a Zentty pane"),
            "Expected pane-local validation error, got: \(stderr)"
        )
    }

    func test_real_cli_theme_toggle_forwards_theme_request() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "theme-1",
                ok: true,
                result: AgentIPCResponseResult(stdout: "light\n")
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["theme", "toggle"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment["ZENTTY_PANE_TOKEN"] = "token-main"
        process.environment = environment
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.availableData, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdout, "light\n")
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "theme")
        XCTAssertEqual(request.arguments, ["toggle"])
        XCTAssertTrue(request.expectsResponse)
    }

    func test_real_cli_theme_explicit_modes_forward_matching_theme_request() throws {
        for command in ["dark", "light", "auto"] {
            let server = try RequestCaptureServer(
                response: AgentIPCResponse(
                    id: "theme-\(command)",
                    ok: true,
                    result: AgentIPCResponseResult(stdout: "\(command)\n")
                )
            )
            defer { server.invalidate() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: try builtCLIPath())
            process.arguments = ["theme", command]

            var environment = ProcessInfo.processInfo.environment
            environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
            environment["ZENTTY_WINDOW_ID"] = "window-main"
            environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
            environment["ZENTTY_PANE_ID"] = "pane-main"
            environment["ZENTTY_PANE_TOKEN"] = "token-main"
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            try process.run()
            let request = try server.receiveOneRequest()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(request.kind, .pane)
            XCTAssertEqual(request.subcommand, "theme")
            XCTAssertEqual(request.arguments, [command])
            XCTAssertTrue(request.expectsResponse)
        }
    }

    func test_real_cli_theme_fails_outside_zentty_instance() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["theme", "toggle"]

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZENTTY_INSTANCE_SOCKET")
        process.environment = environment
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let stderr = String(
            data: stderrPipe.fileHandleForReading.availableData,
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            stderr.contains("Not running inside a Zentty instance"),
            "Expected theme command to require a Zentty instance, got: \(stderr)"
        )
    }

    // Regression: `SOCK=$(ls .../zentty.sock)` under a colorizing `ls` alias
    // wraps the path in ANSI escapes. The CLI used to report only
    // "No such file or directory", hiding which path it tried.
    func test_real_cli_connect_failure_names_the_socket_path_with_escapes_visible() throws {
        // Short on purpose: sun_path caps at 104 bytes, and the escapes must fit.
        let missingSocketPath = "/tmp/zentty-missing-\(UUID().uuidString.prefix(8))/zentty.sock"
        let cases: [(socketPath: String, expectedFragments: [String])] = [
            (missingSocketPath, ["'\(missingSocketPath)'", "No such file or directory"]),
            (
                "\u{1B}[01;35m\(missingSocketPath)\u{1B}[0m=",
                [
                    "'\\u{1B}[01;35m\(missingSocketPath)\\u{1B}[0m='",
                    "No such file or directory",
                    "control characters",
                ]
            ),
        ]

        for testCase in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: try builtCLIPath())
            process.arguments = ["list", "panes", "--json"]

            var environment = ProcessInfo.processInfo.environment
            for key in ["ZENTTY_WINDOW_ID", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID", "ZENTTY_PANE_TOKEN"] {
                environment.removeValue(forKey: key)
            }
            environment["ZENTTY_INSTANCE_SOCKET"] = testCase.socketPath
            process.environment = environment
            process.standardOutput = Pipe()
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            XCTAssertNotEqual(process.terminationStatus, 0)
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertFalse(stderr.contains("\u{1B}"), "Raw escape leaked into stderr: \(stderr)")
            for fragment in testCase.expectedFragments {
                XCTAssertTrue(stderr.contains(fragment), "Expected \(fragment) in: \(stderr)")
            }
        }
    }

    private func builtCLIPath() throws -> String {
        if let builtProductsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: builtProductsDir, isDirectory: true)
                .appendingPathComponent("zentty", isDirectory: false)
                .path
        }
        let testBundleProductsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let testBundleCLIURL = testBundleProductsURL.appendingPathComponent("zentty", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: testBundleCLIURL.path) {
            return testBundleCLIURL.path
        }
        throw XCTSkip("BUILT_PRODUCTS_DIR is unavailable.")
    }

    private func assertRealCLIListOutputsJSON(
        arguments: [String],
        subcommand: String,
        result: AgentIPCResponseResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(id: "list-\(subcommand)", ok: true, result: result)
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.availableData
        let stderrData = stderrPipe.fileHandleForReading.availableData
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail(
                "CLI exited with status \(process.terminationStatus): \(stderr)",
                file: file,
                line: line
            )
            return
        }
        XCTAssertEqual(request.kind, .discover, file: file, line: line)
        XCTAssertEqual(request.subcommand, subcommand, file: file, line: line)
        XCTAssertEqual(stderrData, Data(), "Unexpected stderr: \(stderr)", file: file, line: line)
        let output = try JSONSerialization.jsonObject(with: stdoutData)
        XCTAssertEqual((output as? [Any])?.count, 0, file: file, line: line)
    }
}

private final class RequestCaptureServer {
    let socketPath: String

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.tests.discovery-server")
    private let semaphore = DispatchSemaphore(value: 0)
    private let tempDirectoryURL: URL
    private var capturedRequest: AgentIPCRequest?
    private var response: AgentIPCResponse

    init(response: AgentIPCResponse, tempDirectoryURL providedTempDirectoryURL: URL? = nil) throws {
        self.response = response
        tempDirectoryURL = providedTempDirectoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        socketPath = tempDirectoryURL.appendingPathComponent("zentty.sock", isDirectory: false).path

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = socketPath.utf8CString
        guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(listenFD)
            try? FileManager.default.removeItem(at: tempDirectoryURL)
            throw POSIXError(.ENAMETOOLONG)
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in
                memcpy(pointer, buffer.baseAddress, buffer.count)
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(listenFD, SOMAXCONN) == 0 else {
            close(listenFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        queue.async { [self] in
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            do {
                let requestData = try Self.readLine(from: clientFD)
                capturedRequest = try JSONDecoder().decode(AgentIPCRequest.self, from: requestData)
                try Self.write(response: response, to: clientFD)
            } catch {
            }

            semaphore.signal()
        }
    }

    func invalidate() {
        close(listenFD)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    func receiveOneRequest(timeout: TimeInterval = 5) throws -> AgentIPCRequest {
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        XCTAssertEqual(waitResult, .success)
        return try XCTUnwrap(capturedRequest)
    }

    private static func readLine(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fileDescriptor, &buffer, buffer.count, 0)
            guard count >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                return data
            }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                return Data(data.prefix(upTo: newlineIndex))
            }
        }
    }

    private static func write(response: AgentIPCResponse, to fileDescriptor: Int32) throws {
        var payload = try JSONEncoder().encode(response)
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            _ = send(fileDescriptor, baseAddress, rawBuffer.count, 0)
        }
    }
}
