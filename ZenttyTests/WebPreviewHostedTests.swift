import AppKit
import Network
import WebKit
import XCTest
@testable import Zentty

@MainActor
final class WebPreviewHostedTests: XCTestCase {
    private let html = "<title>Preview fixture</title><p>Visible artifact</p><script>window.testExecuted = 'yes';</script>"

    func test_html_scripts_are_disabled_until_user_enables_them() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("web-preview-\(UUID()).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        for enabled in [false, true] {
            var settings = AppConfig.WebPreview.default
            settings.javaScriptEnabled = enabled
            let browser = try await showBrowser(url: file.absoluteString, settings: settings)
            let title = try await browser.webView.evaluateJavaScript("document.title") as? String
            XCTAssertEqual(title, "Preview fixture")
            let effect = try await browser.webView.evaluateJavaScript("window.testExecuted ?? 'no'") as? String
            XCTAssertEqual(effect, enabled ? "yes" : "no")
        }
    }

    func test_localhost_exception_runs_tool_scripts_with_global_javascript_off() async throws {
        let ready = expectation(description: "loopback HTTP server ready")
        let server = try WebPreviewHTTPFixture(body: html, ready: ready)
        addTeardownBlock { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.port)
        var settings = AppConfig.WebPreview.default
        settings.localhostJavaScriptEnabled = true
        let browser = try await showBrowser(url: "http://127.0.0.1:\(port)/preview", settings: settings)
        let effect = try await browser.webView.evaluateJavaScript("window.testExecuted ?? 'no'") as? String
        XCTAssertEqual(effect, "yes")
        XCTAssertFalse(settings.javaScriptEnabled)
    }

    func test_disabling_javascript_reloads_an_open_page_without_its_scripts() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("web-preview-\(UUID()).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let configFile = AppConfigStore.temporaryFileURL(prefix: "WebPreviewReloadTests")
        addTeardownBlock { try? FileManager.default.removeItem(at: configFile.deletingLastPathComponent()) }
        let config = AppConfigStore(fileURL: configFile)
        try config.update { $0.webPreview.javaScriptEnabled = true }
        let browser = try await showBrowser(url: file.absoluteString, settings: .default, configStore: config)
        let old = browser.webView
        let reloaded = expectation(description: "open preview reloaded after permissions changed")
        let reloadTask = Task { @MainActor in
            for _ in 0..<300 {
                if Task.isCancelled { return }
                if browser.webView !== old, browser.webView.title == "Preview fixture", !browser.webView.isLoading {
                    reloaded.fulfill()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { reloadTask.cancel() }
        try config.update { $0.webPreview.javaScriptEnabled = false }
        await fulfillment(of: [reloaded], timeout: 15)
        let effect = try await browser.webView.evaluateJavaScript("window.testExecuted ?? 'no'") as? String
        XCTAssertEqual(effect, "no")
    }

    func test_toolbar_follows_rendered_top_edge_when_scrolled_with_scripts_disabled() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("web-colors-\(UUID()).html")
        try """
        <style>body{margin:0}section{height:1000px}.first{background:#ff0000}.second{background:#0000ff}</style>
        <section class="first"></section><section class="second"></section>
        <script>window.pageScriptRan=true</script>
        """.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let browser = try await showBrowser(url: file.absoluteString, settings: .default)
        try await waitForToolbarColor(browser, red: 1, blue: 0)
        // Test-only scrolling; the production color sampler never executes JavaScript.
        _ = try await browser.webView.evaluateJavaScript("window.scrollTo(0,1100)")
        try await waitForToolbarColor(browser, red: 0, blue: 1)
        let ran = try await browser.webView.evaluateJavaScript("window.pageScriptRan ?? false") as? Bool
        XCTAssertEqual(ran, false)
    }

    private func waitForToolbarColor(_ browser: WebContentView, red: CGFloat, blue: CGFloat) async throws {
        let matched = expectation(description: "toolbar matches visible page edge")
        let task = Task { @MainActor in
            for _ in 0..<100 {
                if Task.isCancelled { return }
                if let cgColor = browser.toolbarBackgroundColorForTesting,
                   let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB),
                   abs(color.redComponent - red) < 0.05, abs(color.blueComponent - blue) < 0.05 {
                    matched.fulfill()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { task.cancel() }
        await fulfillment(of: [matched], timeout: 6)
    }

    func test_explicit_overlay_and_pane_route_to_the_requested_placement() throws {
        let configFile = AppConfigStore.temporaryFileURL(prefix: "WebPreviewHostedTests")
        addTeardownBlock { try? FileManager.default.removeItem(at: configFile.deletingLastPathComponent()) }
        let config = AppConfigStore(fileURL: configFile)
        let controller = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            configStore: config).prepareForHostedTesting()
        addTeardownBlock { controller.closeWindowBypassingConfirmation() }
        controller.showWindow(nil)
        let source = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        let count = try XCTUnwrap(controller.worklaneStore.activeWorklane).paneStripState.panes.count
        let overlay = try controller.openWeb(on: source, options: .init(url: "https://example.com", placement: .worklane, sizePercent: 100))
        XCTAssertTrue(overlay.hasPrefix("web_"))
        func find(_ view: NSView, id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0, id: id) }.first
        }
        let overlayView = try XCTUnwrap(find(try XCTUnwrap(controller.window.contentView), id: overlay))
        let anchor = try XCTUnwrap(overlayView.superview)
        XCTAssertTrue(anchor is QuickActionOverlayContainerView)
        anchor.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlayView.frame.width, anchor.bounds.width - 32, accuracy: 1)
        XCTAssertEqual(overlayView.frame.height, anchor.bounds.height - 32, accuracy: 1)
        controller.toggleQuickActionOverlay(nil)
        XCTAssertTrue(overlayView.isHidden)
        controller.toggleQuickActionOverlay(nil)
        XCTAssertFalse(overlayView.isHidden)

        XCTAssertEqual(controller.worklaneStore.activeWorklane?.paneStripState.panes.count, count)
        let pane = try controller.openWeb(on: source, options: .init(url: "https://example.com", placement: .pane, sizePercent: 90))
        XCTAssertTrue(pane.hasPrefix("pn_"))
        XCTAssertEqual(controller.worklaneStore.activeWorklane?.paneStripState.panes.count, count + 1)
    }

    private func showBrowser(url: String, settings: AppConfig.WebPreview, configStore: AppConfigStore? = nil) async throws -> WebContentView {
        let browser = WebContentView(url: url, configStore: configStore, settings: settings)
        let finished = expectation(description: "WebKit finished navigation")
        let observation = browser.webView.observe(\.isLoading, options: [.new]) { webView, _ in
            if !webView.isLoading { finished.fulfill() }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false).prepareForHostedTesting()
        addTeardownBlock { window.close() }
        window.contentView = browser
        window.makeKeyAndOrderFrontForHostedTesting(nil)
        await fulfillment(of: [finished], timeout: 15)
        observation.invalidate()
        return browser
    }
}

private final class WebPreviewHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16?

    init(body: String, ready: XCTestExpectation) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "WebPreviewHTTPFixture")
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.port = self.listener.port?.rawValue
            ready.fulfill()
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }
}
