import AppKit

final class PaneContainerView: NSView {
    enum Layout {
        static let borderWidth: CGFloat = 1
    }

    private let terminalAdapter: any TerminalAdapter
    private lazy var terminalHostView = TerminalPaneHostView(adapter: terminalAdapter)
    private(set) var paneID: PaneID
    private var sessionRequest: TerminalSessionRequest
    private var titleTextStorage: String
    var onSelected: (() -> Void)?
    var onMetadataDidChange: ((TerminalMetadata) -> Void)? {
        didSet {
            terminalHostView.onMetadataDidChange = onMetadataDidChange
        }
    }

    init(
        pane: PaneState,
        width: CGFloat,
        height: CGFloat,
        emphasis: CGFloat,
        isFocused: Bool,
        adapter: (any TerminalAdapter)? = nil
    ) {
        self.paneID = pane.id
        self.sessionRequest = pane.sessionRequest
        self.titleTextStorage = pane.title
        self.terminalAdapter = adapter ?? TerminalAdapterRegistry.makeAdapter()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = true
        setup()
        render(pane: pane, width: width, height: height, emphasis: emphasis, isFocused: isFocused)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Layout.borderWidth
        layer?.shadowOffset = .zero
        layer?.masksToBounds = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(terminalHostView)

        terminalHostView.onMetadataDidChange = onMetadataDidChange
        terminalHostView.onFocusDidChange = { [weak self] isFocused in
            guard isFocused else {
                return
            }

            self?.onSelected?()
        }
        try? terminalHostView.startSessionIfNeeded(using: sessionRequest)

        NSLayoutConstraint.activate([
            terminalHostView.topAnchor.constraint(equalTo: topAnchor),
            terminalHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalHostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func render(pane: PaneState, width: CGFloat, height: CGFloat, emphasis: CGFloat, isFocused: Bool) {
        paneID = pane.id
        sessionRequest = pane.sessionRequest
        titleTextStorage = pane.title
        (terminalAdapter as? TerminalPreviewRendering)?.renderPreview(title: pane.title, isFocused: isFocused)

        frame.size = NSSize(width: width, height: height)
        layer?.borderColor = (isFocused
            ? NSColor.systemBlue.withAlphaComponent(0.26)
            : NSColor.separatorColor.withAlphaComponent(0.18)
        ).cgColor
        layer?.backgroundColor = (isFocused
            ? NSColor.systemBlue.withAlphaComponent(0.04)
            : NSColor.white.withAlphaComponent(0.22)
        ).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        layer?.shadowOpacity = Float(max(0, emphasis - 0.88) * 2.2)
        layer?.shadowRadius = 6 + max(0, emphasis - 0.92) * 24
        alphaValue = 0.9 + (emphasis - 0.9) * 0.5
    }

    override func mouseDown(with event: NSEvent) {
        onSelected?()
        focusTerminal()
        super.mouseDown(with: event)
    }

    func focusTerminal() {
        terminalHostView.focusTerminal()
    }

    var titleTextForTesting: String {
        titleTextStorage
    }
}
