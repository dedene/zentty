import AppKit

@MainActor
final class OpenWithPopoverRowButton: NSButton {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let item: OpenWithPopoverItem
    private var theme = ZenttyTheme.fallback(for: nil)
    private var trackingAreaValue: NSTrackingArea?
    private(set) var isHovered = false
    private var isPressed = false
    var isKeyboardHighlighted = false
    var onPress: ((String) -> Void)?
    var onHover: (() -> Void)?
    var onHoverEnded: (() -> Void)?

    init(item: OpenWithPopoverItem) {
        self.item = item
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        isBordered = false
        title = ""
        image = nil
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = item.icon
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = item.title
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }

        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        onHover?()
        apply(theme: theme, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        onHoverEnded?()
        apply(theme: theme, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard item.isEnabled else {
            return
        }

        trackClick(with: event) { [weak self] didActivate in
            guard didActivate, let self else {
                return
            }

            self.onPress?(self.item.stableID)
        }
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        self.theme = theme
        let isHighlighted = isHovered || isKeyboardHighlighted || isPressed
        let background: NSColor
        let border: NSColor

        if isHighlighted && item.isEnabled {
            background = theme.openWithPopoverRowSelectedBackground
            border = theme.openWithPopoverRowSelectedBorder
        } else {
            background = .clear
            border = .clear
        }

        let textColor = theme.openWithPopoverText.withAlphaComponent(item.isEnabled ? 0.98 : 0.46)
        label.textColor = textColor
        iconView.contentTintColor = iconView.image?.isTemplate == true ? textColor : nil
        iconView.alphaValue = item.isEnabled ? 1 : 0.46
        setAccessibilityEnabled(item.isEnabled)
        setAccessibilityValue(item.isSelected ? "Selected" : nil)
        setAccessibilityHelp(item.isSelected ? "Current default Open With app" : nil)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
        }
    }

    private func trackClick(with event: NSEvent, onComplete: @escaping (Bool) -> Void) {
        isPressed = true
        apply(theme: theme, animated: true)

        guard let window else {
            isPressed = false
            apply(theme: theme, animated: true)
            onComplete(true)
            return
        }

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(nextEvent.locationInWindow, from: nil)
            let isInside = bounds.contains(point)

            switch nextEvent.type {
            case .leftMouseDragged:
                isHovered = isInside
                isPressed = isInside
                apply(theme: theme, animated: true)
            case .leftMouseUp:
                isHovered = isInside
                isPressed = false
                apply(theme: theme, animated: true)
                onComplete(isInside)
                return
            default:
                continue
            }
        }

        isPressed = false
        apply(theme: theme, animated: true)
        onComplete(false)
    }

    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        if hovered {
            onHover?()
        } else {
            onHoverEnded?()
        }
        apply(theme: theme, animated: false)
    }

    var backgroundTokenForTesting: String {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }

    var borderTokenForTesting: String {
        layer?.borderColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }
}

@MainActor
final class OpenWithPopoverFooterButton: NSButton {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Choose Apps…")
    private var trackingAreaValue: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var theme = ZenttyTheme.fallback(for: nil)
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        isBordered = false
        title = ""
        image = nil
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Choose Apps")

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Choose Apps"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }

        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        apply(theme: theme, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        apply(theme: theme, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        trackClick(with: event) { [weak self] didActivate in
            guard didActivate else {
                return
            }

            self?.onPress?()
        }
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        self.theme = theme
        let foreground = theme.openWithPopoverSecondaryText.withAlphaComponent((isHovered || isPressed) ? 0.98 : 0.86)
        label.textColor = foreground
        iconView.contentTintColor = foreground

        let background = (isHovered || isPressed) ? theme.openWithPopoverRowSelectedBackground : .clear
        let border = (isHovered || isPressed) ? theme.openWithPopoverRowSelectedBorder : .clear
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
        }
    }

    private func trackClick(with event: NSEvent, onComplete: @escaping (Bool) -> Void) {
        isPressed = true
        apply(theme: theme, animated: true)

        guard let window else {
            isPressed = false
            apply(theme: theme, animated: true)
            onComplete(true)
            return
        }

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(nextEvent.locationInWindow, from: nil)
            let isInside = bounds.contains(point)

            switch nextEvent.type {
            case .leftMouseDragged:
                isHovered = isInside
                isPressed = isInside
                apply(theme: theme, animated: true)
            case .leftMouseUp:
                isHovered = isInside
                isPressed = false
                apply(theme: theme, animated: true)
                onComplete(isInside)
                return
            default:
                continue
            }
        }

        isPressed = false
        apply(theme: theme, animated: true)
        onComplete(false)
    }

    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        apply(theme: theme, animated: false)
    }

    var backgroundTokenForTesting: String {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }

    var borderTokenForTesting: String {
        layer?.borderColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }
}
