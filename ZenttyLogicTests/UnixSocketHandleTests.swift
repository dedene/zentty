import Darwin
import Foundation
import XCTest

@testable import Zentty

final class UnixSocketHandleTests: XCTestCase {
    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("unix-socket-handle-\(UUID().uuidString)", isDirectory: false)
    }

    /// A descriptor is closed exactly once: after `close()` the handle is
    /// invalidated, the underlying fd is really closed, and a second `close()`
    /// is a silent no-op (never a double OS close).
    func test_close_invalidates_and_is_idempotent() {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)

        let handle = UnixSocketHandle(fileDescriptor: fileDescriptor)
        XCTAssertTrue(handle.isValid)
        XCTAssertEqual(handle.fileDescriptor, fileDescriptor)
        XCTAssertNotEqual(fcntl(fileDescriptor, F_GETFD), -1, "fd should be open before close")

        handle.close()
        XCTAssertFalse(handle.isValid)
        XCTAssertEqual(handle.fileDescriptor, -1)
        XCTAssertEqual(fcntl(fileDescriptor, F_GETFD), -1, "fd should be closed after close")

        // Idempotent: no crash, still invalid.
        handle.close()
        XCTAssertEqual(handle.fileDescriptor, -1)
    }

    /// `takeOwnership()` returns the raw fd, invalidates the handle, and a
    /// subsequent `close()` must NOT close the relinquished descriptor.
    func test_takeOwnership_transfers_descriptor() {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)

        let handle = UnixSocketHandle(fileDescriptor: fileDescriptor)
        let taken = handle.takeOwnership()

        XCTAssertEqual(taken, fileDescriptor)
        XCTAssertFalse(handle.isValid)
        XCTAssertEqual(handle.fileDescriptor, -1)

        handle.close() // must be a no-op for the relinquished fd
        XCTAssertNotEqual(fcntl(taken, F_GETFD), -1, "relinquished fd should stay open")

        close(taken)
    }

    /// A listener socket path armed via `unlinkPathOnClose` is removed when the
    /// handle closes while it still owns the descriptor.
    func test_close_unlinks_registered_path() {
        let fileURL = makeTemporaryFileURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let handle = UnixSocketHandle(fileDescriptor: fileDescriptor)
        handle.unlinkPathOnClose(fileURL.path)

        handle.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "registered path should be unlinked")
    }

    /// `takeOwnership()` also disarms the unlink responsibility: after transfer
    /// a `close()` leaves the socket file in place (the new owner is in charge).
    func test_takeOwnership_disarms_unlink() {
        let fileURL = makeTemporaryFileURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let handle = UnixSocketHandle(fileDescriptor: fileDescriptor)
        handle.unlinkPathOnClose(fileURL.path)

        let taken = handle.takeOwnership()
        handle.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "path should survive after ownership transfer")

        close(taken)
    }

    /// The throwing convenience initializer produces a live descriptor.
    func test_convenience_init_creates_valid_socket() throws {
        let handle = try UnixSocketHandle(domain: AF_UNIX, type: SOCK_STREAM, protocol: 0)
        XCTAssertTrue(handle.isValid)
        XCTAssertNotEqual(fcntl(handle.fileDescriptor, F_GETFD), -1)
        handle.close()
        XCTAssertFalse(handle.isValid)
    }
}
