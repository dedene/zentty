import AppKit

@MainActor
final class NotificationPanelView: NSView {

    private enum Layout {
        static let width: CGFloat = 360
        static let maxHeightRatio: CGFloat = 0.70
        static let maxHeightCap: CGFloat = 500
        static let surfaceCornerRadius = GlassSurfaceStyle.notificationPanel.cornerRadius
        static let headerHeight: CGFloat = 40
        static let headerInset: CGFloat = 14
        static let itemHeight: CGFloat = 60
        static let richItemHeight: CGFloat = 72
        static let fadeDuration: TimeInterval = 0.15
    }

    private let surfaceView = GlassSurfaceView(style: .notificationPanel)
    private let contentClipView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Notifications")
    private let jumpButton = NSButton(title: "Jump to Latest  \u{21E7}\u{2318}U", target: nil, action: nil)
    private let clearAllButton = NSButton(title: "Clear All", target: nil, action: nil)
    private let headerView = NSView()
    private let headerSeparator = NSView()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No notifications")

    var onJumpToLatest: (() -> Void)?
    var onClearAll: (() -> Void)?
    var onDismissNotification: ((UUID) -> Void)?
    var onJumpToNotification: ((AppNotification) -> Void)?
    var onClosePanel: (() -> Void)?


    private var notifications: [AppNotification] = []
    private var selectedIndex: Int?
    private var itemViews: [NotificationItemView] = []
    nonisolated(unsafe) private var clickMonitor: Any?
    private var externalConstraints: [NSLayoutConstraint] = []
    private var heightConstraint: NSLayoutConstraint?
    private weak var anchorView: NSView?
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(surfaceView)
        contentClipView.translatesAutoresizingMaskIntoConstraints = false
        contentClipView.wantsLayer = true
        contentClipView.layer?.cornerRadius = Layout.surfaceCornerRadius
        contentClipView.layer?.cornerCurve = .continuous
        contentClipView.layer?.masksToBounds = true
        surfaceView.addSubview(contentClipView)

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        contentClipView.addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        headerView.addSubview(titleLabel)

        for button in [jumpButton, clearAllButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.bezelStyle = .inline
            button.setButtonType(.momentaryChange)
            button.font = .systemFont(ofSize: 11, weight: .regular)
            headerView.addSubview(button)
        }
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatestPressed)
        jumpButton.setAccessibilityLabel("Jump to latest notification")
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllPressed)
        clearAllButton.setAccessibilityLabel("Clear all notifications")

        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.wantsLayer = true
        contentClipView.addSubview(headerSeparator)

        // Scroll area
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        contentClipView.addSubview(scrollView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        let clipView = NSClipView()
        clipView.documentView = stackView
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        contentClipView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Layout.width),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentClipView.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            contentClipView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            contentClipView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            contentClipView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
            headerView.topAnchor.constraint(equalTo: contentClipView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Layout.headerHeight),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: Layout.headerInset),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            jumpButton.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            jumpButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            clearAllButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -Layout.headerInset),
            clearAllButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerSeparator.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 0.5),
            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentClipView.bottomAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    // MARK: - Public API

    func show(below anchorView: NSView, in parentView: NSView, theme: ZenttyTheme) {
        self.anchorView = anchorView
        NSLayoutConstraint.deactivate(externalConstraints)
        removeFromSuperview()
        removeClickMonitor()
        alphaValue = 0
        parentView.addSubview(self)

        let anchorFrame = anchorView.convert(anchorView.bounds, to: parentView)
        let maxH = min(parentView.bounds.height * Layout.maxHeightRatio, Layout.maxHeightCap)
        let panelHeight = min(maxH, computeContentHeight())

        let hc = heightAnchor.constraint(equalToConstant: panelHeight)
        heightConstraint = hc
        let constraints = [
            topAnchor.constraint(equalTo: parentView.topAnchor,
                                 constant: parentView.bounds.height - anchorFrame.minY + 4),
            trailingAnchor.constraint(equalTo: parentView.trailingAnchor,
                                      constant: -(parentView.bounds.width - anchorFrame.maxX - 8)),
            hc,
        ]
        externalConstraints = constraints
        NSLayoutConstraint.activate(constraints)

        applyTheme(theme)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Layout.fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
        installClickMonitor()
        window?.makeFirstResponder(self)
    }

    func close() {
        removeClickMonitor()
        NSLayoutConstraint.deactivate(externalConstraints)
        externalConstraints = []
        heightConstraint = nil
        removeFromSuperview()
    }

    func update(notifications: [AppNotification], theme: ZenttyTheme) {
        self.notifications = notifications
        currentTheme = theme
        rebuildList(theme: theme)
        applyTheme(theme)
        updateHeight()
    }

    private func updateHeight() {
        guard let heightConstraint, superview != nil else { return }
        let maxH = min(superview!.bounds.height * Layout.maxHeightRatio, Layout.maxHeightCap)
        heightConstraint.constant = min(maxH, computeContentHeight())
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 38, 125: moveSelection(delta: 1); return true   // j / down
        case 40, 126: moveSelection(delta: -1); return true  // k / up
        case 36: // return
            if let idx = selectedIndex, notifications.indices.contains(idx) {
                onJumpToNotification?(notifications[idx])
            }
            return true
        case 51, 117: // backspace / forward-delete
            if let idx = selectedIndex, notifications.indices.contains(idx) {
                onDismissNotification?(notifications[idx].id)
            }
            return true
        case 53: onClosePanel?(); return true // escape
        default: return false
        }
    }

    // MARK: - Selection

    private func moveSelection(delta: Int) {
        guard !notifications.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = max(0, min(notifications.count - 1, current + delta))
        } else {
            selectedIndex = delta >= 0 ? 0 : notifications.count - 1
        }
        for (i, v) in itemViews.enumerated() {
            v.isSelected = i == selectedIndex
            v.applyTheme(currentTheme)
        }
        if let idx = selectedIndex, itemViews.indices.contains(idx) {
            scrollView.contentView.scrollToVisible(itemViews[idx].frame)
        }
    }

    // MARK: - Theme

    private func applyTheme(_ theme: ZenttyTheme) {
        currentTheme = theme
        surfaceView.apply(theme: theme, animated: false)
        titleLabel.textColor = theme.primaryText
        jumpButton.contentTintColor = theme.secondaryText
        clearAllButton.contentTintColor = theme.secondaryText
        emptyLabel.textColor = theme.tertiaryText
        headerSeparator.layer?.backgroundColor = theme.notificationPanelSeparator.cgColor
    }

    // MARK: - List

    private func rebuildList(theme: ZenttyTheme) {
        itemViews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
        // Also remove separator views left over from previous rebuild
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
        itemViews.removeAll()
        selectedIndex = nil

        emptyLabel.isHidden = !notifications.isEmpty
        scrollView.isHidden = notifications.isEmpty
        guard !notifications.isEmpty else { return }

        for (index, notification) in notifications.enumerated() {
            let itemView = NotificationItemView(notification: notification)
            itemView.onDismiss = { [weak self] id in self?.onDismissNotification?(id) }
            itemView.onJump = { [weak self] n in self?.onJumpToNotification?(n) }
            itemView.applyTheme(theme)
            stackView.addArrangedSubview(itemView)
            itemView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            let itemHeight = notification.locationText == nil ? Layout.itemHeight : Layout.richItemHeight
            itemView.heightAnchor.constraint(equalToConstant: itemHeight).isActive = true
            itemViews.append(itemView)

            if index < notifications.count - 1 {
                let sep = NSView()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.wantsLayer = true
                sep.layer?.backgroundColor = theme.notificationPanelSeparator.cgColor
                stackView.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            }
        }
    }

    private func computeContentHeight() -> CGFloat {
        let itemHeights = notifications.isEmpty
            ? [Layout.itemHeight]
            : notifications.map { notification in
                notification.locationText == nil ? Layout.itemHeight : Layout.richItemHeight
            }
        let separatorCount = max(0, notifications.count - 1)
        let totalItemHeight = itemHeights.reduce(0, +)
        return Layout.headerHeight + 0.5 + totalItemHeight + CGFloat(separatorCount) * 0.5
    }

    // MARK: - Click-outside

    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            let pointInPanel = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(pointInPanel) { return event }
            // Don't close when clicking the anchor (bell button) — let its toggle action handle it.
            if let anchor = self.anchorView {
                let pointInAnchor = anchor.convert(event.locationInWindow, from: nil)
                if anchor.bounds.contains(pointInAnchor) { return event }
            }
            self.onClosePanel?()
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    @objc private func jumpToLatestPressed() { onJumpToLatest?() }
    @objc private func clearAllPressed() { onClearAll?() }

    override func removeFromSuperview() {
        removeClickMonitor()
        super.removeFromSuperview()
    }
}

// MARK: - NotificationItemView

@MainActor
private final class NotificationItemView: NSView {

    private enum Layout {
        static let iconSize: CGFloat = 16
        static let hPad: CGFloat = 12
        static let vPad: CGFloat = 8
        static let accentWidth: CGFloat = 2
        static let dismissSize: CGFloat = 16
    }

    let notification: AppNotification
    var isSelected = false
    var onDismiss: ((UUID) -> Void)?
    var onJump: ((AppNotification) -> Void)?

    private let iconView = NSImageView()
    private let toolLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let primaryLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let dismissButton = NSButton(title: "\u{00D7}", target: nil, action: nil)
    private let accentBar = NSView()
    private let headlineStack = NSStackView()
    private let textStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isHovered = false

    init(notification: AppNotification) {
        self.notification = notification
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleJump)))
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Build

    private func buildSubviews() {
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        setAccessibilityRole(.button)

        // Accent bar
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.isHidden = notification.isResolved
        addSubview(accentBar)

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        let symbolName = notification.interactionSymbolName ?? "bell.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: Layout.iconSize, weight: .medium)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            iconView.image = img
        }
        addSubview(iconView)

        // Text stack
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        headlineStack.translatesAutoresizingMaskIntoConstraints = false
        headlineStack.orientation = .horizontal
        headlineStack.alignment = .firstBaseline
        headlineStack.spacing = 6

        toolLabel.font = notification.isResolved
            ? .systemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12, weight: .bold)
        for label in [toolLabel, statusLabel, primaryLabel, locationLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        toolLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        toolLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        primaryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        locationLabel.font = .systemFont(ofSize: 11, weight: .regular)
        headlineStack.addArrangedSubview(toolLabel)
        headlineStack.addArrangedSubview(statusLabel)
        textStack.addArrangedSubview(headlineStack)
        textStack.addArrangedSubview(primaryLabel)
        textStack.addArrangedSubview(locationLabel)
        addSubview(textStack)

        // Timestamp
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = .systemFont(ofSize: 11, weight: .regular)
        timestampLabel.alignment = .right
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timestampLabel)

        // Dismiss button
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.isBordered = false
        dismissButton.bezelStyle = .inline
        dismissButton.font = .systemFont(ofSize: 14, weight: .regular)
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        dismissButton.isHidden = true
        dismissButton.setAccessibilityLabel("Dismiss notification")
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            accentBar.widthAnchor.constraint(equalToConstant: Layout.accentWidth),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.hPad),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.vPad + 1),
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: timestampLabel.leadingAnchor, constant: -8),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: Layout.vPad - 1),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.vPad),
            timestampLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.hPad),
            timestampLabel.topAnchor.constraint(equalTo: topAnchor, constant: Layout.vPad),
            timestampLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.hPad),
            dismissButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.vPad),
            dismissButton.widthAnchor.constraint(equalToConstant: Layout.dismissSize),
            dismissButton.heightAnchor.constraint(equalToConstant: Layout.dismissSize),
        ])

        // Content
        toolLabel.stringValue = notification.tool.displayName
        statusLabel.stringValue = notification.statusText
        primaryLabel.stringValue = notification.primaryText
        locationLabel.stringValue = notification.locationText ?? ""
        locationLabel.isHidden = notification.locationText == nil
        timestampLabel.stringValue = relativeTimestamp(notification.createdAt)
        setAccessibilityLabel(accessibilitySummary())
        alphaValue = notification.isResolved ? 0.5 : 1.0
    }

    func applyTheme(_ theme: ZenttyTheme) {
        currentTheme = theme
        toolLabel.textColor = theme.primaryText
        statusLabel.textColor = theme.secondaryText
        primaryLabel.textColor = theme.secondaryText
        locationLabel.textColor = theme.tertiaryText
        timestampLabel.textColor = theme.tertiaryText
        dismissButton.contentTintColor = theme.tertiaryText
        iconView.contentTintColor = notification.isResolved ? theme.tertiaryText : theme.secondaryText
        accentBar.layer?.backgroundColor = NSColor.systemCyan.cgColor
        updateBackground()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func accessibilityPerformPress() -> Bool {
        onJump?(notification)
        return true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        dismissButton.isHidden = false
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        dismissButton.isHidden = true
        updateBackground()
    }

    @objc private func handleDismiss() { onDismiss?(notification.id) }
    @objc private func handleJump() { onJump?(notification) }

    private func updateBackground() {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = currentTheme.notificationPanelRowSelectedBackground
        } else if isHovered {
            backgroundColor = currentTheme.notificationPanelRowHoverBackground
        } else {
            backgroundColor = .clear
        }

        layer?.backgroundColor = backgroundColor.cgColor
    }

    private func accessibilitySummary() -> String {
        [
            notification.tool.displayName,
            WorklaneContextFormatter.trimmed(notification.statusText),
            WorklaneContextFormatter.trimmed(notification.primaryText),
            WorklaneContextFormatter.trimmed(notification.locationText),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
