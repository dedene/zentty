import XCTest
@testable import Zentty

final class FloatNameInferrerTests: XCTestCase {
    func testFirstCommandBecomesName() {
        var inferrer = FloatNameInferrer()
        let result = inferrer.observe(command: "lazygit")
        XCTAssertEqual(result, FloatName(value: "lazygit"))
    }

    func testShellCommandsAreSkipped() {
        var inferrer = FloatNameInferrer()
        XCTAssertNil(inferrer.observe(command: "bash"))
        XCTAssertNil(inferrer.observe(command: "fish"))
        XCTAssertNil(inferrer.observe(command: "zsh"))
        XCTAssertNil(inferrer.observe(command: "nu"))
        XCTAssertEqual(inferrer.observe(command: "claude"), FloatName(value: "claude"))
    }

    func testQuotedAndPathCommandsExtractBasename() {
        var inferrer = FloatNameInferrer()
        XCTAssertEqual(
            inferrer.observe(command: "/usr/local/bin/lazygit"),
            FloatName(value: "lazygit")
        )
    }

    func testOnceNamedSubsequentCommandsIgnored() {
        var inferrer = FloatNameInferrer()
        _ = inferrer.observe(command: "lazygit")
        XCTAssertNil(inferrer.observe(command: "claude"))
    }

    func testCommandWithArgumentsUsesProgramName() {
        var inferrer = FloatNameInferrer()
        XCTAssertEqual(
            inferrer.observe(command: "claude --resume"),
            FloatName(value: "claude")
        )
    }

    func testEmptyOrWhitespaceOnlyCommandIsNoop() {
        var inferrer = FloatNameInferrer()
        XCTAssertNil(inferrer.observe(command: ""))
        XCTAssertNil(inferrer.observe(command: "   "))
        XCTAssertEqual(inferrer.observe(command: "tig"), FloatName(value: "tig"))
    }
}
