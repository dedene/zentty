import AppKit

@MainActor
final class TerminalPaneHostView: NSView {
    private let adapter: any TerminalAdapter
    private let terminalView: NSView
    private var hasStartedSession = false

    var onMetadataDidChange: ((TerminalMetadata) -> Void)? {
        didSet {
            adapter.metadataDidChange = onMetadataDidChange
        }
    }
    var onFocusDidChange: ((Bool) -> Void)? {
        didSet {
            (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        }
    }

    init(adapter: any TerminalAdapter) {
        self.adapter = adapter
        self.terminalView = adapter.makeTerminalView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startSessionIfNeeded() throws {
        guard !hasStartedSession else {
            return
        }

        try adapter.startSession()
        hasStartedSession = true
    }

    func focusTerminal() {
        guard window?.firstResponder !== terminalView else {
            return
        }

        window?.makeFirstResponder(terminalView)
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    var terminalViewForTesting: NSView {
        terminalView
    }
}
