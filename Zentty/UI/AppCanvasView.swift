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
    var onPaneMetadataDidChange: ((PaneID, TerminalMetadata) -> Void)?

    private enum Layout {
        static let stripTopInset: CGFloat = 10
        static let stripBottomInset: CGFloat = 12
    }

    private let contextStripView = ContextStripView()
    private let paneStripView = PaneStripView()
    private var currentState: PaneStripState?
    private var metadataByPaneID: [PaneID: TerminalMetadata] = [:]

    override init(frame frameRect: NSRect) {
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
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.76).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 32
        layer?.shadowOffset = CGSize(width: 0, height: 18)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        contextStripView.translatesAutoresizingMaskIntoConstraints = false
        paneStripView.translatesAutoresizingMaskIntoConstraints = false
        paneStripView.onPaneMetadataDidChange = { [weak self] paneID, metadata in
            self?.metadataByPaneID[paneID] = metadata
            self?.renderFocusedContext()
            self?.onPaneMetadataDidChange?(paneID, metadata)
        }

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
    }

    func render(_ state: PaneStripState) {
        currentState = state
        renderFocusedContext()
        paneStripView.render(state)
    }

    func focusCurrentPaneIfNeeded() {
        paneStripView.focusCurrentPaneIfNeeded()
    }

    private func renderFocusedContext() {
        guard let currentState else {
            return
        }

        let metadata = currentState.focusedPaneID.flatMap { metadataByPaneID[$0] }
        contextStripView.render(currentState, metadata: metadata)
    }
}
