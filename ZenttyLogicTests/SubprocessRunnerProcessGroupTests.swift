import Darwin
import XCTest
@testable import Zentty

final class SubprocessRunnerProcessGroupTests: XCTestCase {
    private var fixture: FakeExecutableFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try FakeExecutableFixture(name: "SubprocessRunnerProcessGroupTests")
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    func test_returns_output_and_exit_status() throws {
        let fake = try fixture.makeExecutable(body: #"echo "out:$1:$ZENTTY_GROUP_TEST"; echo err >&2; exit 7"#)

        let result = try SubprocessRunner.runInProcessGroup(
            executableURL: fake,
            arguments: ["arg"],
            environment: ["ZENTTY_GROUP_TEST": "env"],
            timeout: 10,
            terminationGracePeriod: 1
        )

        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out:arg:env\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
    }

    func test_drains_output_larger_than_the_pipe_buffer() throws {
        let fake = try fixture.makeExecutable(body: "printf '%0200000d' 0; printf '%0200000d' 0 >&2")

        let result = try SubprocessRunner.runInProcessGroup(
            executableURL: fake,
            arguments: [],
            timeout: 10,
            terminationGracePeriod: 1
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func test_child_leads_its_own_process_group() throws {
        let fake = try fixture.makeExecutable(body: "echo \"$$ $(ps -o pgid= -p $$ | tr -d ' ')\"")

        let result = try SubprocessRunner.runInProcessGroup(
            executableURL: fake,
            arguments: [],
            timeout: 10,
            terminationGracePeriod: 1
        )

        let fields = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first, fields.last, "pid must equal pgid")
        XCTAssertNotEqual(fields.last, String(getpgrp()), "the child must not share the test runner's group")
    }

    /// The reason this runner exists: a timed-out child gets `SIGTERM` (not `SIGKILL`), so its
    /// cleanup runs, and the helpers it spawned are signalled too.
    func test_timeout_sends_sigterm_to_the_group_so_cleanup_runs() throws {
        let marker = fixture.directory.appendingPathComponent("cleaned")
        let helperPIDFile = fixture.trackPIDFile(named: "helper.pid")
        let fake = try fixture.makeExecutable(body: """
        trap "echo cleaned > '\(marker.path)'; exit 143" TERM
        /bin/sleep 30 &
        echo $! > '\(helperPIDFile.path)'
        wait $!
        """)
        try fixture.prewarm(fake)

        let startedAt = Date()
        XCTAssertThrowsError(try SubprocessRunner.runInProcessGroup(
            executableURL: fake,
            arguments: [],
            timeout: 2,
            terminationGracePeriod: 5
        )) { error in
            XCTAssertEqual(error as? SubprocessError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 6, "a child that exits on SIGTERM must not wait out the grace")
        XCTAssertEqual(try? String(contentsOf: marker, encoding: .utf8), "cleaned\n")
        try assertEventuallyGone(pidFile: helperPIDFile, "the helper in the child's group must be signalled too")
    }

    func test_child_ignoring_sigterm_is_killed_after_the_grace_period() throws {
        let pidFile = fixture.trackPIDFile(named: "child.pid")
        let fake = try fixture.makeExecutable(body: """
        echo $$ > '\(pidFile.path)'
        trap '' TERM
        exec /bin/sleep 30
        """)
        try fixture.prewarm(fake)

        let startedAt = Date()
        XCTAssertThrowsError(try SubprocessRunner.runInProcessGroup(
            executableURL: fake,
            arguments: [],
            timeout: 2,
            terminationGracePeriod: 1
        )) { error in
            XCTAssertEqual(error as? SubprocessError, .timedOut)
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(elapsed, 2.9, "SIGKILL only after the grace period")
        XCTAssertLessThan(elapsed, 8)
        try fixture.assertProcessReaped(pidFile: pidFile, "timed-out child must be killed and reaped")
    }

    func test_launch_failure_throws() {
        let missing = fixture.directory.appendingPathComponent("missing-executable")

        XCTAssertThrowsError(try SubprocessRunner.runInProcessGroup(
            executableURL: missing,
            arguments: [],
            timeout: 1,
            terminationGracePeriod: 1
        )) { error in
            guard case .launchFailed = error as? SubprocessError else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }

    /// An orphaned helper is reaped by launchd, not by us, so give that a moment.
    private func assertEventuallyGone(pidFile: URL, _ message: String) throws {
        let pid = try XCTUnwrap(FakeExecutableFixture.readPID(from: pidFile))
        let deadline = Date().addingTimeInterval(3)
        while FakeExecutableFixture.isProcessAlive(pid), Date() < deadline {
            usleep(20_000)
        }
        try fixture.assertProcessReaped(pidFile: pidFile, message)
    }
}
