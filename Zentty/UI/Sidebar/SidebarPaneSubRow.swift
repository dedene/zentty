import AppKit

// MARK: - PaneSubRow

@MainActor
final class PaneSubRow: NSButton {
    let paneID: PaneID
    var onSelect: (() -> Void)?

    private let statusIndicator = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let gitContextLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()

    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(handleClick)

        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.setContentHuggingPriority(.required, for: .horizontal)
        statusIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        gitContextLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        gitContextLabel.lineBreakMode = .byTruncatingTail
        gitContextLabel.translatesAutoresizingMaskIntoConstraints = false
        gitContextLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        gitContextLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(statusIndicator)
        rowStack.addArrangedSubview(label)
        rowStack.addArrangedSubview(gitContextLabel)

        addSubview(rowStack)

        let leadingInset = ShellMetrics.sidebarRowHorizontalInset + ShellMetrics.paneSubRowIndent
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ShellMetrics.paneSubRowHeight),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.sidebarRowHorizontalInset),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 12),
            statusIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyHoverState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyHoverState()
    }

    func configure(with pane: PaneSidebarSummary, theme: ZenttyTheme) {
        currentTheme = theme
        label.stringValue = pane.primaryText

        let hasGitContext = !pane.gitContext.isEmpty
        gitContextLabel.stringValue = pane.gitContext
        gitContextLabel.isHidden = !hasGitContext

        // Status indicator
        let (symbolName, symbolSize, tintColor) = statusIndicatorConfig(
            for: pane.attentionState,
            theme: theme
        )
        statusIndicator.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium))
        statusIndicator.contentTintColor = tintColor

        // Text colors
        let textColor = pane.isFocused
            ? theme.sidebarButtonActiveText
            : theme.sidebarButtonInactiveText
        label.textColor = textColor
        gitContextLabel.textColor = pane.isFocused
            ? textColor.withAlphaComponent(0.60)
            : theme.tertiaryText

        applyHoverState()
    }

    private func statusIndicatorConfig(
        for attention: WorkspaceAttentionState?,
        theme: ZenttyTheme
    ) -> (symbolName: String, pointSize: CGFloat, color: NSColor) {
        switch attention {
        case .needsInput:
            return ("bell.badge.fill", 11, NSColor.systemBlue)
        case .unresolvedStop:
            return ("circle.fill", 8, NSColor.systemOrange)
        case .running:
            return ("circle.fill", 8, NSColor.systemGreen)
        case .completed, nil:
            return ("circle.fill", 8, theme.tertiaryText)
        }
    }

    private func applyHoverState() {
        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = self.isHovered
                ? self.currentTheme.sidebarButtonHoverBackground.cgColor
                : NSColor.clear.cgColor
        }
    }

    @objc
    private func handleClick() {
        onSelect?()
    }

    // MARK: - Testing Accessors

    var labelTextForTesting: String {
        label.stringValue
    }
}
