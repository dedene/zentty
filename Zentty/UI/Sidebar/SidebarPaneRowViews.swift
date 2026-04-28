import AppKit

enum SidebarTaskProgressIndicatorMetrics {
    static let sideLength: CGFloat = 11
    static let spacing: CGFloat = 4
    static let reservedWidth = sideLength + spacing
}

// MARK: - Leaf Components

final class SidebarStaticLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        stringValue = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }
}

final class SidebarPrimaryTextContainerView: NSView {
    override var allowsVibrancy: Bool {
        false
    }
}

@MainActor
final class SidebarTaskProgressIndicatorView: NSView {
    private static let sideLength = SidebarTaskProgressIndicatorMetrics.sideLength

    private enum Animation {
        static let key = "taskProgressStrokeEnd"
        static let duration: CFTimeInterval = 0.18
    }

    private enum Arc {
        static let startAngle: CGFloat = .pi / 2
        static let endAngle: CGFloat = -(3 * .pi) / 2
        static let clockwise = true
    }

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var trackingAreaValue: NSTrackingArea?
    private var hasConfiguredProgress = false

    private(set) var fraction: CGFloat = 0
    private(set) var progressColor: NSColor = .controlAccentColor
    private(set) var tooltipText = ""
    private(set) var lastUpdateWasAnimated = false
    var onHoverEntered: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.sideLength, height: Self.sideLength)
    }

    override func layout() {
        super.layout()
        updateLayerPaths()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaValue = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverEntered?()
    }

    var progressArcConfigurationForTesting: (startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        (Arc.startAngle, Arc.endAngle, Arc.clockwise)
    }

    func configure(
        taskProgress: PaneAgentTaskProgress?,
        color: NSColor,
        animated: Bool,
        reducedMotion: Bool
    ) {
        guard let taskProgress else {
            isHidden = true
            toolTip = nil
            tooltipText = ""
            hasConfiguredProgress = false
            lastUpdateWasAnimated = false
            return
        }

        isHidden = false
        progressColor = color
        let progressText = "\(taskProgress.doneCount)/\(taskProgress.totalCount) tasks"
        tooltipText = ""
        toolTip = nil
        setAccessibilityLabel("Task progress")
        setAccessibilityValue(progressText)

        trackLayer.strokeColor = color.withAlphaComponent(0.22).cgColor
        progressLayer.strokeColor = color.cgColor

        let nextFraction = CGFloat(taskProgress.doneCount) / CGFloat(taskProgress.totalCount)
        applyFraction(
            max(0, min(1, nextFraction)),
            animated: animated && reducedMotion == false
        )
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.masksToBounds = false

        [trackLayer, progressLayer].forEach { shapeLayer in
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.lineWidth = 2
            shapeLayer.lineCap = .round
            shapeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(shapeLayer)
        }
        progressLayer.strokeEnd = 0

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.sideLength),
            heightAnchor.constraint(equalToConstant: Self.sideLength),
        ])
    }

    private func applyFraction(_ nextFraction: CGFloat, animated: Bool) {
        let previousFraction = fraction
        fraction = nextFraction

        let shouldAnimate =
            hasConfiguredProgress
            && animated
            && abs(previousFraction - nextFraction) > 0.001
            && isHidden == false
        lastUpdateWasAnimated = shouldAnimate
        hasConfiguredProgress = true

        progressLayer.removeAnimation(forKey: Animation.key)
        if shouldAnimate {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = progressLayer.presentation()?.strokeEnd ?? previousFraction
            animation.toValue = nextFraction
            animation.duration = Animation.duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressLayer.add(animation, forKey: Animation.key)
        }
        progressLayer.strokeEnd = nextFraction
    }

    private func updateLayerPaths() {
        let side = min(bounds.width, bounds.height)
        let inset = max(1, trackLayer.lineWidth / 2)
        let radius = max(0, (side / 2) - inset)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: Arc.startAngle,
            endAngle: Arc.endAngle,
            clockwise: Arc.clockwise
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        progressLayer.frame = bounds
        trackLayer.path = path
        progressLayer.path = path
        trackLayer.strokeEnd = 1
        CATransaction.commit()
    }
}

@MainActor
final class SidebarTaskProgressRevealView: NSView {
    private enum Layout {
        static let leadingPadding: CGFloat = 4
    }

    private enum Animation {
        static let revealDuration: TimeInterval = 0.16
        static let hideDuration: TimeInterval = 0.12
    }

    private let label = SidebarStaticLabel()
    private var measuredExpandedWidth: CGFloat = 0

    private(set) var revealText = ""
    private(set) var isRevealed = false
    private(set) var lastUpdateWasAnimated = false
    private(set) var lastAnimationDuration: TimeInterval?
    private(set) var lastConfigureSyncedPresentationForTesting = false
    var expandedWidth: CGFloat {
        measuredExpandedWidth
    }

    var resolvedWidthForTesting: CGFloat {
        bounds.width
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(taskProgress: PaneAgentTaskProgress?, color: NSColor, font: NSFont) {
        label.font = font
        label.textColor = color

        guard let taskProgress else {
            revealText = ""
            label.stringValue = ""
            measuredExpandedWidth = 0
            lastConfigureSyncedPresentationForTesting = true
            setRevealed(false, animated: false, reducedMotion: true, appliesAlpha: true)
            isHidden = true
            return
        }

        let nextRevealText = "\(taskProgress.doneCount)/\(taskProgress.totalCount) tasks ・"
        let nextMeasuredExpandedWidth = Self.measuredWidth(for: nextRevealText, font: font) + Layout.leadingPadding
        let shouldSyncPresentation =
            isHidden
            || revealText != nextRevealText
            || abs(measuredExpandedWidth - nextMeasuredExpandedWidth) > 0.5

        revealText = nextRevealText
        label.stringValue = revealText
        measuredExpandedWidth = nextMeasuredExpandedWidth
        isHidden = false
        lastConfigureSyncedPresentationForTesting = shouldSyncPresentation
        if shouldSyncPresentation {
            label.alphaValue = isRevealed ? 1 : 0
            needsLayout = true
        }
    }

    func setRevealed(_ revealed: Bool, animated: Bool, reducedMotion: Bool) {
        setRevealed(revealed, animated: animated, reducedMotion: reducedMotion, appliesAlpha: true)
    }

    func setRevealed(
        _ revealed: Bool,
        animated: Bool,
        reducedMotion: Bool,
        appliesAlpha: Bool
    ) {
        guard revealText.isEmpty == false || revealed == false else {
            lastUpdateWasAnimated = false
            return
        }

        isRevealed = revealed
        let targetAlpha: CGFloat = revealed ? 1 : 0
        let shouldAnimate = animated && reducedMotion == false
        lastUpdateWasAnimated = shouldAnimate
        lastAnimationDuration = shouldAnimate
            ? (revealed ? Animation.revealDuration : Animation.hideDuration)
            : nil

        guard appliesAlpha else {
            label.alphaValue = targetAlpha
            return
        }

        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = revealed ? Animation.revealDuration : Animation.hideDuration
                context.timingFunction = CAMediaTimingFunction(
                    name: revealed ? .easeOut : .easeInEaseOut
                )
                label.animator().alphaValue = targetAlpha
            }
        } else {
            label.alphaValue = targetAlpha
        }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: Layout.leadingPadding,
            y: 0,
            width: max(0, bounds.width - Layout.leadingPadding),
            height: bounds.height
        )
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true

        label.autoresizingMask = [.width, .height]
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.alphaValue = 0
        addSubview(label)
    }

    private static func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        SidebarTextMetrics.measuredWidth(for: text, font: font)
    }
}

@MainActor
final class SidebarTaskProgressRevealLineView: NSView {
    private enum Layout {
        static let spacing: CGFloat = 4
        static let protectedStatusTextMaximumWidth: CGFloat = 96
    }

    private enum Animation {
        static let revealDuration: TimeInterval = 0.16
        static let hideDuration: TimeInterval = 0.12
    }

    private var trackingAreaValue: NSTrackingArea?
    private weak var iconView: NSImageView?
    private weak var progressIndicator: SidebarTaskProgressIndicatorView?
    private weak var progressRevealView: SidebarTaskProgressRevealView?
    private weak var textContainer: NSView?
    private weak var trailingLabelView: SidebarStaticLabel?
    private var statusText = ""
    private var statusFont = ShellMetrics.sidebarStatusFont()
    private var trailingPreferredWidth: CGFloat = 0
    private var lineHeight = ShellMetrics.sidebarStatusLineHeight
    private var revealProgress: CGFloat = 0
    private var taskProgressVisible = false
    private var wraps = false
    var onMouseExitedLine: (() -> Void)?
    var onMouseEnteredLine: (() -> Void)?

    var progressRevealWidthForTesting: CGFloat {
        progressRevealView?.bounds.width ?? 0
    }

    var textContainerWidthForTesting: CGFloat {
        textContainer?.bounds.width ?? 0
    }

    var trailingLabelWidthForTesting: CGFloat {
        trailingLabelView?.bounds.width ?? 0
    }

    func configureSubviews(
        iconView: NSImageView,
        progressIndicator: SidebarTaskProgressIndicatorView,
        progressRevealView: SidebarTaskProgressRevealView,
        textContainer: NSView,
        trailingLabelView: SidebarStaticLabel? = nil
    ) {
        self.iconView = iconView
        self.progressIndicator = progressIndicator
        self.progressRevealView = progressRevealView
        self.textContainer = textContainer
        self.trailingLabelView = trailingLabelView

        [iconView, progressIndicator, progressRevealView, textContainer, trailingLabelView].forEach { view in
            guard let view else { return }
            view.translatesAutoresizingMaskIntoConstraints = false
            if view.superview !== self {
                addSubview(view)
            }
        }
    }

    func configureLayout(
        statusText: String,
        statusFont: NSFont,
        trailingPreferredWidth: CGFloat,
        lineHeight: CGFloat,
        wraps: Bool,
        taskProgressVisible: Bool
    ) {
        self.statusText = statusText
        self.statusFont = statusFont
        self.trailingPreferredWidth = trailingPreferredWidth
        self.lineHeight = lineHeight
        self.wraps = wraps
        self.taskProgressVisible = taskProgressVisible
        if taskProgressVisible == false || wraps {
            revealProgress = 0
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        applyLayout(revealProgress: revealProgress, animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaValue = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnteredLine?()
    }

    override func mouseExited(with event: NSEvent) {
        handleMouseExited(pointerIsInsideCurrentBounds: pointerIsInsideCurrentBounds(for: event))
    }

    func setProgressRevealVisible(_ isVisible: Bool, animated: Bool, reducedMotion: Bool) {
        let targetProgress: CGFloat = isVisible && taskProgressVisible && wraps == false ? 1 : 0
        guard abs(revealProgress - targetProgress) > 0.001 else {
            return
        }

        revealProgress = targetProgress
        let shouldAnimate = animated && reducedMotion == false
        guard shouldAnimate else {
            applyLayout(revealProgress: targetProgress, animated: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = targetProgress > 0.5 ? Animation.revealDuration : Animation.hideDuration
            context.timingFunction = CAMediaTimingFunction(
                name: targetProgress > 0.5 ? .easeOut : .easeInEaseOut
            )
            applyLayout(revealProgress: targetProgress, animated: true)
        }
    }

    func simulateMouseExitedForTesting(pointerStillInsideLine: Bool) {
        handleMouseExited(pointerIsInsideCurrentBounds: pointerStillInsideLine)
    }

    func simulateHoverReconciliationForTesting(pointerInsideLine: Bool) {
        handleMouseExited(pointerIsInsideCurrentBounds: pointerInsideLine)
    }

    func simulateMouseEnteredForTesting() {
        onMouseEnteredLine?()
    }

    private func applyLayout(revealProgress: CGFloat, animated: Bool) {
        guard let textContainer else { return }

        let progressRevealView = progressRevealView
        let progressIndicator = progressIndicator
        let iconView = iconView
        let trailingLabelView = trailingLabelView
        let contentHeight = wraps ? bounds.height : lineHeight
        let originY = wraps ? bounds.maxY - contentHeight : (bounds.height - contentHeight) / 2
        var x: CGFloat = 0

        if let iconView, iconView.isHidden == false {
            let side = SidebarTaskProgressIndicatorMetrics.sideLength
            setFrame(
                NSRect(x: x, y: centeredY(for: side, in: contentHeight, originY: originY), width: side, height: side),
                for: iconView,
                animated: animated
            )
            x += side + Layout.spacing
        }

        if let progressIndicator, progressIndicator.isHidden == false {
            let side = SidebarTaskProgressIndicatorMetrics.sideLength
            setFrame(
                NSRect(x: x, y: centeredY(for: side, in: contentHeight, originY: originY), width: side, height: side),
                for: progressIndicator,
                animated: animated
            )
            x += side
        }

        let expandedRevealWidth = taskProgressVisible
            ? (progressRevealView?.expandedWidth ?? 0)
            : 0
        let revealWidth = expandedRevealWidth * revealProgress
        if let progressRevealView {
            progressRevealView.isHidden = taskProgressVisible == false
            progressRevealView.setRevealed(
                revealProgress > 0.001,
                animated: animated,
                reducedMotion: false,
                appliesAlpha: false
            )
            setFrame(
                NSRect(x: x, y: originY, width: revealWidth, height: contentHeight),
                for: progressRevealView,
                animated: animated
            )
            setAlpha(revealProgress, for: progressRevealView, animated: animated)
        }
        if taskProgressVisible {
            x += revealWidth > 0.5 ? revealWidth + Layout.spacing : Layout.spacing
        }

        let remainingWidth = max(0, bounds.width - x)
        let trailingCanShow = trailingLabelView?.isHidden == false && trailingPreferredWidth > 0 && wraps == false
        let measuredStatusWidth = SidebarTextMetrics.measuredWidth(for: statusText, font: statusFont)
        let protectedStatusWidth = min(measuredStatusWidth, Layout.protectedStatusTextMaximumWidth)
        let trailingWidth: CGFloat
        let trailingSpacing: CGFloat
        if trailingCanShow {
            trailingWidth = min(
                trailingPreferredWidth,
                max(0, remainingWidth - protectedStatusWidth - Layout.spacing)
            )
            trailingSpacing = trailingWidth > 0.5 ? Layout.spacing : 0
        } else {
            trailingWidth = 0
            trailingSpacing = 0
        }
        // Cap the status text slot at its natural width so the trailing label
        // sits directly next to the status instead of being pushed to the far
        // right edge with a wide gap.
        let availableTextWidth = max(0, remainingWidth - trailingWidth - trailingSpacing)
        let textWidth = trailingCanShow
            ? min(availableTextWidth, measuredStatusWidth)
            : availableTextWidth
        setFrame(
            NSRect(x: x, y: originY, width: textWidth, height: contentHeight),
            for: textContainer,
            animated: animated
        )
        x += textWidth + trailingSpacing

        if let trailingLabelView {
            setFrame(
                NSRect(x: x, y: originY, width: trailingWidth, height: contentHeight),
                for: trailingLabelView,
                animated: animated
            )
        }
    }

    private func setFrame(_ frame: NSRect, for view: NSView, animated: Bool) {
        guard animated else {
            view.frame = frame
            return
        }

        view.animator().frame = frame
    }

    private func setAlpha(_ alpha: CGFloat, for view: NSView, animated: Bool) {
        guard animated else {
            view.alphaValue = alpha
            return
        }
        view.animator().alphaValue = alpha
    }

    private func centeredY(for childHeight: CGFloat, in contentHeight: CGFloat, originY: CGFloat) -> CGFloat {
        originY + ((contentHeight - childHeight) / 2)
    }

    private func handleMouseExited(pointerIsInsideCurrentBounds: Bool) {
        guard pointerIsInsideCurrentBounds == false else {
            return
        }

        onMouseExitedLine?()
    }

    private func pointerIsInsideCurrentBounds(for event: NSEvent) -> Bool {
        let pointInBounds = convert(event.locationInWindow, from: nil)
        return bounds.insetBy(dx: -1, dy: -1).contains(pointInBounds)
    }
}

// MARK: - SidebarPanePrimaryRowView

@MainActor
final class SidebarPanePrimaryRowView: NSView {
    private let textContainer = SidebarPrimaryTextContainerView()
    private let baseLabel = SidebarStaticLabel()
    private let shimmerLabel = SidebarShimmerTextView()
    private let trailingLabelView = SidebarStaticLabel()
    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var presentationMode: SidebarPaneRowPresentationMode = .inline
    private var requestedLineCount: Int = 1

    private(set) var primaryText: String = ""
    private(set) var trailingText: String?
    private(set) var primaryColor: NSColor = .labelColor
    private(set) var trailingColor: NSColor = .secondaryLabelColor

    var renderedPrimaryTextColorForTesting: NSColor {
        baseLabel.textColor ?? .clear
    }

    var shimmerColorForTesting: NSColor {
        shimmerLabel.shimmerColor
    }

    var renderedTrailingTextColorForTesting: NSColor {
        trailingLabelView.textColor ?? .clear
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: heightConstraint?.constant ?? ShellMetrics.sidebarPrimaryLineHeight
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

    override func layout() {
        super.layout()
        updateAdaptiveHeight()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textContainer.addSubview(baseLabel)
        textContainer.addSubview(shimmerLabel)

        baseLabel.font = ShellMetrics.sidebarPrimaryFont()
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.translatesAutoresizingMaskIntoConstraints = false
        baseLabel.maximumNumberOfLines = 1
        baseLabel.cell?.wraps = false
        baseLabel.cell?.usesSingleLineMode = true

        shimmerLabel.font = ShellMetrics.sidebarPrimaryFont()
        shimmerLabel.lineHeight = ShellMetrics.sidebarPrimaryLineHeight
        shimmerLabel.lineBreakMode = .byTruncatingTail
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false

        trailingLabelView.font = ShellMetrics.sidebarDetailFont()
        trailingLabelView.alignment = .right
        trailingLabelView.lineBreakMode = .byTruncatingHead
        trailingLabelView.translatesAutoresizingMaskIntoConstraints = false
        trailingLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = SidebarPaneRowPresentationMode.inlineSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textContainer)
        stack.addArrangedSubview(trailingLabelView)
        addSubview(stack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarPrimaryLineHeight)
        heightConstraint.priority = .defaultHigh
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            baseLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            baseLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            baseLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            baseLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            shimmerLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            shimmerLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            shimmerLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            shimmerLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    /// Surgical primary-text update for the volatile agent title fast path.
    /// Writes the new text into baseLabel and shimmerLabel without touching
    /// trailing text, presentation mode, line count, or layout. Idempotent.
    func setPrimaryText(_ text: String) {
        guard primaryText != text else { return }
        primaryText = text
        baseLabel.stringValue = text
        shimmerLabel.stringValue = text
    }

    func configure(
        primaryText: String,
        trailingText: String?,
        presentationMode: SidebarPaneRowPresentationMode,
        lineCount: Int
    ) {
        self.primaryText = primaryText
        self.trailingText = trailingText
        self.presentationMode = presentationMode
        requestedLineCount = lineCount
        baseLabel.stringValue = primaryText
        shimmerLabel.stringValue = primaryText
        trailingLabelView.stringValue = trailingText ?? ""
        trailingLabelView.isHidden = (trailingText?.isEmpty ?? true)
        applyPresentationMode(lineCount: lineCount)
    }

    func applyColors(
        primaryColor: NSColor,
        trailingColor: NSColor,
        isShimmering: Bool,
        shimmerColor: NSColor,
        reducedMotion: Bool
    ) {
        self.primaryColor = primaryColor
        self.trailingColor = trailingColor
        baseLabel.textColor = primaryColor
        trailingLabelView.textColor = trailingColor
        // The pane row primary stays single-line with tail truncation (see
        // `applyPresentationMode`) so the shimmer overlay always has a line
        // to clip against — hiding it on wrap would kill the shimmer on
        // running agents.
        shimmerLabel.isHidden = false
        shimmerLabel.isShimmering = isShimmering
        shimmerLabel.reducedMotion = reducedMotion
        shimmerLabel.shimmerColor = shimmerColor
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        shimmerLabel.shimmerCoordinator = coordinator
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        shimmerLabel.isVisibleForSharedAnimation = isVisible
    }

    func setShimmerPhaseOffset(_ offset: CGFloat) {
        shimmerLabel.shimmerPhaseOffset = offset
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        shimmerLabel.shimmerPhaseOffsetForTesting
    }

    private func applyPresentationMode(lineCount: Int) {
        // The pane row primary is intentionally single-line with tail
        // truncation. `SidebarShimmerTextView` is a single-line CoreText
        // renderer, so keeping this label one line wide is what allows
        // running agents to shimmer. Long titles simply truncate.
        //
        // Note: we still honour `presentationMode == .adaptive` for the
        // inline trailing label. In adaptive mode the branch moves to the
        // status row (via `paneRowStatusTrailingLayout`), so hiding the
        // inline trailing here prevents it from appearing in both places.
        let movesTrailingToStatusRow = presentationMode == .adaptive
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.maximumNumberOfLines = 1
        baseLabel.cell?.wraps = false
        baseLabel.cell?.usesSingleLineMode = true
        trailingLabelView.isHidden =
            movesTrailingToStatusRow || (trailingText?.isEmpty ?? true)
        stack.alignment = .centerY
        heightConstraint?.constant = ShellMetrics.sidebarPrimaryLineHeight
        invalidateIntrinsicContentSize()
    }

    private func updateAdaptiveHeight() {
        // The pane row primary is always single-line — no adaptive height.
    }
}

// MARK: - SidebarPaneTextRowView

@MainActor
final class SidebarPaneTextRowView: NSView {
    private static let symbolPointSize: CGFloat = 11

    private let iconView = NSImageView()
    private let progressIndicator = SidebarTaskProgressIndicatorView()
    private let progressRevealView = SidebarTaskProgressRevealView()
    private let textContainer = SidebarPrimaryTextContainerView()
    private let baseLabel = SidebarStaticLabel()
    private let shimmerLabel = SidebarShimmerTextView()
    private let trailingLabelView = SidebarStaticLabel()
    private let contentStack = SidebarTaskProgressRevealLineView()

    private(set) var text: String = ""
    private(set) var symbolName: String = ""
    private(set) var textColor: NSColor = .secondaryLabelColor
    private(set) var trailingText: String?
    private(set) var trailingTextColor: NSColor = .secondaryLabelColor
    private(set) var taskProgress: PaneAgentTaskProgress?
    private var rowLineHeight: CGFloat = ShellMetrics.sidebarStatusLineHeight
    private var heightConstraint: NSLayoutConstraint?
    private var trailingPreferredWidth: CGFloat = 0
    private var lineCount = 1
    private var animatesProgressUpdates = false
    private var reducedMotion = false

    init(font: NSFont, lineHeight: CGFloat) {
        super.init(frame: .zero)
        setup(font: font, lineHeight: lineHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(font: NSFont, lineHeight: CGFloat) {
        rowLineHeight = lineHeight
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(baseLabel)
        textContainer.addSubview(shimmerLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.configureSubviews(
            iconView: iconView,
            progressIndicator: progressIndicator,
            progressRevealView: progressRevealView,
            textContainer: textContainer,
            trailingLabelView: trailingLabelView
        )
        progressIndicator.onHoverEntered = { [weak self] in
            self?.setProgressRevealVisible(true, animated: true)
        }
        contentStack.onMouseEnteredLine = { [weak self] in
            self?.setProgressRevealVisible(true, animated: true)
        }
        contentStack.onMouseExitedLine = { [weak self] in
            self?.setProgressRevealVisible(false, animated: true)
        }
        trailingLabelView.font = ShellMetrics.sidebarDetailFont()
        trailingLabelView.alignment = .right
        trailingLabelView.lineBreakMode = .byTruncatingMiddle
        trailingLabelView.translatesAutoresizingMaskIntoConstraints = false
        trailingLabelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabelView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingLabelView.maximumNumberOfLines = 1
        trailingLabelView.cell?.wraps = false
        trailingLabelView.cell?.usesSingleLineMode = true
        addSubview(contentStack)

        baseLabel.font = font
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.translatesAutoresizingMaskIntoConstraints = false
        baseLabel.maximumNumberOfLines = 1
        baseLabel.cell?.wraps = false
        baseLabel.cell?.usesSingleLineMode = true

        shimmerLabel.font = font
        shimmerLabel.lineHeight = lineHeight
        shimmerLabel.lineBreakMode = .byTruncatingTail
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false

        let heightConstraint = heightAnchor.constraint(equalToConstant: lineHeight)
        heightConstraint.priority = .defaultHigh
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            baseLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            baseLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            baseLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            baseLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            shimmerLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            shimmerLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            shimmerLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            shimmerLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: heightConstraint?.constant ?? rowLineHeight
        )
    }

    override func layout() {
        super.layout()
        updateResolvedTrailingVisibility()
    }

    func configure(
        text: String,
        symbolName: String?,
        taskProgress: PaneAgentTaskProgress?,
        trailingText: String?,
        trailingWidth: CGFloat,
        lineCount: Int,
        animated: Bool
    ) {
        self.text = text
        self.symbolName = symbolName ?? ""
        self.trailingText = trailingText
        self.taskProgress = taskProgress
        animatesProgressUpdates = animated
        let showsTrailingTextInLeadingSlot = rendersTrailingTextInLeadingSlot
        let leadingText = showsTrailingTextInLeadingSlot ? (trailingText ?? "") : text

        baseLabel.stringValue = leadingText
        shimmerLabel.stringValue = leadingText
        iconView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .semibold))
        }
        iconView.isHidden = showsTrailingTextInLeadingSlot || iconView.image == nil
        progressIndicator.isHidden = taskProgress == nil || showsTrailingTextInLeadingSlot
        progressRevealView.configure(
            taskProgress: taskProgress,
            color: .secondaryLabelColor,
            font: baseLabel.font ?? ShellMetrics.sidebarStatusFont()
        )
        if taskProgress == nil || showsTrailingTextInLeadingSlot {
            setProgressRevealVisible(false, animated: false)
        }
        trailingLabelView.stringValue = showsTrailingTextInLeadingSlot ? "" : (trailingText ?? "")
        trailingLabelView.isHidden = showsTrailingTextInLeadingSlot || (trailingText?.isEmpty ?? true)
        trailingPreferredWidth = showsTrailingTextInLeadingSlot || trailingText == nil ? 0 : trailingWidth
        applyPresentation(lineCount: lineCount)
    }

    func applyColors(
        textColor: NSColor,
        trailingTextColor: NSColor?,
        progressColor: NSColor,
        isShimmering: Bool,
        shimmerColor: NSColor,
        reducedMotion: Bool
    ) {
        self.textColor = textColor
        self.trailingTextColor = trailingTextColor ?? .clear
        self.reducedMotion = reducedMotion
        let dimmedColor = isShimmering
            ? textColor.withAlphaComponent(textColor.alphaComponent * 0.90)
            : textColor
        let leadingTextColor = rendersTrailingTextInLeadingSlot
            ? (trailingTextColor ?? textColor)
            : dimmedColor
        baseLabel.textColor = leadingTextColor
        iconView.contentTintColor = dimmedColor
        trailingLabelView.textColor = trailingTextColor
        let visibleTaskProgress =
            lineCount == 1 && rendersTrailingTextInLeadingSlot == false
            ? taskProgress
            : nil
        progressIndicator.configure(
            taskProgress: visibleTaskProgress,
            color: progressColor,
            animated: animatesProgressUpdates,
            reducedMotion: reducedMotion
        )
        progressRevealView.configure(
            taskProgress: visibleTaskProgress,
            color: progressColor,
            font: baseLabel.font ?? ShellMetrics.sidebarStatusFont()
        )
        if visibleTaskProgress == nil {
            setProgressRevealVisible(false, animated: false)
        }
        configureContentLine(taskProgressVisible: visibleTaskProgress != nil)
        shimmerLabel.isShimmering = isShimmering && lineCount == 1 && rendersTrailingTextInLeadingSlot == false
        shimmerLabel.reducedMotion = reducedMotion
        shimmerLabel.shimmerColor = shimmerColor
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        shimmerLabel.shimmerCoordinator = coordinator
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        shimmerLabel.isVisibleForSharedAnimation = isVisible
    }

    func setShimmerPhaseOffset(_ offset: CGFloat) {
        shimmerLabel.shimmerPhaseOffset = offset
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        shimmerLabel.shimmerPhaseOffsetForTesting
    }

    var shimmerColorForTesting: NSColor {
        shimmerLabel.shimmerColor
    }

    var isTrailingVisibleForTesting: Bool {
        trailingLabelView.isHidden == false
    }

    var progressIndicatorIsVisibleForTesting: Bool {
        progressIndicator.isHidden == false
    }

    var progressFractionForTesting: CGFloat {
        progressIndicator.fraction
    }

    var progressToolTipForTesting: String {
        progressIndicator.tooltipText
    }

    var progressRevealTextForTesting: String {
        progressRevealView.revealText
    }

    var progressRevealIsExpandedForTesting: Bool {
        progressRevealView.isRevealed
    }

    var progressRevealLastUpdateWasAnimatedForTesting: Bool {
        progressRevealView.lastUpdateWasAnimated
    }

    var progressRevealLastAnimationDurationForTesting: TimeInterval? {
        progressRevealView.lastAnimationDuration
    }

    var progressRevealLastConfigureSyncedPresentationForTesting: Bool {
        progressRevealView.lastConfigureSyncedPresentationForTesting
    }

    var progressColorForTesting: NSColor {
        progressIndicator.progressColor
    }

    var textContainerWidthForTesting: CGFloat {
        contentStack.textContainerWidthForTesting
    }

    var progressRevealWidthForTesting: CGFloat {
        contentStack.progressRevealWidthForTesting
    }

    var progressRevealIsHiddenForTesting: Bool {
        progressRevealView.isHidden
    }

    var trailingLabelWidthForTesting: CGFloat {
        contentStack.trailingLabelWidthForTesting
    }

    func simulateProgressIconHoverForTesting() {
        simulateProgressIconHoverForTesting(animated: true)
    }

    func simulateProgressIconHoverForTesting(animated: Bool) {
        setProgressRevealVisible(true, animated: animated)
    }

    func simulateProgressLineHoverForTesting() {
        contentStack.simulateMouseEnteredForTesting()
    }

    func simulateProgressLineExitForTesting() {
        setProgressRevealVisible(false, animated: true)
    }

    func simulateProgressLineExitForTesting(pointerStillInsideLine: Bool) {
        contentStack.simulateMouseExitedForTesting(pointerStillInsideLine: pointerStillInsideLine)
    }

    func simulateProgressLineHoverReconciliationForTesting(pointerInsideLine: Bool) {
        contentStack.simulateHoverReconciliationForTesting(pointerInsideLine: pointerInsideLine)
    }

    private func applyPresentation(lineCount: Int) {
        let clampedLineCount = max(1, min(2, lineCount))
        let wraps = clampedLineCount > 1

        self.lineCount = clampedLineCount
        baseLabel.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        baseLabel.maximumNumberOfLines = wraps ? clampedLineCount : 1
        baseLabel.cell?.wraps = wraps
        baseLabel.cell?.usesSingleLineMode = wraps == false
        shimmerLabel.isHidden = wraps
        progressIndicator.isHidden = wraps || rendersTrailingTextInLeadingSlot || taskProgress == nil
        if wraps || rendersTrailingTextInLeadingSlot || taskProgress == nil {
            setProgressRevealVisible(false, animated: false)
        }
        trailingLabelView.isHidden = wraps || rendersTrailingTextInLeadingSlot || (trailingText?.isEmpty ?? true)
        heightConstraint?.constant = rowLineHeight * CGFloat(clampedLineCount)
        configureContentLine(taskProgressVisible: progressIndicator.isHidden == false)
        invalidateIntrinsicContentSize()
    }

    private func setProgressRevealVisible(_ isVisible: Bool, animated: Bool) {
        let canReveal =
            isVisible
            && lineCount == 1
            && rendersTrailingTextInLeadingSlot == false
            && taskProgress != nil
            && progressIndicator.isHidden == false
        progressRevealView.setRevealed(
            canReveal,
            animated: animated,
            reducedMotion: reducedMotion,
            appliesAlpha: false
        )
        contentStack.setProgressRevealVisible(canReveal, animated: animated, reducedMotion: reducedMotion)
    }

    private func updateResolvedTrailingVisibility() {
        guard let trailingText, trailingText.isEmpty == false else {
            trailingLabelView.isHidden = true
            return
        }

        guard rendersTrailingTextInLeadingSlot == false else {
            trailingLabelView.isHidden = true
            return
        }

        guard lineCount == 1 else {
            trailingLabelView.isHidden = true
            return
        }
    }

    private static func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        SidebarTextMetrics.measuredWidth(for: text, font: font)
    }

    private func configureContentLine(taskProgressVisible: Bool) {
        contentStack.configureLayout(
            statusText: text,
            statusFont: baseLabel.font ?? ShellMetrics.sidebarStatusFont(),
            trailingPreferredWidth: trailingPreferredWidth,
            lineHeight: rowLineHeight,
            wraps: lineCount > 1,
            taskProgressVisible: taskProgressVisible
        )
    }

    private var rendersTrailingTextInLeadingSlot: Bool {
        Self.hasVisibleText(text) == false && Self.hasVisibleText(trailingText)
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else {
            return false
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
