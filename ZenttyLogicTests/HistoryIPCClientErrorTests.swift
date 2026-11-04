import Darwin
import XCTest
@testable import Zentty

final class HistoryIPCClientErrorTests: XCTestCase {
    func test_invalid_response_maps_to_version_skew() {
        // An app that predates Agent History can't decode the request and closes the socket.
        XCTAssertEqual(HistoryIPCClientErrorMapper.message(for: .connectionClosed), HistoryIPC.versionSkewMessage)
        XCTAssertEqual(
            HistoryIPCClientErrorMapper.message(
                for: .response(code: "unsupported_subcommand", message: "Unsupported subcommand: history")
            ),
            HistoryIPC.versionSkewMessage
        )
    }

    func test_eagain_maps_to_timeout() {
        for code in [EAGAIN, EWOULDBLOCK, ETIMEDOUT] {
            XCTAssertEqual(HistoryIPCClientErrorMapper.message(for: .posix(code)), HistoryIPC.timeoutMessage)
        }
        XCTAssertEqual(HistoryIPCClientErrorMapper.map(POSIXError(.EAGAIN)), HistoryIPC.timeoutMessage)
        XCTAssertNotEqual(HistoryIPCClientErrorMapper.message(for: .posix(ECONNREFUSED)), HistoryIPC.timeoutMessage)
    }

    func test_response_error_passes_message() {
        XCTAssertEqual(
            HistoryIPCClientErrorMapper.message(
                for: .response(code: "history_scope_denied", message: HistoryIPC.scopeDeniedMessage)
            ),
            HistoryIPC.scopeDeniedMessage
        )
        XCTAssertEqual(HistoryIPCClientErrorMapper.map(HistoryIPCError.outsidePane), HistoryIPC.outsidePaneMessage)
        XCTAssertEqual(HistoryIPCClientErrorMapper.message(for: .other("Cannot connect.")), "Cannot connect.")
    }

    func test_nil_history_payload_maps_to_version_skew() {
        let skew = HistoryIPCClientOutcome.failure(message: HistoryIPC.versionSkewMessage)
        XCTAssertEqual(HistoryIPCClientErrorMapper.outcome(nil), skew)
        XCTAssertEqual(HistoryIPCClientErrorMapper.outcome(AgentIPCResponseResult()), skew)
        XCTAssertEqual(HistoryIPCClientErrorMapper.outcome(AgentIPCResponseResult(history: HistoryIPCResult())), skew)

        let history = HistoryIPCResult(
            search: HistorySearchIPCResponse(
                scope: "all", project: nil, indexedSessions: 0, complete: true, results: []
            )
        )
        XCTAssertEqual(
            HistoryIPCClientErrorMapper.outcome(AgentIPCResponseResult(history: history)),
            .result(history)
        )
    }
}
