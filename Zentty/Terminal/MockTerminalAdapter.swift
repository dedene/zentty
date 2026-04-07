import AppKit

@MainActor
protocol TerminalPreviewRendering: AnyObject {
    func renderPreview(title: String, isFocused: Bool)
}

@MainActor
final class MockTerminalAdapter: TerminalAdapter, TerminalPreviewRendering, TerminalSearchControlling {
    private let surfaceView = TerminalSurfaceMockView()
    private var metadata = TerminalMetadata()
    private var surfaceActivity = TerminalSurfaceActivity()
    private var searchNeedle = ""

    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var searchDidChange: ((TerminalSearchEvent) -> Void)?

    func makeTerminalView() -> NSView {
        surfaceView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        metadata.title = "shell"
        metadata.currentWorkingDirectory = request.workingDirectory
        metadataDidChange?(metadata)
    }

    func close() {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        surfaceActivity = activity
        surfaceView.alphaValue = activity.isVisible ? (activity.isFocused ? 1 : 0.94) : 0
    }

    func renderPreview(title: String, isFocused: Bool) {
        surfaceView.render(title: title, isFocused: isFocused)
        metadata.title = title
        metadataDidChange?(metadata)
    }

    func showSearch() {
        searchDidChange?(.started(needle: searchNeedle.isEmpty ? nil : searchNeedle))
    }

    func useSelectionForFind() {
        searchDidChange?(.started(needle: searchNeedle.isEmpty ? nil : searchNeedle))
    }

    func updateSearch(needle: String) {
        searchNeedle = needle
        searchDidChange?(.total(needle.isEmpty ? 0 : 1))
        searchDidChange?(.selected(-1))
    }

    func findNext() {
        guard !searchNeedle.isEmpty else {
            return
        }

        searchDidChange?(.selected(0))
    }

    func findPrevious() {
        guard !searchNeedle.isEmpty else {
            return
        }

        searchDidChange?(.selected(0))
    }

    func endSearch() {
        searchNeedle = ""
        searchDidChange?(.ended)
    }
}

final class TerminalSurfaceMockView: NSView, TerminalFocusReporting {
    private enum Layout {
        static let contentInset: CGFloat = 12
    }

    private let contentLabel = NSTextField(wrappingLabelWithString: "")
    var onFocusDidChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }

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

        let topConstraint = contentLabel.topAnchor.constraint(equalTo: topAnchor, constant: Layout.contentInset)
        let leadingConstraint = contentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset)
        let trailingConstraint = contentLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -Layout.contentInset
        )
        leadingConstraint.priority = .defaultHigh
        trailingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            topConstraint,
            leadingConstraint,
            trailingConstraint,
        ])
    }

    func render(title: String, isFocused: Bool) {
        contentLabel.stringValue = "$ \(title)\nplaceholder terminal content\nspatial pane shell"
        alphaValue = isFocused ? 1 : 0.94
    }
}
