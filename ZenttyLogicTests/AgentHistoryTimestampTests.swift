import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryTimestampTests: XCTestCase {
    private func ms(_ text: String) -> Int64? {
        AgentHistoryTimestamp.milliseconds(iso8601: text)
    }

    /// Reference value from Foundation for the whole-second part.
    private func reference(_ text: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return Int64((formatter.date(from: text)?.timeIntervalSince1970 ?? .nan) * 1_000)
    }

    func test_utc_without_fraction() {
        XCTAssertEqual(ms("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(ms("2026-10-31T12:34:56Z"), reference("2026-10-31T12:34:56Z"))
        XCTAssertEqual(ms("2024-02-29T23:59:59Z"), reference("2024-02-29T23:59:59Z"))
        XCTAssertEqual(ms("1969-12-31T23:59:59Z"), -1_000)
    }

    func test_fraction_digits_milli_micro_nano() {
        let base = reference("2026-10-31T12:34:56Z")
        XCTAssertEqual(ms("2026-10-31T12:34:56.1Z"), base + 100)
        XCTAssertEqual(ms("2026-10-31T12:34:56.12Z"), base + 120)
        XCTAssertEqual(ms("2026-10-31T12:34:56.123Z"), base + 123)
        XCTAssertEqual(ms("2026-10-31T12:34:56.123456Z"), base + 123, "microseconds truncate")
        XCTAssertEqual(ms("2026-10-31T12:34:56.987654321Z"), base + 987, "nanoseconds truncate")
        XCTAssertNil(ms("2026-10-31T12:34:56.1234567890Z"), "more than 9 digits")
        XCTAssertNil(ms("2026-10-31T12:34:56.Z"), "separator without digits")
    }

    func test_offsets() {
        let utc = reference("2026-10-31T12:34:56Z")
        XCTAssertEqual(ms("2026-10-31T14:34:56+02:00"), utc)
        XCTAssertEqual(ms("2026-10-31T14:34:56+0200"), utc)
        XCTAssertEqual(ms("2026-10-31T14:34:56+02"), utc)
        XCTAssertEqual(ms("2026-10-31T07:04:56-05:30"), utc)
        XCTAssertEqual(ms("2026-10-31T12:34:56.5-00:00"), utc + 500)
        XCTAssertEqual(ms("2026-10-31 12:34:56z"), utc, "space separator and lowercase z")
        XCTAssertEqual(ms("2026-10-31T12:34Z"), utc - 56_000, "seconds are optional")
    }

    func test_invalid() {
        for text in [
            "",
            "2026-10-31",
            "2026-10-31T12:34:56",       // no zone
            "2026-13-01T00:00:00Z",
            "2026-02-29T00:00:00Z",      // not a leap year
            "2026-10-32T00:00:00Z",
            "2026-10-31T24:00:00Z",
            "2026-10-31T12:60:00Z",
            "2026-10-31T12:34:56+25:00",
            "2026-10-31T12:34:56+02:60",
            "2026-10-31T12:34:56Zjunk",
            "26-10-31T12:34:56Z",
            "2026/10/31T12:34:56Z",
            "1761914096",
        ] {
            XCTAssertNil(ms(text), text)
        }
    }
}
