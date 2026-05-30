import AppKit

/// A tinted status pill for a menu-bar dropdown row: a rounded capsule (fill +
/// border in the status hue) with a leading dot — or the hosted task-progress
/// spinner while a task is running — followed by the status label. On hover it
/// reveals the "N/M tasks" detail, matching the sidebar behavior.
///
/// Colors come from ``MenuBarStatusPalette`` resolved against the menu's
/// appearance. The view lays its content out manually and reports an
/// ``intrinsicContentSize`` so the row can right-align and size it.
@MainActor
final class MenuBarStatusPillView: NSView {
    private enum Metrics {
        static let height: CGFloat = 18
        static let cornerRadius: CGFloat = 9
        static let paddingLeading: CGFloat = 7
        static let paddingTrailing: CGFloat = 9
        static let dotSide: CGFloat = 6
        static let spinnerSide = SidebarTaskProgressIndicatorMetrics.sideLength
        static let leadingToContentGap: CGFloat = 5
        static let borderWidth: CGFloat = 1
    }

    private let dotLayer = CALayer()
    private let progressIndicator = SidebarTaskProgressIndicatorView()
    private let revealView = SidebarTaskProgressRevealView()
    private let label = NSTextField(labelWithString: "")

    private var kind: MenuBarStatusKind = .idle
    private var hasProgress = false
    private var isRevealed = false

    // Applied colors, retained for the debug snapshot / tests.
    private var appliedLabelColor: NSColor?
    private var appliedFillColor: NSColor?
    private var appliedBorderColor: NSColor?
    private var appliedDotColor: NSColor?

    /// Forwarded so the row can drive hover-reveal of the progress detail.
    var onProgressHoverEntered: (() -> Void)? {
        get { progressIndicator.onHoverEntered }
        set { progressIndicator.onHoverEntered = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keep pill colors exact (no menu vibrancy graying the tinted hues).
    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        let leadingWidth = hasProgress ? Metrics.spinnerSide : Metrics.dotSide
        let revealWidth = (hasProgress && isRevealed) ? revealView.expandedWidth : 0
        let width = Metrics.paddingLeading
            + leadingWidth
            + Metrics.leadingToContentGap
            + revealWidth
            + ceil(label.fittingSize.width)
            + Metrics.paddingTrailing
        return NSSize(width: ceil(width), height: Metrics.height)
    }

    func configure(
        kind: MenuBarStatusKind,
        text: String,
        taskProgress: PaneAgentTaskProgress?,
        appearance: NSAppearance?,
        reduceTransparency: Bool
    ) {
        self.kind = kind
        hasProgress = taskProgress != nil

        let isDark = MenuBarStatusPalette.isDark(appearance)
        let labelColor = MenuBarStatusPalette.labelColor(for: kind, isDark: isDark)
        let fillColor = MenuBarStatusPalette.fillColor(for: kind, isDark: isDark, reduceTransparency: reduceTransparency)
        let borderColor = MenuBarStatusPalette.borderColor(for: kind, isDark: isDark, reduceTransparency: reduceTransparency)
        let dotColor = MenuBarStatusPalette.dotColor(for: kind, isDark: isDark)

        appliedLabelColor = labelColor
        appliedFillColor = fillColor
        appliedBorderColor = borderColor
        appliedDotColor = dotColor

        label.stringValue = text
        label.textColor = labelColor

        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = borderColor.cgColor

        dotLayer.isHidden = hasProgress
        dotLayer.backgroundColor = dotColor.cgColor

        // The spinner hides itself when taskProgress is nil. Tint it to match
        // the dot/label so the running pill reads as one color.
        progressIndicator.configure(
            taskProgress: taskProgress,
            color: dotColor,
            animated: false,
            reducedMotion: true
        )
        revealView.configure(
            taskProgress: taskProgress,
            color: labelColor,
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        revealView.setRevealed(isRevealed, animated: false, reducedMotion: true)

        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Reveal/hide the "N/M tasks" detail (driven by the row's hover state).
    func setRevealed(_ revealed: Bool, animated: Bool, reducedMotion: Bool) {
        guard isRevealed != revealed else { return }
        isRevealed = revealed
        revealView.setRevealed(revealed, animated: animated, reducedMotion: reducedMotion)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        var x = Metrics.paddingLeading

        let leadingWidth = hasProgress ? Metrics.spinnerSide : Metrics.dotSide
        let leadingY = ((bounds.height - leadingWidth) / 2).rounded()
        if hasProgress {
            progressIndicator.frame = NSRect(x: x, y: leadingY, width: Metrics.spinnerSide, height: Metrics.spinnerSide)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dotLayer.frame = NSRect(x: x, y: leadingY, width: Metrics.dotSide, height: Metrics.dotSide)
            CATransaction.commit()
        }
        x += leadingWidth + Metrics.leadingToContentGap

        // Vertically center the label, and place the hover-reveal detail in the
        // same band so its "N/M tasks ·" text shares the label's baseline
        // instead of riding high in a full-height box.
        let labelHeight = ceil(label.fittingSize.height)
        let contentY = ((bounds.height - labelHeight) / 2).rounded()

        let revealWidth = (hasProgress && isRevealed) ? revealView.expandedWidth : 0
        revealView.frame = NSRect(x: x, y: contentY, width: revealWidth, height: labelHeight)
        x += revealWidth

        // Clamp to the room left inside the pill so the label truncates (it's
        // .byTruncatingTail) instead of being hard-clipped by the capsule when
        // the row frames the pill narrower than its intrinsic width.
        let availableLabelWidth = max(0, bounds.width - x - Metrics.paddingTrailing)
        let labelWidth = min(ceil(label.fittingSize.width), availableLabelWidth)
        label.frame = NSRect(x: x, y: contentY, width: labelWidth, height: labelHeight)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.borderWidth = Metrics.borderWidth
        layer?.masksToBounds = true

        dotLayer.cornerRadius = Metrics.dotSide / 2
        layer?.addSublayer(dotLayer)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .left

        progressIndicator.isHidden = true

        [revealView, progressIndicator, label].forEach(addSubview)
    }

    // MARK: - Testing

    struct DebugSnapshot {
        let kind: MenuBarStatusKind
        let labelText: String
        let labelColor: NSColor?
        let fillColor: NSColor?
        let borderColor: NSColor?
        let dotColor: NSColor?
        let isProgressVisible: Bool
        let intrinsicSize: NSSize
    }

    var debugSnapshotForTesting: DebugSnapshot {
        DebugSnapshot(
            kind: kind,
            labelText: label.stringValue,
            labelColor: appliedLabelColor,
            fillColor: appliedFillColor,
            borderColor: appliedBorderColor,
            dotColor: appliedDotColor,
            isProgressVisible: hasProgress && progressIndicator.isHidden == false,
            intrinsicSize: intrinsicContentSize
        )
    }
}
