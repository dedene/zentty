import CryptoKit
import Darwin
import Foundation
import os

private let agentIPCLogger = Logger(subsystem: "be.zenjoy.zentty", category: "AgentIPC")

struct AgentIPCMessage: Codable, Equatable {
    let subcommand: String
    let arguments: [String]
    let standardInput: String?
    let environment: [String: String]

    func canonicalized(for target: AgentIPCTarget) -> AgentIPCMessage {
        var environment = self.environment
        if let windowID = target.windowID {
            environment["ZENTTY_WINDOW_ID"] = windowID.rawValue
        } else {
            environment.removeValue(forKey: "ZENTTY_WINDOW_ID")
        }
        environment["ZENTTY_WORKLANE_ID"] = target.worklaneID.rawValue
        environment["ZENTTY_PANE_ID"] = target.paneID.rawValue
        let arguments = canonicalizedArguments(for: target)

        return AgentIPCMessage(
            subcommand: subcommand,
            arguments: arguments,
            standardInput: standardInput,
            environment: environment
        )
    }

    private func canonicalizedArguments(for target: AgentIPCTarget) -> [String] {
        guard subcommand == "agent-signal" || subcommand == "agent-status" else {
            return arguments
        }

        var sanitizedArguments: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if Self.routingOptionNames.contains(argument) {
                index += min(2, arguments.count - index)
                continue
            }
            sanitizedArguments.append(argument)
            index += 1
        }

        if let windowID = target.windowID {
            sanitizedArguments.append(contentsOf: ["--window-id", windowID.rawValue])
        }
        sanitizedArguments.append(contentsOf: ["--worklane-id", target.worklaneID.rawValue])
        sanitizedArguments.append(contentsOf: ["--pane-id", target.paneID.rawValue])
        return sanitizedArguments
    }

    private static let routingOptionNames: Set<String> = [
        "--window-id",
        "--worklane-id",
        "--pane-id",
    ]
}

enum AgentIPCError: Error {
    case invalidMessage
    case unsupportedSubcommand(String)
    case commandFailed(Int32)
    case requestTooLarge
}

struct AgentIPCAuthentication {
    private let secret: String

    init(secret: String = UUID().uuidString) {
        self.secret = secret
    }

    func token(
        windowID: WindowID?,
        worklaneID: WorklaneID,
        paneID: PaneID
    ) -> String {
        let value = [
            secret,
            windowID?.rawValue ?? "",
            worklaneID.rawValue,
            paneID.rawValue,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isValid(
        token: String,
        windowID: WindowID?,
        worklaneID: WorklaneID,
        paneID: PaneID
    ) -> Bool {
        self.token(windowID: windowID, worklaneID: worklaneID, paneID: paneID) == token
    }
}

enum AgentIPCBridge {
    static func handle(
        data: Data,
        post: (AgentStatusPayload) -> Void,
        bootstrap: (AgentIPCRequest) throws -> AgentLaunchPlan = { _ in
            throw AgentIPCError.unsupportedSubcommand("bootstrap")
        },
        writeError: (Error) -> Void = { _ in }
    ) throws -> AgentIPCResponse? {
        if let request = try? JSONDecoder().decode(AgentIPCRequest.self, from: data) {
            return try handle(
                request: request,
                post: post,
                bootstrap: bootstrap,
                writeError: writeError
            )
        }

        let message = try JSONDecoder().decode(AgentIPCMessage.self, from: data)
        try handle(message: message, post: post, writeError: writeError)
        return nil
    }

    static func handle(
        request: AgentIPCRequest,
        post: (AgentStatusPayload) -> Void,
        bootstrap: (AgentIPCRequest) throws -> AgentLaunchPlan = { _ in
            throw AgentIPCError.unsupportedSubcommand("bootstrap")
        },
        writeError: (Error) -> Void = { _ in }
    ) throws -> AgentIPCResponse? {
        switch request.kind {
        case .ipc:
            guard let subcommand = request.subcommand else {
                throw AgentIPCError.invalidMessage
            }
            try handle(
                message: AgentIPCMessage(
                    subcommand: subcommand,
                    arguments: request.arguments,
                    standardInput: request.standardInput,
                    environment: request.environment
                ),
                post: post,
                writeError: writeError
            )
            guard request.expectsResponse else {
                return nil
            }
            return AgentIPCResponse(id: request.id, ok: true, result: AgentIPCResponseResult())
        case .bootstrap:
            let launchPlan = try bootstrap(request)
            guard request.expectsResponse else {
                return nil
            }
            return AgentIPCResponse(
                id: request.id,
                ok: true,
                result: AgentIPCResponseResult(launchPlan: launchPlan)
            )
        case .pane:
            throw AgentIPCError.unsupportedSubcommand("pane (must be handled by server)")
        }
    }

    static func handle(
        message: AgentIPCMessage,
        post: (AgentStatusPayload) -> Void,
        writeError: (Error) -> Void = { _ in }
    ) throws {
        let bridgedArguments = bridgedArguments(for: message)
        let arguments = ["zentty", message.subcommand] + bridgedArguments
        switch message.subcommand {
        case "agent-event":
            let exitCode = AgentEventBridge.run(
                arguments: arguments,
                environment: message.environment,
                inputData: Data((message.standardInput ?? "").utf8),
                post: post,
                writeError: writeError
            )
            guard exitCode == EXIT_SUCCESS else {
                throw AgentIPCError.commandFailed(exitCode)
            }
        case "agent-signal":
            post(try AgentSignalCommand.parse(arguments: arguments, environment: message.environment).payload)
        case "agent-status":
            post(try AgentStatusCommand.parse(arguments: arguments, environment: message.environment).payload)
        default:
            throw AgentIPCError.unsupportedSubcommand(message.subcommand)
        }
    }

    private static func bridgedArguments(for message: AgentIPCMessage) -> [String] {
        guard message.subcommand == "agent-signal" else {
            return message.arguments
        }

        if message.arguments.contains("--origin") || message.arguments.contains(where: { $0.hasPrefix("--origin=") }) {
            return message.arguments
        }

        guard message.arguments.first == AgentSignalKind.lifecycle.rawValue else {
            return message.arguments
        }

        return message.arguments + ["--origin", AgentSignalOrigin.explicitAPI.rawValue]
    }
}

extension AgentIPCRequest {
    func canonicalized(for target: AgentIPCTarget) -> AgentIPCRequest {
        var environment = self.environment
        if let windowID = target.windowID {
            environment["ZENTTY_WINDOW_ID"] = windowID.rawValue
        } else {
            environment.removeValue(forKey: "ZENTTY_WINDOW_ID")
        }
        environment["ZENTTY_WORKLANE_ID"] = target.worklaneID.rawValue
        environment["ZENTTY_PANE_ID"] = target.paneID.rawValue

        guard kind == .ipc, let subcommand else {
            return AgentIPCRequest(
                version: version,
                id: id,
                kind: kind,
                arguments: arguments,
                standardInput: standardInput,
                environment: environment,
                expectsResponse: expectsResponse,
                subcommand: subcommand,
                tool: tool
            )
        }

        let message = AgentIPCMessage(
            subcommand: subcommand,
            arguments: arguments,
            standardInput: standardInput,
            environment: environment
        ).canonicalized(for: target)

        return AgentIPCRequest(
            version: version,
            id: id,
            kind: kind,
            arguments: message.arguments,
            standardInput: message.standardInput,
            environment: message.environment,
            expectsResponse: expectsResponse,
            subcommand: message.subcommand,
            tool: tool
        )
    }
}

struct AgentIPCConnectionInfo {
    let socketPath: String
    let paneToken: String
    let cliPath: String
    let instanceID: String
}

struct AgentIPCTarget: Equatable {
    let windowID: WindowID?
    let worklaneID: WorklaneID
    let paneID: PaneID
}

final class AgentIPCServer: @unchecked Sendable {
    static let shared = AgentIPCServer()

    private static let maxRequestBytes = 256 * 1024
    private static let connectionTimeoutSeconds: Int = 2

    private let fileManager: FileManager
    private let authentication: AgentIPCAuthentication
    let instanceID: String
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.agent-ipc")
    private let diagnosticsEnabled: Bool
    private var socketFileDescriptor: Int32 = -1
    private var socketPath: String?
    private var runtimeDirectoryURL: URL?
    private var readSource: DispatchSourceRead?

    init(
        fileManager: FileManager = .default,
        authentication: AgentIPCAuthentication = AgentIPCAuthentication(),
        instanceID: String = UUID().uuidString.lowercased(),
        diagnosticsEnabled: Bool = ProcessInfo.processInfo.environment["ZENTTY_IPC_DIAGNOSTICS"] == "1"
    ) {
        self.fileManager = fileManager
        self.authentication = authentication
        self.instanceID = instanceID
        self.diagnosticsEnabled = diagnosticsEnabled
    }

    deinit {
        stop()
    }

    func connectionInfo(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        bundle: Bundle = .main
    ) -> AgentIPCConnectionInfo? {
        guard let cliPath = AgentStatusHelper.cliPath(in: bundle) else {
            return nil
        }
        guard let socketPath = startIfNeeded() else {
            return nil
        }
        return AgentIPCConnectionInfo(
            socketPath: socketPath,
            paneToken: authentication.token(windowID: windowID, worklaneID: worklaneID, paneID: paneID),
            cliPath: cliPath,
            instanceID: instanceID
        )
    }

    @discardableResult
    func startIfNeeded() -> String? {
        queue.sync { () -> String? in
            if let socketPath {
                return socketPath
            }

            do {
                cleanupStaleRuntimeDirectories(in: baseRuntimeDirectoryURL())
                let runtimeDirectoryURL = try makeRuntimeDirectory()
                let socketURL = runtimeDirectoryURL.appendingPathComponent("zentty.sock", isDirectory: false)
                let socketPath = socketURL.path
                let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fileDescriptor >= 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }

                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let utf8Path = socketPath.utf8CString
                guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                    close(fileDescriptor)
                    throw AgentIPCError.invalidMessage
                }
                unlink(socketPath)
                _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                    utf8Path.withUnsafeBufferPointer { buffer in
                        memcpy(pointer, buffer.baseAddress, buffer.count)
                    }
                }

                let bindResult = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(
                            fileDescriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
                guard bindResult == 0 else {
                    let bindError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    close(fileDescriptor)
                    unlink(socketPath)
                    throw bindError
                }

                guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                    let listenError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    close(fileDescriptor)
                    unlink(socketPath)
                    throw listenError
                }

                let flags = fcntl(fileDescriptor, F_GETFL)
                _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
                let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
                _ = fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC)

                let readSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
                readSource.setEventHandler { [weak self] in
                    self?.acceptPendingConnections()
                }
                let cleanupSocketPath = socketPath
                let cleanupRuntimeDirectoryURL = runtimeDirectoryURL
                let cleanupFileManager = fileManager
                readSource.setCancelHandler { [weak self] in
                    close(fileDescriptor)
                    unlink(cleanupSocketPath)
                    try? cleanupFileManager.removeItem(at: cleanupRuntimeDirectoryURL)
                    self?.socketFileDescriptor = -1
                }
                readSource.resume()

                self.runtimeDirectoryURL = runtimeDirectoryURL
                self.socketPath = socketPath
                self.socketFileDescriptor = fileDescriptor
                self.readSource = readSource
                return socketPath
            } catch {
                logError("Failed to start IPC socket: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func stop() {
        queue.sync {
            let activeSource = readSource
            readSource = nil
            socketPath = nil
            runtimeDirectoryURL = nil
            socketFileDescriptor = -1
            activeSource?.cancel()
        }
    }

    func currentRuntimeDirectoryURL() -> URL? {
        queue.sync {
            runtimeDirectoryURL
        }
    }

    private func makeRuntimeDirectory() throws -> URL {
        let baseDirectory = baseRuntimeDirectoryURL()
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)

        let runtimeDirectory = baseDirectory.appendingPathComponent(
            "ipc-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
        return runtimeDirectory
    }

    private func acceptPendingConnections() {
        guard socketFileDescriptor >= 0 else {
            return
        }

        while true {
            let clientFileDescriptor = accept(socketFileDescriptor, nil, nil)
            if clientFileDescriptor >= 0 {
                configureAcceptedConnection(clientFileDescriptor)
                let diagnosticsEnabled = diagnosticsEnabled
                let authentication = authentication
                let runtimeDirectoryURL = runtimeDirectoryURL
                let instanceID = instanceID
                let bundle = Bundle.main
                DispatchQueue.global(qos: .utility).async {
                    Self.handleConnection(
                        clientFileDescriptor,
                        authentication: authentication,
                        diagnosticsEnabled: diagnosticsEnabled,
                        runtimeDirectoryURL: runtimeDirectoryURL,
                        bundle: bundle,
                        post: { payload in
                            AgentStatusHelper.post(payload, instanceID: instanceID)
                        },
                        writeError: { [weak self] message in
                            self?.logError(message)
                        }
                    )
                }
                continue
            }

            if errno == EWOULDBLOCK || errno == EAGAIN {
                return
            }

            logError("Socket accept failed: \(String(cString: strerror(errno)))")
            return
        }
    }

    private func configureAcceptedConnection(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
        let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
        _ = fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC)

        var timeout = timeval(
            tv_sec: Self.connectionTimeoutSeconds,
            tv_usec: 0
        )
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    private static func handleConnection(
        _ fileDescriptor: Int32,
        authentication: AgentIPCAuthentication,
        diagnosticsEnabled: Bool,
        runtimeDirectoryURL: URL?,
        bundle: Bundle,
        post: @escaping (AgentStatusPayload) -> Void,
        writeError: @escaping (String) -> Void
    ) {
        defer { close(fileDescriptor) }
        var requestForErrorResponse: AgentIPCRequest?

        do {
            let requestData = try readRequestData(from: fileDescriptor)
            let request = try JSONDecoder().decode(AgentIPCRequest.self, from: requestData)
            requestForErrorResponse = request
            guard let target = validatedTarget(
                for: request.environment,
                authentication: authentication,
                diagnosticsEnabled: diagnosticsEnabled
            ) else {
                return
            }
            let canonicalRequest = request.canonicalized(for: target)

            if canonicalRequest.kind == .pane {
                let result = try PaneIPCHandler.handle(request: canonicalRequest, target: target)
                if canonicalRequest.expectsResponse {
                    try writeResponse(
                        AgentIPCResponse(id: canonicalRequest.id, ok: true, result: result),
                        to: fileDescriptor
                    )
                }
                return
            }

            let response = try AgentIPCBridge.handle(
                request: canonicalRequest,
                post: post,
                bootstrap: { request in
                    guard let runtimeDirectoryURL else {
                        throw AgentIPCError.invalidMessage
                    }
                    return try AgentLaunchBootstrap.makePlan(
                        request: request,
                        target: target,
                        runtimeDirectoryURL: runtimeDirectoryURL,
                        bundle: bundle,
                        fileManager: .default
                    )
                }
            ) { error in
                if diagnosticsEnabled {
                    writeError("IPC bridge error: \(error.localizedDescription)")
                }
            }
            if let response {
                try writeResponse(response, to: fileDescriptor)
            }
        } catch {
            if let request = requestForErrorResponse, request.expectsResponse {
                let response = errorResponse(for: request, error: error)
                try? writeResponse(response, to: fileDescriptor)
            }
            if diagnosticsEnabled {
                writeError("Malformed IPC request: \(error.localizedDescription)")
            }
        }
    }

    private static func readRequestData(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let receivedCount = recv(fileDescriptor, &buffer, buffer.count, 0)
            if receivedCount > 0 {
                data.append(buffer, count: receivedCount)
                if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                    return Data(data.prefix(upTo: newlineIndex))
                }
                if data.count > Self.maxRequestBytes {
                    throw AgentIPCError.requestTooLarge
                }
                continue
            }

            if receivedCount == 0 {
                if data.isEmpty {
                    throw AgentIPCError.invalidMessage
                }
                return data
            }

            if errno == EINTR {
                continue
            }

            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeResponse(_ response: AgentIPCResponse, to fileDescriptor: Int32) throws {
        var payload = try JSONEncoder().encode(response)
        payload.append(UInt8(ascii: "\n"))

        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = send(
                    fileDescriptor,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten,
                    0
                )
                if result > 0 {
                    bytesWritten += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func errorResponse(for request: AgentIPCRequest, error: Error) -> AgentIPCResponse {
        AgentIPCResponse(
            id: request.id,
            ok: false,
            error: AgentIPCResponseError(
                code: errorCode(for: error),
                message: error.localizedDescription
            )
        )
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case AgentIPCError.invalidMessage:
            return "invalid_message"
        case AgentIPCError.unsupportedSubcommand:
            return "unsupported_subcommand"
        case AgentIPCError.commandFailed:
            return "command_failed"
        case AgentIPCError.requestTooLarge:
            return "request_too_large"
        default:
            return "internal_error"
        }
    }

    private static func validatedTarget(
        for environment: [String: String],
        authentication: AgentIPCAuthentication,
        diagnosticsEnabled: Bool
    ) -> AgentIPCTarget? {
        guard let worklaneID = environment["ZENTTY_WORKLANE_ID"] else {
            if diagnosticsEnabled {
                agentIPCLogger.debug("Rejecting IPC message without worklane id")
            }
            return nil
        }
        guard let paneID = environment["ZENTTY_PANE_ID"] else {
            if diagnosticsEnabled {
                agentIPCLogger.debug("Rejecting IPC message without pane id")
            }
            return nil
        }
        let windowID = environment["ZENTTY_WINDOW_ID"].map(WindowID.init)
        let token = environment["ZENTTY_PANE_TOKEN"] ?? ""
        let target = AgentIPCTarget(
            windowID: windowID,
            worklaneID: WorklaneID(worklaneID),
            paneID: PaneID(paneID)
        )
        guard authentication.isValid(
            token: token,
            windowID: target.windowID,
            worklaneID: target.worklaneID,
            paneID: target.paneID
        ) else {
            if diagnosticsEnabled {
                agentIPCLogger.debug("Rejecting IPC message with invalid pane token for pane=\(paneID)")
            }
            return nil
        }
        return target
    }

    private func logDebug(_ message: String) {
        guard diagnosticsEnabled else {
            return
        }
        agentIPCLogger.debug("\(message)")
    }

    private func logError(_ message: String) {
        guard diagnosticsEnabled else {
            return
        }
        agentIPCLogger.error("\(message)")
    }

    private func baseRuntimeDirectoryURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("Zentty", isDirectory: true)
    }

    private func cleanupStaleRuntimeDirectories(in baseDirectory: URL) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directory in directories where directory.lastPathComponent.hasPrefix("ipc-") {
            let components = directory.lastPathComponent.split(separator: "-")
            guard components.count >= 2, let pid = Int32(components[1]) else {
                continue
            }
            if pid == ProcessInfo.processInfo.processIdentifier {
                continue
            }
            if kill(pid, 0) == 0 || errno == EPERM {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }
}
