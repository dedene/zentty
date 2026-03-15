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
    private enum Layout {
        static let stripTopInset: CGFloat = 10
        static let stripBottomInset: CGFloat = 12
    }

    private let contextStripView = ContextStripView()
    private let paneStripView: PaneStripView
    private var currentState: PaneStripState?
    private var currentWorkspaceName = "MAIN"
    private var metadataByPaneID: [PaneID: TerminalMetadata] = [:]
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
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = currentTheme.canvasBorder.cgColor
        layer?.backgroundColor = currentTheme.canvasBackground.cgColor
        layer?.shadowColor = currentTheme.canvasShadow.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 32
        layer?.shadowOffset = CGSize(width: 0, height: 18)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        contextStripView.translatesAutoresizingMaskIntoConstraints = false
        paneStripView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(contextStripView)
        contentView.addSubview(paneStripView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contextStripView.topAnchor.constraint(equalTo: contentView.topAnchor),
            contextStripView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contextStripView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contextStripView.heightAnchor.constraint(
                equalToConstant: ContextStripView.preferredHeight),

            paneStripView.topAnchor.constraint(
                equalTo: contextStripView.bottomAnchor,
                constant: Layout.stripTopInset
            ),
            paneStripView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            paneStripView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            paneStripView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -Layout.stripBottomInset
            ),
        ])

        contextStripView.apply(theme: currentTheme, animated: false)
        paneStripView.apply(theme: currentTheme, animated: false)
    }

    func render(
        workspaceName: String,
        state: PaneStripState,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        theme: ZenttyTheme
    ) {
        currentWorkspaceName = workspaceName
        currentState = state
        self.metadataByPaneID = metadataByPaneID
        apply(theme: theme, animated: true)
        renderFocusedContext()
        paneStripView.render(state)
    }

    func focusCurrentPaneIfNeeded() {
        paneStripView.focusCurrentPaneIfNeeded()
    }

    func updateMetadata(for paneID: PaneID, metadata: TerminalMetadata) {
        metadataByPaneID[paneID] = metadata
        renderFocusedContext()
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        contextStripView.apply(theme: theme, animated: animated)
        paneStripView.apply(theme: theme, animated: animated)
        performThemeAnimation(animated: animated) {
            self.layer?.borderColor = theme.canvasBorder.cgColor
            self.layer?.backgroundColor = theme.canvasBackground.cgColor
            self.layer?.shadowColor = theme.canvasShadow.cgColor
        }
    }

    private func renderFocusedContext() {
        guard let currentState else {
            return
        }

        let metadata = currentState.focusedPaneID.flatMap { metadataByPaneID[$0] }
        contextStripView.render(
            workspaceName: currentWorkspaceName,
            state: currentState,
            metadata: metadata
        )
    }
}
