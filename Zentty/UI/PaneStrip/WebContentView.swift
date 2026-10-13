import AppKit
import WebKit
import QuartzCore

@MainActor
final class WebContentView: NSView, WKNavigationDelegate, WKUIDelegate {
    override var isFlipped: Bool { true }
    private var focusedWebView: FocusReportingWebView
    private let pageClipView = RoundedWebPageClipView()
    private let toolbar = RoundedWebToolbarView()
    private var toolbarColorTimer: WebToolbarColorTimer?
    private var colorSnapshotInFlight = false
    var webView: WKWebView { focusedWebView }
    var toolbarBackgroundColorForTesting: CGColor? { toolbar.layer?.backgroundColor }
    var onClose: (() -> Void)?
    var onSelected: (() -> Void)?
    var onURLDidChange: ((String) -> Void)? {
        didSet {
            guard webView.url != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let url = self.webView.url else { return }
                self.onURLDidChange?(url.absoluteString)
            }
        }
    }
    private let sourceURL: URL
    private let configStore: AppConfigStore?
    private var configObserverID: UUID?
    private var settings: AppConfig.WebPreview
    private var webViewConstraints: [NSLayoutConstraint] = []
    private var didLoadInitialURL = false
    private let backButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: nil, action: nil)
    private let forwardButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!, target: nil, action: nil)
    private let reloadButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")!, target: nil, action: nil)
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close web pane")!, target: nil, action: nil)
    private let navigationStatusLabel = NSTextField(wrappingLabelWithString: "Loading…")

    init(url: String, showsCloseButton: Bool = false, configStore: AppConfigStore? = nil,
         settings: AppConfig.WebPreview = .default) {
        sourceURL = WebPreviewPolicy.resourceURL(url) ?? URL(string: "about:blank")!
        self.configStore = configStore
        self.settings = configStore?.current.webPreview ?? settings
        focusedWebView = Self.makeWebView(source: sourceURL, settings: self.settings)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pageClipView.translatesAutoresizingMaskIntoConstraints = false
        pageClipView.wantsLayer = true
        pageClipView.layer?.masksToBounds = true
        toolbar.wantsLayer = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        for (index, button) in [backButton, forwardButton, reloadButton, closeButton].enumerated() {
            button.isBordered = false
            button.bezelStyle = .inline
            button.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: CGFloat(8 + index * 30)),
                button.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        closeButton.isHidden = !showsCloseButton
        navigationStatusLabel.alignment = .center
        navigationStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        navigationStatusLabel.textColor = .secondaryLabelColor
        navigationStatusLabel.maximumNumberOfLines = 0
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        closeButton.target = self; closeButton.action = #selector(close)
        addSubview(toolbar)
        addSubview(pageClipView)
        installWebView()
        pageClipView.addSubview(navigationStatusLabel, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6), toolbar.heightAnchor.constraint(equalToConstant: 36),
            pageClipView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pageClipView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pageClipView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pageClipView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            navigationStatusLabel.centerXAnchor.constraint(equalTo: pageClipView.centerXAnchor),
            navigationStatusLabel.centerYAnchor.constraint(equalTo: pageClipView.centerYAnchor),
            navigationStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pageClipView.leadingAnchor, constant: 16),
            navigationStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: pageClipView.trailingAnchor, constant: -16),
        ])
        configObserverID = configStore?.addObserver { [weak self] config in
            DispatchQueue.main.async { self?.apply(settings: config.webPreview) }
        }
    }

    deinit {
        toolbarColorTimer?.invalidate()
        if let configObserverID { configStore?.removeObserver(configObserverID) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        toolbarColorTimer?.invalidate()
        toolbarColorTimer = nil
        if window != nil {
            let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateToolbarColor() }
            }
            RunLoop.main.add(timer, forMode: .common)
            toolbarColorTimer = WebToolbarColorTimer(timer)
        }
        guard window != nil, !didLoadInitialURL else { return }
        didLoadInitialURL = true
        load(sourceURL.absoluteString)
    }

    // Sample rendered pixels rather than executing scripts in the document.
    // A tiny snapshot follows scrolling, including pages with scripts disabled.
    private func updateToolbarColor() {
        guard !colorSnapshotInFlight, window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              !webView.isLoading, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let sampledWebView = webView
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: sampledWebView.bounds.width, height: 3)
        colorSnapshotInFlight = true
        sampledWebView.takeSnapshot(with: configuration) { [weak self, weak sampledWebView] image, _ in
            guard let self else { return }
            self.colorSnapshotInFlight = false
            guard sampledWebView === self.webView, let image,
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return }
            var red = CGFloat.zero, green = CGFloat.zero, blue = CGFloat.zero, count = CGFloat.zero
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                guard let color = bitmap.colorAt(x: x, y: 0)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.9 else { continue }
                red += color.redComponent; green += color.greenComponent; blue += color.blueComponent
                count += 1
            }
            guard count > 0 else { return }
            let color = NSColor(deviceRed: red / count, green: green / count, blue: blue / count, alpha: 1)
            self.toolbar.layer?.backgroundColor = color.cgColor
            let luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / count
            for button in [self.backButton, self.forwardButton, self.reloadButton, self.closeButton] {
                button.contentTintColor = luminance > 0.5 ? .black : .white
            }
        }
    }

    private static func makeWebView(source: URL, settings: AppConfig.WebPreview) -> FocusReportingWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = settings.persistentStorageEnabled && !source.isFileURL
            ? .default() : .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = WebPreviewPolicy.allowsJavaScript(at: source, settings: settings)
        return FocusReportingWebView(frame: .zero, configuration: configuration)
    }

    private func installWebView() {
        focusedWebView.translatesAutoresizingMaskIntoConstraints = false
        focusedWebView.wantsLayer = true
        focusedWebView.layer?.masksToBounds = true
        focusedWebView.navigationDelegate = self
        focusedWebView.uiDelegate = self
        focusedWebView.onMouseDown = { [weak self] in self?.onSelected?() }
        focusedWebView.allowsBackForwardNavigationGestures = true
        pageClipView.addSubview(focusedWebView, positioned: .below, relativeTo: nil)
        webViewConstraints = [
            focusedWebView.leadingAnchor.constraint(equalTo: pageClipView.leadingAnchor),
            focusedWebView.trailingAnchor.constraint(equalTo: pageClipView.trailingAnchor),
            focusedWebView.topAnchor.constraint(equalTo: pageClipView.topAnchor),
            focusedWebView.bottomAnchor.constraint(equalTo: pageClipView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(webViewConstraints)
        backButton.isEnabled = false
        forwardButton.isEnabled = false
    }

    func apply(settings newSettings: AppConfig.WebPreview) {
        let reload = WebPreviewPolicy.permissionsChanged(settings, newSettings)
        settings = newSettings
        guard reload else { return }
        let shownURL = webView.url ?? sourceURL
        let target = WebPreviewPolicy.allowsNavigation(to: shownURL, source: sourceURL, mainFrame: true, settings: settings)
            ? shownURL : sourceURL
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: focusedWebView) == true
        focusedWebView.stopLoading()
        focusedWebView.navigationDelegate = nil
        focusedWebView.uiDelegate = nil
        focusedWebView.onMouseDown = nil
        NSLayoutConstraint.deactivate(webViewConstraints)
        focusedWebView.removeFromSuperview()
        focusedWebView = Self.makeWebView(source: sourceURL, settings: settings)
        installWebView()
        if didLoadInitialURL { load(target.absoluteString) }
        if hadFocus { window?.makeFirstResponder(focusedWebView) }
    }

    func load(_ value: String) {
        guard let url = WebPreviewPolicy.resourceURL(value),
              WebPreviewPolicy.allowsNavigation(to: url, source: sourceURL, mainFrame: true, settings: settings) else { return }
        navigationStatusLabel.stringValue = "Loading…"
        navigationStatusLabel.isHidden = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let activeSettings = configStore?.current.webPreview ?? settings
        guard let url = navigationAction.request.url,
              WebPreviewPolicy.allowsNavigation(to: url, source: sourceURL,
                                                mainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                                settings: activeSettings) else {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                navigationStatusLabel.stringValue = "This destination is blocked by Web Preview settings in Worklanes & Panes."
                navigationStatusLabel.isHidden = false
            }
            decisionHandler(.cancel, preferences)
            return
        }
        preferences.allowsContentJavaScript = WebPreviewPolicy.allowsJavaScript(at: url, settings: activeSettings)
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { onURLDidChange?(url.absoluteString) }
        navigationStatusLabel.isHidden = true
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { onURLDidChange?(url.absoluteString) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           WebPreviewPolicy.allowsNavigation(to: url, source: sourceURL, mainFrame: true,
                                             settings: configStore?.current.webPreview ?? settings) {
            load(url.absoluteString)
        }
        return nil
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }
    @objc private func close() { onClose?() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStatusLabel.stringValue = "Loading…"
        navigationStatusLabel.isHidden = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationStatusLabel.stringValue = "The web page stopped. Reload to try again."
        navigationStatusLabel.isHidden = false
    }

    private func showNavigationError(_ error: Error) {
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        navigationStatusLabel.stringValue = "Unable to load this page\n\(error.localizedDescription)"
        navigationStatusLabel.isHidden = false
    }
}

@MainActor
private final class FocusReportingWebView: WKWebView {
    var onMouseDown: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class RoundedWebPageClipView: NSView {
    private let roundedMask = CAShapeLayer()
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if #available(macOS 14.0, *) { clipsToBounds = true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        roundedMask.frame = bounds
        // The page is inset six points from the pane, so its bottom curve
        // uses the concentric inner radius. The toolbar boundary stays square.
        let radius = min(max(0, ChromeGeometry.paneRadius - 6), min(bounds.width, bounds.height) / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY),
                          control: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.addQuadCurve(to: CGPoint(x: bounds.minX, y: bounds.maxY - radius),
                          control: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.closeSubpath()
        roundedMask.path = path
        roundedMask.fillColor = NSColor.black.cgColor
        layer?.mask = roundedMask
        CATransaction.commit()
    }
}


// Timer is created and used on the main actor. This holder allows the view's
// nonisolated deinit to invalidate it without passing Timer across actors.
private final class WebToolbarColorTimer: @unchecked Sendable {
    private let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    func invalidate() { timer.invalidate() }
}

@MainActor
private final class RoundedWebToolbarView: NSView {
    private let roundedMask = CAShapeLayer()
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let radius = min(max(0, ChromeGeometry.paneRadius - 6), min(bounds.width, bounds.height) / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + radius))
        path.addQuadCurve(to: CGPoint(x: bounds.minX + radius, y: bounds.minY),
                          control: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: bounds.minY))
        path.addQuadCurve(to: CGPoint(x: bounds.maxX, y: bounds.minY + radius),
                          control: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        roundedMask.frame = bounds
        roundedMask.path = path
        roundedMask.fillColor = NSColor.black.cgColor
        layer?.mask = roundedMask
        CATransaction.commit()
    }
}
