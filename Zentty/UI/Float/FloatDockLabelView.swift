import AppKit

/// The "Dock here" capsule centred on a float's dock preview. Never takes
/// clicks.
@MainActor
final class FloatDockLabelView: NSView {
    static let text = "Dock here"
    private static let horizontalPadding: CGFloat = 9
    private static let verticalPadding: CGFloat = 3

    private let label: NSTextField

    override init(frame: NSRect) {
        label = NSTextField(labelWithString: Self.text)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.text)
        setFrameSize(intrinsicContentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        label.stringValue
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(
            width: ceil(size.width) + Self.horizontalPadding * 2,
            height: ceil(size.height) + Self.verticalPadding * 2
        )
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Centres the label on `point`, kept inside `container`.
    func center(on point: CGPoint, within container: CGRect) {
        let size = intrinsicContentSize
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if container.width >= size.width {
            origin.x = min(max(origin.x, container.minX), container.maxX - size.width)
        }
        if container.height >= size.height {
            origin.y = min(max(origin.y, container.minY), container.maxY - size.height)
        }
        frame = CGRect(origin: origin, size: size).integral
        needsLayout = true
    }
}
