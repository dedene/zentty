import XCTest
@testable import Zentty

final class ServerOutputURLDetectorTests: XCTestCase {
    func test_detects_localhost_url_in_dev_server_output() throws {
        let detections = ServerOutputURLDetector.detect(in: "Local: http://localhost:5173/")

        XCTAssertEqual(detections.map(\.origin), ["http://localhost:5173"])
        XCTAssertEqual(detections.first?.url.absoluteString, "http://localhost:5173/")
    }

    func test_detects_lan_url_in_dev_server_output() throws {
        let detections = ServerOutputURLDetector.detect(in: "Network: http://192.168.1.20:5173/")

        XCTAssertEqual(detections.map(\.origin), ["http://192.168.1.20:5173"])
    }

    func test_ignores_public_url_in_output() throws {
        let detections = ServerOutputURLDetector.detect(in: "Docs: https://example.com:443 Local: http://localhost:3000/")

        XCTAssertEqual(detections.map(\.origin), ["http://localhost:3000"])
    }

    func test_prefers_localhost_when_output_contains_localhost_and_lan() throws {
        let detections = ServerOutputURLDetector.detect(
            in: "Local: http://localhost:5173/\nNetwork: http://192.168.1.20:5173/"
        )

        XCTAssertEqual(detections.first?.origin, "http://localhost:5173")
        XCTAssertEqual(detections.map(\.origin), ["http://localhost:5173", "http://192.168.1.20:5173"])
    }

    func test_preserves_path_query_fragment() throws {
        let detections = ServerOutputURLDetector.detect(in: "Ready at http://127.0.0.1:8080/docs?q=1#top")

        XCTAssertEqual(detections.first?.origin, "http://localhost:8080")
        XCTAssertEqual(detections.first?.url.absoluteString, "http://localhost:8080/docs?q=1#top")
    }

    func test_trims_common_trailing_punctuation() throws {
        let detections = ServerOutputURLDetector.detect(in: "Open (http://localhost:3000/).")

        XCTAssertEqual(detections.first?.url.absoluteString, "http://localhost:3000/")
    }
}
