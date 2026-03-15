import AppKit

final class WindowChromeView: NSView {
    static let preferredHeight: CGFloat = ShellMetrics.headerHeight

    private let contextStripView = ContextStripView()

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
        addSubview(contextStripView)

        contextStripView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contextStripView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: ShellMetrics.headerHorizontalInset),
            contextStripView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.headerHorizontalInset),
            contextStripView.centerYAnchor.constraint(equalTo: centerYAnchor),
            contextStripView.heightAnchor.constraint(equalToConstant: ContextStripView.preferredHeight),
        ])
    }

    func render(workspaceName: String, state: PaneStripState, metadata: TerminalMetadata?) {
        contextStripView.render(
            workspaceName: workspaceName,
            state: state,
            metadata: metadata
        )
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        contextStripView.apply(theme: theme, animated: animated)
    }

    var titleTextForTesting: String { "" }
}
