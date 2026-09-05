import Darwin
import Foundation
import XCTest
@testable import Zentty

final class ProcessInspectionUnixSocketTests: XCTestCase {
    func test_unix_socket_peer_paths_reports_connected_server_path() throws {
        // Short path: sockaddr_un.sun_path is 104 bytes.
        let path = "/tmp/zentty-\(getpid())-\(UInt32.random(in: 0...9999)).sock"
        unlink(path)
        defer { unlink(path) }

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = try Self.makeAddress(path)
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, addressLength) }
        }
        XCTAssertEqual(bound, 0, "bind failed errno=\(errno)")
        XCTAssertEqual(listen(server, 1), 0)

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, addressLength) }
        }
        XCTAssertEqual(connected, 0, "connect failed errno=\(errno)")

        let peers = DarwinProcessInspector().unixSocketPeerPaths(of: getpid())

        XCTAssertTrue(peers.contains(path), "peers=\(peers)")
    }

    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw XCTSkip("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
        }
        return address
    }
}
