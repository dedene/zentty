import AppKit

final class PaneContainerView: NSView {
    fileprivate enum Layout {
        static let outerInset: CGFloat = 12
        static let headerBottomSpacing: CGFloat = 10
        static let terminalInnerInset: CGFloat = 12
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let terminalSurfaceView = TerminalSurfaceMockView()

    init(title: String, subtitle: String, width: CGFloat, height: CGFloat, emphasis: CGFloat, isFocused: Bool) {
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

        terminalSurfaceView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(terminalSurfaceView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: Layout.outerInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.outerInset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.outerInset),

            terminalSurfaceView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Layout.headerBottomSpacing),
            terminalSurfaceView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.outerInset),
            terminalSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.outerInset),
            terminalSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.outerInset),
        ])
    }

    func render(title: String, subtitle: String, width: CGFloat, height: CGFloat, emphasis: CGFloat, isFocused: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        terminalSurfaceView.render(title: title, isFocused: isFocused)

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

    var titleTextForTesting: String {
        titleLabel.stringValue
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
