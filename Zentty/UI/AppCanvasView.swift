import AppKit

final class AppCanvasView: NSView {
    var onFocusSettled: ((PaneID) -> Void)? {
        didSet {
            paneStripView.onFocusSettled = onFocusSettled
        }
    }
    var onPaneSelected: ((PaneID) -> Void)? {
        didSet {
            paneStripView.onPaneSelected = onPaneSelected
        }
    }
    var onPaneCloseRequested: ((PaneID) -> Void)? {
        didSet {
            paneStripView.onPaneCloseRequested = onPaneCloseRequested
        }
    }
    var leadingVisibleInset: CGFloat = 0 {
        didSet {
            paneStripView.leadingVisibleInset = leadingVisibleInset
        }
    }
    private let paneStripView: PaneStripView
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    init(frame frameRect: NSRect = .zero, runtimeRegistry: PaneRuntimeRegistry) {
        self.paneStripView = PaneStripView(runtimeRegistry: runtimeRegistry)
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        paneStripView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneStripView)

        NSLayoutConstraint.activate([
            paneStripView.topAnchor.constraint(equalTo: topAnchor),
            paneStripView.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStripView.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneStripView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        paneStripView.apply(theme: currentTheme, animated: false)
        paneStripView.leadingVisibleInset = leadingVisibleInset
    }

    func render(
        workspaceName: String,
        state: PaneStripState,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        theme: ZenttyTheme
    ) {
        apply(theme: theme, animated: true)
        paneStripView.render(state)
    }

    func focusCurrentPaneIfNeeded() {
        paneStripView.focusCurrentPaneIfNeeded()
    }

    func updateMetadata(for paneID: PaneID, metadata: TerminalMetadata) {
        _ = paneID
        _ = metadata
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        paneStripView.apply(theme: theme, animated: animated)
    }
}
