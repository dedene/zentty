import AppKit
import QuartzCore

// MARK: - PaneSubRow

@MainActor
final class PaneSubRow: NSButton {
    private enum WorkingIndicator {
        static let shimmerAnimationKey = "pane-row-shimmer"
    }

    let paneID: PaneID
    var onSelect: (() -> Void)?

    private let statusIndicator = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let gitContextLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()
    private let shimmerLayer = CAGradientLayer()

    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isWorking = false
    private let reducedMotionProvider: () -> Bool

    init(
        paneID: PaneID,
        reducedMotionProvider: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.paneID = paneID
        self.reducedMotionProvider = reducedMotionProvider
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
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(handleClick)

        shimmerLayer.isHidden = true
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(shimmerLayer)

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

    override func layout() {
        super.layout()
        shimmerLayer.frame = bounds
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
        applyVisualState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyVisualState()
    }

    func configure(with pane: PaneSidebarSummary, theme: ZenttyTheme) {
        currentTheme = theme
        isWorking = pane.isWorking
        label.stringValue = pane.primaryText

        let hasGitContext = !pane.gitContext.isEmpty
        gitContextLabel.stringValue = pane.gitContext
        gitContextLabel.isHidden = !hasGitContext

        // Status indicator
        let (symbolName, symbolSize, tintColor) = statusIndicatorConfig(
            for: pane.attentionState,
            isWorking: pane.isWorking,
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

        applyVisualState()
    }

    private func statusIndicatorConfig(
        for attention: WorkspaceAttentionState?,
        isWorking: Bool,
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
            if isWorking {
                return ("circle.fill", 8, NSColor.systemGreen)
            }
            return ("circle.fill", 8, theme.tertiaryText)
        }
    }

    private func applyVisualState() {
        updateShimmerState()

        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = self.backgroundColorForCurrentState().cgColor
        }
    }

    private func backgroundColorForCurrentState() -> NSColor {
        if isHovered {
            return currentTheme.sidebarButtonHoverBackground
        }

        guard isWorking else {
            return .clear
        }

        let base = currentTheme.sidebarButtonInactiveBackground
            .mixed(towards: currentTheme.sidebarGradientStart, amount: 0.18)
        return base.withAlphaComponent(currentTheme.reducedTransparency ? 0.30 : 0.18)
    }

    private func updateShimmerState() {
        shimmerLayer.removeAnimation(forKey: WorkingIndicator.shimmerAnimationKey)

        guard isWorking else {
            shimmerLayer.isHidden = true
            shimmerLayer.opacity = 0
            return
        }

        let highlight = currentTheme.sidebarGradientStart
            .brightenedForLabel
            .withAlphaComponent(currentTheme.reducedTransparency ? 0.18 : 0.30)
        shimmerLayer.colors = [
            NSColor.clear.cgColor,
            highlight.cgColor,
            NSColor.clear.cgColor,
        ]

        if reducedMotionProvider() {
            shimmerLayer.isHidden = false
            shimmerLayer.opacity = 0.55
            shimmerLayer.locations = [0.28, 0.50, 0.72]
            return
        }

        shimmerLayer.isHidden = false
        shimmerLayer.opacity = 1
        shimmerLayer.locations = [0, 0.18, 0.36]

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.55, -0.20, 0.15]
        animation.toValue = [0.85, 1.20, 1.55]
        animation.duration = 1.15
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerLayer.add(animation, forKey: WorkingIndicator.shimmerAnimationKey)
    }

    @objc
    private func handleClick() {
        onSelect?()
    }

    // MARK: - Testing Accessors

    var labelTextForTesting: String {
        label.stringValue
    }

    var isWorkingForTesting: Bool {
        isWorking
    }

    var shimmerIsAnimatingForTesting: Bool {
        shimmerLayer.animation(forKey: WorkingIndicator.shimmerAnimationKey) != nil
    }
}
