import AppKit

@MainActor
protocol TerminalPreviewRendering: AnyObject {
    func renderPreview(title: String, isFocused: Bool)
}

@MainActor
final class MockTerminalAdapter: TerminalAdapter, TerminalPreviewRendering {
    private let surfaceView = TerminalSurfaceMockView()

    var metadataDidChange: ((TerminalMetadata) -> Void)?

    func makeTerminalView() -> NSView {
        surfaceView
    }

    func startSession() throws {}

    func renderPreview(title: String, isFocused: Bool) {
        surfaceView.render(title: title, isFocused: isFocused)
        metadataDidChange?(TerminalMetadata(title: title))
    }
}

final class TerminalSurfaceMockView: NSView {
    private let contentLabel = NSTextField(wrappingLabelWithString: "")

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
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.96).cgColor

        contentLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        contentLabel.textColor = NSColor(calibratedRed: 0.83, green: 0.96, blue: 0.85, alpha: 1)
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentLabel)

        NSLayoutConstraint.activate([
            contentLabel.topAnchor.constraint(equalTo: topAnchor, constant: PaneContainerView.Layout.terminalInnerInset),
            contentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaneContainerView.Layout.terminalInnerInset),
            contentLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PaneContainerView.Layout.terminalInnerInset),
        ])
    }

    func render(title: String, isFocused: Bool) {
        contentLabel.stringValue = "$ \(title)\nplaceholder terminal content\nspatial pane shell"
        alphaValue = isFocused ? 1 : 0.94
    }
}
