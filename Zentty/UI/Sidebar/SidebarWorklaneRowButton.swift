import AppKit
import QuartzCore

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
    private let statusProgressIndicator = SidebarTaskProgressIndicatorView()
    private let statusProgressRevealView = SidebarTaskProgressRevealView()
    private let statusTextContainer = SidebarPrimaryTextContainerView()
    private let statusBaseLabel = SidebarStaticLabel()
    private let statusLabel = SidebarShimmerTextView()
    private let statusContentStack = SidebarTaskProgressRevealLineView()
    private let overflowLabel = SidebarStaticLabel()
    private let textStack = NSStackView()

    private var detailLabels: [SidebarStaticLabel] = []
    private let paneRowRenderer = SidebarPaneRowRenderer(paneWrapperInset: Layout.paneWrapperInset)
    private var panePrimaryRows: [SidebarPanePrimaryRowView] { paneRowRenderer.panePrimaryRows }
    private var paneDetailLabels: [SidebarStaticLabel] { paneRowRenderer.paneDetailLabels }
    private var paneStatusRows: [SidebarPaneTextRowView] { paneRowRenderer.paneStatusRows }
    private var paneRowButtons: [SidebarPaneRowButton] { paneRowRenderer.paneRowButtons }
    private var paneRowContainers: [SidebarInsetContainerView] { paneRowRenderer.paneRowContainers }
    private let tintLayer = CALayer()
    private var currentSummary: WorklaneSidebarSummary?
    private var currentPresentation: SidebarWorklaneRowPresentation?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var lastAppliedBoundsWidth: CGFloat = -1
#if DEBUG
    private(set) var configureApplyCountForTesting: Int = 0
#endif
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
    private var isReorderDragActive = false
    private var worklaneMoveAvailability: SidebarWorklaneMoveAvailability = .none
    private let reducedMotionProvider: () -> Bool

    var onPaneSelected: ((PaneID) -> Void)?
    var onCloseWorklaneRequested: (() -> Void)?
    var onClosePaneRequested: ((PaneID) -> Void)?
    var onSplitHorizontalRequested: ((PaneID) -> Void)?
    var onSplitVerticalRequested: ((PaneID) -> Void)?
    var onMovePaneToNewWindowRequested: ((PaneID) -> Void)?
    var onWorklaneColorChanged: ((WorklaneID, WorklaneColor?) -> Void)?
    var onWorklaneDragRequested: ((SidebarWorklaneRowButton, NSEvent) -> Bool)?
    var onWorklaneMoveRequested: ((WorklaneID, SidebarWorklaneMoveDirection) -> Void)?
    var onBookmarkAction: ((WorklaneID, SidebarBookmarkRowAction) -> Void)?
    var bookmarkNameLookup: ((UUID) -> String?)?
    var isOnlyWorklane = false {
        didSet {
            paneRowRenderer.setOnlyWorklane(isOnlyWorklane)
        }
    }

    private var activeContextPicker: WorklaneColorMenuItemView?

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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        CATransaction.commit()

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

        tintLayer.cornerRadius = ChromeGeometry.rowRadius
        tintLayer.cornerCurve = .continuous
        tintLayer.backgroundColor = NSColor.clear.cgColor
        tintLayer.zPosition = -1
        layer?.insertSublayer(tintLayer, at: 0)

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
        statusLabel.font = ShellMetrics.sidebarStatusFont()
        statusLabel.lineHeight = ShellMetrics.sidebarStatusLineHeight
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusTextContainer.translatesAutoresizingMaskIntoConstraints = false
        statusTextContainer.addSubview(statusBaseLabel)
        statusTextContainer.addSubview(statusLabel)
        statusContentStack.translatesAutoresizingMaskIntoConstraints = false
        statusContentStack.configureSubviews(
            iconView: statusIconView,
            progressIndicator: statusProgressIndicator,
            progressRevealView: statusProgressRevealView,
            textContainer: statusTextContainer
        )
        statusProgressIndicator.onHoverEntered = { [weak self] in
            self?.setStatusProgressRevealVisible(true, animated: true)
        }
        statusContentStack.onMouseEnteredLine = { [weak self] in
            self?.setStatusProgressRevealVisible(true, animated: true)
        }
        statusContentStack.onMouseExitedLine = { [weak self] in
            self?.setStatusProgressRevealVisible(false, animated: true)
        }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let worklaneID else { return nil }
        let originID = currentSummary?.bookmarkOriginID
        let result = SidebarWorklaneContextMenu.makeMenu(
            context: SidebarWorklaneContextMenuContext(
                origin: .worklane,
                moveAvailability: worklaneMoveAvailability,
                worklaneColor: currentSummary?.color,
                bookmarkOriginID: originID,
                bookmarkName: originID.flatMap { bookmarkNameLookup?($0) },
                isOnlyWorklane: false
            ),
            actions: SidebarWorklaneContextMenuActions(
                target: self,
                closeWorklaneAction: #selector(handleCloseWorklane),
                closePaneAction: nil,
                moveUpAction: #selector(handleMoveWorklaneUp),
                moveDownAction: #selector(handleMoveWorklaneDown),
                splitHorizontalAction: nil,
                splitVerticalAction: nil,
                movePaneToNewWindowAction: nil,
                bookmarkAction: #selector(handleBookmarkMenuItem(_:)),
                colorChanged: { [weak self] picked in
                    self?.onWorklaneColorChanged?(worklaneID, picked)
                }
            )
        )
        activeContextPicker = result.activePicker
        return result.menu
    }

    @objc private func handleCloseWorklane() {
        onCloseWorklaneRequested?()
    }

    @objc
    private func handleBookmarkMenuItem(_ sender: NSMenuItem) {
        guard let worklaneID,
              let box = sender.representedObject as? SidebarBookmarkRowActionBox else {
            return
        }
        onBookmarkAction?(worklaneID, box.action)
    }

    @objc private func handleMoveWorklaneUp() {
        guard let worklaneID else { return }
        onWorklaneMoveRequested?(worklaneID, .up)
    }

    @objc private func handleMoveWorklaneDown() {
        guard let worklaneID else { return }
        onWorklaneMoveRequested?(worklaneID, .down)
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
        paneRowRenderer.setShimmerCoordinator(coordinator)
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        primaryLabel.isVisibleForSharedAnimation = isVisible
        statusLabel.isVisibleForSharedAnimation = isVisible
        paneRowRenderer.setShimmerVisibility(isVisible)
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

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, onWorklaneDragRequested != nil else {
            super.mouseDown(with: event)
            return
        }

        SidebarWorklaneDragGestureTracker.track(
            from: self,
            event: event,
            beginDrag: { [weak self] dragEvent in
                guard let self else { return false }
                return self.onWorklaneDragRequested?(self, dragEvent) ?? false
            },
            click: { [weak self] in
                self?.performClick(nil)
            }
        )
    }

    // MARK: - Public API

    func setReorderDragActive(_ isActive: Bool) {
        guard isReorderDragActive != isActive else {
            return
        }

        isReorderDragActive = isActive
        applyCurrentAppearance(animated: false)
    }

    func setWorklaneMoveAvailability(_ availability: SidebarWorklaneMoveAvailability) {
        worklaneMoveAvailability = availability
        paneRowRenderer.setWorklaneMoveAvailability(availability)
    }

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
#if DEBUG
        configureApplyCountForTesting &+= 1
#endif
        applyResolvedSummary(animated: animated)
    }

    /// Surgical label update for sub-100ms agent title ticks (spinner frames,
    /// elapsed-time counters). Writes the new text directly to the affected
    /// primary labels without reconfiguring the row, rebuilding the layout,
    /// or invalidating autolayout.
    ///
    /// This is a **deliberate 60Hz optimization**, not a workaround for a
    /// slow `configure(with:)` path. The slow path is fast enough for ordinary
    /// render updates, but spinner ticks at 20+ Hz still benefit from surgical
    /// label mutation to avoid per-tick summary construction + diff + layout passes.
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

        paneRowRenderer.setVolatilePaneTitle(
            paneID: paneID,
            text: text,
            paneRows: summary.paneRows
        )
    }

    // MARK: - Rendering

    private func applyResolvedSummary(animated: Bool) {
        guard let summary = currentSummary, isApplyingResolvedSummary == false else {
            return
        }

        isApplyingResolvedSummary = true
        defer { isApplyingResolvedSummary = false }

        let presentation = SidebarWorklaneRowPresentation(summary: summary, availableWidth: bounds.width)
        currentPresentation = presentation
        let layout = presentation.layout
        applyTextStackVerticalInsets(hasPaneRows: summary.paneRows.isEmpty == false)

        topLabel.stringValue = summary.topLabel ?? ""
        overflowLabel.stringValue = summary.overflowText ?? ""
        contextPrefixLabel.stringValue = summary.contextPrefixText ?? ""
        if summary.paneRows.isEmpty {
            primaryBaseLabel.stringValue = summary.primaryText
            primaryLabel.stringValue = summary.primaryText
            applyWorklanePrimaryPresentation()
            statusBaseLabel.stringValue = presentation.statusDisplayText
            statusLabel.stringValue = presentation.statusDisplayText
            statusProgressRevealView.configure(
                taskProgress: summary.taskProgress,
                color: currentTheme.statusRunning,
                font: statusBaseLabel.font ?? ShellMetrics.sidebarStatusFont()
            )
            currentStatusSymbolName = presentation.statusSymbolName
            statusIconView.image =
                currentStatusSymbolName.isEmpty
                ? nil
                : NSImage(systemSymbolName: currentStatusSymbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            statusIconView.isHidden = statusIconView.image == nil
            applyWorklaneStatusPresentation(
                lineCount: presentation.statusLineCount
            )
            configureDetailLabels(for: summary.detailLines)
        } else {
            primaryBaseLabel.stringValue = ""
            primaryLabel.stringValue = ""
            statusBaseLabel.stringValue = ""
            statusLabel.stringValue = ""
            statusProgressRevealView.configure(
                taskProgress: nil,
                color: currentTheme.statusRunning,
                font: statusBaseLabel.font ?? ShellMetrics.sidebarStatusFont()
            )
            currentStatusSymbolName = ""
            statusIconView.image = nil
            statusIconView.isHidden = true
            configurePaneRows(for: presentation.paneRows, animated: animated)
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
        statusProgressIndicator.isHidden = wraps || currentSummary?.taskProgress == nil
        if wraps || currentSummary?.taskProgress == nil {
            setStatusProgressRevealVisible(false, animated: false)
        }
        let statusHeight = ShellMetrics.sidebarStatusLineHeight * CGFloat(clampedLineCount)
        statusTextHeightConstraint?.constant = statusHeight
        statusContentHeightConstraint?.constant = statusHeight
        configureStatusContentLine(taskProgressVisible: statusProgressIndicator.isHidden == false)
    }

    private func setStatusProgressRevealVisible(_ isVisible: Bool, animated: Bool) {
        let summary = currentSummary
        let canReveal =
            isVisible
            && (summary?.paneRows.isEmpty ?? false)
            && summary?.taskProgress != nil
            && statusProgressIndicator.isHidden == false
        statusProgressRevealView.setRevealed(
            canReveal,
            animated: animated,
            reducedMotion: reducedMotionProvider(),
            appliesAlpha: false
        )
        statusContentStack.setProgressRevealVisible(
            canReveal,
            animated: animated,
            reducedMotion: reducedMotionProvider()
        )
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

    private func configurePaneRows(
        for panePresentations: [SidebarWorklaneRowPresentation.PaneRow],
        animated: Bool
    ) {
        paneRowRenderer.configure(
            panePresentations: panePresentations,
            animated: animated,
            worklaneColor: currentSummary?.color,
            referenceWidthView: textStack,
            callbacks: SidebarPaneRowRenderer.Callbacks(
                onPaneSelected: { [weak self] paneID in
                    self?.onPaneSelected?(paneID)
                },
                onCloseWorklaneRequested: { [weak self] in
                    self?.onCloseWorklaneRequested?()
                },
                onClosePaneRequested: { [weak self] paneID in
                    self?.onClosePaneRequested?(paneID)
                },
                onSplitHorizontalRequested: { [weak self] paneID in
                    self?.onSplitHorizontalRequested?(paneID)
                },
                onSplitVerticalRequested: { [weak self] paneID in
                    self?.onSplitVerticalRequested?(paneID)
                },
                onMovePaneToNewWindowRequested: { [weak self] paneID in
                    self?.onMovePaneToNewWindowRequested?(paneID)
                },
                onWorklaneColorChanged: { [weak self] color in
                    guard let self, let worklaneID = self.worklaneID else { return }
                    self.onWorklaneColorChanged?(worklaneID, color)
                },
                onBookmarkAction: { [weak self] action in
                    guard let self, let worklaneID = self.worklaneID else { return }
                    self.onBookmarkAction?(worklaneID, action)
                },
                bookmarkOriginID: currentSummary?.bookmarkOriginID,
                bookmarkNameLookup: bookmarkNameLookup,
                onWorklaneDragRequested: { [weak self] event in
                    guard let self else { return false }
                    return self.onWorklaneDragRequested?(self, event) ?? false
                },
                onHoverChanged: { [weak self] isHovered in
                    self?.paneRowHoverChanged(isHovered: isHovered)
                },
                isOnlyWorklane: isOnlyWorklane,
                worklaneMoveAvailability: worklaneMoveAvailability,
                onMoveWorklaneRequested: { [weak self] direction in
                    guard let self, let worklaneID = self.worklaneID else { return }
                    self.onWorklaneMoveRequested?(worklaneID, direction)
                }
            )
        )
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

        topLabel.textColor = SidebarWorklaneRowStyleResolver.topLabelTextColor(
            isActive: summary.isActive,
            activeTextColor: activeTextColor,
            theme: currentTheme
        )
        overflowLabel.textColor = SidebarWorklaneRowStyleResolver.overflowTextColor(
            isActive: summary.isActive,
            activeTextColor: activeTextColor,
            theme: currentTheme
        )

        if summary.paneRows.isEmpty {
            let primaryColor = SidebarWorklaneRowStyleResolver.primaryTextColor(
                isActive: summary.isActive,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            primaryBaseLabel.textColor = SidebarWorklaneRowStyleResolver.renderedBaseTextColor(
                primaryColor,
                isShimmering: summary.isWorking,
                treatment: .shadow
            )
            statusBaseLabel.textColor = SidebarWorklaneRowStyleResolver.statusTextColor(
                attentionState: summary.attentionState,
                theme: currentTheme
            )
            statusIconView.contentTintColor =
                statusBaseLabel.textColor ?? currentTheme.secondaryText
            let statusWraps = (currentPresentation?.statusLineCount ?? 1) > 1
            statusProgressIndicator.configure(
                taskProgress: statusWraps ? nil : summary.taskProgress,
                color: currentTheme.statusRunning,
                animated: animated,
                reducedMotion: reducedMotionProvider()
            )
            statusProgressRevealView.configure(
                taskProgress: statusWraps ? nil : summary.taskProgress,
                color: currentTheme.statusRunning,
                font: statusBaseLabel.font ?? ShellMetrics.sidebarStatusFont()
            )
            if statusWraps || summary.taskProgress == nil {
                setStatusProgressRevealVisible(false, animated: false)
            }
            configureStatusContentLine(taskProgressVisible: statusWraps == false && summary.taskProgress != nil)
            contextPrefixLabel.textColor = SidebarWorklaneRowStyleResolver.detailTextColor(
                emphasis: .secondary,
                isActive: summary.isActive,
                theme: currentTheme
            )

            for (index, detailLabel) in detailLabels.enumerated() {
                guard summary.detailLines.indices.contains(index) else {
                    continue
                }

                detailLabel.textColor = SidebarWorklaneRowStyleResolver.detailTextColor(
                    emphasis: summary.detailLines[index].emphasis,
                    isActive: summary.isActive,
                    theme: currentTheme
                )
            }
        } else {
            applyPaneRowColors(
                paneRows: summary.paneRows,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
        }

        let paneRowInteractionColors = SidebarWorklaneRowStyleResolver.paneRowInteractionColors(
            worklaneColor: summary.color,
            theme: currentTheme
        )
        for button in paneRowButtons {
            button.updateTheme(
                hoverColor: paneRowInteractionColors.hover,
                pressedColor: paneRowInteractionColors.pressed
            )
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
                SidebarWorklaneRowStyleResolver.resolvedBackgroundColor(
                    isActive: summary.isActive,
                    isWorking: self.isWorking,
                    isHovered: self.isHovered,
                    isPaneRowHovered: self.isPaneRowHovered,
                    isReorderDragActive: self.isReorderDragActive,
                    activeBackground: activeBackground,
                    hoverBackground: hoverBackground,
                    inactiveBackground: inactiveBackground,
                    theme: self.currentTheme
                ).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = summary.isActive ? 0.8 : 1
            self.layer?.shadowColor =
                NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = summary.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
            self.tintLayer.backgroundColor = SidebarWorklaneRowStyleResolver.tintColor(
                worklaneColor: summary.color,
                isActive: summary.isActive,
                isHovered: self.isHovered,
                isPaneRowHovered: self.isPaneRowHovered
            )
        }
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

        let primaryColor = SidebarWorklaneRowStyleResolver.primaryTextColor(
            isActive: summary.isActive,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        // Primary is always rendered single-line (see `applyWorklanePrimaryPresentation`),
        // so the shimmer view can always animate while the agent is working.
        primaryLabel.isShimmering = isWorking
        primaryLabel.reducedMotion = reducedMotionProvider()
        let primaryShimmerTreatment: SidebarShimmerColorResolver.Treatment = isActive ? .shadow : .highlight
        primaryLabel.shimmerColor = SidebarWorklaneRowStyleResolver.shimmerColor(
            baseTextColor: primaryColor,
            worklaneColor: summary.color,
            coloredEmphasis: .full,
            treatment: primaryShimmerTreatment,
            isActive: isActive,
            theme: currentTheme
        )
        let statusWraps = (currentPresentation?.statusLineCount ?? 1) > 1
        let shimmersStatus =
            summary.attentionState == .running
            && statusWraps == false
        statusLabel.isShimmering = shimmersStatus
        statusLabel.reducedMotion = reducedMotionProvider()
        let shimmerBase = SidebarWorklaneRowStyleResolver.statusShimmerBaseColor(
            statusColor: currentTheme.statusRunning,
            theme: currentTheme
        )
        statusLabel.shimmerColor = SidebarWorklaneRowStyleResolver.shimmerColor(
            baseTextColor: shimmerBase,
            worklaneColor: nil,
            coloredEmphasis: .full,
            treatment: .highlight,
            isActive: isActive,
            theme: currentTheme
        )
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

            let isActive = currentSummary?.isActive ?? false
            let primaryColor = SidebarWorklaneRowStyleResolver.panePrimaryTextColor(
                isFocused: paneRow.isFocused,
                isActive: isActive,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor,
                theme: currentTheme
            )
            let trailingColor = SidebarWorklaneRowStyleResolver.paneTrailingTextColor(
                isFocused: paneRow.isFocused,
                isActive: isActive,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor,
                theme: currentTheme
            )
            let presentationMode: SidebarPaneRowPresentationMode
            if let panePresentations = currentPresentation?.paneRows,
               panePresentations.indices.contains(index) {
                presentationMode = panePresentations[index].presentationMode
            } else {
                presentationMode = .inline
            }
            let paneShimmerTreatment: SidebarShimmerColorResolver.Treatment = isActive ? .shadow : .highlight
            panePrimaryRows[index].applyColors(
                primaryColor: primaryColor,
                trailingColor: trailingColor,
                isShimmering: paneRow.isWorking,
                shimmerColor: SidebarWorklaneRowStyleResolver.shimmerColor(
                    baseTextColor: primaryColor,
                    worklaneColor: currentSummary?.color,
                    coloredEmphasis: paneRow.isFocused ? .focusedPane : .unfocusedPane,
                    treatment: paneShimmerTreatment,
                    isActive: isActive,
                    theme: currentTheme
                ),
                reducedMotion: reducedMotionProvider()
            )
            paneDetailLabels[index].textColor = SidebarWorklaneRowStyleResolver.paneDetailTextColor(
                isFocused: paneRow.isFocused,
                isWorking: paneRow.isWorking,
                isActive: isActive,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor,
                theme: currentTheme
            )
            paneStatusRows[index].applyColors(
                textColor: SidebarWorklaneRowStyleResolver.statusTextColor(
                    attentionState: paneRow.attentionState,
                    theme: currentTheme
                ),
                trailingTextColor: presentationMode == .adaptive ? trailingColor : nil,
                progressColor: currentTheme.statusRunning,
                isShimmering: paneRow.isWorking && paneRow.attentionState == .running,
                shimmerColor: SidebarWorklaneRowStyleResolver.shimmerColor(
                    baseTextColor: SidebarWorklaneRowStyleResolver.statusShimmerBaseColor(
                        statusColor: currentTheme.statusRunning,
                        theme: currentTheme
                    ),
                    worklaneColor: nil,
                    coloredEmphasis: .full,
                    treatment: .highlight,
                    isActive: isActive,
                    theme: currentTheme
                ),
                reducedMotion: reducedMotionProvider()
            )
        }
    }

    private func configureStatusContentLine(taskProgressVisible: Bool) {
        statusContentStack.configureLayout(
            statusText: statusBaseLabel.stringValue,
            statusFont: statusBaseLabel.font ?? ShellMetrics.sidebarStatusFont(),
            trailingPreferredWidth: 0,
            lineHeight: ShellMetrics.sidebarStatusLineHeight,
            wraps: statusLabel.isHidden,
            taskProgressVisible: taskProgressVisible
        )
    }

    // MARK: - Layout Composition

    private func groupedViews(for layout: SidebarWorklaneRowLayout) -> [NSView] {
        layout.contentGroups.map { group in
            switch group {
            case .standalone(let row):
                return insetWrappedView(for: label(for: row))
            case .pane(let index, let rows):
                paneRowButtons[index].setContent(rows.map(label(for:)))
                return paneRowContainers[index]
            }
        }
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

#if DEBUG
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

    var tintLayerBackgroundColorForTesting: CGColor? {
        tintLayer.backgroundColor
    }

    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        applyCurrentAppearance(animated: false)
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

    var statusProgressIndicatorIsVisibleForTesting: Bool {
        statusProgressIndicator.isHidden == false
    }

    var statusProgressFractionForTesting: CGFloat {
        statusProgressIndicator.fraction
    }

    var statusProgressToolTipForTesting: String {
        statusProgressIndicator.tooltipText
    }

    var statusProgressRevealTextForTesting: String {
        statusProgressRevealView.revealText
    }

    var statusProgressRevealIsExpandedForTesting: Bool {
        statusProgressRevealView.isRevealed
    }

    var statusProgressRevealLastUpdateWasAnimatedForTesting: Bool {
        statusProgressRevealView.lastUpdateWasAnimated
    }

    var statusProgressRevealLastAnimationDurationForTesting: TimeInterval? {
        statusProgressRevealView.lastAnimationDuration
    }

    var statusProgressColorForTesting: NSColor {
        statusProgressIndicator.progressColor
    }

    var statusProgressLastUpdateWasAnimatedForTesting: Bool {
        statusProgressIndicator.lastUpdateWasAnimated
    }

    var statusTextContainerWidthForTesting: CGFloat {
        statusContentStack.textContainerWidthForTesting
    }

    var statusProgressRevealWidthForTesting: CGFloat {
        statusContentStack.progressRevealWidthForTesting
    }

    var statusProgressRevealIsHiddenForTesting: Bool {
        statusProgressRevealView.isHidden
    }

    func simulateStatusProgressIconHoverForTesting() {
        simulateStatusProgressIconHoverForTesting(animated: true)
    }

    func simulateStatusProgressIconHoverForTesting(animated: Bool) {
        setStatusProgressRevealVisible(true, animated: animated)
    }

    func simulateStatusLineHoverForTesting() {
        statusContentStack.simulateMouseEnteredForTesting()
    }

    func simulateStatusLineExitForTesting() {
        setStatusProgressRevealVisible(false, animated: true)
    }

    func simulateStatusLineExitForTesting(pointerStillInsideLine: Bool) {
        statusContentStack.simulateMouseExitedForTesting(pointerStillInsideLine: pointerStillInsideLine)
    }

    func simulateStatusLineHoverReconciliationForTesting(pointerInsideLine: Bool) {
        statusContentStack.simulateHoverReconciliationForTesting(pointerInsideLine: pointerInsideLine)
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

    var firstPaneStatusShimmerColorForTesting: NSColor? {
        paneStatusRows.first?.shimmerColorForTesting
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

    var firstPaneStatusProgressIndicatorIsVisibleForTesting: Bool {
        paneStatusRows.first?.progressIndicatorIsVisibleForTesting ?? false
    }

    var firstPaneStatusProgressFractionForTesting: CGFloat {
        paneStatusRows.first?.progressFractionForTesting ?? 0
    }

    var firstPaneStatusProgressToolTipForTesting: String {
        paneStatusRows.first?.progressToolTipForTesting ?? ""
    }

    var firstPaneStatusProgressRevealTextForTesting: String {
        paneStatusRows.first?.progressRevealTextForTesting ?? ""
    }

    var firstPaneStatusProgressRevealIsExpandedForTesting: Bool {
        paneStatusRows.first?.progressRevealIsExpandedForTesting ?? false
    }

    var firstPaneStatusProgressRevealLastUpdateWasAnimatedForTesting: Bool {
        paneStatusRows.first?.progressRevealLastUpdateWasAnimatedForTesting ?? false
    }

    var firstPaneStatusProgressRevealLastAnimationDurationForTesting: TimeInterval? {
        paneStatusRows.first?.progressRevealLastAnimationDurationForTesting
    }

    var firstPaneStatusProgressRevealLastConfigureSyncedPresentationForTesting: Bool {
        paneStatusRows.first?.progressRevealLastConfigureSyncedPresentationForTesting ?? false
    }

    var firstPaneStatusProgressColorForTesting: NSColor? {
        paneStatusRows.first?.progressColorForTesting
    }

    var firstPaneStatusTextContainerWidthForTesting: CGFloat? {
        paneStatusRows.first?.textContainerWidthForTesting
    }

    var firstPaneStatusProgressRevealWidthForTesting: CGFloat? {
        paneStatusRows.first?.progressRevealWidthForTesting
    }

    var firstPaneStatusProgressRevealIsHiddenForTesting: Bool? {
        paneStatusRows.first?.progressRevealIsHiddenForTesting
    }

    var firstPaneStatusTrailingLabelWidthForTesting: CGFloat? {
        paneStatusRows.first?.trailingLabelWidthForTesting
    }

    func simulateFirstPaneStatusProgressIconHoverForTesting() {
        simulateFirstPaneStatusProgressIconHoverForTesting(animated: true)
    }

    func simulateFirstPaneStatusProgressIconHoverForTesting(animated: Bool) {
        paneStatusRows.first?.simulateProgressIconHoverForTesting(animated: animated)
    }

    func simulateFirstPaneStatusLineHoverForTesting() {
        paneStatusRows.first?.simulateProgressLineHoverForTesting()
    }

    func simulateFirstPaneStatusLineExitForTesting() {
        paneStatusRows.first?.simulateProgressLineExitForTesting()
    }

    func simulateFirstPaneStatusLineExitForTesting(pointerStillInsideLine: Bool) {
        paneStatusRows.first?.simulateProgressLineExitForTesting(
            pointerStillInsideLine: pointerStillInsideLine
        )
    }

    func simulateFirstPaneStatusLineHoverReconciliationForTesting(pointerInsideLine: Bool) {
        paneStatusRows.first?.simulateProgressLineHoverReconciliationForTesting(
            pointerInsideLine: pointerInsideLine
        )
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

    func setWorklaneMoveAvailabilityForTesting(_ availability: SidebarWorklaneMoveAvailability) {
        setWorklaneMoveAvailability(availability)
    }

    func firstPaneRowMenuForTesting(event: NSEvent) -> NSMenu? {
        paneRowButtons.first?.menu(for: event)
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
#endif
}
