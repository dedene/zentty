import Darwin
import XCTest
@testable import Zentty

/// `history` requests over a real socket. Only paths that never hop to main are covered here:
/// authentication and argument parsing run before the pane lookup, which needs `NSApp`.
final class HistoryIPCServerTests: XCTestCase {
    private static let secret = "history-ipc-test-secret"
    private static let worklaneID = WorklaneID("worklane-1")
    private static let paneID = PaneID("pane-1")
    private static let windowID = WindowID("window-1")

    private var baseDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short and outside NSTemporaryDirectory(): `sockaddr_un` paths are capped at 104 bytes.
        baseDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("zt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
        baseDirectory = nil
        try super.tearDownWithError()
    }

    func test_history_request_without_pane_token_is_answered_with_invalid_pane_token() throws {
        let (_, socketPath) = try startServer()
        var environment = Self.routingEnvironment(token: nil)
        environment.removeValue(forKey: "ZENTTY_PANE_TOKEN")

        let response = try send(Self.searchRequest(environment: environment), to: socketPath)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_pane_token")
        XCTAssertNil(response.result?.history)
    }

    func test_history_request_with_wrong_token_is_answered_with_invalid_pane_token() throws {
        let (server, socketPath) = try startServer()
        // A token minted for another pane of the same server.
        let otherPaneToken = server.paneToken(windowID: Self.windowID, worklaneID: Self.worklaneID, paneID: PaneID("pane-2"))

        let response = try send(
            Self.searchRequest(environment: Self.routingEnvironment(token: otherPaneToken)), to: socketPath)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_pane_token")

        let missingIDs = try send(Self.searchRequest(environment: ["ZENTTY_PANE_TOKEN": otherPaneToken]), to: socketPath)
        XCTAssertEqual(missingIDs.error?.code, "missing_target_context")
    }

    func test_authenticated_environment_target_requires_ids_and_valid_token() throws {
        let authentication = AgentIPCAuthentication(secret: Self.secret)
        let token = authentication.token(windowID: Self.windowID, worklaneID: Self.worklaneID, paneID: Self.paneID)
        let valid = Self.routingEnvironment(token: token)

        let target = try AgentIPCServer.authenticatedEnvironmentTarget(environment: valid, authentication: authentication)
        XCTAssertEqual(target, AgentIPCTarget(windowID: Self.windowID, worklaneID: Self.worklaneID, paneID: Self.paneID))

        for key in ["ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"] {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try AgentIPCServer.authenticatedEnvironmentTarget(
                environment: missing, authentication: authentication)) { error in
                guard case PaneRoutingError.missingTargetContext = error else {
                    return XCTFail("\(key) missing: \(error)")
                }
            }
            var empty = valid
            empty[key] = ""
            XCTAssertThrowsError(try AgentIPCServer.authenticatedEnvironmentTarget(
                environment: empty, authentication: authentication)) { error in
                guard case PaneRoutingError.missingTargetContext = error else {
                    return XCTFail("\(key) empty: \(error)")
                }
            }
        }

        for badToken in [nil, "", "not-a-token", AgentIPCAuthentication(secret: "other").token(
            windowID: Self.windowID, worklaneID: Self.worklaneID, paneID: Self.paneID)] {
            var environment = valid
            environment["ZENTTY_PANE_TOKEN"] = badToken
            XCTAssertThrowsError(try AgentIPCServer.authenticatedEnvironmentTarget(
                environment: environment, authentication: authentication)) { error in
                guard case PaneRoutingError.invalidPaneToken = error else {
                    return XCTFail("token \(String(describing: badToken)): \(error)")
                }
            }
        }

        // The window id is part of the token: dropping it invalidates a windowed token.
        var withoutWindow = valid
        withoutWindow.removeValue(forKey: "ZENTTY_WINDOW_ID")
        XCTAssertThrowsError(try AgentIPCServer.authenticatedEnvironmentTarget(
            environment: withoutWindow, authentication: authentication))
    }

    func test_history_ignores_pane_selector_arguments() throws {
        let (server, socketPath) = try startServer()
        let token = server.paneToken(windowID: Self.windowID, worklaneID: Self.worklaneID, paneID: Self.paneID)
        let request = AgentIPCRequest(
            kind: .history,
            arguments: [HistoryIPC.queryFlag, "cache", "--pane-id", "pane-2"],
            standardInput: nil,
            environment: Self.routingEnvironment(token: token),
            expectsResponse: true,
            subcommand: HistoryIPC.searchSubcommand
        )

        let response = try send(request, to: socketPath)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unexpected_argument")
        XCTAssertEqual(response.error?.message, "Unexpected argument '--pane-id'.")
    }

    // MARK: - Helpers

    private func startServer() throws -> (AgentIPCServer, String) {
        let server = AgentIPCServer(
            authentication: AgentIPCAuthentication(secret: Self.secret),
            instanceID: "historytest",
            baseRuntimeDirectory: baseDirectory
        )
        addTeardownBlock { server.stop() }
        let socketPath = try XCTUnwrap(server.startIfNeeded(), "server failed to start")
        return (server, socketPath)
    }

    private static func routingEnvironment(token: String?) -> [String: String] {
        var environment = [
            "ZENTTY_WINDOW_ID": windowID.rawValue,
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]
        environment["ZENTTY_PANE_TOKEN"] = token
        return environment
    }

    private static func searchRequest(environment: [String: String]) -> AgentIPCRequest {
        AgentIPCRequest(
            kind: .history,
            arguments: HistoryIPCCommand.search(HistorySearchIPCOptions(query: "cache")).ipcArguments,
            standardInput: nil,
            environment: environment,
            expectsResponse: true,
            subcommand: HistoryIPC.searchSubcommand
        )
    }

    /// Writes one request line and reads one response line, with a 5 s receive timeout so a
    /// broken server fails the test instead of hanging it.
    private func send(_ request: AgentIPCRequest, to socketPath: String) throws -> AgentIPCResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        XCTAssertLessThanOrEqual(path.count, MemoryLayout.size(ofValue: address.sun_path))
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            path.withUnsafeBufferPointer { memcpy(pointer, $0.baseAddress, $0.count) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        let written = payload.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, payload.count)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !received.contains(UInt8(ascii: "\n")) {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        let line = received.prefix { $0 != UInt8(ascii: "\n") }
        return try JSONDecoder().decode(AgentIPCResponse.self, from: Data(line))
    }
}
