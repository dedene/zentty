import AppKit
import QuartzCore

private enum SidebarShimmerTreatment {
    case highlight
    case shadow
}

@MainActor
final class SidebarWorklaneRowButton: NSButton {
    private enum DropTargetHighlightAnimation {
        static let scaleKey = "dropTargetScale"
        static let shadowOpacityKey = "dropTargetShadowOpacity"
        static let scale: CGFloat = 1.025
        static let shadowOpacity: Float = 0.7
        static let springMass: CGFloat = 1.0
        static let springStiffness: CGFloat = 300
        static let springDamping: CGFloat = 20
        static let shadowFadeDuration: CFTimeInterval = 0.15
    }

    private enum Layout {
        static let contentInset = min(
            ShellMetrics.sidebarPaneRowHorizontalInset,
            ShellMetrics.sidebarWorklaneTextHorizontalInset
        )
        static let textContentInset = ShellMetrics.sidebarWorklaneTextHorizontalInset
        static let textWrapperInset = max(0, textContentInset - contentInset)
        static let paneWrapperInset = max(0, ShellMetrics.sidebarPaneRowHorizontalInset - contentInset)
        static let primaryTextLeadingInset: CGFloat = 0
    }

    let worklaneID: WorklaneID?

    private let topLabel = SidebarStaticLabel()
    private let primaryTextContainer = SidebarPrimaryTextContainerView()
    private let primaryBaseLabel = SidebarStaticLabel()
    private let primaryLabel = SidebarShimmerTextView()
    private let contextPrefixLabel = SidebarStaticLabel()
    private let statusIconView = NSImageView()
    private let statusTextContainer = SidebarPrimaryTextContainerView()
    private let statusBaseLabel = SidebarStaticLabel()
    private let statusLabel = SidebarShimmerTextView()
    private let statusContentStack = NSStackView()
    private let overflowLabel = SidebarStaticLabel()
    private let textStack = NSStackView()

    private var detailLabels: [SidebarStaticLabel] = []
    private var panePrimaryRows: [SidebarPanePrimaryRowView] = []
    private var paneDetailLabels: [SidebarStaticLabel] = []
    private var paneStatusRows: [SidebarPaneTextRowView] = []
    private var paneRowButtons: [SidebarPaneRowButton] = []
    private var paneRowContainers: [SidebarInsetContainerView] = []
    private var currentSummary: WorklaneSidebarSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var lastAppliedBoundsWidth: CGFloat = -1
    private(set) var configureApplyCountForTesting: Int = 0
    private var currentStatusSymbolName = ""
    private var isHovered = false
    private var isPaneRowHovered = false
    private var trackingArea: NSTrackingArea?
    private var heightConstraint: NSLayoutConstraint?
    private var textStackTopConstraint: NSLayoutConstraint?
    private var textStackBottomConstraint: NSLayoutConstraint?
    private var primaryTextHeightConstraint: NSLayoutConstraint?
    private var statusTextHeightConstraint: NSLayoutConstraint?
    private var statusContentHeightConstraint: NSLayoutConstraint?
    private var isWorking = false
    private var isApplyingResolvedSummary = false
    private var shimmerCoordinator: SidebarShimmerCoordinator?
    private var isDropTargetHighlighted = false
    private let reducedMotionProvider: () -> Bool

    var onPaneSelected: ((PaneID) -> Void)?
    var onCloseWorklaneRequested: ((PaneID) -> Void)?
    var onClosePaneRequested: ((PaneID) -> Void)?
    var onSplitHorizontalRequested: ((PaneID) -> Void)?
    var onSplitVerticalRequested: ((PaneID) -> Void)?

    init(
        worklaneID: WorklaneID?,
        reducedMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.worklaneID = worklaneID
        self.reducedMotionProvider = reducedMotionProvider
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: heightConstraint?.constant ?? NSView.noIntrinsicMetric
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.size.width
        super.setFrameSize(newSize)

        guard abs(previousWidth - newSize.width) > .ulpOfOne else {
            return
        }

        applyResolvedSummary(animated: false)
    }

    override func layout() {
        super.layout()

        guard bounds.width > 0 else {
            return
        }

        applyResolvedSummary(animated: false)
    }

    // MARK: - Setup

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.rowRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        configureLabel(
            topLabel,
            font: ShellMetrics.sidebarTitleFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            primaryBaseLabel,
            font: ShellMetrics.sidebarPrimaryFont(),
            lineBreakMode: .byTruncatingTail
        )
        primaryLabel.font = ShellMetrics.sidebarPrimaryFont()
        primaryLabel.lineHeight = ShellMetrics.sidebarPrimaryLineHeight
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryTextContainer.translatesAutoresizingMaskIntoConstraints = false
        primaryTextContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryTextContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryTextContainer.addSubview(primaryBaseLabel)
        primaryTextContainer.addSubview(primaryLabel)
        configureLabel(
            statusBaseLabel,
            font: ShellMetrics.sidebarStatusFont(),
            lineBreakMode: .byTruncatingTail
        )
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.imageScaling = .scaleProportionallyDown
        statusIconView.setContentHuggingPriority(.required, for: .horizontal)
        statusIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.font = ShellMetrics.sidebarStatusFont()
        statusLabel.lineHeight = ShellMetrics.sidebarStatusLineHeight
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusTextContainer.translatesAutoresizingMaskIntoConstraints = false
        statusTextContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusTextContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusTextContainer.addSubview(statusBaseLabel)
        statusTextContainer.addSubview(statusLabel)
        statusContentStack.orientation = .horizontal
        statusContentStack.alignment = .centerY
        statusContentStack.spacing = 4
        statusContentStack.translatesAutoresizingMaskIntoConstraints = false
        statusContentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusContentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusContentStack.addArrangedSubview(statusIconView)
        statusContentStack.addArrangedSubview(statusTextContainer)
        configureLabel(
            overflowLabel,
            font: ShellMetrics.sidebarOverflowFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            contextPrefixLabel,
            font: ShellMetrics.sidebarDetailFont(),
            lineBreakMode: .byTruncatingTail
        )

        NSLayoutConstraint.activate([
            primaryBaseLabel.topAnchor.constraint(equalTo: primaryTextContainer.topAnchor),
            primaryBaseLabel.leadingAnchor.constraint(
                equalTo: primaryTextContainer.leadingAnchor,
                constant: Layout.primaryTextLeadingInset),
            primaryBaseLabel.trailingAnchor.constraint(
                equalTo: primaryTextContainer.trailingAnchor),
            primaryBaseLabel.bottomAnchor.constraint(equalTo: primaryTextContainer.bottomAnchor),
            primaryLabel.topAnchor.constraint(equalTo: primaryTextContainer.topAnchor),
            primaryLabel.leadingAnchor.constraint(equalTo: primaryTextContainer.leadingAnchor),
            primaryLabel.trailingAnchor.constraint(equalTo: primaryTextContainer.trailingAnchor),
            primaryLabel.bottomAnchor.constraint(equalTo: primaryTextContainer.bottomAnchor),
            statusBaseLabel.topAnchor.constraint(equalTo: statusTextContainer.topAnchor),
            statusBaseLabel.leadingAnchor.constraint(equalTo: statusTextContainer.leadingAnchor),
            statusBaseLabel.trailingAnchor.constraint(equalTo: statusTextContainer.trailingAnchor),
            statusBaseLabel.bottomAnchor.constraint(equalTo: statusTextContainer.bottomAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusTextContainer.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusTextContainer.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: statusTextContainer.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: statusTextContainer.bottomAnchor),
            statusIconView.widthAnchor.constraint(equalToConstant: 11),
            statusIconView.heightAnchor.constraint(equalToConstant: 11),
        ])

        textStack.orientation = .vertical
        textStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(textStack)

        let heightConstraint = heightAnchor.constraint(
            equalToConstant: ShellMetrics.sidebarCompactRowHeight)
        self.heightConstraint = heightConstraint
        let textStackTopConstraint = textStack.topAnchor.constraint(
            equalTo: topAnchor,
            constant: ShellMetrics.sidebarRowTopInset
        )
        self.textStackTopConstraint = textStackTopConstraint
        let textStackBottomConstraint = textStack.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -ShellMetrics.sidebarRowBottomInset
        )
        self.textStackBottomConstraint = textStackBottomConstraint
        let primaryTextHeightConstraint = primaryTextContainer.heightAnchor.constraint(
            equalToConstant: ShellMetrics.sidebarPrimaryLineHeight
        )
        self.primaryTextHeightConstraint = primaryTextHeightConstraint
        let statusTextHeightConstraint = statusTextContainer.heightAnchor.constraint(
            equalToConstant: ShellMetrics.sidebarStatusLineHeight
        )
        self.statusTextHeightConstraint = statusTextHeightConstraint
        let statusContentHeightConstraint = statusContentStack.heightAnchor.constraint(
            equalToConstant: ShellMetrics.sidebarStatusLineHeight
        )
        self.statusContentHeightConstraint = statusContentHeightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,
            textStackTopConstraint,
            textStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Layout.contentInset),
            textStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Layout.contentInset),
            textStackBottomConstraint,
            primaryTextHeightConstraint,
            statusTextHeightConstraint,
            statusContentHeightConstraint,
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }

        let pointInSelf = convert(point, from: superview)
        guard bounds.contains(pointInSelf), !isHidden, alphaValue > 0 else {
            return nil
        }

        let activePaneCount = currentSummary?.paneRows.count ?? 0
        for paneButton in paneRowButtons.prefix(activePaneCount)
        where paneButton.superview != nil && !paneButton.isHidden {
            let pointInPane = paneButton.convert(point, from: superview)
            if paneButton.bounds.contains(pointInPane) {
                return paneButton
            }
        }

        return self
    }

    func paneRowHoverChanged(isHovered: Bool) {
        isPaneRowHovered = isHovered
        applyCurrentAppearance(animated: true)
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        shimmerCoordinator = coordinator
        primaryLabel.shimmerCoordinator = coordinator
        statusLabel.shimmerCoordinator = coordinator
        panePrimaryRows.forEach { $0.setShimmerCoordinator(coordinator) }
        paneStatusRows.forEach { $0.setShimmerCoordinator(coordinator) }
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        primaryLabel.isVisibleForSharedAnimation = isVisible
        statusLabel.isVisibleForSharedAnimation = isVisible
        panePrimaryRows.forEach { $0.setShimmerVisibility(isVisible) }
        paneStatusRows.forEach { $0.setShimmerVisibility(isVisible) }
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard wantsLayer, let layer else { return }
        guard highlighted != isDropTargetHighlighted else { return }
        isDropTargetHighlighted = highlighted

        let targetTransform = highlighted
            ? CATransform3DMakeScale(
                DropTargetHighlightAnimation.scale,
                DropTargetHighlightAnimation.scale,
                1
            )
            : CATransform3DIdentity
        let targetShadowOpacity: Float = highlighted
            ? DropTargetHighlightAnimation.shadowOpacity
            : 0

        layer.removeAnimation(forKey: DropTargetHighlightAnimation.scaleKey)
        layer.removeAnimation(forKey: DropTargetHighlightAnimation.shadowOpacityKey)
        if highlighted {
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowRadius = 8
            layer.shadowOffset = .zero
        }

        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let currentShadowOpacity = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = targetTransform
        layer.shadowOpacity = targetShadowOpacity
        CATransaction.commit()

        if reducedMotionProvider() {
            return
        }

        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = DropTargetHighlightAnimation.springMass
        spring.stiffness = DropTargetHighlightAnimation.springStiffness
        spring.damping = DropTargetHighlightAnimation.springDamping
        spring.fromValue = currentTransform
        spring.toValue = targetTransform
        spring.isRemovedOnCompletion = true
        layer.add(spring, forKey: DropTargetHighlightAnimation.scaleKey)

        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = currentShadowOpacity
        fade.toValue = targetShadowOpacity
        fade.duration = DropTargetHighlightAnimation.shadowFadeDuration
        fade.isRemovedOnCompletion = true
        layer.add(fade, forKey: DropTargetHighlightAnimation.shadowOpacityKey)
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
        applyCurrentAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyCurrentAppearance(animated: true)
    }

    // MARK: - Public API

    func configure(
        with summary: WorklaneSidebarSummary,
        theme: ZenttyTheme,
        animated: Bool
    ) {
        if summary == currentSummary,
           theme == currentTheme,
           bounds.width == lastAppliedBoundsWidth {
            return
        }
        currentSummary = summary
        currentTheme = theme
        isWorking = summary.isWorking
        let worklanePhaseOffset = SidebarShimmerPhaseOffset.forIdentifier(summary.worklaneID.rawValue)
        primaryLabel.shimmerPhaseOffset = worklanePhaseOffset
        statusLabel.shimmerPhaseOffset = worklanePhaseOffset
        lastAppliedBoundsWidth = bounds.width
        configureApplyCountForTesting &+= 1
        applyResolvedSummary(animated: animated)
    }

    /// Surgical label update for the volatile agent title fast path.
    /// Surgical label update for sub-100ms agent title ticks (spinner frames,
    /// elapsed-time counters). Writes the new text directly to the affected
    /// primary labels without reconfiguring the row, rebuilding the layout,
    /// or invalidating autolayout.
    ///
    /// This is a **deliberate 60Hz optimization**, not a workaround for a
    /// slow `configure(with:)` path. The slow path is fast enough for
    /// structural changes (Phase 1+2 refactor), but spinner ticks at 20+ Hz
    /// still benefit from surgical label mutation to avoid per-tick summary
    /// construction + diff + layout passes.
    ///
    /// Does not mutate `currentSummary` — the next full-path configure will
    /// reconcile from the authoritative summary if a structural change arrives.
    func setVolatilePaneTitle(paneID: PaneID, text: String) {
        guard let summary = currentSummary else {
            return
        }

        if summary.paneRows.isEmpty {
            // Single-pane worklane — the volatile title lives in the worklane row's
            // top-level primary labels.
            guard primaryBaseLabel.stringValue != text else { return }
            primaryBaseLabel.stringValue = text
            primaryLabel.stringValue = text
            return
        }

        guard let rowIndex = summary.paneRows.firstIndex(where: { $0.paneID == paneID }),
              panePrimaryRows.indices.contains(rowIndex)
        else {
            return
        }
        panePrimaryRows[rowIndex].setPrimaryText(text)
    }

    // MARK: - Rendering

    private func applyResolvedSummary(animated: Bool) {
        guard let summary = currentSummary, isApplyingResolvedSummary == false else {
            return
        }

        isApplyingResolvedSummary = true
        defer { isApplyingResolvedSummary = false }

        let layout = SidebarWorklaneRowLayout(summary: summary, availableWidth: bounds.width)
        applyTextStackVerticalInsets(hasPaneRows: summary.paneRows.isEmpty == false)

        topLabel.stringValue = summary.topLabel ?? ""
        overflowLabel.stringValue = summary.overflowText ?? ""
        contextPrefixLabel.stringValue = summary.contextPrefixText ?? ""
        if summary.paneRows.isEmpty {
            primaryBaseLabel.stringValue = summary.primaryText
            primaryLabel.stringValue = summary.primaryText
            applyWorklanePrimaryPresentation()
            let statusCopy = SidebarStatusResolver.resolveDisplayStatusText(
                statusText: summary.statusText,
                attentionState: summary.attentionState,
                interactionKind: summary.interactionKind,
                interactionLabel: summary.interactionLabel
            )
            statusBaseLabel.stringValue = statusCopy
            statusLabel.stringValue = statusCopy
            currentStatusSymbolName = SidebarStatusResolver.resolveStatusSymbolName(
                statusSymbolName: summary.statusSymbolName,
                attentionState: summary.attentionState,
                interactionKind: summary.interactionKind,
                interactionSymbolName: summary.interactionSymbolName
            )
            statusIconView.image =
                currentStatusSymbolName.isEmpty
                ? nil
                : NSImage(systemSymbolName: currentStatusSymbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            statusIconView.isHidden = statusIconView.image == nil
            applyWorklaneStatusPresentation(
                lineCount: SidebarWorklaneRowLayout.worklaneStatusLineCount(
                    for: summary,
                    availableWidth: bounds.width
                )
            )
            configureDetailLabels(for: summary.detailLines)
        } else {
            primaryBaseLabel.stringValue = ""
            primaryLabel.stringValue = ""
            statusBaseLabel.stringValue = ""
            statusLabel.stringValue = ""
            currentStatusSymbolName = ""
            statusIconView.image = nil
            statusIconView.isHidden = true
            configurePaneRows(for: summary.paneRows)
        }

        textStack.setViews(
            groupedViews(for: layout),
            in: .top
        )
        heightConstraint?.constant = layout.rowHeight
        invalidateIntrinsicContentSize()

        applyCurrentAppearance(animated: animated)
    }

    private func applyTextStackVerticalInsets(hasPaneRows: Bool) {
        textStackTopConstraint?.constant = hasPaneRows
            ? ShellMetrics.sidebarPaneRowVerticalInset
            : ShellMetrics.sidebarRowTopInset
        textStackBottomConstraint?.constant = hasPaneRows
            ? -ShellMetrics.sidebarPaneRowVerticalInset
            : -ShellMetrics.sidebarRowBottomInset
    }

    private func applyWorklanePrimaryPresentation() {
        // The worklane primary row is intentionally single-line with tail
        // truncation. The shimmer overlay (`SidebarShimmerTextView`) is a
        // single-line CoreText renderer, so keeping this label one line wide
        // is what allows running agents to shimmer. Long paths expose their
        // disambiguation prefix on the dedicated `.contextPrefix` row via
        // `WorklaneSidebarSummary.contextPrefixText`.
        primaryBaseLabel.lineBreakMode = .byTruncatingTail
        primaryBaseLabel.maximumNumberOfLines = 1
        primaryBaseLabel.cell?.wraps = false
        primaryBaseLabel.cell?.usesSingleLineMode = true
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.isHidden = false
        primaryTextHeightConstraint?.constant = ShellMetrics.sidebarPrimaryLineHeight
        primaryTextContainer.invalidateIntrinsicContentSize()
    }

    private func applyWorklaneStatusPresentation(lineCount: Int) {
        let clampedLineCount = max(1, min(2, lineCount))
        let wraps = clampedLineCount > 1

        statusBaseLabel.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        statusBaseLabel.maximumNumberOfLines = wraps ? clampedLineCount : 1
        statusBaseLabel.cell?.wraps = wraps
        statusBaseLabel.cell?.usesSingleLineMode = wraps == false
        statusLabel.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        statusLabel.isHidden = wraps
        statusContentStack.alignment = wraps ? .top : .centerY
        let statusHeight = ShellMetrics.sidebarStatusLineHeight * CGFloat(clampedLineCount)
        statusTextHeightConstraint?.constant = statusHeight
        statusContentHeightConstraint?.constant = statusHeight
        statusTextContainer.invalidateIntrinsicContentSize()
        statusContentStack.invalidateIntrinsicContentSize()
    }

    private func configureDetailLabels(for detailLines: [WorklaneSidebarDetailLine]) {
        while detailLabels.count < detailLines.count {
            let label = SidebarStaticLabel()
            configureLabel(
                label,
                font: ShellMetrics.sidebarDetailFont(),
                lineBreakMode: .byTruncatingMiddle
            )
            detailLabels.append(label)
        }

        for (index, detailLine) in detailLines.enumerated() {
            detailLabels[index].stringValue = detailLine.text
        }
    }

    private func configurePaneRows(for paneRows: [WorklaneSidebarPaneRow]) {
        while panePrimaryRows.count < paneRows.count {
            panePrimaryRows.append(SidebarPanePrimaryRowView())
        }

        while paneDetailLabels.count < paneRows.count {
            let label = SidebarStaticLabel()
            configureLabel(
                label,
                font: ShellMetrics.sidebarDetailFont(),
                lineBreakMode: .byTruncatingMiddle
            )
            paneDetailLabels.append(label)
        }

        while paneStatusRows.count < paneRows.count {
            paneStatusRows.append(
                SidebarPaneTextRowView(
                    font: ShellMetrics.sidebarStatusFont(),
                    lineHeight: ShellMetrics.sidebarStatusLineHeight
                )
            )
        }

        while paneRowButtons.count < paneRows.count {
            let button = SidebarPaneRowButton()
            paneRowButtons.append(button)
            paneRowContainers.append(
                SidebarInsetContainerView(
                    contentView: button,
                    horizontalInset: Layout.paneWrapperInset,
                    referenceWidthView: textStack
                )
            )
        }

        for (index, paneRow) in paneRows.enumerated() {
            let panePhaseOffset = SidebarShimmerPhaseOffset.forIdentifier(paneRow.paneID.rawValue)
            let presentationMode = SidebarWorklaneRowLayout.paneRowPresentationMode(
                for: paneRow,
                availableWidth: bounds.width
            )
            let statusTrailingLayout = presentationMode == .adaptive
                ? SidebarWorklaneRowLayout.paneRowStatusTrailingLayout(
                    for: paneRow,
                    availableWidth: bounds.width
                )
                : .hidden
            // Pane row primaries are always single-line so the shimmer
            // overlay can animate (SidebarShimmerTextView is single-line CoreText).
            panePrimaryRows[index].configure(
                primaryText: paneRow.primaryText,
                trailingText: presentationMode == .inline ? paneRow.trailingText : nil,
                presentationMode: presentationMode,
                lineCount: 1
            )
            panePrimaryRows[index].setShimmerPhaseOffset(panePhaseOffset)
            paneDetailLabels[index].stringValue = paneRow.detailText ?? ""
            paneStatusRows[index].configure(
                text: SidebarStatusResolver.resolveDisplayStatusText(
                    statusText: paneRow.statusText,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionLabel: paneRow.interactionLabel
                ),
                symbolName: SidebarStatusResolver.resolveStatusSymbolName(
                    statusSymbolName: paneRow.statusSymbolName,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionSymbolName: paneRow.interactionSymbolName
                ),
                trailingText: statusTrailingLayout.isVisible ? paneRow.trailingText : nil,
                trailingWidth: statusTrailingLayout.width,
                lineCount: SidebarWorklaneRowLayout.paneRowStatusLineCount(
                    for: paneRow,
                    availableWidth: bounds.width
                )
            )
            paneStatusRows[index].setShimmerPhaseOffset(panePhaseOffset)

            let button = paneRowButtons[index]
            button.paneID = paneRow.paneID
            button.isLastPaneInWorklane = paneRows.count == 1
            button.setAccessibilityLabel(paneRow.primaryText)
            button.onPaneClicked = { [weak self] paneID in
                self?.onPaneSelected?(paneID)
            }
            button.onCloseWorklane = { [weak self] paneID in
                self?.onCloseWorklaneRequested?(paneID)
            }
            button.onClosePane = { [weak self] paneID in
                self?.onClosePaneRequested?(paneID)
            }
            button.onSplitHorizontal = { [weak self] paneID in
                self?.onSplitHorizontalRequested?(paneID)
            }
            button.onSplitVertical = { [weak self] paneID in
                self?.onSplitVerticalRequested?(paneID)
            }
            button.onHoverChanged = { [weak self] isHovered in
                self?.paneRowHoverChanged(isHovered: isHovered)
            }
        }
    }

    // MARK: - Appearance & Colors

    private func applyCurrentAppearance(animated: Bool) {
        guard let summary = currentSummary else {
            return
        }

        appearance = NSAppearance(named: currentTheme.sidebarGlassAppearance.nsAppearanceName)
        updateShimmerState()

        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText

        topLabel.textColor = topLabelTextColor(
            for: summary,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        overflowLabel.textColor =
            summary.isActive
            ? activeTextColor.withAlphaComponent(0.54)
            : currentTheme.tertiaryText

        if summary.paneRows.isEmpty {
            let primaryColor = primaryTextColor(
                for: summary,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            primaryBaseLabel.textColor = renderedBaseTextColor(
                primaryColor,
                isShimmering: summary.isWorking,
                treatment: .shadow
            )
            statusBaseLabel.textColor = statusTextColor(for: summary)
            statusIconView.contentTintColor =
                statusBaseLabel.textColor ?? currentTheme.secondaryText
            contextPrefixLabel.textColor = detailTextColor(
                for: .secondary,
                summary: summary
            )

            for (index, detailLabel) in detailLabels.enumerated() {
                guard summary.detailLines.indices.contains(index) else {
                    continue
                }

                detailLabel.textColor = detailTextColor(
                    for: summary.detailLines[index].emphasis,
                    summary: summary
                )
            }
        } else {
            applyPaneRowColors(
                paneRows: summary.paneRows,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
        }

        let paneRowHoverColor = currentTheme.sidebarButtonHoverBackground.withAlphaComponent(0.5)
        for button in paneRowButtons {
            button.updateTheme(hoverColor: paneRowHoverColor)
        }

        let activeBackground = currentTheme.sidebarButtonActiveBackground
        let hoverBackground = currentTheme.sidebarButtonHoverBackground
        let inactiveBackground = currentTheme.sidebarButtonInactiveBackground
        let activeBorder = currentTheme.sidebarButtonActiveBorder
        let inactiveBorder = currentTheme.sidebarButtonInactiveBorder.withAlphaComponent(
            isHovered ? 0.16 : 0.10)

        performThemeAnimation(animated: animated) {
            self.layer?.zPosition = summary.isActive ? 10 : 0
            self.layer?.backgroundColor =
                self.backgroundColor(
                    isActive: summary.isActive,
                    activeBackground: activeBackground,
                    hoverBackground: hoverBackground,
                    inactiveBackground: inactiveBackground
                ).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = summary.isActive ? 0.8 : 1
            self.layer?.shadowColor =
                NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = summary.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func backgroundColor(
        isActive: Bool,
        activeBackground: NSColor,
        hoverBackground: NSColor,
        inactiveBackground: NSColor
    ) -> NSColor {
        if isActive {
            guard isWorking else {
                return activeBackground
            }

            return
                activeBackground
                .mixed(towards: currentTheme.sidebarGradientStart.brightenedForLabel, amount: 0.12)
        }

        if isHovered && !isPaneRowHovered {
            return hoverBackground
        }

        return inactiveBackground
    }

    private func updateShimmerState() {
        guard let summary = currentSummary else {
            primaryLabel.isShimmering = false
            statusLabel.isShimmering = false
            return
        }

        let isActive = currentSummary?.isActive ?? false
        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText
        if summary.paneRows.isEmpty == false {
            primaryLabel.isShimmering = false
            statusLabel.isShimmering = false
            return
        }

        let primaryColor = primaryTextColor(
            for: summary,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        // Primary is always rendered single-line (see `applyWorklanePrimaryPresentation`),
        // so the shimmer view can always animate while the agent is working.
        primaryLabel.isShimmering = isWorking
        primaryLabel.reducedMotion = reducedMotionProvider()
        let primaryShimmerTreatment: SidebarShimmerTreatment = isActive ? .shadow : .highlight
        primaryLabel.shimmerColor = shimmerColor(
            for: primaryColor,
            treatment: primaryShimmerTreatment,
            isActive: isActive
        )
        let statusWraps = SidebarWorklaneRowLayout.worklaneStatusLineCount(
            for: summary,
            availableWidth: bounds.width
        ) > 1
        let shimmersStatus =
            summary.attentionState == .running
            && statusWraps == false
        statusLabel.isShimmering = shimmersStatus
        statusLabel.reducedMotion = reducedMotionProvider()
        let shimmerBase = statusShimmerBaseColor(for: currentTheme.statusRunning)
        statusLabel.shimmerColor = shimmerColor(
            for: shimmerBase,
            treatment: .highlight,
            isActive: isActive
        )
    }

    private func primaryTextColor(
        for summary: WorklaneSidebarSummary,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        return summary.isActive ? activeTextColor : inactiveTextColor
    }

    private func applyPaneRowColors(
        paneRows: [WorklaneSidebarPaneRow],
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) {
        for (index, paneRow) in paneRows.enumerated() {
            guard panePrimaryRows.indices.contains(index),
                paneDetailLabels.indices.contains(index),
                paneStatusRows.indices.contains(index)
            else {
                continue
            }

            let primaryColor = panePrimaryTextColor(
                for: paneRow,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            let trailingColor = paneTrailingTextColor(
                for: paneRow,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            let presentationMode = SidebarWorklaneRowLayout.paneRowPresentationMode(
                for: paneRow,
                availableWidth: bounds.width
            )
            let isActive = currentSummary?.isActive ?? false
            let paneShimmerTreatment: SidebarShimmerTreatment = isActive ? .shadow : .highlight
            panePrimaryRows[index].applyColors(
                primaryColor: primaryColor,
                trailingColor: trailingColor,
                isShimmering: paneRow.isWorking,
                shimmerColor: shimmerColor(
                    for: primaryColor,
                    treatment: paneShimmerTreatment,
                    isActive: isActive
                ),
                reducedMotion: reducedMotionProvider()
            )
            paneDetailLabels[index].textColor = paneDetailTextColor(
                for: paneRow,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            paneStatusRows[index].applyColors(
                textColor: paneStatusTextColor(
                    for: paneRow,
                    activeTextColor: activeTextColor,
                    inactiveTextColor: inactiveTextColor
                ),
                trailingTextColor: presentationMode == .adaptive ? trailingColor : nil,
                isShimmering: paneRow.isWorking && paneRow.attentionState == .running,
                shimmerColor: shimmerColor(
                    for: statusShimmerBaseColor(for: currentTheme.statusRunning),
                    treatment: .highlight,
                    isActive: currentSummary?.isActive ?? false
                ),
                reducedMotion: reducedMotionProvider()
            )
        }
    }

    private func panePrimaryTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        let focusedBaseColor =
            (currentSummary?.isActive ?? false) ? activeTextColor : inactiveTextColor
        return paneRow.isFocused ? focusedBaseColor : currentTheme.secondaryText
    }

    private func paneTrailingTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        let focusedBaseColor =
            (currentSummary?.isActive ?? false) ? activeTextColor : inactiveTextColor
        if paneRow.isWorking {
            return paneRow.isFocused
                ? focusedBaseColor.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        }

        return paneRow.isFocused
            ? focusedBaseColor.withAlphaComponent(0.62)
            : currentTheme.tertiaryText
    }

    private func paneDetailTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        let focusedBaseColor =
            (currentSummary?.isActive ?? false) ? activeTextColor : inactiveTextColor
        if paneRow.isWorking {
            let emphasis = workingTextHighlightColor(
                isActive: currentSummary?.isActive ?? false,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            return paneRow.isFocused
                ? emphasis.withAlphaComponent(0.68)
                : emphasis.withAlphaComponent(0.60)
        }

        return paneRow.isFocused
            ? focusedBaseColor.withAlphaComponent(0.62)
            : currentTheme.tertiaryText
    }

    private func topLabelTextColor(
        for summary: WorklaneSidebarSummary,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        return summary.isActive
            ? activeTextColor.withAlphaComponent(0.66)
            : currentTheme.tertiaryText
    }

    private func workingTextHighlightColor(
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        if isActive {
            return .white
        }

        return inactiveTextColor.mixed(towards: .white, amount: 0.72)
    }

    private func shimmerHighlightAlpha(isActive: Bool) -> CGFloat {
        if currentTheme.reducedTransparency {
            return isActive ? 1.0 : 0.72
        }

        return isActive ? 1.0 : 0.86
    }

    private func shadowShimmerAlpha(isActive: Bool) -> CGFloat {
        if currentTheme.reducedTransparency {
            return isActive ? 0.64 : 0.54
        }

        return isActive ? 0.72 : 0.60
    }

    private func statusShimmerBaseColor(for statusColor: NSColor) -> NSColor {
        if currentTheme.sidebarGlassAppearance == .dark {
            return statusColor.adjustedHSB(
                saturationBy: 0.18,
                brightnessBy: 0.10
            )
        }

        return statusColor.adjustedHSB(
            saturationBy: 0.14,
            brightnessBy: -0.04
        )
    }

    private func shimmerColor(
        for baseTextColor: NSColor,
        treatment: SidebarShimmerTreatment,
        isActive: Bool
    ) -> NSColor {
        switch treatment {
        case .highlight:
            return baseTextColor.withAlphaComponent(shimmerHighlightAlpha(isActive: isActive))
        case .shadow:
            let shadowTarget = currentTheme.sidebarGlassAppearance == .dark
                ? NSColor.black
                : currentTheme.sidebarBackground
            return baseTextColor
                .mixed(towards: shadowTarget, amount: currentTheme.sidebarGlassAppearance == .dark ? 0.82 : 0.74)
                .withAlphaComponent(shadowShimmerAlpha(isActive: isActive))
        }
    }

    private func renderedBaseTextColor(
        _ textColor: NSColor,
        isShimmering: Bool,
        treatment: SidebarShimmerTreatment
    ) -> NSColor {
        guard isShimmering else {
            return textColor
        }

        switch treatment {
        case .highlight:
            return textColor.withAlphaComponent(textColor.alphaComponent * 0.78)
        case .shadow:
            return textColor
        }
    }

    private func statusTextColor(for summary: WorklaneSidebarSummary) -> NSColor {
        switch summary.attentionState {
        case .running:
            return currentTheme.statusRunning
        case .needsInput:
            return currentTheme.statusNeedsInput
        case .unresolvedStop:
            return currentTheme.statusStopped
        case .ready:
            return currentTheme.statusReady
        case nil:
            return currentTheme.secondaryText
        }
    }

    private func paneStatusTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        switch paneRow.attentionState {
        case .running:
            return currentTheme.statusRunning
        case .needsInput:
            return currentTheme.statusNeedsInput
        case .unresolvedStop:
            return currentTheme.statusStopped
        case .ready:
            return currentTheme.statusReady
        case nil:
            return currentTheme.secondaryText
        }
    }

    private func detailTextColor(
        for emphasis: WorklaneSidebarDetailEmphasis,
        summary: WorklaneSidebarSummary
    ) -> NSColor {
        switch emphasis {
        case .primary:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.78)
                : currentTheme.secondaryText
        case .secondary:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        }
    }

    // MARK: - Layout Composition

    private func groupedViews(for layout: SidebarWorklaneRowLayout) -> [NSView] {
        var views: [NSView] = []
        var currentPaneIndex: Int?
        // Track whether the context prefix has already been bundled into a
        // pane row button so the fallback branch (paneRows.isEmpty) and the
        // adjacency check in `.contextPrefix` below know to skip it.
        var contextPrefixConsumed = false

        for row in layout.visibleTextRows {
            switch row {
            case .panePrimary(let index):
                if index != currentPaneIndex {
                    currentPaneIndex = index
                    var subViews: [NSView] = [panePrimaryRows[index]]
                    for next in layout.visibleTextRows {
                        switch next {
                        case .paneDetail(let i) where i == index:
                            subViews.append(paneDetailLabels[i])
                        case .contextPrefix where index == 0:
                            subViews.append(contextPrefixLabel)
                            contextPrefixConsumed = true
                        case .paneStatus(let i) where i == index:
                            subViews.append(paneStatusRows[i])
                        default:
                            break
                        }
                    }
                    paneRowButtons[index].setContent(subViews)
                    views.append(paneRowContainers[index])
                }
            case .paneDetail, .paneStatus:
                break
            case .contextPrefix:
                // Skip when the pane row bundle already absorbed it. This
                // only fires in the standalone (paneRows.isEmpty) fallback.
                if contextPrefixConsumed == false {
                    currentPaneIndex = nil
                    views.append(insetWrappedView(for: label(for: row)))
                }
            default:
                currentPaneIndex = nil
                views.append(insetWrappedView(for: label(for: row)))
            }
        }

        return views
    }

    private func insetWrappedView(for view: NSView) -> NSView {
        return SidebarInsetContainerView(
            contentView: view,
            horizontalInset: Layout.textWrapperInset,
            referenceWidthView: textStack
        )
    }

    private func label(for row: WorklaneRowTextRow) -> NSView {
        switch row {
        case .topLabel:
            topLabel
        case .primary:
            primaryTextContainer
        case .contextPrefix:
            contextPrefixLabel
        case .status:
            statusContentStack
        case .panePrimary(let index):
            panePrimaryRows[index]
        case .paneDetail(let index):
            paneDetailLabels[index]
        case .paneStatus(let index):
            paneStatusRows[index]
        case .context:
            detailLabels.first ?? overflowLabel
        case .detail(let index):
            detailLabels[index]
        case .overflow:
            overflowLabel
        }
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        guard let superview = primaryTextContainer.superview else {
            return view.convert(primaryBaseLabel.bounds, from: primaryBaseLabel).minX
        }

        let primaryTextFrame = convert(primaryTextContainer.frame, from: superview)
        return view.convert(primaryTextFrame, from: self).minX
    }

    private func configureLabel(
        _ label: NSTextField,
        font: NSFont,
        lineBreakMode: NSLineBreakMode
    ) {
        label.font = font
        label.lineBreakMode = lineBreakMode
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
    }

    // MARK: - Test Accessors
    //
    // The block below is read-only support for XCTest assertions. It uses
    // `@testable import Zentty` to reach these internal/private members.
    // Production code must not depend on anything in this section — it is
    // reviewable as one contiguous skippable block in the minimap.

    var detailTextsForTesting: [String] {
        if currentSummary?.paneRows.isEmpty == false {
            return
                paneDetailLabels
                .prefix(currentSummary?.paneRows.count ?? 0)
                .map(\.stringValue)
                .filter { $0.isEmpty == false }
        }

        return detailLabels.prefix(currentSummary?.detailLines.count ?? 0).map(\.stringValue)
    }

    var overflowTextForTesting: String {
        currentSummary?.overflowText ?? ""
    }

    var statusTextForTesting: String {
        if currentSummary?.paneRows.isEmpty == false {
            return paneStatusRows.first?.text ?? ""
        }

        return statusBaseLabel.stringValue
    }

    var statusTextColorForTesting: NSColor {
        if currentSummary?.paneRows.isEmpty == false {
            return paneStatusRows.first?.textColor ?? .clear
        }

        return statusBaseLabel.textColor ?? .clear
    }

    var statusSymbolNameForTesting: String {
        if currentSummary?.paneRows.isEmpty == false {
            return paneStatusRows.first?.symbolName ?? ""
        }

        return currentStatusSymbolName
    }

    var topLabelColorForTesting: NSColor {
        topLabel.textColor ?? .clear
    }

    var isWorkingForTesting: Bool {
        isWorking
    }

    var shimmerIsAnimatingForTesting: Bool {
        primaryLabel.shimmerIsAnimating
    }

    var primaryShimmerViewIsHiddenForTesting: Bool {
        primaryLabel.isHidden
    }

    var primaryBaseLabelMaximumNumberOfLinesForTesting: Int {
        primaryBaseLabel.maximumNumberOfLines
    }

    var contextPrefixTextForTesting: String {
        contextPrefixLabel.stringValue
    }

    var contextPrefixRowIsVisibleForTesting: Bool {
        textStack.arrangedSubviews.contains { view in
            view === contextPrefixLabel || view.containsDescendant(contextPrefixLabel)
        }
    }

    var statusShimmerIsAnimatingForTesting: Bool {
        statusLabel.shimmerIsAnimating
    }

    var shimmerCoordinatorIdentifierForTesting: ObjectIdentifier? {
        shimmerCoordinator.map(ObjectIdentifier.init)
    }

    var shimmerColorForTesting: NSColor {
        primaryLabel.shimmerColor
    }

    var statusShimmerColorForTesting: NSColor {
        statusLabel.shimmerColor
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        primaryLabel.shimmerPhaseOffsetForTesting
    }

    var statusShimmerPhaseOffsetForTesting: CGFloat {
        statusLabel.shimmerPhaseOffsetForTesting
    }

    var primaryTextColorForTesting: NSColor {
        primaryBaseLabel.textColor ?? .clear
    }

    var primaryRowIndexForTesting: Int? {
        if currentSummary?.paneRows.isEmpty == false {
            guard let firstPaneButton = paneRowButtons.first else {
                return nil
            }

            return textStack.arrangedSubviews.firstIndex(of: firstPaneButton)
        }

        return textStack.arrangedSubviews.firstIndex {
            $0 === primaryTextContainer || $0.containsDescendant(primaryTextContainer)
        }
    }

    var primaryTextsForTesting: [String] {
        panePrimaryRows.prefix(currentSummary?.paneRows.count ?? 0).map(\.primaryText)
    }

    var firstPanePrimaryTextColorForTesting: NSColor? {
        panePrimaryRows.first?.renderedPrimaryTextColorForTesting
    }

    var firstPanePrimaryShimmerColorForTesting: NSColor? {
        panePrimaryRows.first?.shimmerColorForTesting
    }

    var firstPanePrimaryHeightForTesting: CGFloat? {
        panePrimaryRows.first.map { max($0.bounds.height, $0.fittingSize.height) }
    }

    var firstPaneTrailingTextColorForTesting: NSColor? {
        panePrimaryRows.first?.renderedTrailingTextColorForTesting
    }

    var panePrimaryShimmerPhaseOffsetsForTesting: [CGFloat] {
        panePrimaryRows.prefix(currentSummary?.paneRows.count ?? 0).map(\.shimmerPhaseOffsetForTesting)
    }

    var primaryTrailingTextsForTesting: [String] {
        panePrimaryRows.prefix(currentSummary?.paneRows.count ?? 0).compactMap(\.trailingText)
    }

    var paneStatusTextsForTesting: [String] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .map(\.text)
            .filter { $0.isEmpty == false }
    }

    var paneStatusTrailingTextsForTesting: [String] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .compactMap { row in
                row.isTrailingVisibleForTesting ? row.trailingText : nil
            }
    }

    var paneStatusSymbolNamesForTesting: [String] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .map(\.symbolName)
            .filter { $0.isEmpty == false }
    }

    var paneStatusShimmerPhaseOffsetsForTesting: [CGFloat] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .map(\.shimmerPhaseOffsetForTesting)
    }

    var firstPaneStatusTextColorForTesting: NSColor? {
        paneStatusRows.first?.textColor
    }

    var paneRowWidthConstraintCountForTesting: Int {
        paneRowContainers.filter(\.hasActiveWidthConstraintForTesting).count
    }

    var firstPaneRowMinXForTesting: CGFloat? {
        paneRowButtons.first.map { convert($0.bounds, from: $0).minX }
    }

    var firstPaneRowMaxTrailingInsetForTesting: CGFloat? {
        paneRowButtons.first.map { bounds.maxX - convert($0.bounds, from: $0).maxX }
    }

    var firstPaneRowContentMinXForTesting: CGFloat? {
        paneRowButtons.first?.contentMinXForTesting
    }

    var firstPaneRowContentMaxTrailingInsetForTesting: CGFloat? {
        paneRowButtons.first?.contentMaxTrailingInsetForTesting
    }

    var firstPaneRowMinYForTesting: CGFloat? {
        paneRowButtons.first.map { convert($0.bounds, from: $0).minY }
    }

    var firstPaneRowMaxTopInsetForTesting: CGFloat? {
        paneRowButtons.first.map { bounds.maxY - convert($0.bounds, from: $0).maxY }
    }

    var firstPaneRowContentMinYForTesting: CGFloat? {
        paneRowButtons.first?.contentMinYForTesting
    }

    var firstPaneRowContentMaxTopInsetForTesting: CGFloat? {
        paneRowButtons.first?.contentMaxTopInsetForTesting
    }

    var firstPaneRowCornerRadiusForTesting: CGFloat? {
        paneRowButtons.first?.cornerRadiusForTesting
    }

    var primaryTextMinXForTesting: CGFloat? {
        guard currentSummary?.paneRows.isEmpty != false,
              let superview = primaryTextContainer.superview else {
            return nil
        }

        return convert(primaryTextContainer.frame, from: superview).minX
    }

    var primaryTextMaxTrailingInsetForTesting: CGFloat? {
        guard currentSummary?.paneRows.isEmpty != false,
              let superview = primaryTextContainer.superview else {
            return nil
        }

        let primaryTextFrame = convert(primaryTextContainer.frame, from: superview)
        return bounds.maxX - primaryTextFrame.maxX
    }

    var backgroundColorForTesting: NSColor? {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
    }

    var appearanceMatchForTesting: NSAppearance.Name? {
        appearance?.bestMatch(from: [.darkAqua, .aqua])
    }
}
