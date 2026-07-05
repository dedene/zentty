import XCTest
@testable import Zentty

final class PaneSSHProcessProbeTests: XCTestCase {
    func test_destination_from_argv_parses_supported_ssh_forms() throws {
        struct Case {
            let argv: [String]
            let target: String
            let user: String?
            let host: String
            let port: Int?
        }

        let cases = [
            Case(argv: ["ssh", "host"], target: "host", user: nil, host: "host", port: nil),
            Case(argv: ["ssh", "user@host"], target: "user@host", user: "user", host: "host", port: nil),
            Case(argv: ["ssh", "-p", "2222", "host"], target: "host", user: nil, host: "host", port: 2222),
            Case(argv: ["ssh", "-l", "user", "host"], target: "user@host", user: "user", host: "host", port: nil),
            Case(argv: ["ssh", "-i", "/k", "-o", "ProxyJump=b", "host"], target: "host", user: nil, host: "host", port: nil),
            Case(argv: ["ssh", "user@2001:db8::1"], target: "user@2001:db8::1", user: "user", host: "2001:db8::1", port: nil),
            Case(argv: ["ssh", "user@[2001:db8::1]"], target: "user@[2001:db8::1]", user: "user", host: "[2001:db8::1]", port: nil),
            Case(argv: ["ssh", "-p", "2222", "2001:db8::1"], target: "2001:db8::1", user: nil, host: "2001:db8::1", port: 2222),
        ]

        for testCase in cases {
            let destination = try XCTUnwrap(
                PaneSSHProcessProbe.destination(fromArgv: testCase.argv),
                "argv: \(testCase.argv)"
            )
            XCTAssertEqual(destination.target, testCase.target, "argv: \(testCase.argv)")
            XCTAssertEqual(destination.user, testCase.user, "argv: \(testCase.argv)")
            XCTAssertEqual(destination.host, testCase.host, "argv: \(testCase.argv)")
            XCTAssertEqual(destination.port, testCase.port, "argv: \(testCase.argv)")
        }
    }

    func test_scan_returns_destination_when_ssh_is_present() throws {
        let treeProvider = FakePaneSSHProcessTreeProvider(
            pids: [100: [100, 101]],
            names: [100: "zsh", 101: "ssh"]
        )
        let argvProvider = FakePaneSSHArgvProvider(
            argvByPID: [101: ["ssh", "-p", "2222", "peter@gilfoyle.example.test"]]
        )
        let probe = PaneSSHProcessProbe(
            processTreeProvider: treeProvider,
            argvProvider: argvProvider
        )

        let destination = try XCTUnwrap(probe.scan(rootPID: 100))

        XCTAssertEqual(destination.target, "peter@gilfoyle.example.test")
        XCTAssertEqual(destination.user, "peter")
        XCTAssertEqual(destination.host, "gilfoyle.example.test")
        XCTAssertEqual(destination.port, 2222)
    }

    func test_scan_returns_nil_when_ssh_is_absent() {
        let probe = PaneSSHProcessProbe(
            processTreeProvider: FakePaneSSHProcessTreeProvider(
                pids: [100: [100, 101]],
                names: [100: "zsh", 101: "vim"]
            ),
            argvProvider: FakePaneSSHArgvProvider(argvByPID: [:])
        )

        XCTAssertNil(probe.scan(rootPID: 100))
        XCTAssertFalse(probe.hasSSH(rootPID: 100))
    }

    func test_scan_prefers_deepest_nested_ssh() throws {
        let probe = PaneSSHProcessProbe(
            processTreeProvider: FakePaneSSHProcessTreeProvider(
                pids: [100: [100, 101, 102]],
                names: [100: "zsh", 101: "ssh", 102: "ssh"]
            ),
            argvProvider: FakePaneSSHArgvProvider(
                argvByPID: [
                    101: ["ssh", "jump.example.test"],
                    102: ["ssh", "-l", "deploy", "prod.example.test"],
                ]
            )
        )

        let destination = try XCTUnwrap(probe.scan(rootPID: 100))

        XCTAssertEqual(destination.target, "deploy@prod.example.test")
        XCTAssertEqual(destination.user, "deploy")
        XCTAssertEqual(destination.host, "prod.example.test")
    }

    func test_darwin_process_tree_provider_reads_current_process_name() throws {
        let pid = ProcessInfo.processInfo.processIdentifier

        let processName = try XCTUnwrap(DarwinPaneSSHProcessTreeProvider().processName(pid: pid))

        XCTAssertFalse(processName.isEmpty)
    }

    func test_darwin_argv_provider_reads_current_process_arguments() throws {
        let pid = ProcessInfo.processInfo.processIdentifier

        let argv = try XCTUnwrap(DarwinPaneSSHProcessArgvProvider().argv(pid: pid))

        XCTAssertFalse(argv.isEmpty)
    }
}

private struct FakePaneSSHProcessTreeProvider: PaneSSHProcessTreeProviding {
    var pids: [Int32: [Int32]]
    var names: [Int32: String]

    func treePIDs(rootPID: Int32) -> [Int32] {
        pids[rootPID] ?? []
    }

    func processName(pid: Int32) -> String? {
        names[pid]
    }
}

private struct FakePaneSSHArgvProvider: PaneSSHProcessArgvProviding {
    var argvByPID: [Int32: [String]]

    func argv(pid: Int32) -> [String]? {
        argvByPID[pid]
    }
}
