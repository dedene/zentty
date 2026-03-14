import AppKit

final class ContextStripView: NSView {
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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let workspaceChip = makeChip(text: "api.zentty", emphasized: true)
        let focusedChip = makeChip(text: "focused pane: editor", emphasized: false)
        let cwdChip = makeChip(text: "cwd: ~/src/zentty/server", emphasized: false)

        let stack = NSStackView(views: [workspaceChip, focusedChip, cwdChip])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeChip(text: String, emphasized: Bool) -> NSTextField {
        let chip = NSTextField(labelWithString: text)
        chip.font = NSFont.systemFont(ofSize: 12, weight: emphasized ? .semibold : .medium)
        chip.textColor = emphasized ? .labelColor : .secondaryLabelColor
        chip.wantsLayer = true
        chip.layer?.backgroundColor = (emphasized
            ? NSColor.systemBlue.withAlphaComponent(0.14)
            : NSColor.white.withAlphaComponent(0.18)
        ).cgColor
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
}
