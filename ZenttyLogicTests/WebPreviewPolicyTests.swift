import XCTest
@testable import Zentty

final class WebPreviewPolicyTests: XCTestCase {
    func test_legacy_config_keeps_every_web_capability_disabled() throws {
        let config = try XCTUnwrap(AppConfigTOML.decode("[panes]\nshow_labels = true\n"))
        XCTAssertEqual(config.webPreview, .default)
        XCTAssertFalse(config.webPreview.javaScriptEnabled)
        XCTAssertFalse(config.webPreview.localhostJavaScriptEnabled)
        XCTAssertFalse(config.webPreview.persistentStorageEnabled)
        XCTAssertFalse(config.webPreview.browsingEnabled)
    }

    func test_all_web_settings_round_trip_and_reject_wrong_types() throws {
        var config = AppConfig.default
        config.webPreview = .init(javaScriptEnabled: true, localhostJavaScriptEnabled: true,
                                  persistentStorageEnabled: true, browsingEnabled: true)
        XCTAssertEqual(try XCTUnwrap(AppConfigTOML.decode(AppConfigTOML.encode(config))).webPreview, config.webPreview)
        XCTAssertNil(AppConfigTOML.decode("[web_preview]\njavascript_enabled = \"true\""))
        XCTAssertEqual(AppConfigTOML.decode("[web_preview]\nunknown = true")?.webPreview, .default)
    }

    func test_localhost_exception_accepts_only_loopback_web_addresses() throws {
        var settings = AppConfig.WebPreview.default
        settings.localhostJavaScriptEnabled = true
        for text in ["http://localhost:3000", "https://LOCALHOST", "http://127.0.0.1", "http://127.42.1.2:5000", "http://[::1]:3000"] {
            XCTAssertTrue(WebPreviewPolicy.allowsJavaScript(at: try XCTUnwrap(URL(string: text)), settings: settings), text)
        }
        for text in ["https://localhost.example.com", "https://example.com", "http://192.168.1.2", "http://128.0.0.1", "http://127.0.0.256", "file:///tmp/localhost.html", "about:blank"] {
            XCTAssertFalse(WebPreviewPolicy.allowsJavaScript(at: try XCTUnwrap(URL(string: text)), settings: settings), text)
        }
    }

    func test_global_javascript_requires_opt_in() throws {
        let site = try XCTUnwrap(URL(string: "https://example.com"))
        let file = URL(fileURLWithPath: "/tmp/report.html")
        for url in [site, file] {
            XCTAssertFalse(WebPreviewPolicy.allowsJavaScript(at: url, settings: .default))
            var settings = AppConfig.WebPreview.default
            settings.javaScriptEnabled = true
            XCTAssertTrue(WebPreviewPolicy.allowsJavaScript(at: url, settings: settings))
        }
    }

    func test_browsing_off_keeps_main_frame_on_exact_origin() throws {
        let source = try XCTUnwrap(URL(string: "http://localhost:3000"))
        for text in ["http://localhost:3000/page", "http://LOCALHOST:3000/#section", "about:blank"] {
            XCTAssertTrue(WebPreviewPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: text)), source: source, mainFrame: true, settings: .default), text)
        }
        for text in ["http://localhost:3001", "https://localhost:3000", "http://127.0.0.1:3000", "https://example.com", "file:///tmp/page.html", "data:text/html,hello", "mailto:a@example.com", "zentty://open"] {
            XCTAssertFalse(WebPreviewPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: text)), source: source, mainFrame: true, settings: .default), text)
        }
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertTrue(WebPreviewPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: "https://EXAMPLE.com:443/page")), source: https, mainFrame: true, settings: .default))
    }

    func test_browsing_opt_in_still_rejects_local_files_and_custom_schemes() throws {
        var settings = AppConfig.WebPreview.default
        settings.browsingEnabled = true
        let source = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertTrue(WebPreviewPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: "https://other.example/page")), source: source, mainFrame: true, settings: settings))
        for text in ["file:///tmp/report.html", "data:text/html,hi", "javascript:alert(1)", "custom://open"] {
            XCTAssertFalse(WebPreviewPolicy.allowsNavigation(to: try XCTUnwrap(URL(string: text)), source: source, mainFrame: true, settings: settings), text)
        }
    }

    func test_local_file_navigation_stays_inside_its_directory() {
        let source = URL(fileURLWithPath: "/tmp/artifacts/report.html")
        XCTAssertTrue(WebPreviewPolicy.allowsNavigation(to: URL(fileURLWithPath: "/tmp/artifacts/next.html"), source: source, mainFrame: true, settings: .default))
        for path in ["/tmp/artifacts-other/report.html", "/tmp/artifacts/../secret.html"] {
            XCTAssertFalse(WebPreviewPolicy.allowsNavigation(to: URL(fileURLWithPath: path), source: source, mainFrame: true, settings: .default))
        }
    }

    func test_ipc_defaults_to_pane_and_security_flags_are_refused() throws {
        XCTAssertEqual(try WebPaneIPCOptions.parse(arguments: ["--url", "https://example.com"]).placement, .pane)
        XCTAssertEqual(try WebPaneIPCOptions.parse(arguments: ["--url", "https://example.com", "--placement", "overlay"]).placement, .worklane)
        for flag in ["--js", "--persistent", "--browse"] {
            XCTAssertThrowsError(try WebPaneIPCOptions.parse(arguments: ["--url", "https://example.com", flag, "true"]))
        }
        XCTAssertThrowsError(try WebPaneIPCOptions.parse(arguments: ["--url", "javascript:alert(1)"]))
    }
}
