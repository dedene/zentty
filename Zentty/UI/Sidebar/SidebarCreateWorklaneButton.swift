import AppKit
import QuartzCore

final class SidebarCreateWorklaneButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New worklane")
    private let contentStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var backgroundColorForTesting = NSColor.clear
    private var borderColorForTesting = NSColor.clear
    private(set) var isHovered = false

    override var isHighlighted: Bool {
        didSet {
            applyCurrentAppearance(animated: true)
        }
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentStack.fittingSize
        return NSSize(
            width: contentSize.width + (ShellMetrics.sidebarCreateWorklaneHorizontalInset * 2),
            height: ShellMetrics.sidebarCreateWorklaneButtonHeight
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        title = ""
        setAccessibilityLabel("New worklane")
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        font = NSFont.systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCreateWorklaneButtonHeight).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New worklane"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = ShellMetrics.sidebarCreateWorklaneIconSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        let leading = contentStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ShellMetrics.sidebarCreateWorklaneHorizontalInset
        )
        leading.priority = .defaultHigh

        let trailing = contentStack.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -ShellMetrics.sidebarCreateWorklaneHorizontalInset
        )
        trailing.priority = .defaultHigh

        let iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            leading,
            trailing,
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        if let cell = cell as? NSButtonCell {
            cell.alignment = .left
            cell.imagePosition = .noImage
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else {
            return
        }

        isHovered = true
        applyCurrentAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        applyCurrentAppearance(animated: true)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        titleLabel.stringValue = "New worklane"
        invalidateIntrinsicContentSize()
        applyCurrentAppearance(animated: animated)
    }

    var titleText: String {
        titleLabel.stringValue
    }

    var iconAlpha: CGFloat {
        iconView.contentTintColor?.alphaComponent ?? 0
    }

    var titleAlpha: CGFloat {
        titleLabel.textColor?.alphaComponent ?? 0
    }

    var backgroundAlpha: CGFloat {
        backgroundColorForTesting.alphaComponent
    }

    var borderAlpha: CGFloat {
        borderColorForTesting.alphaComponent
    }

    var usesPointingHandCursorForTesting: Bool {
        true
    }

    func contentMinX(in view: NSView) -> CGFloat {
        view.convert(contentStack.bounds, from: contentStack).minX
    }

    func contentMidX(in view: NSView) -> CGFloat {
        view.convert(contentStack.bounds, from: contentStack).midX
    }

    func setHoveredForTesting(_ isHovered: Bool) {
        self.isHovered = isHovered
        applyCurrentAppearance(animated: false)
    }

    private func applyCurrentAppearance(animated: Bool) {
        let isEmphasized = isHovered || isHighlighted
        let titleColor = isEmphasized
            ? currentTheme.primaryText.withAlphaComponent(0.96)
            : currentTheme.secondaryText.withAlphaComponent(0.90)
        let iconColor = isEmphasized
            ? currentTheme.secondaryText.withAlphaComponent(0.92)
            : currentTheme.tertiaryText.withAlphaComponent(0.68)
        let backgroundColor: NSColor
        if isEmphasized {
            let hoverMix: CGFloat = currentTheme.sidebarBackground.isDarkThemeColor ? 0.12 : 0.18
            backgroundColor = currentTheme.sidebarBackground
                .mixed(towards: currentTheme.primaryText, amount: hoverMix)
                .withAlphaComponent(min(1, currentTheme.sidebarBackground.alphaComponent + 0.10))
        } else {
            backgroundColor = .clear
        }

        titleLabel.textColor = titleColor
        iconView.contentTintColor = iconColor
        backgroundColorForTesting = backgroundColor
        borderColorForTesting = .clear

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 0
        }
    }
}
