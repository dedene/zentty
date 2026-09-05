import XCTest
@testable import Zentty

final class OnePasswordPromptAttributorTests: XCTestCase {
    private let agentSocket = "/Users/peter/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    func test_finds_pane_running_op_cli() {
        let provider = FakeOnePasswordProcessProvider(
            trees: [100: [100, 101, 102]],
            names: [100: "zsh", 101: "claude", 102: "op"],
            argv: [102: ["op", "read", "op://vault/item"]],
            startTimes: [102: 50]
        )
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        let candidate = attributor.bestCandidate(in: [source(pane: "a", rootPID: 100)])

        XCTAssertEqual(candidate?.source.paneID, PaneID("a"))
        XCTAssertEqual(candidate?.kind, .cli)
        XCTAssertEqual(candidate?.pid, 102)
    }

    func test_ignores_op_daemon_and_panes_without_requests() {
        let provider = FakeOnePasswordProcessProvider(
            trees: [100: [100, 101], 200: [200]],
            names: [100: "zsh", 101: "op", 200: "zsh"],
            argv: [101: ["op", "daemon", "--background"]]
        )
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        XCTAssertNil(attributor.bestCandidate(in: [source(pane: "a", rootPID: 100), source(pane: "b", rootPID: 200)]))
    }

    func test_finds_ssh_connected_to_one_password_agent_only() {
        let provider = FakeOnePasswordProcessProvider(
            trees: [100: [100, 101], 200: [200, 201]],
            names: [100: "zsh", 101: "ssh", 200: "zsh", 201: "ssh"],
            peerPaths: [101: ["/tmp/other.sock"], 201: [agentSocket]]
        )
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        let candidates = attributor.candidates(in: [source(pane: "a", rootPID: 100), source(pane: "b", rootPID: 200)])

        XCTAssertEqual(candidates.map(\.source.paneID), [PaneID("b")])
        XCTAssertEqual(candidates.first?.kind, .sshAgent)
    }

    func test_git_using_agent_counts_as_ssh_request() {
        let provider = FakeOnePasswordProcessProvider(
            trees: [100: [100, 101, 102]],
            names: [100: "zsh", 101: "git", 102: "ssh"],
            peerPaths: [102: [agentSocket]]
        )
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        XCTAssertEqual(attributor.bestCandidate(in: [source(pane: "a", rootPID: 100)])?.pid, 102)
    }

    func test_prefers_most_recently_started_request_across_panes() {
        let provider = FakeOnePasswordProcessProvider(
            trees: [100: [100, 101], 200: [200, 201]],
            names: [100: "zsh", 101: "op", 200: "zsh", 201: "op"],
            startTimes: [101: 10, 201: 20]
        )
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        let candidates = attributor.candidates(in: [source(pane: "a", rootPID: 100), source(pane: "b", rootPID: 200)])

        XCTAssertEqual(candidates.map(\.source.paneID), [PaneID("b"), PaneID("a")])
    }

    func test_pane_contributes_only_its_newest_request() {
        let provider = FakeOnePasswordProcessProvider(
            trees: [100: [100, 101, 102]],
            names: [100: "zsh", 101: "op", 102: "op"],
            startTimes: [101: 5, 102: 9]
        )
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        let candidates = attributor.candidates(in: [source(pane: "a", rootPID: 100)])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.pid, 102)
    }

    func test_skips_sources_without_root_pid() {
        let provider = FakeOnePasswordProcessProvider(trees: [:], names: [:])
        let attributor = OnePasswordPromptAttributor(processProvider: provider)

        XCTAssertNil(attributor.bestCandidate(in: [source(pane: "a", rootPID: nil)]))
        XCTAssertTrue(provider.requestedRoots.isEmpty)
    }

    func test_agent_socket_matcher_requires_one_password_container() {
        XCTAssertTrue(OnePasswordPromptAttributor.isOnePasswordAgentSocket(agentSocket))
        XCTAssertFalse(OnePasswordPromptAttributor.isOnePasswordAgentSocket("/tmp/ssh-XXXX/agent.sock"))
        XCTAssertFalse(OnePasswordPromptAttributor.isOnePasswordAgentSocket(
            "/Users/peter/Library/Group Containers/2BUA8C4S2C.com.1password/t/s.sock"
        ))
    }

    private func source(pane: String, rootPID: Int32?) -> OnePasswordPromptPaneSource {
        OnePasswordPromptPaneSource(
            windowID: WindowID("w"),
            worklaneID: WorklaneID("l"),
            paneID: PaneID(pane),
            rootPID: rootPID
        )
    }
}

private final class FakeOnePasswordProcessProvider: OnePasswordPromptProcessProviding, @unchecked Sendable {
    private let trees: [Int32: [Int32]]
    private let names: [Int32: String]
    private let argvByPID: [Int32: [String]]
    private let startTimes: [Int32: TimeInterval]
    private let peerPaths: [Int32: [String]]
    private(set) var requestedRoots: [Int32] = []

    init(
        trees: [Int32: [Int32]],
        names: [Int32: String],
        argv: [Int32: [String]] = [:],
        startTimes: [Int32: TimeInterval] = [:],
        peerPaths: [Int32: [String]] = [:]
    ) {
        self.trees = trees
        self.names = names
        self.argvByPID = argv
        self.startTimes = startTimes
        self.peerPaths = peerPaths
    }

    func treePIDs(rootPID: Int32) -> [Int32] {
        requestedRoots.append(rootPID)
        return trees[rootPID] ?? []
    }

    func processName(pid: Int32) -> String? { names[pid] }
    func argv(pid: Int32) -> [String]? { argvByPID[pid] }
    func startTime(pid: Int32) -> TimeInterval? { startTimes[pid] }
    func unixSocketPeerPaths(pid: Int32) -> [String] { peerPaths[pid] ?? [] }
}
