import AppKit

final class ContextStripView: NSView {
    static let preferredHeight: CGFloat = 34

    private let workspaceChip = ContextStripView.makeChip(text: "api.zentty")
    private let focusedLabel = ContextStripView.makeLabel(text: "editor", color: .secondaryLabelColor, weight: .medium)
    private let cwdLabel = ContextStripView.makeLabel(text: "cwd ~/src/zentty/editor", color: .tertiaryLabelColor, weight: .regular)

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

        let stack = NSStackView(views: [workspaceChip, focusedLabel, cwdLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func render(_ state: PaneStripState) {
        let focusedTitle = state.focusedPane?.title ?? "none"
        focusedLabel.stringValue = focusedTitle
        cwdLabel.stringValue = "cwd ~/src/zentty/\(focusedTitle)"
    }

    private static func makeChip(text: String) -> NSTextField {
        let chip = NSTextField(labelWithString: text)
        chip.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        chip.textColor = .labelColor
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.11).cgColor
        chip.layer?.cornerRadius = 11
        chip.layer?.cornerCurve = .continuous
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.lineBreakMode = .byTruncatingMiddle
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
        ])
        return chip
    }

    private static func makeLabel(
        text: String,
        color: NSColor,
        weight: NSFont.Weight
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
