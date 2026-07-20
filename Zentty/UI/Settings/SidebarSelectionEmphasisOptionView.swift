import AppKit

/// Selectable option tile for the "Sidebar selection" appearance card, mirroring
/// `ThemeModeOptionView`'s selectable-card interaction but with a lightweight preview
/// of how the active worklane row is highlighted (subtle tint vs. accent-colored fill).
@MainActor
final class SidebarSelectionEmphasisOptionView: NSControl {
    let emphasis: AppConfig.Appearance.SidebarSelectionEmphasis

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateAppearance()
        }
    }

    private let previewView: SidebarSelectionEmphasisPreviewView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField

    init(emphasis: AppConfig.Appearance.SidebarSelectionEmphasis, title: String, subtitle: String) {
        self.emphasis = emphasis
        self.previewView = SidebarSelectionEmphasisPreviewView(emphasis: emphasis)
        self.titleLabel = NSTextField(labelWithString: title)
        self.subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(previewView)
        previewView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: 58).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        stackView.addArrangedSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 136),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isDarkMode ? 0.18 : 0.11).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isHighlighted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(isDarkMode ? 0.18 : 0.55).cgColor
            layer?.borderColor = (isDarkMode
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.12)).cgColor
        }
        previewView.isSelected = isSelected
    }
}

/// Draws a miniature sidebar with three worklane rows, one of them selected, to preview
/// how strongly the active row stands out under `.subtle` vs. `.vivid` emphasis.
@MainActor
private final class SidebarSelectionEmphasisPreviewView: NSView {
    let emphasis: AppConfig.Appearance.SidebarSelectionEmphasis

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(emphasis: AppConfig.Appearance.SidebarSelectionEmphasis) {
        self.emphasis = emphasis
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let accent = NSColor.controlAccentColor
        let stroke = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        let background = NSColor.textBackgroundColor
        let idleText = NSColor.secondaryLabelColor
        let rect = bounds.insetBy(dx: 2, dy: 4)

        let shellPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        stroke.setStroke()
        shellPath.lineWidth = isSelected ? 1.5 : 1
        shellPath.stroke()
        background.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()

        let inset = rect.insetBy(dx: 6, dy: 6)
        let rowHeight: CGFloat = 10
        let rowSpacing: CGFloat = 4
        let rowWidths: [CGFloat] = [0.9, 0.7, 0.8]
        let selectedRowIndex = 1

        for index in 0..<rowWidths.count {
            let rowRect = NSRect(
                x: inset.minX,
                y: inset.minY + CGFloat(index) * (rowHeight + rowSpacing),
                width: inset.width,
                height: rowHeight
            )
            let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 3, yRadius: 3)

            if index == selectedRowIndex {
                switch emphasis {
                case .subtle:
                    idleText.withAlphaComponent(0.16).setFill()
                    rowPath.fill()
                case .vivid:
                    accent.withAlphaComponent(0.28).setFill()
                    rowPath.fill()
                    accent.setStroke()
                    rowPath.lineWidth = 1
                    rowPath.stroke()
                }

                let textColor = emphasis == .vivid ? accent : idleText
                let textRect = rowRect.insetBy(dx: 3, dy: 2.5)
                textColor.setFill()
                NSBezierPath(roundedRect: textRect.divided(atDistance: textRect.width * rowWidths[index], from: .minXEdge).slice, xRadius: 1, yRadius: 1).fill()
            } else {
                let textRect = rowRect.insetBy(dx: 3, dy: 2.5)
                idleText.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: textRect.divided(atDistance: textRect.width * rowWidths[index], from: .minXEdge).slice, xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}
