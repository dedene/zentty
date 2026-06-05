import AppKit
import QuartzCore

@MainActor
final class SidebarWorklaneRowButton: NSButton {
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
    private let topLabelSeparator = NSView()
    private let topLabelHeaderView = NSView()
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
    private lazy var contentRenderer = SidebarWorklaneRowContentRenderer(
        textStack: textStack,
        textWrapperInset: Layout.textWrapperInset
    )
    private var panePrimaryRows: [SidebarPanePrimaryRowView] { paneRowRenderer.panePrimaryRows }
    private var paneDetailLabels: [SidebarStaticLabel] { paneRowRenderer.paneDetailLabels }
    private var paneStatusRows: [SidebarPaneTextRowView] { paneRowRenderer.paneStatusRows }
    private var paneServerRows: [SidebarPaneServerRowView] { paneRowRenderer.paneServerRows }
    private var paneRowButtons: [SidebarPaneRowButton] { paneRowRenderer.paneRowButtons }
    private var paneRowContainers: [SidebarInsetContainerView] { paneRowRenderer.paneRowContainers }
    private let chrome = SidebarWorklaneRowChrome()
    private let menuController = SidebarWorklaneRowMenuController()
    private var currentSummary: WorklaneSidebarSummary?
    private var currentRenderPlan: SidebarWorklaneRowRenderPlan?
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
    private var isReorderDragActive = false
    private var worklaneMoveAvailability: SidebarWorklaneMoveAvailability = .none
    private let reducedMotionProvider: () -> Bool

    var onPaneSelected: ((PaneID) -> Void)?
    var onCloseWorklaneRequested: (() -> Void)?
    var onRenameWorklaneRequested: (() -> Void)?
    var onClosePaneRequested: ((PaneID) -> Void)?
    var onSplitHorizontalRequested: ((PaneID) -> Void)?
    var onSplitVerticalRequested: ((PaneID) -> Void)?
    var onAddPaneLeftRequested: ((PaneID) -> Void)?
    var onForceSplitRightRequested: ((PaneID) -> Void)?
    var onForceAddPaneRightRequested: ((PaneID) -> Void)?
    var onMovePaneToNewWindowRequested: ((PaneID) -> Void)?
    var onServerPortSelected: ((String) -> Void)?
    var onRunRestoredCommand: ((PaneID) -> Void)?
    var onWorklaneColorChanged: ((WorklaneID, WorklaneColor?) -> Void)?
    var onWorklaneDragRequested: ((SidebarWorklaneRowButton, NSEvent) -> Bool)?
    var onWorklaneMoveRequested: ((WorklaneID, SidebarWorklaneMoveDirection) -> Void)?
    var onBookmarkAction: ((WorklaneID, SidebarBookmarkRowAction) -> Void)?
    var bookmarkNameLookup: ((UUID) -> String?)?
    var rightPaneCommandPresentationProvider: (() -> PaneRightCommandPresentation)?
    var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?
    var restoredRerunnableCommandProvider: ((PaneID) -> String?)?
    var isOnlyWorklane = false {
        didSet {
            paneRowRenderer.setOnlyWorklane(isOnlyWorklane)
        }
    }

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

        chrome.updateTintFrame(bounds)

        applyResolvedSummary(animated: false)
    }

    // MARK: - Setup

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        chrome.install(in: self)
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        configureLabel(
            topLabel,
            font: ShellMetrics.sidebarTitleFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureTopLabelHeader()
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
        syncMenuControllerCallbacks()
        return menuController.makeMenu(
            worklaneID: worklaneID,
            summary: currentSummary,
            moveAvailability: worklaneMoveAvailability
        )
    }

    private func syncMenuControllerCallbacks() {
        menuController.onCloseWorklaneRequested = onCloseWorklaneRequested
        menuController.onRenameWorklaneRequested = onRenameWorklaneRequested
        menuController.onWorklaneColorChanged = onWorklaneColorChanged
        menuController.onWorklaneMoveRequested = onWorklaneMoveRequested
        menuController.onBookmarkAction = onBookmarkAction
        menuController.bookmarkNameLookup = bookmarkNameLookup
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

    /// Returns Y positions of pane insertion boundaries within this worklane row,
    /// in the given target view's coordinate space. Boundaries sit at the midpoint
    /// of each gap between pane rows (first/last at the top/bottom of the row).
    /// Only containers currently in the view hierarchy are considered, so stale
    /// containers from previous configurations never produce phantom boundaries.
    func paneRowInsertionBoundaries(in targetView: NSView) -> [PaneInsertionBoundary] {
        guard let summary = currentSummary, summary.paneRows.isEmpty == false else {
            return []
        }

        let paneCount = summary.paneRows.count
        guard paneRowContainers.count >= paneCount else {
            return []
        }

        let activeContainers = paneRowContainers.prefix(paneCount)
        guard activeContainers.allSatisfy({ container in
            textStack.arrangedSubviews.contains(container)
                && container.superview != nil
                && !container.isHidden
                && container.bounds.width > 0
                && container.bounds.height > 0
        }) else {
            return []
        }

        let frames: [CGRect] = activeContainers.map { $0.convert($0.bounds, to: targetView) }
        guard frames.allSatisfy({ $0.minY.isFinite && $0.maxY.isFinite && $0.height > 0 }) else {
            return []
        }

        var boundaries: [PaneInsertionBoundary] = []
        let tolerance: CGFloat = 0.5

        if targetView.isFlipped {
            boundaries.append(PaneInsertionBoundary(y: frames[0].minY))

            for i in 1..<frames.count {
                guard frames[i - 1].maxY <= frames[i].minY + tolerance else {
                    return []
                }
                let gapMid = (frames[i - 1].maxY + frames[i].minY) / 2
                boundaries.append(PaneInsertionBoundary(y: gapMid))
            }

            boundaries.append(PaneInsertionBoundary(y: frames.last!.maxY))
        } else {
            boundaries.append(PaneInsertionBoundary(y: frames[0].maxY))

            for i in 1..<frames.count {
                guard frames[i - 1].minY + tolerance >= frames[i].maxY else {
                    return []
                }
                let gapMid = (frames[i - 1].minY + frames[i].maxY) / 2
                boundaries.append(PaneInsertionBoundary(y: gapMid))
            }

            boundaries.append(PaneInsertionBoundary(y: frames.last!.minY))
        }

        return boundaries
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        chrome.setDropTargetHighlighted(
            highlighted,
            layer: layer,
            reducedMotion: reducedMotionProvider()
        )
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

        let renderPlan = SidebarWorklaneRowRenderPlan(summary: summary, availableWidth: bounds.width)
        currentRenderPlan = renderPlan
        applyTextStackVerticalInsets(renderPlan)

        topLabel.stringValue = summary.topLabel ?? ""
        overflowLabel.stringValue = summary.overflowText ?? ""
        contextPrefixLabel.stringValue = summary.contextPrefixText ?? ""
        if summary.paneRows.isEmpty {
            primaryBaseLabel.stringValue = summary.primaryText
            primaryLabel.stringValue = summary.primaryText
            applyWorklanePrimaryPresentation()
            statusBaseLabel.stringValue = renderPlan.statusDisplayText
            statusLabel.stringValue = renderPlan.statusDisplayText
            statusProgressRevealView.configure(
                taskProgress: summary.taskProgress,
                color: currentTheme.statusRunning,
                font: statusBaseLabel.font ?? ShellMetrics.sidebarStatusFont()
            )
            currentStatusSymbolName = renderPlan.statusSymbolName
            statusIconView.image =
                currentStatusSymbolName.isEmpty
                ? nil
                : NSImage(systemSymbolName: currentStatusSymbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            statusIconView.isHidden = statusIconView.image == nil
            applyWorklaneStatusPresentation(
                lineCount: renderPlan.statusLineCount
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
            configurePaneRows(for: renderPlan.paneRows, animated: animated)
        }

        textStack.setViews(
            contentRenderer.groupedViews(
                for: renderPlan,
                labels: contentLabels(),
                paneRows: contentPaneRows()
            ),
            in: .top
        )
        heightConstraint?.constant = renderPlan.rowHeight
        invalidateIntrinsicContentSize()

        applyCurrentAppearance(animated: animated)
    }

    private func applyTextStackVerticalInsets(_ renderPlan: SidebarWorklaneRowRenderPlan) {
        textStackTopConstraint?.constant = renderPlan.textStackTopInset
        textStackBottomConstraint?.constant = renderPlan.textStackBottomInset
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
        for panePresentations: [SidebarWorklaneRowRenderPlan.PaneRow],
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
                onRenameWorklaneRequested: { [weak self] in
                    self?.onRenameWorklaneRequested?()
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
                onAddPaneLeftRequested: { [weak self] paneID in
                    self?.onAddPaneLeftRequested?(paneID)
                },
                onForceSplitRightRequested: { [weak self] paneID in
                    self?.onForceSplitRightRequested?(paneID)
                },
                onForceAddPaneRightRequested: { [weak self] paneID in
                    self?.onForceAddPaneRightRequested?(paneID)
                },
                onMovePaneToNewWindowRequested: { [weak self] paneID in
                    self?.onMovePaneToNewWindowRequested?(paneID)
                },
                onRunRestoredCommandRequested: { [weak self] paneID in
                    self?.onRunRestoredCommand?(paneID)
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
                },
                rightPaneCommandPresentationProvider: rightPaneCommandPresentationProvider,
                moveToWorklaneCatalogProvider: moveToWorklaneCatalogProvider,
                onServerPortSelected: { [weak self] serverID in
                    self?.onServerPortSelected?(serverID)
                },
                restoredRerunnableCommandProvider: restoredRerunnableCommandProvider
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
        topLabelSeparator.layer?.backgroundColor = currentTheme.sidebarBorder.cgColor
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
            let statusWraps = (currentRenderPlan?.statusLineCount ?? 1) > 1
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

        chrome.apply(
            summary: summary,
            theme: currentTheme,
            isWorking: isWorking,
            isHovered: isHovered,
            isPaneRowHovered: isPaneRowHovered,
            isReorderDragActive: isReorderDragActive,
            animated: animated,
            layer: layer
        )
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
        let statusWraps = (currentRenderPlan?.statusLineCount ?? 1) > 1
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
                paneStatusRows.indices.contains(index),
                paneServerRows.indices.contains(index)
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
            if let panePresentations = currentRenderPlan?.paneRows,
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
            paneServerRows[index].applyColors(
                defaultColor: SidebarWorklaneRowStyleResolver.paneDetailTextColor(
                    isFocused: paneRow.isFocused,
                    isWorking: paneRow.isWorking,
                    isActive: isActive,
                    activeTextColor: activeTextColor,
                    inactiveTextColor: inactiveTextColor,
                    theme: currentTheme
                ),
                hoverColor: currentTheme.statusRunning
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

    /// Composes the title header: label with a hairline separator below,
    /// rendered as one row so the layout's titleRowHeight stays in lockstep.
    private func configureTopLabelHeader() {
        topLabelHeaderView.translatesAutoresizingMaskIntoConstraints = false
        topLabelSeparator.translatesAutoresizingMaskIntoConstraints = false
        topLabelSeparator.wantsLayer = true
        topLabelHeaderView.addSubview(topLabel)
        topLabelHeaderView.addSubview(topLabelSeparator)
        NSLayoutConstraint.activate([
            topLabel.topAnchor.constraint(equalTo: topLabelHeaderView.topAnchor),
            topLabel.leadingAnchor.constraint(equalTo: topLabelHeaderView.leadingAnchor),
            topLabel.trailingAnchor.constraint(equalTo: topLabelHeaderView.trailingAnchor),
            topLabelSeparator.topAnchor.constraint(
                equalTo: topLabel.bottomAnchor,
                constant: ShellMetrics.sidebarTopLabelSeparatorSpacing
            ),
            topLabelSeparator.leadingAnchor.constraint(equalTo: topLabelHeaderView.leadingAnchor),
            topLabelSeparator.trailingAnchor.constraint(equalTo: topLabelHeaderView.trailingAnchor),
            topLabelSeparator.heightAnchor.constraint(
                equalToConstant: ShellMetrics.sidebarTopLabelSeparatorHeight
            ),
            topLabelSeparator.bottomAnchor.constraint(equalTo: topLabelHeaderView.bottomAnchor),
        ])
    }

    private func contentLabels() -> SidebarWorklaneRowContentRenderer.Labels {
        SidebarWorklaneRowContentRenderer.Labels(
            topLabel: topLabelHeaderView,
            primaryTextContainer: primaryTextContainer,
            contextPrefixLabel: contextPrefixLabel,
            statusContentStack: statusContentStack,
            detailLabels: detailLabels,
            overflowLabel: overflowLabel
        )
    }

    private func contentPaneRows() -> SidebarWorklaneRowContentRenderer.PaneRows {
        SidebarWorklaneRowContentRenderer.PaneRows(
            primaryRows: panePrimaryRows,
            detailLabels: paneDetailLabels,
            statusRows: paneStatusRows,
            serverRows: paneServerRows,
            buttons: paneRowButtons,
            containers: paneRowContainers
        )
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
    var debugAccessForTesting: SidebarWorklaneRowDebugAccess {
        SidebarWorklaneRowDebugAccess(
            owner: self,
            currentSummary: currentSummary,
            currentStatusSymbolName: currentStatusSymbolName,
            isWorking: isWorking,
            shimmerCoordinator: shimmerCoordinator,
            configureApplyCount: configureApplyCountForTesting,
            textStack: textStack,
            topLabel: topLabel,
            primaryTextContainer: primaryTextContainer,
            primaryBaseLabel: primaryBaseLabel,
            primaryLabel: primaryLabel,
            contextPrefixLabel: contextPrefixLabel,
            statusBaseLabel: statusBaseLabel,
            statusLabel: statusLabel,
            statusContentStack: statusContentStack,
            statusProgressIndicator: statusProgressIndicator,
            statusProgressRevealView: statusProgressRevealView,
            overflowLabel: overflowLabel,
            detailLabels: detailLabels,
            panePrimaryRows: panePrimaryRows,
            paneDetailLabels: paneDetailLabels,
            paneStatusRows: paneStatusRows,
            paneServerRows: paneServerRows,
            paneRowButtons: paneRowButtons,
            paneRowContainers: paneRowContainers,
            tintLayer: chrome.tintLayer,
            setHovered: { [weak self] hovered in
                self?.isHovered = hovered
                self?.applyCurrentAppearance(animated: false)
            },
            setStatusProgressRevealVisible: { [weak self] isVisible, animated in
                self?.setStatusProgressRevealVisible(isVisible, animated: animated)
            }
        )
    }
#endif
}
