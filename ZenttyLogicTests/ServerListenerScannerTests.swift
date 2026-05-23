import Darwin
import XCTest
@testable import Zentty

final class ServerListenerScannerTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-1")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")
    private let date = Date(timeIntervalSince1970: 1_000)

    func test_attributes_listener_by_shell_pid_descendant() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "127.0.0.1", port: 5173)],
                parentByPID: [300: 200, 200: 100],
                cwdByPID: [:]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: "/tmp/project", shellPID: 100)
        ]))

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].paneID, paneA)
        XCTAssertEqual(servers[0].confidence, .pid)
        XCTAssertEqual(servers[0].origin, "http://localhost:5173")
        XCTAssertEqual(servers[0].source, .scanner)
    }

    func test_attributes_listener_by_matching_cwd_when_pid_tree_unavailable() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "localhost", port: 3000)],
                parentByPID: [:],
                cwdByPID: [300: "/tmp/project/frontend"]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(
                paneID: paneA,
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                shellPID: nil
            )
        ]))

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].paneID, paneA)
        XCTAssertEqual(servers[0].confidence, .cwd)
    }

    func test_attributes_nested_cwd_to_deepest_matching_pane() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "localhost", port: 3000)],
                parentByPID: [:],
                cwdByPID: [300: "/tmp/project/frontend/src"]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(
                paneID: paneA,
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                shellPID: nil
            ),
            PaneScanContext(
                paneID: paneB,
                workingDirectory: "/tmp/project/frontend",
                repositoryRoot: "/tmp/project",
                shellPID: nil
            ),
        ]))

        XCTAssertEqual(servers.single?.paneID, paneB)
        XCTAssertEqual(servers.single?.confidence, .cwd)
    }

    func test_returns_worklane_level_result_for_ambiguous_matching_cwd() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "0.0.0.0", port: 8080)],
                parentByPID: [:],
                cwdByPID: [300: "/tmp/project/frontend"]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(
                paneID: paneA,
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                shellPID: nil
            ),
            PaneScanContext(
                paneID: paneB,
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                shellPID: nil
            ),
        ]))

        XCTAssertEqual(servers.count, 1)
        XCTAssertNil(servers[0].paneID)
        XCTAssertEqual(servers[0].confidence, .worklane)
        XCTAssertEqual(servers[0].origin, "http://localhost:8080")
    }

    func test_ipv6_listener_host_is_normalized() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "::1", port: 8080)],
                parentByPID: [300: 100],
                cwdByPID: [:]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: "/tmp/project", shellPID: 100)
        ]))

        XCTAssertEqual(servers.single?.origin, "http://localhost:8080")
        XCTAssertEqual(servers.single?.display, "localhost:8080")
    }

    func test_ignores_non_listening_tcp_socket() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(sockets: [], parentByPID: [:], cwdByPID: [:]),
            currentDate: { date }
        )

        XCTAssertTrue(scanner.scan(context: context(panes: [])).isEmpty)
    }

    func test_ignores_non_web_public_address() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "93.184.216.34", port: 3000)],
                parentByPID: [300: 100],
                cwdByPID: [300: "/tmp/project"]
            ),
            currentDate: { date }
        )

        XCTAssertTrue(scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: "/tmp/project", shellPID: 100)
        ])).isEmpty)
    }

    func test_unreadable_processes_do_not_fail_scan() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [
                    ListeningSocket(pid: 300, localHost: "localhost", port: 3000),
                    ListeningSocket(pid: 400, localHost: "localhost", port: 4000),
                ],
                parentByPID: [400: 100],
                cwdByPID: [:]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: "/tmp/project", shellPID: 100)
        ]))

        XCTAssertEqual(servers.map(\.origin), ["http://localhost:4000"])
    }

    func test_ignores_cwd_match_from_broad_roots() throws {
        let homePath = NSHomeDirectory()
        let cases = [
            (panePath: "/", processPath: "/usr/local/share/service"),
            (panePath: "/tmp", processPath: "/tmp/project"),
            (panePath: "/private/tmp", processPath: "/private/tmp/project"),
            (panePath: "/var/tmp", processPath: "/var/tmp/project"),
            (panePath: "/Users", processPath: "\(homePath)/Library/Application Support/Redis"),
            (panePath: homePath, processPath: "\(homePath)/Library/Application Support/Redis"),
        ]

        for testCase in cases {
            let date = date
            let scanner = ServerListenerScanner(
                processInspector: FakeProcessInspector(
                    sockets: [ListeningSocket(pid: 300, localHost: "localhost", port: 6379)],
                    parentByPID: [:],
                    cwdByPID: [300: testCase.processPath]
                ),
                currentDate: { date }
            )

            let servers = scanner.scan(context: context(panes: [
                PaneScanContext(
                    paneID: paneA,
                    workingDirectory: testCase.panePath,
                    repositoryRoot: testCase.panePath,
                    shellPID: nil
                )
            ]))

            XCTAssertTrue(servers.isEmpty, "Expected no cwd attribution for \(testCase.panePath)")
        }
    }

    func test_ignores_cwd_match_without_repository_root() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "localhost", port: 3000)],
                parentByPID: [:],
                cwdByPID: [300: "/tmp/project/frontend"]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: "/tmp/project", shellPID: nil)
        ]))

        XCTAssertTrue(servers.isEmpty)
    }

    func test_pid_descendant_attribution_still_works_from_home_directory() throws {
        let homePath = NSHomeDirectory()
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [ListeningSocket(pid: 300, localHost: "localhost", port: 3000)],
                parentByPID: [300: 200, 200: 100],
                cwdByPID: [300: "\(homePath)/Library/Application Support/App"]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: homePath, shellPID: 100)
        ]))

        XCTAssertEqual(servers.single?.paneID, paneA)
        XCTAssertEqual(servers.single?.confidence, .pid)
        XCTAssertEqual(servers.single?.origin, "http://localhost:3000")
    }

    func test_later_discovered_subprocess_server_gets_newer_timestamp() throws {
        let date = date
        let scanner = ServerListenerScanner(
            processInspector: FakeProcessInspector(
                sockets: [
                    ListeningSocket(pid: 300, localHost: "localhost", port: 4568),
                    ListeningSocket(pid: 400, localHost: "localhost", port: 4567),
                ],
                parentByPID: [
                    300: 100,
                    400: 100,
                ],
                cwdByPID: [:]
            ),
            currentDate: { date }
        )

        let servers = scanner.scan(context: context(panes: [
            PaneScanContext(paneID: paneA, workingDirectory: "/tmp/project", shellPID: 100)
        ]))

        XCTAssertEqual(servers.map(\.origin), ["http://localhost:4568", "http://localhost:4567"])
        XCTAssertGreaterThan(try XCTUnwrap(servers.last?.updatedAt), try XCTUnwrap(servers.first?.updatedAt))
    }

    private func context(panes: [PaneScanContext]) -> ServerScanContext {
        ServerScanContext(worklaneID: worklaneID, panes: panes)
    }
}

private struct FakeProcessInspector: ProcessInspecting {
    let sockets: [ListeningSocket]
    let parentByPID: [pid_t: pid_t]
    let cwdByPID: [pid_t: String]

    func listeningTCPSockets() -> [ListeningSocket] {
        sockets
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        parentByPID[pid]
    }

    func workingDirectory(of pid: pid_t) -> String? {
        cwdByPID[pid]
    }

    func isProcessAlive(_ pid: pid_t) -> Bool {
        parentByPID[pid] != nil || cwdByPID[pid] != nil
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
