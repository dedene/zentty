import AppKit

final class PaneContainerView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let screen = NSTextField(wrappingLabelWithString: "")
    private var widthConstraint: NSLayoutConstraint!

    init(title: String, subtitle: String, emphasized: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        render(title: title, subtitle: subtitle, width: emphasized ? 408 : 248, isFocused: emphasized)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, NSView(), subtitleLabel])
        header.orientation = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false

        screen.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        screen.textColor = NSColor(calibratedRed: 0.83, green: 0.96, blue: 0.85, alpha: 1)
        screen.wantsLayer = true
        screen.layer?.cornerRadius = 16
        screen.layer?.cornerCurve = .continuous
        screen.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.96).cgColor
        screen.translatesAutoresizingMaskIntoConstraints = false
        screen.alphaValue = 0.96

        addSubview(header)
        addSubview(screen)

        widthConstraint = widthAnchor.constraint(equalToConstant: 248)
        widthConstraint.isActive = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 360),

            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            screen.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            screen.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            screen.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    func render(title: String, subtitle: String, width: CGFloat, isFocused: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        screen.stringValue = "$ \(title)\nplaceholder terminal content\nspatial pane shell"

        widthConstraint.constant = width
        layer?.borderColor = (isFocused
            ? NSColor.systemBlue.withAlphaComponent(0.30)
            : NSColor.separatorColor.withAlphaComponent(0.18)
        ).cgColor
        layer?.backgroundColor = (isFocused
            ? NSColor.systemBlue.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.22)
        ).cgColor
        alphaValue = isFocused ? 1 : 0.92
        screen.alphaValue = isFocused ? 1 : 0.94
    }
}
