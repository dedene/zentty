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

    func test_detects_url_written_across_two_chunks() throws {
        let detections = try runDetectingURLs(script: """
        printf 'Listening: http://local'
        /bin/sleep 0.2
        printf 'host:3000\\n'
        """)

        XCTAssertEqual(detections.map(\.origin), ["http://localhost:3000"])
    }

    func test_detects_url_on_a_line_with_a_character_split_across_chunks() throws {
        let detections = try runDetectingURLs(script: """
        printf '\\303'
        /bin/sleep 0.2
        printf '\\251 http://localhost:3000\\n'
        """)

        XCTAssertEqual(detections.map(\.origin), ["http://localhost:3000"])
    }

    func test_detects_url_in_an_unterminated_line_at_exit() throws {
        let detections = try runDetectingURLs(script: "printf 'http://localhost:3000'")

        XCTAssertEqual(detections.map(\.origin), ["http://localhost:3000"])
    }

    func test_stdout_and_stderr_never_share_a_partial_line() throws {
        let detections = try runDetectingURLs(script: """
        printf 'http://local'
        printf 'http://localhost:4000\\n' >&2
        /bin/sleep 0.2
        printf 'host:3000\\n'
        """)

        XCTAssertEqual(Set(detections.map(\.origin)), ["http://localhost:3000", "http://localhost:4000"])
    }

    func test_partial_line_is_forwarded_before_its_newline_arrives() throws {
        let stdoutURL = fixture.directory.appendingPathComponent("partial.log")
        let observedURL = fixture.directory.appendingPathComponent("observed.log")
        let fake = try fixture.makeExecutable(body: """
        printf 'partial'
        /bin/sleep 0.5
        /bin/cat '\(stdoutURL.path)' > '\(observedURL.path)'
        printf ' line\\n'
        """)
        let output = try makeOutputFile(at: stdoutURL)
        let runner = ServerWatchRunner(
            handleDetection: { _ in },
            output: output,
            errorOutput: try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        )

        _ = try runner.run(command: [fake.path], environment: ["PATH": "/usr/bin:/bin"])
        try output.close()

        XCTAssertEqual(try String(contentsOf: observedURL, encoding: .utf8), "partial")
        XCTAssertEqual(try String(contentsOf: stdoutURL, encoding: .utf8), "partial line\n")
    }

    func test_line_buffer_detects_url_split_across_chunks() {
        var buffer = ServerWatchLineBuffer()

        XCTAssertNil(buffer.append(Data("Listening: http://local".utf8)))
        let lines = buffer.append(Data("host:3000\n".utf8))

        XCTAssertEqual(lines, "Listening: http://localhost:3000\n")
        XCTAssertEqual(ServerOutputURLDetector.detect(in: lines ?? "").map(\.origin), ["http://localhost:3000"])
    }

    func test_line_buffer_handles_utf8_split() {
        var buffer = ServerWatchLineBuffer()

        XCTAssertNil(buffer.append(Data([0xC3])))

        XCTAssertEqual(buffer.append(Data([0xA9]) + Data(" http://localhost:3000\n".utf8)), "é http://localhost:3000\n")
    }

    func test_line_buffer_keeps_detecting_lines_with_invalid_utf8() {
        var buffer = ServerWatchLineBuffer()

        let lines = buffer.append(Data([0xFF]) + Data(" http://localhost:3000\n".utf8))

        XCTAssertEqual(ServerOutputURLDetector.detect(in: lines ?? "").map(\.origin), ["http://localhost:3000"])
    }

    func test_line_buffer_returns_every_complete_line_and_keeps_the_tail() {
        var buffer = ServerWatchLineBuffer()

        XCTAssertEqual(buffer.append(Data("one\ntwo\nthr".utf8)), "one\ntwo\n")
        XCTAssertEqual(buffer.flush(), "thr")
    }

    func test_line_buffer_flushes_unterminated_tail_at_exit() {
        var buffer = ServerWatchLineBuffer()

        XCTAssertNil(buffer.append(Data("http://localhost:3000".utf8)))

        XCTAssertEqual(buffer.flush(), "http://localhost:3000")
        XCTAssertNil(buffer.flush(), "The tail is reported once")
    }

    func test_line_buffer_caps_unbounded_lines() {
        var buffer = ServerWatchLineBuffer(capacity: 8)

        XCTAssertNil(buffer.append(Data("0123456789".utf8)))
        XCTAssertNil(buffer.append(Data("abc".utf8)))

        XCTAssertEqual(buffer.flush(), "56789abc", "The oldest bytes go first")
    }

    private func runDetectingURLs(script: String) throws -> [ServerURLCandidate] {
        let fake = try fixture.makeExecutable(body: script)
        let detections = DetectionBox()
        let runner = ServerWatchRunner(
            handleDetection: { detections.append($0) },
            output: try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null")),
            errorOutput: try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        )

        _ = try runner.run(command: [fake.path], environment: ["PATH": "/usr/bin:/bin"])
        return detections.values
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
