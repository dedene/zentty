import Darwin
import Foundation
import XCTest
@testable import Zentty

final class ZenttyCLIDiscoveryTests: XCTestCase {
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
        process.standardOutput = Pipe()
        process.standardError = Pipe()

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

    private func builtCLIPath() throws -> String {
        if let builtProductsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: builtProductsDir, isDirectory: true)
                .appendingPathComponent("zentty", isDirectory: false)
                .path
        }
        throw XCTSkip("BUILT_PRODUCTS_DIR is unavailable.")
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

    init(response: AgentIPCResponse) throws {
        self.response = response
        tempDirectoryURL = FileManager.default.temporaryDirectory
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
