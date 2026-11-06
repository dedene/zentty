import XCTest
@testable import Zentty

final class AgentEventSerializerTests: XCTestCase {
    private static let settleTime: DispatchTimeInterval = .milliseconds(200)
    private static let completionTime: DispatchTimeInterval = .seconds(10)

    func test_same_pane_events_never_overlap() {
        let serializer = AgentEventSerializer()
        let firstStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            serializer.run(paneID: "pane-1") {
                firstStarted.signal()
                release.wait()
            }
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + Self.completionTime), .success)

        DispatchQueue.global().async {
            serializer.run(paneID: "pane-1") {
                secondStarted.signal()
            }
        }

        XCTAssertEqual(secondStarted.wait(timeout: .now() + Self.settleTime), .timedOut)
        release.signal()
        XCTAssertEqual(secondStarted.wait(timeout: .now() + Self.completionTime), .success)
    }

    func test_events_for_other_stripes_run_concurrently() throws {
        let serializer = AgentEventSerializer()
        let blockedPane = "pane-0"
        let otherPane = try XCTUnwrap(
            (1..<256).map { "pane-\($0)" }.first {
                serializer.stripeIndex(forPaneID: $0) != serializer.stripeIndex(forPaneID: blockedPane)
            }
        )
        let blockedStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let otherFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            serializer.run(paneID: blockedPane) {
                blockedStarted.signal()
                release.wait()
            }
        }
        XCTAssertEqual(blockedStarted.wait(timeout: .now() + Self.completionTime), .success)

        DispatchQueue.global().async {
            serializer.run(paneID: otherPane) {
                otherFinished.signal()
            }
        }

        XCTAssertEqual(otherFinished.wait(timeout: .now() + Self.completionTime), .success)
        release.signal()
    }

    func test_events_without_a_pane_id_never_overlap() {
        let serializer = AgentEventSerializer()
        let firstStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            serializer.run(paneID: nil) {
                firstStarted.signal()
                release.wait()
            }
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + Self.completionTime), .success)

        DispatchQueue.global().async {
            serializer.run(paneID: nil) {
                secondStarted.signal()
            }
        }

        XCTAssertEqual(secondStarted.wait(timeout: .now() + Self.settleTime), .timedOut)
        release.signal()
        XCTAssertEqual(secondStarted.wait(timeout: .now() + Self.completionTime), .success)
    }

    func test_run_rethrows_and_keeps_serving_the_stripe() throws {
        struct Failure: Error {}
        let serializer = AgentEventSerializer()

        XCTAssertThrowsError(try serializer.run(paneID: "pane-1") { throw Failure() })

        XCTAssertEqual(serializer.run(paneID: "pane-1") { 42 }, 42)
    }

    func test_ipc_agent_events_wait_for_their_pane_stripe() {
        let serializer = AgentEventSerializer()
        let holderStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let posted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            serializer.run(paneID: "pane-main") {
                holderStarted.signal()
                release.wait()
            }
        }
        XCTAssertEqual(holderStarted.wait(timeout: .now() + Self.completionTime), .success)

        let request = Self.agentEventRequest()
        DispatchQueue.global().async {
            _ = try? AgentIPCBridge.handleSerializingAgentEvents(
                request: request,
                serializer: serializer,
                post: { _ in posted.signal() },
                writeError: { _ in }
            )
        }

        XCTAssertEqual(posted.wait(timeout: .now() + Self.settleTime), .timedOut)
        release.signal()
        XCTAssertEqual(posted.wait(timeout: .now() + Self.completionTime), .success)
    }

    func test_ipc_agent_signals_do_not_wait_for_a_pane_stripe() {
        let serializer = AgentEventSerializer()
        let holderStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let posted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            serializer.run(paneID: "pane-main") {
                holderStarted.signal()
                release.wait()
            }
        }
        XCTAssertEqual(holderStarted.wait(timeout: .now() + Self.completionTime), .success)

        let request = Self.agentSignalRequest()
        DispatchQueue.global().async {
            _ = try? AgentIPCBridge.handleSerializingAgentEvents(
                request: request,
                serializer: serializer,
                post: { _ in posted.signal() },
                writeError: { _ in }
            )
        }

        XCTAssertEqual(posted.wait(timeout: .now() + Self.completionTime), .success)
        release.signal()
    }

    private static let routingEnvironment = [
        "ZENTTY_WINDOW_ID": "window-main",
        "ZENTTY_WORKLANE_ID": "worklane-main",
        "ZENTTY_PANE_ID": "pane-main",
    ]

    private static func agentEventRequest() -> AgentIPCRequest {
        AgentIPCRequest(
            kind: .ipc,
            arguments: ["--adapter=codex", "session-start"],
            standardInput: #"{"session_id":"session-codex","cwd":"/tmp/project"}"#,
            environment: routingEnvironment,
            expectsResponse: false,
            subcommand: "agent-event"
        )
    }

    private static func agentSignalRequest() -> AgentIPCRequest {
        AgentIPCRequest(
            kind: .ipc,
            arguments: ["lifecycle", "needs-input", "--tool", "Codex"],
            standardInput: nil,
            environment: routingEnvironment,
            expectsResponse: false,
            subcommand: "agent-signal"
        )
    }
}
