import AppKit

final class PaneStripView: NSView {
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

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        [
            PaneContainerView(title: "logs", subtitle: "left", emphasized: false),
            PaneContainerView(title: "editor", subtitle: "focused", emphasized: true),
            PaneContainerView(title: "tests", subtitle: "right", emphasized: false),
            PaneContainerView(title: "shell", subtitle: "far right", emphasized: false),
        ].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
        ])
    }
}
