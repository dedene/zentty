import AppKit

final class ContentShellView: NSView {
    var onFocusSettled: ((PaneID) -> Void)? {
        didSet {
            appCanvasView.onFocusSettled = onFocusSettled
        }
    }

    var onPaneSelected: ((PaneID) -> Void)? {
        didSet {
            appCanvasView.onPaneSelected = onPaneSelected
        }
    }

    var onPaneCloseRequested: ((PaneID) -> Void)? {
        didSet {
            appCanvasView.onPaneCloseRequested = onPaneCloseRequested
        }
    }

    private let contentClipView = NSView()
    private let windowChromeView = WindowChromeView()
    private let appCanvasView: AppCanvasView
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    init(frame frameRect: NSRect = .zero, runtimeRegistry: PaneRuntimeRegistry) {
        self.appCanvasView = AppCanvasView(runtimeRegistry: runtimeRegistry)
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: 10)
        layer?.backgroundColor = NSColor.clear.cgColor

        contentClipView.translatesAutoresizingMaskIntoConstraints = false
        contentClipView.wantsLayer = true
        contentClipView.layer?.cornerCurve = .continuous
        contentClipView.layer?.masksToBounds = true

        windowChromeView.translatesAutoresizingMaskIntoConstraints = false
        appCanvasView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentClipView)
        contentClipView.addSubview(windowChromeView)
        contentClipView.addSubview(appCanvasView)

        NSLayoutConstraint.activate([
            contentClipView.topAnchor.constraint(equalTo: topAnchor),
            contentClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentClipView.bottomAnchor.constraint(equalTo: bottomAnchor),

            windowChromeView.topAnchor.constraint(equalTo: contentClipView.topAnchor),
            windowChromeView.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor),
            windowChromeView.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor),
            windowChromeView.heightAnchor.constraint(equalToConstant: WindowChromeView.preferredHeight),

            appCanvasView.topAnchor.constraint(equalTo: windowChromeView.bottomAnchor),
            appCanvasView.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor, constant: ShellMetrics.contentPadding),
            appCanvasView.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor, constant: -ShellMetrics.contentPadding),
            appCanvasView.bottomAnchor.constraint(equalTo: contentClipView.bottomAnchor, constant: -ShellMetrics.contentPadding),
        ])

        apply(theme: currentTheme, animated: false)
    }

    func render(
        workspaceName: String,
        state: PaneStripState,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        attention: WorkspaceAttentionSummary? = nil,
        theme: ZenttyTheme
    ) {
        let metadata = state.focusedPaneID.flatMap { metadataByPaneID[$0] }
        windowChromeView.render(
            workspaceName: workspaceName,
            state: state,
            metadata: metadata,
            attention: attention
        )
        appCanvasView.render(
            workspaceName: workspaceName,
            state: state,
            metadataByPaneID: metadataByPaneID,
            theme: theme
        )
    }

    func focusCurrentPaneIfNeeded() {
        appCanvasView.focusCurrentPaneIfNeeded()
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        windowChromeView.apply(theme: theme, animated: animated)
        appCanvasView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.shadowColor = theme.canvasShadow.cgColor
            self.contentClipView.layer?.cornerRadius = ShellMetrics.contentShellRadius
            self.contentClipView.layer?.backgroundColor = theme.canvasBackground.cgColor
            self.contentClipView.layer?.borderColor = theme.canvasBorder.cgColor
            self.contentClipView.layer?.borderWidth = 1
        }
    }
}
