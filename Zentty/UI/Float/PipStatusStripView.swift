import AppKit
import QuartzCore

/// The PiP's bottom overlay: status dot, name, and the status word on the
/// right, over a gradient that fades the terminal out underneath.
@MainActor
final class PipStatusStripView: NSView {
    static let nameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let statusFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

    private let gradientLayer = CAGradientLayer()
    private let dotLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private(set) var status: PillBarItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // y-up layer: transparent at the top, opaque from 45% down.
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.locations = [0, 0.45, 1]
        layer?.addSublayer(gradientLayer)
        dotLayer.cornerRadius = PipChrome.statusDotSize / 2
        layer?.addSublayer(dotLayer)
        for label in [nameLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        nameLabel.font = Self.nameFont
        statusLabel.font = Self.statusFont
        statusLabel.alignment = .right
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(status: PillBarItem?, theme: ZenttyTheme) {
        self.status = status
        nameLabel.stringValue = status?.name ?? ""
        statusLabel.stringValue = status?.statusWord ?? ""
        statusLabel.isHidden = status?.statusWord == nil
        nameLabel.textColor = theme.primaryText
        statusLabel.textColor = SidebarWorklaneRowStyleResolver.statusTextColor(
            attentionState: status?.attention,
            theme: theme
        )
        let backdrop = theme.paneOpaqueBackdrop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [
            backdrop.withAlphaComponent(0).cgColor,
            backdrop.withAlphaComponent(0.95).cgColor,
            backdrop.withAlphaComponent(0.95).cgColor,
        ]
        dotLayer.backgroundColor = PillView.dotColor(for: status?.attention, theme: theme).cgColor
        CATransaction.commit()
        PillView.updatePulse(on: dotLayer, attention: status?.attention)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let padding = PipChrome.statusHorizontalPadding
        let dot = PipChrome.statusDotSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        dotLayer.frame = CGRect(x: padding, y: ((height - dot) / 2).rounded(), width: dot, height: dot)
        CATransaction.commit()

        let statusSize = statusLabel.isHidden ? .zero : statusLabel.intrinsicContentSize
        let statusWidth = min(ceil(statusSize.width), bounds.width / 2)
        statusLabel.frame = CGRect(
            x: bounds.maxX - padding - statusWidth,
            y: ((height - statusSize.height) / 2).rounded(),
            width: statusWidth,
            height: statusSize.height
        )
        let nameX = padding + dot + PipChrome.statusGap
        let nameMaxX = statusLabel.isHidden ? bounds.maxX - padding : statusLabel.frame.minX - PipChrome.statusGap
        let nameSize = nameLabel.intrinsicContentSize
        nameLabel.frame = CGRect(
            x: nameX,
            y: ((height - nameSize.height) / 2).rounded(),
            width: max(0, min(ceil(nameSize.width), nameMaxX - nameX)),
            height: nameSize.height
        )
    }

    var nameForTesting: String {
        nameLabel.stringValue
    }

    var statusWordForTesting: String? {
        statusLabel.isHidden ? nil : statusLabel.stringValue
    }

    var dotLayerForTesting: CALayer {
        dotLayer
    }
}
