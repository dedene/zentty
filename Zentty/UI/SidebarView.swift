import AppKit

final class SidebarView: NSView {
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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        ["API", "WEB", "OPS", "+"].enumerated().forEach { index, title in
            let pill = NSTextField(labelWithString: title)
            pill.alignment = .center
            pill.font = NSFont.systemFont(ofSize: 12, weight: index == 0 ? .semibold : .medium)
            pill.textColor = index == 0 ? .labelColor : .secondaryLabelColor
            pill.wantsLayer = true
            pill.layer?.backgroundColor = (index == 0
                ? NSColor.systemBlue.withAlphaComponent(0.16)
                : NSColor.white.withAlphaComponent(0.18)
            ).cgColor
            pill.layer?.cornerRadius = 16
            pill.layer?.cornerCurve = .continuous
            pill.layer?.borderWidth = index == 0 ? 1 : 0
            pill.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.28).cgColor
            pill.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 58),
                pill.widthAnchor.constraint(equalToConstant: 56),
            ])
            stack.addArrangedSubview(pill)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
}
