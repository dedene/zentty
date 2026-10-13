import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WebPreviewSettingsTests: AppKitTestCase {
    func test_browser_survives_pane_host_recreation() throws {
        var pane = PaneState(id: PaneID("web"), title: "Web", webURL: "https://example.com")
        let runtime = PaneRuntime(pane: pane, adapter: MockTerminalAdapter(), metadataSink: { _, _ in }, eventSink: { _, _ in })
        let first = try XCTUnwrap(runtime.webContentView(for: pane))
        pane.webURL = "https://example.com/next"
        runtime.update(pane: pane)
        XCTAssertTrue(runtime.webContentView(for: pane) === first)
        XCTAssertFalse(runtime.hasAttemptedSessionStart)
        runtime.ensureStarted()
        XCTAssertFalse(runtime.hasAttemptedSessionStart)
    }

    func test_settings_group_saves_each_opt_in_and_refreshes_switches() throws {
        let file = AppConfigStore.temporaryFileURL(prefix: "WebPreviewSettingsTests")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AppConfigStore(fileURL: file)
        let controller = PaneLayoutSettingsSectionViewController(configStore: store)
        _ = controller.view
        XCTAssertEqual(controller.webPreviewSwitchesForTesting.count, 4)
        XCTAssertTrue(controller.webPreviewSwitchesForTesting.allSatisfy { $0.state == .off })
        for toggle in controller.webPreviewSwitchesForTesting {
            toggle.state = .on
            XCTAssertTrue(toggle.sendAction(try XCTUnwrap(toggle.action), to: toggle.target))
        }
        let expected = AppConfig.WebPreview(javaScriptEnabled: true, localhostJavaScriptEnabled: true,
                                             persistentStorageEnabled: true, browsingEnabled: true)
        XCTAssertEqual(store.current.webPreview, expected)
        XCTAssertEqual(AppConfigTOML.decode(try String(contentsOf: file, encoding: .utf8))?.webPreview, expected)
        controller.apply(webPreview: .default)
        XCTAssertTrue(controller.webPreviewSwitchesForTesting.allSatisfy { $0.state == .off })
    }

    func test_webview_configuration_is_private_and_scripts_off_by_default() {
        let browser = WebContentView(url: "https://example.com")
        XCTAssertFalse(browser.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(browser.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func test_localhost_exception_does_not_enable_scripts_on_other_sites() {
        var settings = AppConfig.WebPreview.default
        settings.localhostJavaScriptEnabled = true
        XCTAssertTrue(WebContentView(url: "http://localhost:3000", settings: settings).webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(WebContentView(url: "https://example.com", settings: settings).webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func test_permission_changes_replace_webview_and_disable_saved_store() {
        let browser = WebContentView(url: "https://example.com")
        let initial = browser.webView
        var settings = AppConfig.WebPreview.default
        settings.persistentStorageEnabled = true
        settings.javaScriptEnabled = true
        browser.apply(settings: settings)
        XCTAssertFalse(browser.webView === initial)
        XCTAssertTrue(browser.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(browser.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let persistent = browser.webView
        browser.apply(settings: .default)
        XCTAssertFalse(browser.webView === persistent)
        XCTAssertFalse(browser.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(browser.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func test_unchanged_settings_keep_webview_and_files_never_get_saved_store() {
        let browser = WebContentView(url: "https://example.com")
        let original = browser.webView
        var settings = AppConfig.WebPreview.default
        browser.apply(settings: settings)
        XCTAssertTrue(browser.webView === original)
        settings.persistentStorageEnabled = true
        XCTAssertFalse(WebContentView(url: "file:///tmp/report.html", settings: settings).webView.configuration.websiteDataStore.isPersistent)
    }
}
