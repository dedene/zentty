import XCTest
@testable import Zentty

/// `zentty history` takes one main-thread hop for the pane; the exclusions matcher (it may
/// resolve symlinks on a cold cache) is built after that hop, on the IPC thread.
final class HistoryIPCHandlerCallerTests: XCTestCase {
    func test_exclusions_are_built_after_the_main_hop_off_main() throws {
        let log = CallLog()
        let built = expectation(description: "caller built")
        DispatchQueue.global(qos: .userInitiated).async {
            let caller = try? HistoryIPCHandler.makeCaller(
                pane: {
                    try PaneControlIPCHandler.onMain {
                        log.append("pane", isMain: Thread.isMainThread)
                        return HistoryIPCPaneSnapshot(
                            paneCWD: "/tmp/agent-history-ipc/repo", paneRepoRoot: nil, isRemotePane: false,
                            allowAgentsAllProjects: true, liveKeys: [], dataSource: nil,
                            exclusions: {
                                log.append("exclusions", isMain: Thread.isMainThread)
                                return AgentHistoryExclusionMatcher(folders: [])
                            }
                        )
                    }
                }
            )
            XCTAssertEqual(caller?.paneCWD, "/tmp/agent-history-ipc/repo")
            XCTAssertEqual(caller?.allowAgentsAllProjects, true)
            built.fulfill()
        }
        wait(for: [built], timeout: 5)

        XCTAssertEqual(log.entries.map(\.name), ["pane", "exclusions"])
        XCTAssertEqual(log.entries.map(\.isMain), [true, false], "only the pane snapshot runs on main")
    }

    func test_a_failed_main_hop_throws() {
        XCTAssertThrowsError(try HistoryIPCHandler.makeCaller(pane: { throw PaneRoutingError.paneNotFound }))
    }
}

private final class CallLog: @unchecked Sendable {
    struct Entry {
        let name: String
        let isMain: Bool
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    func append(_ name: String, isMain: Bool) {
        lock.withLock { stored.append(Entry(name: name, isMain: isMain)) }
    }

    var entries: [Entry] { lock.withLock { stored } }
}
