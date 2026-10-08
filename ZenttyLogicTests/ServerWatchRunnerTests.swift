import XCTest
@testable import Zentty

final class ServerWatchRunnerTests: XCTestCase {
    private var fixture: FakeExecutableFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try FakeExecutableFixture(name: "ServerWatchRunnerTests")
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    func test_forwards_and_detects_output_written_right_before_exit() throws {
        let fake = try fixture.makeExecutable(body: """
        echo 'Local: http://localhost:5173/'
        echo 'warning' >&2
        exit 3
        """)
        let stdoutURL = fixture.directory.appendingPathComponent("stdout.log")
        let stderrURL = fixture.directory.appendingPathComponent("stderr.log")
        let output = try makeOutputFile(at: stdoutURL)
        let errorOutput = try makeOutputFile(at: stderrURL)
        let detections = DetectionBox()
        let runner = ServerWatchRunner(
            handleDetection: { detections.append($0) },
            output: output,
            errorOutput: errorOutput
        )

        let status = try runner.run(command: [fake.path], environment: ["PATH": "/usr/bin:/bin"])
        try output.close()
        try errorOutput.close()

        XCTAssertEqual(status, 3)
        XCTAssertEqual(try String(contentsOf: stdoutURL, encoding: .utf8), "Local: http://localhost:5173/\n")
        XCTAssertEqual(try String(contentsOf: stderrURL, encoding: .utf8), "warning\n")
        XCTAssertEqual(detections.values.map(\.port), [5173])
    }

    func test_grandchild_that_keeps_writing_does_not_keep_run_alive() throws {
        let pidFile = fixture.trackPIDFile(named: "writer.pid")
        let fake = try fixture.makeExecutable(body: """
        /usr/bin/yes spam &
        echo $! > '\(pidFile.path)'
        exit 0
        """)
        try fixture.prewarm(fake)
        let runner = ServerWatchRunner(
            handleDetection: { _ in },
            output: try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null")),
            errorOutput: try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        )

        let startedAt = Date()
        let status = try runner.run(command: [fake.path], environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    private func makeOutputFile(at url: URL) throws -> FileHandle {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        return try FileHandle(forWritingTo: url)
    }
}

private final class DetectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [ServerURLCandidate] = []

    var values: [ServerURLCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: ServerURLCandidate) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}
