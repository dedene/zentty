import AppKit

final class WindowChromeView: NSView {
    static let preferredHeight: CGFloat = ChromeGeometry.headerHeight

    private let attentionChipView = WorkspaceAttentionChipView()
    private let contextStripView = ContextStripView()
    private var currentTheme = ZenttyTheme.fallback(for: nil)

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
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(attentionChipView)
        addSubview(contextStripView)

        attentionChipView.translatesAutoresizingMaskIntoConstraints = false
        contextStripView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            attentionChipView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: ChromeGeometry.headerHorizontalInset),
            attentionChipView.centerYAnchor.constraint(equalTo: centerYAnchor),
            attentionChipView.trailingAnchor.constraint(lessThanOrEqualTo: contextStripView.leadingAnchor, constant: -8),

            contextStripView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: ChromeGeometry.headerHorizontalInset),
            contextStripView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeGeometry.headerHorizontalInset),
            contextStripView.centerYAnchor.constraint(equalTo: centerYAnchor),
            contextStripView.heightAnchor.constraint(equalToConstant: ContextStripView.preferredHeight),
        ])
    }

    func render(
        workspaceName: String,
        state: PaneStripState,
        metadata: TerminalMetadata?,
        attention: WorkspaceAttentionSummary?
    ) {
        contextStripView.render(
            workspaceName: workspaceName,
            state: state,
            metadata: metadata
        )
        attentionChipView.render(attention: attention)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        attentionChipView.apply(theme: theme, animated: animated)
        contextStripView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.topChromeBackground.cgColor
        }
    }

    var titleTextForTesting: String { "" }
    var isAttentionHiddenForTesting: Bool { attentionChipView.isHidden }
    var attentionTextForTesting: String { attentionChipView.stateTextForTesting }
    var attentionArtifactTextForTesting: String { attentionChipView.artifactTextForTesting }
}
