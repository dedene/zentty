import XCTest
@testable import Zentty

final class DefaultWorklaneReviewCommandRunnerTests: XCTestCase {
    private var fixture: FakeExecutableFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try FakeExecutableFixture(name: "DefaultWorklaneReviewCommandRunnerTests")
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    func test_returns_full_stdout_larger_than_the_pipe_buffer() async throws {
        let fake = try fixture.makeExecutable(body: "printf '%0200000d' 0")
        let runner = DefaultWorklaneReviewCommandRunner(environment: ["PATH": "/usr/bin:/bin"])

        let result = await runner.run(arguments: [fake.path], currentDirectoryPath: fixture.directory.path)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func test_reports_launch_failure_as_status_minus_one() async {
        let missing = fixture.directory.appendingPathComponent("missing-executable").path
        let runner = DefaultWorklaneReviewCommandRunner(environment: ["PATH": "/usr/bin:/bin"])

        let result = await runner.run(arguments: [missing], currentDirectoryPath: fixture.directory.path)

        XCTAssertEqual(result.terminationStatus, -1)
        XCTAssertTrue(result.stdout.isEmpty)
    }
}
