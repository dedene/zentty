import Darwin
import XCTest
@testable import Zentty

final class SubprocessRunnerTests: XCTestCase {
    private var fixture: FakeExecutableFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try FakeExecutableFixture(name: "SubprocessRunnerTests")
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    func test_returns_stdout_larger_than_the_pipe_buffer() throws {
        let fake = try fixture.makeExecutable(body: "printf '%0200000d' 0")

        let result = try SubprocessRunner.run(executableURL: fake, arguments: [], timeout: 5)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func test_drains_stderr_larger_than_the_pipe_buffer() throws {
        let fake = try fixture.makeExecutable(body: "printf '%0200000d' 0 >&2; echo done")

        let result = try SubprocessRunner.run(executableURL: fake, arguments: [], timeout: 5)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stderr.count, 200_000)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }

    func test_reports_non_zero_exit_in_result() throws {
        let fake = try fixture.makeExecutable(body: "echo out; echo err >&2; exit 7")

        let result = try SubprocessRunner.run(executableURL: fake, arguments: [], timeout: 5)

        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
    }

    func test_passes_arguments_environment_and_working_directory() throws {
        let fake = try fixture.makeExecutable(body: #"echo "$1|$ZENTTY_SUBPROCESS_TEST|$(pwd -P)""#)
        // `pwd -P` reports the physical path (/private/var/…), so compare to realpath.
        let workingDirectory = try XCTUnwrap(realpath(fixture.directory.path, nil).map { pointer in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        })

        let result = try SubprocessRunner.run(
            executableURL: fake,
            arguments: ["arg"],
            environment: ["ZENTTY_SUBPROCESS_TEST": "env"],
            currentDirectoryURL: workingDirectory,
            timeout: 5
        )

        XCTAssertEqual(
            String(decoding: result.stdout, as: UTF8.self),
            "arg|env|\(workingDirectory.path)\n"
        )
    }

    func test_child_that_ignores_sigterm_is_killed_and_reaped_on_timeout() throws {
        let pidFile = fixture.trackPIDFile(named: "child.pid")
        let fake = try fixture.makeExecutable(body: """
        echo $$ > '\(pidFile.path)'
        trap '' TERM
        printf '%0200000d' 0
        exec /bin/sleep 30
        """)
        try fixture.prewarm(fake)

        let startedAt = Date()
        XCTAssertThrowsError(try SubprocessRunner.run(executableURL: fake, arguments: [], timeout: 3)) { error in
            XCTAssertEqual(error as? SubprocessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 6)

        try fixture.assertProcessReaped(pidFile: pidFile, "timed-out child must be killed and reaped")
    }

    func test_grandchild_holding_the_pipe_does_not_block_after_child_exit() throws {
        let pidFile = fixture.trackPIDFile(named: "grandchild.pid")
        let fake = try fixture.makeExecutable(body: """
        echo out
        /bin/sleep 30 &
        echo $! > '\(pidFile.path)'
        exit 0
        """)
        try fixture.prewarm(fake)

        let startedAt = Date()
        let result = try SubprocessRunner.run(executableURL: fake, arguments: [], timeout: 10)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func test_launch_failure_throws() {
        let missing = fixture.directory.appendingPathComponent("missing-executable")

        XCTAssertThrowsError(try SubprocessRunner.run(executableURL: missing, arguments: [], timeout: 1)) { error in
            guard case .launchFailed = error as? SubprocessError else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }
}
