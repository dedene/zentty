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
        static let hiddenLeadingOffset: CGFloat = -5
    }

    private enum Animation {
        static let transitionDuration: TimeInterval = 0.24

        static func transitionTimingFunction() -> CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.25, 1.0)
        }
    }

    private let label = SidebarStaticLabel()
    private var widthConstraint: NSLayoutConstraint?
    private var labelLeadingConstraint: NSLayoutConstraint?
    private var measuredExpandedWidth: CGFloat = 0

    private(set) var revealText = ""
    private(set) var isRevealed = false
    private(set) var lastUpdateWasAnimated = false
    private(set) var lastAnimationDuration: TimeInterval?
    private(set) var lastConfigureSyncedPresentationForTesting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widthConstraint?.constant ?? 0, height: NSView.noIntrinsicMetric)
    }

    func configure(taskProgress: PaneAgentTaskProgress?, color: NSColor, font: NSFont) {
        label.font = font
        label.textColor = color

        guard let taskProgress else {
            revealText = ""
            label.stringValue = ""
            measuredExpandedWidth = 0
            lastConfigureSyncedPresentationForTesting = true
            setRevealed(false, animated: false, reducedMotion: true)
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
            widthConstraint?.constant = isRevealed ? measuredExpandedWidth : 0
            labelLeadingConstraint?.constant = isRevealed ? Layout.leadingPadding : Layout.hiddenLeadingOffset
            label.alphaValue = isRevealed ? 1 : 0
        }
        invalidateIntrinsicContentSize()
    }

    func setRevealed(_ revealed: Bool, animated: Bool, reducedMotion: Bool) {
        guard revealText.isEmpty == false || revealed == false else {
            lastUpdateWasAnimated = false
            return
        }

        isRevealed = revealed
        let targetWidth = revealed ? measuredExpandedWidth : 0
        let targetAlpha: CGFloat = revealed ? 1 : 0
        let targetLeading = revealed ? Layout.leadingPadding : Layout.hiddenLeadingOffset
        let shouldAnimate = animated && reducedMotion == false
        lastUpdateWasAnimated = shouldAnimate
        lastAnimationDuration = shouldAnimate ? Animation.transitionDuration : nil

        guard shouldAnimate else {
            widthConstraint?.constant = targetWidth
            labelLeadingConstraint?.constant = targetLeading
            label.alphaValue = targetAlpha
            superview?.layoutSubtreeIfNeeded()
            invalidateIntrinsicContentSize()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Animation.transitionDuration
            context.timingFunction = Animation.transitionTimingFunction()
            widthConstraint?.animator().constant = targetWidth
            labelLeadingConstraint?.animator().constant = targetLeading
            label.animator().alphaValue = targetAlpha
            superview?.animator().layoutSubtreeIfNeeded()
        }
        invalidateIntrinsicContentSize()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.alphaValue = 0
        addSubview(label)

        let widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.priority = .required
        let labelLeadingConstraint = label.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Layout.hiddenLeadingOffset
        )
        self.widthConstraint = widthConstraint
        self.labelLeadingConstraint = labelLeadingConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            labelLeadingConstraint,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    private static func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        SidebarTextMetrics.measuredWidth(for: text, font: font)
    }
}

@MainActor
final class SidebarTaskProgressRevealLineStackView: NSStackView {
    private enum HoverReconciliation {
        static let interval: TimeInterval = 0.05
    }

    private var trackingAreaValue: NSTrackingArea?
    private var hoverReconciliationTimer: Timer?
    var onMouseExitedLine: (() -> Void)?

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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopHoverReconciliation()
        }
    }

    override func mouseExited(with event: NSEvent) {
        handleMouseExited(pointerIsInsideCurrentBounds: pointerIsInsideCurrentBounds(for: event))
    }

    func startHoverReconciliation() {
        guard hoverReconciliationTimer == nil else { return }
        guard window != nil else { return }

        let timer = Timer(timeInterval: HoverReconciliation.interval, repeats: true) { [weak self] _ in
            self?.reconcilePointerHoverUsingCurrentLocation()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverReconciliationTimer = timer
    }

    func stopHoverReconciliation() {
        hoverReconciliationTimer?.invalidate()
        hoverReconciliationTimer = nil
    }

    func simulateMouseExitedForTesting(pointerStillInsideLine: Bool) {
        handleMouseExited(pointerIsInsideCurrentBounds: pointerStillInsideLine)
    }

    func simulateHoverReconciliationForTesting(pointerInsideLine: Bool) {
        handleMouseExited(pointerIsInsideCurrentBounds: pointerInsideLine)
    }

    private func handleMouseExited(pointerIsInsideCurrentBounds: Bool) {
        guard pointerIsInsideCurrentBounds == false else {
            return
        }

        stopHoverReconciliation()
        onMouseExitedLine?()
    }

    private func pointerIsInsideCurrentBounds(for event: NSEvent) -> Bool {
        let pointInBounds = convert(event.locationInWindow, from: nil)
        return bounds.insetBy(dx: -1, dy: -1).contains(pointInBounds)
    }

    private func reconcilePointerHoverUsingCurrentLocation() {
        guard let window, window.isVisible, isHidden == false else {
            handleMouseExited(pointerIsInsideCurrentBounds: false)
            return
        }

        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInBounds = convert(pointInWindow, from: nil)
        handleMouseExited(pointerIsInsideCurrentBounds: bounds.insetBy(dx: -1, dy: -1).contains(pointInBounds))
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
    private let contentStack = SidebarTaskProgressRevealLineStackView()

    private(set) var text: String = ""
    private(set) var symbolName: String = ""
    private(set) var textColor: NSColor = .secondaryLabelColor
    private(set) var trailingText: String?
    private(set) var trailingTextColor: NSColor = .secondaryLabelColor
    private(set) var taskProgress: PaneAgentTaskProgress?
    private var rowLineHeight: CGFloat = ShellMetrics.sidebarStatusLineHeight
    private var heightConstraint: NSLayoutConstraint?
    private var trailingWidthConstraint: NSLayoutConstraint?
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
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textContainer.addSubview(baseLabel)
        textContainer.addSubview(shimmerLabel)
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(progressIndicator)
        contentStack.addArrangedSubview(progressRevealView)
        contentStack.addArrangedSubview(textContainer)
        contentStack.setCustomSpacing(0, after: progressIndicator)
        contentStack.setCustomSpacing(4, after: progressRevealView)
        progressIndicator.onHoverEntered = { [weak self] in
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
        contentStack.addArrangedSubview(trailingLabelView)
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
        let trailingWidthConstraint = trailingLabelView.widthAnchor.constraint(equalToConstant: 0)
        self.trailingWidthConstraint = trailingWidthConstraint

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.symbolPointSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.symbolPointSize),
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
            trailingWidthConstraint,
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
        trailingWidthConstraint?.constant = showsTrailingTextInLeadingSlot || trailingText == nil ? 0 : trailingWidth
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

    func simulateProgressIconHoverForTesting() {
        setProgressRevealVisible(true, animated: true)
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
        contentStack.alignment = wraps ? .top : .centerY
        progressIndicator.isHidden = wraps || rendersTrailingTextInLeadingSlot || taskProgress == nil
        if wraps || rendersTrailingTextInLeadingSlot || taskProgress == nil {
            setProgressRevealVisible(false, animated: false)
        }
        trailingLabelView.isHidden = wraps || rendersTrailingTextInLeadingSlot || (trailingText?.isEmpty ?? true)
        heightConstraint?.constant = rowLineHeight * CGFloat(clampedLineCount)
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
            reducedMotion: reducedMotion
        )
        if canReveal {
            contentStack.startHoverReconciliation()
        } else {
            contentStack.stopHoverReconciliation()
        }
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

        let availableTextWidth = max(0, textContainer.bounds.width)
        guard availableTextWidth > 0 else {
            trailingLabelView.isHidden = false
            return
        }

        let font = baseLabel.font ?? ShellMetrics.sidebarStatusFont()
        let measuredTextWidth = Self.measuredWidth(for: text, font: font)
        let measuredLineCount = Self.measuredLineCount(
            for: text,
            font: font,
            lineHeight: rowLineHeight,
            width: availableTextWidth
        )
        trailingLabelView.isHidden =
            measuredTextWidth > availableTextWidth + 0.5
            || measuredLineCount > 1
    }

    private static func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        SidebarTextMetrics.measuredWidth(for: text, font: font)
    }

    private static func measuredLineCount(
        for text: String,
        font: NSFont,
        lineHeight: CGFloat,
        width: CGFloat
    ) -> Int {
        SidebarTextMetrics.measuredLineCount(for: text, font: font, lineHeight: lineHeight, width: width)
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
