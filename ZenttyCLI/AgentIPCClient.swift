import Darwin
import Foundation

enum AgentIPCClientError: Error {
    case invalidSocketPath
    case requestTooLarge
    case invalidResponse
    case responseError(AgentIPCResponseError)
}

enum AgentIPCClient {
    private static let maxResponseBytes = 256 * 1024
    private static let timeoutSeconds: Int = 2

    static func send(request: AgentIPCRequest, socketPath: String) throws -> AgentIPCResponse? {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        configure(fileDescriptor)
        try connect(fileDescriptor, socketPath: socketPath)
        try write(request: request, to: fileDescriptor)

        guard request.expectsResponse else {
            return nil
        }

        let response = try readResponse(from: fileDescriptor)
        if !response.ok, let error = response.error {
            throw AgentIPCClientError.responseError(error)
        }
        return response
    }

    private static func configure(_ fileDescriptor: Int32) {
        let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
        _ = fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC)

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
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

    private static func connect(_ fileDescriptor: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = socketPath.utf8CString
        guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AgentIPCClientError.invalidSocketPath
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in
                memcpy(pointer, buffer.baseAddress, buffer.count)
            }
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func write(request: AgentIPCRequest, to fileDescriptor: Int32) throws {
        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))

        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = Darwin.send(
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

    private static func readResponse(from fileDescriptor: Int32) throws -> AgentIPCResponse {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let receivedCount = recv(fileDescriptor, &buffer, buffer.count, 0)
            if receivedCount > 0 {
                data.append(buffer, count: receivedCount)
                if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                    let responseData = data.prefix(upTo: newlineIndex)
                    return try JSONDecoder().decode(AgentIPCResponse.self, from: responseData)
                }
                if data.count > maxResponseBytes {
                    throw AgentIPCClientError.requestTooLarge
                }
                continue
            }

            if receivedCount == 0 {
                guard !data.isEmpty else {
                    throw AgentIPCClientError.invalidResponse
                }
                return try JSONDecoder().decode(AgentIPCResponse.self, from: data)
            }

            if errno == EINTR {
                continue
            }

            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
