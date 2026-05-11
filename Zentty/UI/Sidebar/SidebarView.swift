import AppKit

@MainActor
final class SidebarReorderSpacerView: NSView {
    private var heightConstraint: NSLayoutConstraint?

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        updateHeight(height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var spacerHeight: CGFloat {
        heightConstraint?.constant ?? 0
    }

    func updateHeight(_ height: CGFloat) {
        let clampedHeight = max(0, height)
        if let heightConstraint {
            heightConstraint.constant = clampedHeight
            return
        }

        let heightConstraint = heightAnchor.constraint(equalToConstant: clampedHeight)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint
    }
}

@MainActor
final class SidebarView: NSView {
    private enum Layout {
        static let contentInset: CGFloat = ShellMetrics.sidebarContentInset
        static let headerHeight: CGFloat = ShellMetrics.sidebarHeaderHeight
        static let updateRowHeight: CGFloat = 28
        static let updateRowBottomInset: CGFloat = ShellMetrics.sidebarContentInset
        static let updateRowSpacing: CGFloat = 8
        static let resizeHandleWidth: CGFloat = 4
        static let headerButtonSpacing: CGFloat = 6
        static let reorderPreviewAnimationDuration: TimeInterval = 0.11
        static let defaultHeaderContentMinX: CGFloat =
            ShellMetrics.sidebarContentInset + ShellMetrics.sidebarCreateWorklaneHorizontalInset
    }

    var onWorklaneSelected: ((WorklaneID) -> Void)?
    var onPaneSelected: ((WorklaneID, PaneID) -> Void)?
    var onCloseWorklaneRequested: ((WorklaneID) -> Void)?
    var onClosePaneRequested: ((WorklaneID, PaneID) -> Void)?
    var onSplitHorizontalRequested: ((WorklaneID, PaneID) -> Void)?
    var onSplitVerticalRequested: ((WorklaneID, PaneID) -> Void)?
    var onForceSplitRightRequested: ((WorklaneID, PaneID) -> Void)?
    var onForceAddPaneRightRequested: ((WorklaneID, PaneID) -> Void)?
    var onMovePaneToNewWindowRequested: ((WorklaneID, PaneID) -> Void)?
    var onWorklaneColorChanged: ((WorklaneID, WorklaneColor?) -> Void)?
    var onWorklaneReorderCommitted: ((WorklaneID, Int) -> Bool)?
    var onNewWorklaneRequested: (() -> Void)?
    var onOpenBookmarksPopoverRequested: ((NSView) -> Void)?
    var onBookmarkAction: ((WorklaneID, SidebarBookmarkRowAction) -> Void)?
    var bookmarkNameLookup: ((UUID) -> String?)?
    var rightPaneCommandPresentationProvider: (() -> PaneRightCommandPresentation)?
    var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?
    var onCheckForUpdatesRequested: (() -> Void)?
    var onResized: ((CGFloat) -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let backgroundView = GlassSurfaceView(style: .sidebar)
    private let headerView = NSView()
    private let listScrollView = NSScrollView()
    private let listDocumentView = FlippedSidebarDocumentView()
    private let listStack = NSStackView()
    private let updateAvailableRowView = SidebarUpdateAvailableRowView()
    private let addWorklaneButton = SidebarCreateWorklaneButton()
    private let bookmarksButton = SidebarBookmarksButton()
    private let resizeHandleView = SidebarResizeHandleView()
    private let shimmerCoordinator = SidebarShimmerCoordinator()
    private let activeWorklaneAutoScroller = SidebarActiveWorklaneAutoScroller()
    private let windowRenderabilityResolver: (NSWindow?) -> Bool
    private lazy var chrome = SidebarViewChrome(
        hostView: self,
        backgroundView: backgroundView,
        listScrollView: listScrollView,
        listDocumentView: listDocumentView,
        listStack: listStack,
        addWorklaneButton: addWorklaneButton,
        bookmarksButton: bookmarksButton,
        updateAvailableRowView: updateAvailableRowView,
        resizeHandleView: resizeHandleView
    )
    private lazy var dragCoordinator = SidebarDragCoordinator(sidebarView: self)
    private lazy var paneDropPresenter = SidebarPaneDropPresenter(targetStack: listStack, lineContainer: listDocumentView)

    private var worklaneButtons: [SidebarWorklaneRowButton] = []
    private var worklaneSummaries: [WorklaneSidebarSummary] = []
    private var canonicalWorklaneSummaries: [WorklaneSidebarSummary] = []
    private var dragPreviewOrder: [WorklaneID]?
    private var dragPreviewDraggedWorklaneID: WorklaneID?
    private var reorderSpacerView: SidebarReorderSpacerView?
    private var reorderSpacerHeight: CGFloat = ShellMetrics.sidebarCompactRowHeight
    private var addWorklaneLeadingConstraint: NSLayoutConstraint?
    private var addWorklaneWidthConstraint: NSLayoutConstraint?
    private var addWorklaneCenterYConstraint: NSLayoutConstraint?
    private var headerTopConstraint: NSLayoutConstraint?
    private var listBottomConstraint: NSLayoutConstraint?
    private var updateRowHeightConstraint: NSLayoutConstraint?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
#if DEBUG
    private(set) var renderInvocationCountDebug: Int = 0
    private(set) var reorderPreviewLastAnimationDurationDebug: TimeInterval?
#endif
    private var headerPinnedContentMinX = Layout.defaultHeaderContentMinX
    private var headerVisibilityMode: SidebarVisibilityMode = .pinnedOpen
    private var resizeStartWidth: CGFloat = SidebarWidthPreference.defaultWidth
    private var trackingArea: NSTrackingArea?
    private var isResizeEnabled = true
    private var isUpdateAvailable = false

    override init(frame frameRect: NSRect) {
        windowRenderabilityResolver = SidebarWindowRenderability.appKitRenderableWindow
        super.init(frame: frameRect)
        setup()
    }

#if DEBUG
    init(
        frame frameRect: NSRect,
        windowRenderabilityResolver: @escaping (NSWindow?) -> Bool
    ) {
        self.windowRenderabilityResolver = windowRenderabilityResolver
        super.init(frame: frameRect)
        setup()
    }
#endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 6
        listStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        headerView.translatesAutoresizingMaskIntoConstraints = false

        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.borderType = .noBorder
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        listDocumentView.translatesAutoresizingMaskIntoConstraints = false
        listDocumentView.addSubview(listStack)
        listScrollView.documentView = listDocumentView
        listScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: listScrollView.contentView
        )

        addWorklaneButton.translatesAutoresizingMaskIntoConstraints = false
        addWorklaneButton.setContentHuggingPriority(.required, for: .horizontal)
        addWorklaneButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addWorklaneButton.target = self
        addWorklaneButton.action = #selector(handleCreateWorklane)

        bookmarksButton.target = self
        bookmarksButton.action = #selector(handleOpenBookmarksPopover)

        resizeHandleView.translatesAutoresizingMaskIntoConstraints = false
        resizeHandleView.onPan = { [weak self] recognizer in
            self?.handleResizePan(recognizer)
        }
        updateAvailableRowView.onPressed = { [weak self] in
            self?.handleCheckForUpdates()
        }

        addSubview(backgroundView)
        addSubview(headerView)
        addSubview(listScrollView)
        addSubview(updateAvailableRowView)
        addSubview(resizeHandleView)

        headerView.addSubview(addWorklaneButton)
        headerView.addSubview(bookmarksButton)

        let addWorklaneLeadingConstraint = addWorklaneButton.leadingAnchor.constraint(
            equalTo: headerView.leadingAnchor,
            constant: Layout.contentInset
        )
        self.addWorklaneLeadingConstraint = addWorklaneLeadingConstraint
        let addWorklaneWidthConstraint = addWorklaneButton.widthAnchor.constraint(
            lessThanOrEqualToConstant: 0
        )
        self.addWorklaneWidthConstraint = addWorklaneWidthConstraint
        let addWorklaneCenterYConstraint = addWorklaneButton.centerYAnchor.constraint(
            equalTo: headerView.centerYAnchor
        )
        self.addWorklaneCenterYConstraint = addWorklaneCenterYConstraint

        let headerTopConstraint = headerView.topAnchor.constraint(equalTo: topAnchor)
        self.headerTopConstraint = headerTopConstraint

        updateAvailableRowView.translatesAutoresizingMaskIntoConstraints = false
        let listBottomConstraint = listScrollView.bottomAnchor.constraint(
            equalTo: updateAvailableRowView.topAnchor,
            constant: -Layout.updateRowSpacing
        )
        self.listBottomConstraint = listBottomConstraint
        let updateRowHeightConstraint = updateAvailableRowView.heightAnchor.constraint(
            equalToConstant: Layout.updateRowHeight
        )
        self.updateRowHeightConstraint = updateRowHeightConstraint

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerTopConstraint,
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Layout.headerHeight),

            addWorklaneLeadingConstraint,
            addWorklaneButton.trailingAnchor.constraint(
                lessThanOrEqualTo: bookmarksButton.leadingAnchor,
                constant: -Layout.headerButtonSpacing
            ),
            addWorklaneWidthConstraint,
            addWorklaneCenterYConstraint,
            addWorklaneButton.topAnchor.constraint(
                greaterThanOrEqualTo: headerView.topAnchor
            ),
            addWorklaneButton.bottomAnchor.constraint(
                lessThanOrEqualTo: headerView.bottomAnchor
            ),

            bookmarksButton.trailingAnchor.constraint(
                equalTo: headerView.trailingAnchor,
                constant: -Layout.contentInset
            ),
            bookmarksButton.centerYAnchor.constraint(
                equalTo: headerView.centerYAnchor
            ),

            listScrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset),
            listScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.contentInset),
            listBottomConstraint,

            updateAvailableRowView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset),
            updateAvailableRowView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.contentInset),
            updateAvailableRowView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Layout.updateRowBottomInset
            ),
            updateRowHeightConstraint,

            listDocumentView.widthAnchor.constraint(equalTo: listScrollView.contentView.widthAnchor),

            listStack.topAnchor.constraint(equalTo: listDocumentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: listDocumentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDocumentView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDocumentView.bottomAnchor),

            resizeHandleView.topAnchor.constraint(equalTo: topAnchor),
            resizeHandleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandleView.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandleView.widthAnchor.constraint(equalToConstant: Layout.resizeHandleWidth),
        ])

        updateHeaderLayoutConstraints()
        applyUpdateAvailability()
        apply(theme: currentTheme, animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }

    override func layout() {
        super.layout()
        updateHeaderLayoutConstraints()
        syncShimmerVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowVisibilityObservation()
        syncShimmerVisibility()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isResizeEnabled, !resizeHandleView.isHidden, resizeHandleView.frame.contains(point) else {
            return super.hitTest(point)
        }

        return resizeHandleView
    }

    /// Surgical label update for the volatile agent title fast path.
    /// Routes the new text directly to the affected worklane row button,
    /// bypassing summary rebuilds and full sidebar re-apply. Idempotent.
    func setVolatilePaneTitle(
        worklaneID: WorklaneID,
        paneID: PaneID,
        text: String
    ) {
        guard let button = worklaneButtons.first(where: { $0.worklaneID == worklaneID }) else {
            return
        }
        button.setVolatilePaneTitle(paneID: paneID, text: text)
    }

    func render(
        summaries: [WorklaneSidebarSummary],
        theme: ZenttyTheme
    ) {
        reconcileDragPreview(with: summaries)
        let effectiveSummaries = effectiveSummaries(for: summaries)

        if effectiveSummaries == worklaneSummaries,
           theme == currentTheme,
           worklaneButtons.map(\.worklaneID) == effectiveSummaries.map(\.worklaneID) {
            syncWorklaneMoveAvailability()
            syncReorderSpacer()
            return
        }

#if DEBUG
        renderInvocationCountDebug &+= 1
#endif
        let previousActiveID = worklaneSummaries.first(where: \.isActive)?.worklaneID
        let previousSummaries = worklaneSummaries
        let previousTheme = currentTheme
        canonicalWorklaneSummaries = summaries
        worklaneSummaries = effectiveSummaries
        currentTheme = theme

        let diff = SidebarRowDiff.compute(old: previousSummaries, new: effectiveSummaries)

        if !diff.hasStructuralChange {
            // Same IDs — apply theme + content updates in place.
            apply(theme: theme, animated: true)
        } else {
            worklaneButtons = SidebarListRenderer.renderStructuralDiff(
                diff,
                summaries: effectiveSummaries,
                currentButtons: worklaneButtons,
                targetStack: listStack,
                theme: theme,
                shimmerCoordinator: shimmerCoordinator,
                reconfigureSurvivingButtons: theme != previousTheme,
                excludedWorklaneID: dragPreviewDraggedWorklaneID,
                buttonFactory: makeWorklaneButton(for:)
            )
            applySidebarChrome(theme: theme, animated: true)
        }

        worklaneButtons.forEach { $0.isOnlyWorklane = effectiveSummaries.count == 1 }
        syncReorderSpacer()
        syncWorklaneMoveAvailability()
        worklaneButtons.forEach { $0.setShimmerCoordinator(shimmerCoordinator) }
        syncShimmerVisibility()
        shimmerCoordinator.labelStateDidChange()

        let newActiveID = summaries.first(where: \.isActive)?.worklaneID
        if dragPreviewDraggedWorklaneID == nil, newActiveID != previousActiveID, let newActiveID {
            activeWorklaneAutoScroller.scrollToActiveWorklaneIfNeeded(
                newActiveID,
                currentActiveID: { [weak self] in
                    self?.worklaneSummaries.first(where: \.isActive)?.worklaneID
                },
                layoutIfNeeded: { [weak self] in
                    self?.layoutSubtreeIfNeeded()
                },
                isVisible: { [weak self] worklaneID in
                    self?.isWorklaneVisible(id: worklaneID) ?? false
                },
                scroll: { [weak self] worklaneID in
                    self?.scrollToWorklane(id: worklaneID)
                }
            )
        }
    }

    /// Creates a new row button with all callback closures wired up.
    private func makeWorklaneButton(
        for summary: WorklaneSidebarSummary
    ) -> SidebarWorklaneRowButton {
        let button = SidebarWorklaneRowButton(worklaneID: summary.worklaneID)
        button.target = self
        button.action = #selector(handleWorklaneButton(_:))

        let worklaneID = summary.worklaneID
        button.onPaneSelected = { [weak self] paneID in
            self?.onPaneSelected?(worklaneID, paneID)
        }
        button.onCloseWorklaneRequested = { [weak self] in
            self?.onCloseWorklaneRequested?(worklaneID)
        }
        button.onClosePaneRequested = { [weak self] paneID in
            self?.onClosePaneRequested?(worklaneID, paneID)
        }
        button.onSplitHorizontalRequested = { [weak self] paneID in
            self?.onSplitHorizontalRequested?(worklaneID, paneID)
        }
        button.onSplitVerticalRequested = { [weak self] paneID in
            self?.onSplitVerticalRequested?(worklaneID, paneID)
        }
        button.onForceSplitRightRequested = { [weak self] paneID in
            self?.onForceSplitRightRequested?(worklaneID, paneID)
        }
        button.onForceAddPaneRightRequested = { [weak self] paneID in
            self?.onForceAddPaneRightRequested?(worklaneID, paneID)
        }
        button.rightPaneCommandPresentationProvider = { [weak self] in
            self?.rightPaneCommandPresentationProvider?() ?? .addsToWorklane
        }
        button.moveToWorklaneCatalogProvider = { [weak self] paneID in
            self?.moveToWorklaneCatalogProvider?(paneID)
        }
        button.onMovePaneToNewWindowRequested = { [weak self] paneID in
            self?.onMovePaneToNewWindowRequested?(worklaneID, paneID)
        }
        button.onWorklaneColorChanged = { [weak self] id, color in
            self?.onWorklaneColorChanged?(id, color)
        }
        button.onWorklaneDragRequested = { [weak self] button, event in
            self?.beginWorklaneDrag(button: button, event: event) ?? false
        }
        button.onWorklaneMoveRequested = { [weak self] id, direction in
            self?.moveWorklaneFromMenu(id: id, direction: direction)
        }
        button.onBookmarkAction = { [weak self] id, action in
            self?.onBookmarkAction?(id, action)
        }
        button.bookmarkNameLookup = { [weak self] id in
            self?.bookmarkNameLookup?(id)
        }

        button.setShimmerCoordinator(shimmerCoordinator)
        return button
    }

    /// Applies theme to sidebar chrome (appearances, background, add-button,
    /// resize handle) WITHOUT re-configuring worklane buttons. Use after
    /// structural mutations where buttons are already configured.
    private func applySidebarChrome(theme: ZenttyTheme, animated: Bool) {
        chrome.apply(theme: theme, animated: animated)
    }

    private func isWorklaneVisible(id: WorklaneID) -> Bool {
        guard let index = worklaneSummaries.firstIndex(where: { $0.worklaneID == id }),
              worklaneButtons.indices.contains(index) else {
            return false
        }
        let button = worklaneButtons[index]
        let buttonFrame = listDocumentView.convert(button.bounds, from: button)
        return listScrollView.documentVisibleRect.contains(buttonFrame)
    }

    private func scrollToWorklane(id: WorklaneID) {
        guard let index = worklaneSummaries.firstIndex(where: { $0.worklaneID == id }),
              worklaneButtons.indices.contains(index) else {
            return
        }
        let button = worklaneButtons[index]
        let buttonFrame = listDocumentView.convert(button.bounds, from: button)
        listScrollView.contentView.scrollToVisible(buttonFrame)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        applySidebarChrome(theme: theme, animated: animated)

        worklaneButtons.enumerated().forEach { index, button in
            guard worklaneSummaries.indices.contains(index) else {
                return
            }
            button.isOnlyWorklane = worklaneSummaries.count == 1
            button.configure(
                with: worklaneSummaries[index],
                theme: theme,
                animated: animated
            )
        }

        worklaneButtons.forEach { $0.setShimmerCoordinator(shimmerCoordinator) }
        syncShimmerVisibility()
    }

    func updateHeaderLayout(
        visibilityMode: SidebarVisibilityMode,
        pinnedContentMinX: CGFloat
    ) {
        headerVisibilityMode = visibilityMode
        headerPinnedContentMinX = pinnedContentMinX
        updateHeaderLayoutConstraints()
        needsLayout = true
    }

    func setResizeEnabled(_ isEnabled: Bool) {
        isResizeEnabled = isEnabled
        resizeHandleView.setEnabled(isEnabled)
    }

    func setUpdateAvailable(_ isUpdateAvailable: Bool) {
        guard self.isUpdateAvailable != isUpdateAvailable else {
            return
        }

        self.isUpdateAvailable = isUpdateAvailable
        applyUpdateAvailability()
    }

    func adjustScrollOffset(by delta: CGFloat) {
        let clipView = listScrollView.contentView
        var origin = clipView.bounds.origin
        origin.y += delta
        let maxY = max(0, listDocumentView.frame.height - clipView.bounds.height)
        origin.y = max(0, min(origin.y, maxY))
        clipView.scroll(to: origin)
        listScrollView.reflectScrolledClipView(clipView)
    }

    func worklaneRowFrames(in targetView: NSView) -> [(WorklaneID, CGRect)] {
        worklaneButtons.compactMap { button in
            guard let worklaneID = button.worklaneID else { return nil }
            let targetFrame = targetView.convert(button.bounds, from: button)
            return (worklaneID, targetFrame)
        }
    }

    /// Returns pane insertion boundaries per worklane, in targetView coordinates.
    /// Each element is (worklaneID, [PaneInsertionBoundary]) with count = paneCount + 1.
    /// Excludes worklanes with no pane rows.
    func paneInsertionBoundaries(in targetView: NSView) -> [(WorklaneID, [PaneInsertionBoundary])] {
        worklaneButtons.compactMap { button in
            guard let worklaneID = button.worklaneID else { return nil }
            let boundaries = button.paneRowInsertionBoundaries(in: targetView)
            return boundaries.isEmpty ? nil : (worklaneID, boundaries)
        }
    }

    func visibleListRect(in targetView: NSView) -> CGRect {
        targetView.convert(listScrollView.contentView.bounds, from: listScrollView.contentView)
    }

    func visibleListRectForReordering() -> CGRect {
        listDocumentView.convert(listScrollView.contentView.bounds, from: listScrollView.contentView)
    }

    func reorderPoint(fromWindowLocation windowLocation: NSPoint) -> NSPoint {
        listDocumentView.convert(windowLocation, from: nil)
    }

    func worklaneRowFramesForReordering() -> [(WorklaneID, CGRect)] {
        worklaneRowFrames(in: listDocumentView)
    }

    func currentWorklaneOrder() -> [WorklaneID] {
        canonicalWorklaneSummaries.map(\.worklaneID)
    }

    func setDragPreview(draggedID: WorklaneID, previewOrder: [WorklaneID]) {
        let currentIDs = canonicalWorklaneSummaries.map(\.worklaneID)
        guard Set(previewOrder) == Set(currentIDs), previewOrder.count == currentIDs.count else {
            return
        }

        let shouldAnimate = SidebarWorklaneReorderModel.previewSlotChanged(
            previousPreviewOrder: dragPreviewOrder,
            nextPreviewOrder: previewOrder,
            draggedID: draggedID
        )
        dragPreviewDraggedWorklaneID = draggedID
        dragPreviewOrder = previewOrder
        renderDragPreview(animated: shouldAnimate)
    }

    func clearDragPreview() {
        guard dragPreviewOrder != nil || dragPreviewDraggedWorklaneID != nil else {
            return
        }

        let detachedDraggedButton = worklaneButtons.first { button in
            button.worklaneID == dragPreviewDraggedWorklaneID
                && !listStack.arrangedSubviews.contains(button)
        }

        dragPreviewOrder = nil
        dragPreviewDraggedWorklaneID = nil
        removeReorderSpacer()

        if detachedDraggedButton != nil,
           canonicalWorklaneSummaries == worklaneSummaries,
           worklaneButtons.map(\.worklaneID) == canonicalWorklaneSummaries.map(\.worklaneID) {
            restoreArrangedWorklaneButtons()
        } else {
            render(summaries: canonicalWorklaneSummaries, theme: currentTheme)
        }
    }

    func commitWorklaneReorder(id: WorklaneID, toIndex: Int) -> Bool {
        onWorklaneReorderCommitted?(id, toIndex) ?? false
    }

    private func moveWorklaneFromMenu(id: WorklaneID, direction: SidebarWorklaneMoveDirection) {
        guard let currentIndex = canonicalWorklaneSummaries.firstIndex(where: { $0.worklaneID == id }) else {
            return
        }

        let targetIndex = currentIndex + direction.delta
        guard canonicalWorklaneSummaries.indices.contains(targetIndex) else {
            return
        }

        _ = commitWorklaneReorder(id: id, toIndex: targetIndex)
    }

    private func syncWorklaneMoveAvailability() {
        for button in worklaneButtons {
            guard let worklaneID = button.worklaneID else {
                button.setWorklaneMoveAvailability(.none)
                continue
            }

            button.setWorklaneMoveAvailability(moveAvailability(for: worklaneID))
        }
    }

    private func moveAvailability(for worklaneID: WorklaneID) -> SidebarWorklaneMoveAvailability {
        guard let index = canonicalWorklaneSummaries.firstIndex(where: { $0.worklaneID == worklaneID }),
              canonicalWorklaneSummaries.count > 1 else {
            return .none
        }

        return SidebarWorklaneMoveAvailability(
            canMoveUp: index > 0,
            canMoveDown: index < canonicalWorklaneSummaries.count - 1
        )
    }

    func prepareDraggedWorklaneButton(_ button: SidebarWorklaneRowButton) {
        layoutSubtreeIfNeeded()
        let frameInDocument = listDocumentView.convert(button.bounds, from: button)
        reorderSpacerHeight = frameInDocument.height
        deactivateListStackConstraints(referencing: button)
        listStack.removeArrangedSubview(button)
        if button.superview !== listDocumentView {
            button.removeFromSuperview()
            listDocumentView.addSubview(button)
        }
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = frameInDocument
        button.setReorderDragActive(true)
        button.layer?.zPosition = 100
    }

    func positionDraggedWorklaneButton(
        _ button: SidebarWorklaneRowButton,
        atWindowLocation windowLocation: NSPoint,
        verticalOffset: CGFloat
    ) {
        let point = listDocumentView.convert(windowLocation, from: nil)
        var frame = button.frame
        frame.origin.y = point.y - verticalOffset
        frame.origin.x = 0
        frame.size.width = max(
            listStack.bounds.width,
            listScrollView.contentView.bounds.width,
            frame.width
        )
        button.frame = frame
    }

    func finishDraggedWorklaneButton(_ button: SidebarWorklaneRowButton) {
        button.alphaValue = 1
        button.setReorderDragActive(false)
        button.layer?.zPosition = 0
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    func setHighlightedDropTargetWorklane(_ worklaneID: WorklaneID?) {
        paneDropPresenter.setHighlightedDropTargetWorklane(
            worklaneID,
            buttons: worklaneButtons
        )
    }

    func showNewWorklanePlaceholder(atIndex insertionIndex: Int) {
        paneDropPresenter.showNewWorklanePlaceholder(atIndex: insertionIndex)
    }

    func hideNewWorklanePlaceholder() {
        paneDropPresenter.hideNewWorklanePlaceholder()
    }

    func showInsertionLine(_ target: SidebarPaneInsertionLineTarget) {
        paneDropPresenter.showInsertionLine(target, buttons: worklaneButtons)
    }

    func hideInsertionLine() {
        paneDropPresenter.hideInsertionLine()
    }

    /// Converts a Y coordinate from the given source view (e.g., AppCanvasView)
    /// into the sidebar's listDocumentView coordinate space.
    func convertYForInsertionLine(_ y: CGFloat, from sourceView: NSView) -> CGFloat {
        listDocumentView.convert(CGPoint(x: 0, y: y), from: sourceView).y
    }

    @objc
    private func handleWorklaneButton(_ sender: SidebarWorklaneRowButton) {
        guard let worklaneID = sender.worklaneID else {
            return
        }

        onWorklaneSelected?(worklaneID)
    }

    private func beginWorklaneDrag(button: SidebarWorklaneRowButton, event: NSEvent) -> Bool {
        dragCoordinator.beginDrag(button: button, event: event)
    }

    @objc
    private func handleCreateWorklane() {
        onNewWorklaneRequested?()
    }

    @objc
    private func handleOpenBookmarksPopover() {
        onOpenBookmarksPopoverRequested?(bookmarksButton)
    }

    func setBookmarksPopoverPresented(_ presented: Bool, animated: Bool = true) {
        bookmarksButton.setPopoverPresented(presented, animated: animated)
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        addWorklaneButton.updateShortcutTooltip(shortcutManager)
        bookmarksButton.updateShortcutTooltip(shortcutManager)
    }

    var bookmarksButtonAnchor: NSView {
        bookmarksButton
    }

    @objc
    private func handleCheckForUpdates() {
        guard isUpdateAvailable else {
            return
        }

        onCheckForUpdatesRequested?()
    }

    @objc
    private func handleScrollBoundsDidChange(_ notification: Notification) {
        _ = notification
        Task { @MainActor [weak self] in
            self?.syncShimmerVisibility()
        }
    }

    private func handleResizePan(_ recognizer: NSPanGestureRecognizer) {
        guard isResizeEnabled else {
            return
        }

        switch recognizer.state {
        case .began:
            resizeStartWidth = bounds.width
        case .changed, .ended:
            let translation = recognizer.translation(in: self).x
            onResized?(
                SidebarResizeModel.proposedWidth(
                    startWidth: resizeStartWidth,
                    translation: translation
                )
            )
        default:
            break
        }
    }

#if DEBUG
    var debugAccessForTesting: SidebarViewDebugAccess {
        SidebarViewDebugAccess(
            sidebarView: self,
            renderInvocationCount: renderInvocationCountDebug,
            reorderPreviewLastAnimationDuration: reorderPreviewLastAnimationDurationDebug,
            worklaneButtons: worklaneButtons,
            worklaneSummaries: worklaneSummaries,
            listStack: listStack,
            reorderSpacerView: reorderSpacerView,
            resizeHandleView: resizeHandleView,
            updateAvailableRowView: updateAvailableRowView,
            addWorklaneButton: addWorklaneButton,
            addWorklaneWidthConstraintConstant: addWorklaneWidthConstraint?.constant ?? 0,
            headerView: headerView,
            listScrollView: listScrollView,
            appearance: appearance,
            shimmerDriverIsRunning: shimmerCoordinator.isRunningForTesting,
            performAction: { [weak self] action in
                switch action {
                case .setAddWorklaneHovered(let isHovered):
                    self?.addWorklaneButton.setHoveredForTesting(isHovered)
                case .updateShimmerVisibility:
                    self?.syncShimmerVisibility()
                case .performUpdateAvailableRowClick:
                    self?.updateAvailableRowView.performClickForTesting()
                }
            }
        )
    }
#endif
}

private extension SidebarView {
    func renderDragPreview(animated: Bool) {
#if DEBUG
        reorderPreviewLastAnimationDurationDebug = animated
            ? Layout.reorderPreviewAnimationDuration
            : 0
#endif

        guard animated else {
            render(summaries: canonicalWorklaneSummaries, theme: currentTheme)
            return
        }

        listDocumentView.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.reorderPreviewAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            render(summaries: canonicalWorklaneSummaries, theme: currentTheme)
            listDocumentView.animator().layoutSubtreeIfNeeded()
        }
    }

    func syncReorderSpacer() {
        guard let draggedID = dragPreviewDraggedWorklaneID,
              let dragPreviewOrder,
              let spacerIndex = dragPreviewOrder.firstIndex(of: draggedID) else {
            removeReorderSpacer()
            return
        }

        let spacer = reorderSpacerView ?? makeReorderSpacer()
        spacer.updateHeight(reorderSpacerHeight)
        reorderSpacerView = spacer

        if listStack.arrangedSubviews.contains(spacer) {
            listStack.removeArrangedSubview(spacer)
        }

        let insertionIndex = min(spacerIndex, listStack.arrangedSubviews.count)
        listStack.insertArrangedSubview(spacer, at: insertionIndex)
        ensureReorderSpacerConstraints(spacer)
    }

    func makeReorderSpacer() -> SidebarReorderSpacerView {
        SidebarReorderSpacerView(height: reorderSpacerHeight)
    }

    func ensureReorderSpacerConstraints(_ spacer: SidebarReorderSpacerView) {
        let hasLeadingConstraint = listStack.constraints.contains { constraint in
            constraint.isActive
                && (constraint.firstItem as AnyObject?) === spacer
                && constraint.firstAttribute == .leading
                && (constraint.secondItem as AnyObject?) === listStack
                && constraint.secondAttribute == .leading
        }
        let hasTrailingConstraint = listStack.constraints.contains { constraint in
            constraint.isActive
                && (constraint.firstItem as AnyObject?) === spacer
                && constraint.firstAttribute == .trailing
                && (constraint.secondItem as AnyObject?) === listStack
                && constraint.secondAttribute == .trailing
        }

        var constraints: [NSLayoutConstraint] = []
        if !hasLeadingConstraint {
            constraints.append(spacer.leadingAnchor.constraint(equalTo: listStack.leadingAnchor))
        }
        if !hasTrailingConstraint {
            constraints.append(spacer.trailingAnchor.constraint(equalTo: listStack.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    func removeReorderSpacer() {
        guard let spacer = reorderSpacerView else {
            return
        }

        if listStack.arrangedSubviews.contains(spacer) {
            listStack.removeArrangedSubview(spacer)
        }
        spacer.removeFromSuperview()
        reorderSpacerView = nil
    }

    func restoreArrangedWorklaneButtons() {
        removeReorderSpacer()

        for button in worklaneButtons where listStack.arrangedSubviews.contains(button) {
            listStack.removeArrangedSubview(button)
        }

        let buttonsByID = Dictionary(
            uniqueKeysWithValues: worklaneButtons.compactMap { button in
                button.worklaneID.map { ($0, button) }
            }
        )

        for (index, summary) in canonicalWorklaneSummaries.enumerated() {
            guard let button = buttonsByID[summary.worklaneID] else {
                continue
            }

            button.translatesAutoresizingMaskIntoConstraints = false
            listStack.insertArrangedSubview(button, at: min(index, listStack.arrangedSubviews.count))
            ensureListStackEdgeConstraints(for: button)
        }
    }

    func ensureListStackEdgeConstraints(for button: SidebarWorklaneRowButton) {
        let hasLeadingConstraint = listStack.constraints.contains { constraint in
            constraint.isActive
                && (constraint.firstItem as AnyObject?) === button
                && constraint.firstAttribute == .leading
                && (constraint.secondItem as AnyObject?) === listStack
                && constraint.secondAttribute == .leading
        }
        let hasTrailingConstraint = listStack.constraints.contains { constraint in
            constraint.isActive
                && (constraint.firstItem as AnyObject?) === button
                && constraint.firstAttribute == .trailing
                && (constraint.secondItem as AnyObject?) === listStack
                && constraint.secondAttribute == .trailing
        }

        var constraints: [NSLayoutConstraint] = []
        if !hasLeadingConstraint {
            constraints.append(button.leadingAnchor.constraint(equalTo: listStack.leadingAnchor))
        }
        if !hasTrailingConstraint {
            constraints.append(button.trailingAnchor.constraint(equalTo: listStack.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    func reconcileDragPreview(with summaries: [WorklaneSidebarSummary]) {
        guard let dragPreviewOrder else {
            return
        }

        let summaryIDs = summaries.map(\.worklaneID)
        if dragPreviewOrder.count != summaryIDs.count || Set(dragPreviewOrder) != Set(summaryIDs) {
            self.dragPreviewOrder = nil
            dragPreviewDraggedWorklaneID = nil
        }
    }

    func effectiveSummaries(for summaries: [WorklaneSidebarSummary]) -> [WorklaneSidebarSummary] {
        guard let dragPreviewOrder else {
            return summaries
        }

        let summariesByID = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.worklaneID, $0) }
        )
        let reorderedSummaries = dragPreviewOrder.compactMap { summariesByID[$0] }
        guard reorderedSummaries.count == summaries.count else {
            return summaries
        }
        return reorderedSummaries
    }

    func deactivateListStackConstraints(referencing view: NSView) {
        let constraints = listStack.constraints.filter { constraint in
            (constraint.firstItem as AnyObject?) === view
                || (constraint.secondItem as AnyObject?) === view
        }
        NSLayoutConstraint.deactivate(constraints)
    }

    func applyUpdateAvailability() {
        updateAvailableRowView.isHidden = !isUpdateAvailable
        updateRowHeightConstraint?.constant = isUpdateAvailable ? Layout.updateRowHeight : 0
        listBottomConstraint?.constant = isUpdateAvailable ? -Layout.updateRowSpacing : 0
    }

    func updateHeaderLayoutConstraints() {
        let desiredContentMinX: CGFloat
        switch headerVisibilityMode {
        case .pinnedOpen:
            desiredContentMinX = max(Layout.defaultHeaderContentMinX, headerPinnedContentMinX)
                + ShellMetrics.sidebarCreateWorklanePinnedLeadingPad
        case .hidden, .hoverPeek:
            desiredContentMinX = Layout.defaultHeaderContentMinX
        }

        let buttonLeading = max(
            Layout.contentInset,
            desiredContentMinX - ShellMetrics.sidebarCreateWorklaneHorizontalInset
        )
        addWorklaneLeadingConstraint?.constant = buttonLeading

        let maxAllowedWidth = max(0, bounds.width - buttonLeading - Layout.contentInset)
        addWorklaneWidthConstraint?.constant = maxAllowedWidth

        headerTopConstraint?.constant = headerVisibilityMode == .hoverPeek
            ? ShellMetrics.sidebarHeaderPeekTopInset
            : 0

        addWorklaneCenterYConstraint?.constant = switch headerVisibilityMode {
        case .pinnedOpen: ShellMetrics.sidebarCreateWorklanePinnedVerticalOffset
        case .hoverPeek: ShellMetrics.sidebarCreateWorklanePeekVerticalOffset
        case .hidden: 0
        }
    }

    func updateWindowVisibilityObservation() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        guard let window else {
            shimmerCoordinator.setWindowIsRenderable(false)
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowVisibilityDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    func syncShimmerVisibility() {
        let windowRenderable = windowRenderabilityResolver(window)
        shimmerCoordinator.setWindowIsRenderable(windowRenderable)

        guard windowRenderable else {
            worklaneButtons.forEach { $0.setShimmerVisibility(false) }
            return
        }

        let visibleRect = listScrollView.documentVisibleRect
        worklaneButtons.forEach { button in
            let buttonFrame = button.convert(button.bounds, to: listDocumentView)
            button.setShimmerVisibility(visibleRect.intersects(buttonFrame))
        }
    }
}

private extension SidebarView {
    @objc
    func handleWindowVisibilityDidChange(_ notification: Notification) {
        _ = notification
        Task { @MainActor [weak self] in
            self?.syncShimmerVisibility()
        }
    }
}
