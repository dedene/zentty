import XCTest
@testable import Zentty

final class ServerURLNormalizerTests: XCTestCase {
    func test_bare_port_normalizes_to_localhost_http_url() throws {
        let result = try ServerURLNormalizer.normalize("3000")

        XCTAssertEqual(result.url.absoluteString, "http://localhost:3000/")
        XCTAssertEqual(result.origin, "http://localhost:3000")
        XCTAssertEqual(result.display, "localhost:3000")
        XCTAssertEqual(result.port, 3000)
    }

    func test_host_port_preserves_localhost() throws {
        let result = try ServerURLNormalizer.normalize("localhost:5173")

        XCTAssertEqual(result.url.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(result.origin, "http://localhost:5173")
    }

    func test_full_url_preserves_path_query_and_fragment() throws {
        let result = try ServerURLNormalizer.normalize("http://127.0.0.1:8080/docs?q=1#top")

        XCTAssertEqual(result.url.absoluteString, "http://localhost:8080/docs?q=1#top")
        XCTAssertEqual(result.origin, "http://localhost:8080")
        XCTAssertEqual(result.display, "localhost:8080")
    }

    func test_wildcard_host_normalizes_to_localhost() throws {
        let result = try ServerURLNormalizer.normalize("http://0.0.0.0:5173/")

        XCTAssertEqual(result.url.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(result.origin, "http://localhost:5173")
        XCTAssertEqual(result.display, "localhost:5173")
    }

    func test_bracketed_ipv6_wildcard_host_normalizes_to_localhost() throws {
        let result = try ServerURLNormalizer.normalize("http://[::]:5173/")

        XCTAssertEqual(result.url.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(result.origin, "http://localhost:5173")
    }

    func test_loopback_ipv6_host_is_accepted() throws {
        let result = try ServerURLNormalizer.normalize("http://[::1]:8080/")

        XCTAssertEqual(result.url.absoluteString, "http://localhost:8080/")
        XCTAssertEqual(result.origin, "http://localhost:8080")
        XCTAssertEqual(result.display, "localhost:8080")
    }

    func test_private_lan_host_is_accepted() throws {
        let result = try ServerURLNormalizer.normalize("http://192.168.1.20:4173/")

        XCTAssertEqual(result.url.absoluteString, "http://192.168.1.20:4173/")
        XCTAssertEqual(result.origin, "http://192.168.1.20:4173")
    }

    func test_local_hostname_is_accepted() throws {
        let result = try ServerURLNormalizer.normalize("my-app.local:8080")

        XCTAssertEqual(result.url.absoluteString, "http://my-app.local:8080/")
        XCTAssertEqual(result.origin, "http://my-app.local:8080")
    }

    func test_public_host_is_rejected() {
        XCTAssertThrowsError(try ServerURLNormalizer.normalize("https://example.com:443")) { error in
            XCTAssertEqual(error as? ServerURLNormalizer.Error, .unsupportedHost("example.com"))
        }
    }

    func test_public_url_without_port_is_rejected_by_host_before_missing_port() {
        XCTAssertThrowsError(try ServerURLNormalizer.normalize("https://example.com")) { error in
            XCTAssertEqual(error as? ServerURLNormalizer.Error, .unsupportedHost("example.com"))
        }
    }

    func test_missing_port_on_supported_host_is_rejected() {
        XCTAssertThrowsError(try ServerURLNormalizer.normalize("http://localhost")) { error in
            XCTAssertEqual(error as? ServerURLNormalizer.Error, .missingPort)
        }
    }

    func test_non_http_scheme_is_rejected() {
        XCTAssertThrowsError(try ServerURLNormalizer.normalize("file://localhost:3000")) { error in
            XCTAssertEqual(error as? ServerURLNormalizer.Error, .unsupportedScheme("file"))
        }
    }
}
