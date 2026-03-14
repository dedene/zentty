import AppKit

final class PaneContainerView: NSView {
    init(title: String, subtitle: String, emphasized: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(title: title, subtitle: subtitle, emphasized: emphasized)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(title: String, subtitle: String, emphasized: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = (emphasized
            ? NSColor.systemBlue.withAlphaComponent(0.30)
            : NSColor.separatorColor.withAlphaComponent(0.18)
        ).cgColor
        layer?.backgroundColor = (emphasized
            ? NSColor.systemBlue.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.22)
        ).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, NSView(), subtitleLabel])
        header.orientation = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false

        let screen = NSTextField(wrappingLabelWithString: "$ \(title)\nplaceholder terminal content\nspatial pane shell")
        screen.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        screen.textColor = NSColor(calibratedRed: 0.83, green: 0.96, blue: 0.85, alpha: 1)
        screen.wantsLayer = true
        screen.layer?.cornerRadius = 16
        screen.layer?.cornerCurve = .continuous
        screen.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.96).cgColor
        screen.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(screen)

        let width: CGFloat = emphasized ? 408 : 248

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
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
}
