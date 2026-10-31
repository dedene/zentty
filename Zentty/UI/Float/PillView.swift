import AppKit
import QuartzCore

/// One pill: a 28pt capsule with a status dot, the float's name and a muted
/// short cwd. A button for VoiceOver. Mouse handling lives in `PillBarView`
/// (press, drag, click); the pill only reports hover.
@MainActor
final class PillView: NSView {
    private enum Metrics {
        static let leadingPadding: CGFloat = 9
        static let trailingPadding: CGFloat = 12
        static let dotSize: CGFloat = 7
        static let gap: CGFloat = 7
        static let compactNameMaxWidth: CGFloat = 72
    }

    static let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let subtitleFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let pulseKey = "pill.pulse"

    private(set) var item: PillBarItem
    private(set) var style: PillBarLayout.Style = .full
    var onHoverChanged: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private(set) var isHovered = false
    private var theme = ZenttyTheme.fallback(for: nil)
    private let dotLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(item: PillBarItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PillBarLayout.pillHeight / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        dotLayer.cornerRadius = Metrics.dotSize / 2
        layer?.addSublayer(dotLayer)
        for label in [nameLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        nameLabel.font = Self.nameFont
        subtitleLabel.font = Self.subtitleFont
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: PillBarItem, style: PillBarLayout.Style, theme: ZenttyTheme) {
        let changed = item != self.item || style != self.style || theme != self.theme
        self.item = item
        self.style = style
        self.theme = theme
        if changed {
            apply()
        }
    }

    /// Width with the whole label, and as dot + short name.
    static func widths(for item: PillBarItem) -> (full: CGFloat, compact: CGFloat) {
        let nameWidth = textWidth(item.name, font: nameFont)
        let base = Metrics.leadingPadding + Metrics.dotSize + Metrics.gap + Metrics.trailingPadding
        var full = base + nameWidth
        if let subtitle = item.subtitle {
            full += Metrics.gap + textWidth(subtitle, font: subtitleFont)
        }
        let compact = base + min(nameWidth, Metrics.compactNameMaxWidth)
        return (ceil(full), ceil(compact))
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyColors()
        onHoverChanged?(hovered)
    }

    // MARK: - Layout and appearance

    override func layout() {
        super.layout()
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.frame = CGRect(
            x: Metrics.leadingPadding,
            y: ((height - Metrics.dotSize) / 2).rounded(),
            width: Metrics.dotSize,
            height: Metrics.dotSize
        )
        CATransaction.commit()

        let textX = Metrics.leadingPadding + Metrics.dotSize + Metrics.gap
        let available = max(0, bounds.width - textX - Metrics.trailingPadding)
        let nameSize = nameLabel.intrinsicContentSize
        let nameWidth = min(ceil(nameSize.width), available)
        nameLabel.frame = CGRect(
            x: textX,
            y: ((height - nameSize.height) / 2).rounded(),
            width: nameWidth,
            height: nameSize.height
        )
        if !subtitleLabel.isHidden {
            let subtitleSize = subtitleLabel.intrinsicContentSize
            let subtitleX = nameLabel.frame.maxX + Metrics.gap
            subtitleLabel.frame = CGRect(
                x: subtitleX,
                y: ((height - subtitleSize.height) / 2).rounded(),
                width: max(0, bounds.maxX - Metrics.trailingPadding - subtitleX),
                height: subtitleSize.height
            )
        }
    }

    private func apply() {
        nameLabel.stringValue = item.name
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.isHidden = style == .compact || item.subtitle == nil
        toolTip = [item.name, item.subtitle].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel(item.accessibilityLabel)
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let needsInput = item.attention == .needsInput
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (isHovered
            ? theme.openWithChromeHoverBackground
            : theme.openWithChromeBackground).cgColor
        layer?.borderColor = needsInput
            ? theme.statusNeedsInput.withAlphaComponent(0.65).cgColor
            : (isHovered ? theme.secondaryText.withAlphaComponent(0.6) : theme.openWithChromeBorder).cgColor
        dotLayer.backgroundColor = Self.dotColor(for: item.attention, theme: theme).cgColor
        CATransaction.commit()
        nameLabel.textColor = theme.primaryText
        subtitleLabel.textColor = theme.tertiaryText
        updatePulse()
    }

    static func dotColor(for attention: WorklaneAttentionState?, theme: ZenttyTheme) -> NSColor {
        guard attention != nil else {
            return theme.tertiaryText.withAlphaComponent(0.6)
        }
        return SidebarWorklaneRowStyleResolver.statusTextColor(attentionState: attention, theme: theme)
    }

    /// Working pills pulse their dot softly (not under Reduce Motion).
    private func updatePulse() {
        Self.updatePulse(on: dotLayer, attention: item.attention)
    }

    /// Pulses `dotLayer` softly while `attention` is working (pills and PiP
    /// status strips), never under Reduce Motion.
    static func updatePulse(on dotLayer: CALayer, attention: WorklaneAttentionState?) {
        let pulses = attention == .running && !FloatMotion.reduceMotion
        if pulses, dotLayer.animation(forKey: pulseKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(pulse, forKey: pulseKey)
        } else if !pulses {
            dotLayer.removeAnimation(forKey: pulseKey)
        }
    }

    var dotLayerForTesting: CALayer {
        dotLayer
    }

    var isSubtitleShownForTesting: Bool {
        !subtitleLabel.isHidden
    }

    // MARK: - Hover and accessibility

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The "+N" capsule at the left of a full bar; opens a menu of the oldest
/// pills that don't fit.
@MainActor
final class PillOverflowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var theme = ZenttyTheme.fallback(for: nil)
    var onPress: (() -> Void)?
    private(set) var count = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PillBarLayout.pillHeight / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        label.font = PillView.nameFont
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(count: Int, theme: ZenttyTheme) {
        self.count = count
        self.theme = theme
        label.stringValue = "+\(count)"
        label.textColor = theme.primaryText
        layer?.backgroundColor = theme.openWithChromeBackground.cgColor
        layer?.borderColor = theme.openWithChromeBorder.cgColor
        setAccessibilityLabel("\(count) more minimized panes")
        toolTip = "\(count) more minimized panes"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(
            x: 0,
            y: ((bounds.height - size.height) / 2).rounded(),
            width: bounds.width,
            height: size.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
