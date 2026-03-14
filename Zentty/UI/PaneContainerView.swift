import AppKit

final class PaneContainerView: NSView {
    enum Layout {
        static let outerInset: CGFloat = 12
        static let headerBottomSpacing: CGFloat = 10
        static let terminalInnerInset: CGFloat = 12
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let terminalAdapter: any TerminalAdapter
    private lazy var terminalHostView = TerminalPaneHostView(adapter: terminalAdapter)
    var onSelected: (() -> Void)?
    var onMetadataDidChange: ((TerminalMetadata) -> Void)? {
        didSet {
            terminalHostView.onMetadataDidChange = onMetadataDidChange
        }
    }

    init(
        title: String,
        subtitle: String,
        width: CGFloat,
        height: CGFloat,
        emphasis: CGFloat,
        isFocused: Bool,
        adapter: (any TerminalAdapter)? = nil
    ) {
        self.terminalAdapter = adapter ?? TerminalAdapterRegistry.makeAdapter()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = true
        setup()
        render(title: title, subtitle: subtitle, width: width, height: height, emphasis: emphasis, isFocused: isFocused)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOffset = .zero
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, NSView(), subtitleLabel])
        header.orientation = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(terminalHostView)

        terminalHostView.onMetadataDidChange = onMetadataDidChange
        terminalHostView.onFocusDidChange = { [weak self] isFocused in
            guard isFocused else {
                return
            }

            self?.onSelected?()
        }
        try? terminalHostView.startSessionIfNeeded()

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: Layout.outerInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.outerInset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.outerInset),

            terminalHostView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Layout.headerBottomSpacing),
            terminalHostView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.outerInset),
            terminalHostView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.outerInset),
            terminalHostView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.outerInset),
        ])
    }

    func render(title: String, subtitle: String, width: CGFloat, height: CGFloat, emphasis: CGFloat, isFocused: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        (terminalAdapter as? TerminalPreviewRendering)?.renderPreview(title: title, isFocused: isFocused)

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
        titleLabel.stringValue
    }
}
