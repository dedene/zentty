import AppKit

@MainActor
final class SidebarView: NSView {
    private enum Layout {
        static let contentInset: CGFloat = ShellMetrics.sidebarContentInset
        static let headerHeight: CGFloat = ShellMetrics.sidebarHeaderHeight
        static let updateRowHeight: CGFloat = 28
        static let updateRowBottomInset: CGFloat = ShellMetrics.sidebarContentInset
        static let updateRowSpacing: CGFloat = 8
        static let resizeHandleWidth: CGFloat = 4
        static let defaultHeaderContentMinX: CGFloat =
            ShellMetrics.sidebarContentInset + ShellMetrics.sidebarCreateWorklaneHorizontalInset
    }

    var onWorklaneSelected: ((WorklaneID) -> Void)?
    var onPaneSelected: ((WorklaneID, PaneID) -> Void)?
    var onCloseWorklaneRequested: ((WorklaneID, PaneID) -> Void)?
    var onClosePaneRequested: ((WorklaneID, PaneID) -> Void)?
    var onSplitHorizontalRequested: ((WorklaneID, PaneID) -> Void)?
    var onSplitVerticalRequested: ((WorklaneID, PaneID) -> Void)?
    var onNewWorklaneRequested: (() -> Void)?
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
    private let resizeHandleView = SidebarResizeHandleView()
    private let shimmerCoordinator = SidebarShimmerCoordinator()

    private var worklaneButtons: [SidebarWorklaneRowButton] = []
    /// Retained until the removal animation completes, then nilled.
    private var pendingRemovalButtons: [SidebarWorklaneRowButton]?
    private var worklaneSummaries: [WorklaneSidebarSummary] = []
    private var addWorklaneLeadingConstraint: NSLayoutConstraint?
    private var addWorklaneWidthConstraint: NSLayoutConstraint?
    private var addWorklaneCenterYConstraint: NSLayoutConstraint?
    private var headerTopConstraint: NSLayoutConstraint?
    private var listBottomConstraint: NSLayoutConstraint?
    private var updateRowHeightConstraint: NSLayoutConstraint?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private(set) var renderInvocationCountForTesting: Int = 0
    private var headerPinnedContentMinX = Layout.defaultHeaderContentMinX
    private var headerVisibilityMode: SidebarVisibilityMode = .pinnedOpen
    private var resizeStartWidth: CGFloat = SidebarWidthPreference.defaultWidth
    private var trackingArea: NSTrackingArea?
    private var isResizeEnabled = true
    private var isUpdateAvailable = false
    private var dropPlaceholder: SidebarDropPlaceholderView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

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
                lessThanOrEqualTo: headerView.trailingAnchor,
                constant: -Layout.contentInset
            ),
            addWorklaneWidthConstraint,
            addWorklaneCenterYConstraint,
            addWorklaneButton.topAnchor.constraint(
                greaterThanOrEqualTo: headerView.topAnchor
            ),
            addWorklaneButton.bottomAnchor.constraint(
                lessThanOrEqualTo: headerView.bottomAnchor
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

    /// When true, insert/remove mutations animate via NSStackView's
    /// `isHidden` collapse mechanism. Set to false to fall back to the
    /// pre-Phase-2 instant wipe-and-rebuild behavior.
    static var structuralAnimationEnabled = true

    func render(
        summaries: [WorklaneSidebarSummary],
        theme: ZenttyTheme
    ) {
        if summaries == worklaneSummaries,
           theme == currentTheme,
           worklaneButtons.map(\.worklaneID) == summaries.map(\.worklaneID) {
            return
        }

        renderInvocationCountForTesting &+= 1
        let previousActiveID = worklaneSummaries.first(where: \.isActive)?.worklaneID
        let previousSummaries = worklaneSummaries
        worklaneSummaries = summaries
        currentTheme = theme

        let diff = SidebarRowDiff.compute(old: previousSummaries, new: summaries)

        if !diff.hasStructuralChange {
            // Same IDs — apply theme + content updates in place.
            apply(theme: theme, animated: true)
        } else if Self.structuralAnimationEnabled {
            renderStructuralDiff(diff, summaries: summaries, theme: theme)
        } else {
            renderWipeAndRebuild(summaries: summaries, theme: theme)
        }

        worklaneButtons.forEach { $0.setShimmerCoordinator(shimmerCoordinator) }
        syncShimmerVisibility()
        shimmerCoordinator.labelStateDidChange()

        let newActiveID = summaries.first(where: \.isActive)?.worklaneID
        if newActiveID != previousActiveID, let newActiveID {
            listStack.layoutSubtreeIfNeeded()
            if !isWorklaneVisible(id: newActiveID) {
                scrollToWorklane(id: newActiveID)
            }
        }
    }

    // MARK: - Diff-based structural mutation (Phase 2)

    /// Applies a structural diff (insertions, removals, moves, updates)
    /// to the sidebar button list with animated transitions. Surviving
    /// buttons are REUSED — their hover, focus, tooltip, and shimmer
    /// state is preserved across the mutation.
    private func renderStructuralDiff(
        _ diff: SidebarRowDiff,
        summaries: [WorklaneSidebarSummary],
        theme: ZenttyTheme
    ) {
        // Build lookup: worklaneID → existing button instance.
        var buttonsByID: [WorklaneID: SidebarWorklaneRowButton] = [:]
        for button in worklaneButtons {
            if let id = button.worklaneID {
                buttonsByID[id] = button
            }
        }

        // Create new buttons for insertions (hidden + transparent).
        var insertedButtons: [WorklaneID: SidebarWorklaneRowButton] = [:]
        for insertion in diff.insertions {
            let summary = insertion.summary
            let button = makeWorklaneButton(for: summary)
            button.configure(with: summary, theme: theme, animated: false)
            button.isHidden = true
            button.alphaValue = 0
            insertedButtons[summary.worklaneID] = button
        }

        // Identify buttons that will be removed.
        let removedIDs = Set(diff.removals.map(\.worklaneID))
        var pendingRemovalButtons: [SidebarWorklaneRowButton] = []
        for removal in diff.removals {
            if let button = buttonsByID[removal.worklaneID] {
                pendingRemovalButtons.append(button)
            }
        }

        // Build the target button array in new order.
        var targetButtons: [SidebarWorklaneRowButton] = []
        for summary in summaries {
            let id = summary.worklaneID
            if let existing = buttonsByID[id] {
                targetButtons.append(existing)
            } else if let inserted = insertedButtons[id] {
                targetButtons.append(inserted)
            }
        }

        // Rebuild the arranged subview list with only target buttons.
        // Removed buttons are NOT re-added as arranged subviews —
        // their space collapses instantly. We only animate their opacity
        // to 0 so they fade out gracefully while the layout snaps.
        // Re-adding them at the end of the stack caused ghost artifacts
        // (visible as text overlap / lingering rows below surviving items).
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
        }
        for button in targetButtons {
            listStack.addArrangedSubview(button)
            // Only new buttons need explicit edge constraints.
            if let id = button.worklaneID, insertedButtons[id] != nil {
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
                ])
            }
        }

        // Immediately hide removed buttons so they don't occupy visual
        // space, then fade their alpha in the animation block for a
        // clean disappearance. They stay in the superview (not arranged)
        // until the completion handler removes them.
        for button in pendingRemovalButtons {
            button.isHidden = true
        }

        // Capture before the closure for Swift 6 concurrency safety.
        let buttonsToRemove = pendingRemovalButtons

        // Animate the visibility transitions.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            // Removals: fade out (space already collapsed above).
            for button in buttonsToRemove {
                button.animator().alphaValue = 0
            }

            // Insertions: expand space + fade in.
            for (_, button) in insertedButtons {
                button.isHidden = false
                button.animator().alphaValue = 1
            }

            // Updates: re-configure surviving buttons with new content.
            for update in diff.updates {
                buttonsByID[update.worklaneID]?.configure(
                    with: update.summary,
                    theme: theme,
                    animated: true
                )
            }
        } completionHandler: { [weak self] in
            for button in buttonsToRemove where button.superview != nil {
                button.removeFromSuperview()
            }
            self?.pendingRemovalButtons?.removeAll(where: {
                buttonsToRemove.contains($0)
            })
        }

        // Append (don't overwrite) to handle rapid re-render during
        // a 0.22s animation — the previous batch's completion handler
        // drains its own captured set.
        if self.pendingRemovalButtons != nil {
            self.pendingRemovalButtons?.append(contentsOf: pendingRemovalButtons)
        } else {
            self.pendingRemovalButtons = pendingRemovalButtons
        }
        worklaneButtons = targetButtons

        // Apply theme to sidebar chrome (add-worklane button, resize handle, etc.)
        // without re-configuring worklane buttons (they're already correct).
        applySidebarChrome(theme: theme, animated: true)
    }

    /// Fallback: the pre-Phase-2 wipe-and-rebuild path. Used when
    /// `structuralAnimationEnabled` is false.
    private func renderWipeAndRebuild(
        summaries: [WorklaneSidebarSummary],
        theme: ZenttyTheme
    ) {
        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        worklaneButtons.removeAll(keepingCapacity: true)

        for summary in summaries {
            let button = makeWorklaneButton(for: summary)
            button.setShimmerCoordinator(shimmerCoordinator)
            button.configure(with: summary, theme: theme, animated: false)
            worklaneButtons.append(button)
            listStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            ])
        }

        apply(theme: theme, animated: true)
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
        button.onCloseWorklaneRequested = { [weak self] paneID in
            self?.onCloseWorklaneRequested?(worklaneID, paneID)
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

        button.setShimmerCoordinator(shimmerCoordinator)
        return button
    }

    /// Applies theme to sidebar chrome (appearances, background, add-button,
    /// resize handle) WITHOUT re-configuring worklane buttons. Use after
    /// structural mutations where buttons are already configured.
    private func applySidebarChrome(theme: ZenttyTheme, animated: Bool) {
        let sidebarAppearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        appearance = sidebarAppearance
        listScrollView.appearance = sidebarAppearance
        listDocumentView.appearance = sidebarAppearance
        listStack.appearance = sidebarAppearance
        addWorklaneButton.configure(theme: theme, animated: animated)
        updateAvailableRowView.configure(theme: theme, animated: animated)
        resizeHandleView.apply(theme: theme, animated: animated)
        backgroundView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
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
        let sidebarAppearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        appearance = sidebarAppearance
        listScrollView.appearance = sidebarAppearance
        listDocumentView.appearance = sidebarAppearance
        listStack.appearance = sidebarAppearance
        addWorklaneButton.configure(theme: theme, animated: animated)
        updateAvailableRowView.configure(theme: theme, animated: animated)
        resizeHandleView.apply(theme: theme, animated: animated)
        backgroundView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }

        worklaneButtons.enumerated().forEach { index, button in
            guard worklaneSummaries.indices.contains(index) else {
                return
            }
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

    func setUpdateAvailable(_ isUpdateAvailable: Bool, animated: Bool = false) {
        _ = animated
        guard self.isUpdateAvailable != isUpdateAvailable else {
            return
        }

        self.isUpdateAvailable = isUpdateAvailable
        applyUpdateAvailability()
    }

    func adjustScrollOffset(by delta: CGFloat) {
        guard let clipView = listScrollView.contentView as? NSClipView else { return }
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

    func setHighlightedDropTargetWorklane(_ worklaneID: WorklaneID?) {
        for button in worklaneButtons {
            button.setDropTargetHighlighted(button.worklaneID == worklaneID)
        }
    }

    func showNewWorklanePlaceholder() {
        guard dropPlaceholder == nil else { return }

        let placeholder = SidebarDropPlaceholderView()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            placeholder.heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCompactRowHeight),
        ])
        dropPlaceholder = placeholder
        placeholder.animateIn()
    }

    func hideNewWorklanePlaceholder() {
        guard let placeholder = dropPlaceholder else { return }
        placeholder.animateOut { [weak self] in
            placeholder.removeFromSuperview()
            self?.dropPlaceholder = nil
        }
    }

    @objc
    private func handleWorklaneButton(_ sender: SidebarWorklaneRowButton) {
        guard let worklaneID = sender.worklaneID else {
            return
        }

        onWorklaneSelected?(worklaneID)
    }

    @objc
    private func handleCreateWorklane() {
        onNewWorklaneRequested?()
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
                resolvedResizeWidth(
                    startWidth: resizeStartWidth,
                    translation: translation,
                    availableWidth: window?.contentView?.bounds.width
                )
            )
        default:
            break
        }
    }

    private func resolvedResizeWidth(
        startWidth: CGFloat,
        translation: CGFloat,
        availableWidth: CGFloat?
    ) -> CGFloat {
        _ = availableWidth
        return startWidth + translation
    }

    var worklanePrimaryTexts: [String] {
        worklaneSummaries.map(\.primaryText)
    }

    var worklaneContextTexts: [String] {
        worklaneSummaries.map(\.contextText)
    }

    var worklaneButtonsForTesting: [NSButton] {
        worklaneButtons
    }

    var addWorklaneTitle: String {
        addWorklaneButton.titleText
    }

    var isHeaderHidden: Bool {
        headerView.isHidden
    }

    var hasVisibleDivider: Bool {
        false
    }

    var firstWorklaneTopInset: CGFloat {
        guard let firstButton = worklaneButtons.first else {
            return .greatestFiniteMagnitude
        }

        let buttonFrame = convert(firstButton.bounds, from: firstButton)
        return listScrollView.frame.maxY - buttonFrame.maxY
    }

    var firstWorklaneMinY: CGFloat {
        guard let firstButton = worklaneButtons.first else {
            return 0
        }

        return convert(firstButton.bounds, from: firstButton).minY
    }

    var firstWorklaneMaxY: CGFloat {
        guard let firstButton = worklaneButtons.first else {
            return 0
        }

        return convert(firstButton.bounds, from: firstButton).maxY
    }

    var addWorklaneMinY: CGFloat {
        convert(addWorklaneButton.bounds, from: addWorklaneButton).minY
    }

    var addWorklaneMaxY: CGFloat {
        convert(addWorklaneButton.bounds, from: addWorklaneButton).maxY
    }

    var addWorklaneButtonMinX: CGFloat {
        convert(addWorklaneButton.bounds, from: addWorklaneButton).minX
    }

    var addWorklaneButtonWidth: CGFloat {
        convert(addWorklaneButton.bounds, from: addWorklaneButton).width
    }

    var addWorklaneButtonMidY: CGFloat {
        convert(addWorklaneButton.bounds, from: addWorklaneButton).midY
    }

    var firstWorklaneWidth: CGFloat {
        worklaneButtons.first.map { convert($0.bounds, from: $0).width } ?? 0
    }

    var firstWorklanePrimaryMinX: CGFloat {
        worklaneButtons.first.map { $0.primaryMinX(in: self) } ?? 0
    }

    var secondWorklanePrimaryMinX: CGFloat {
        guard worklaneButtons.count > 1 else {
            return 0
        }

        return worklaneButtons[1].primaryMinX(in: self)
    }

    var worklaneDetailTexts: [[String]] {
        worklaneButtons.map(\.detailTextsForTesting)
    }

    var worklaneOverflowTexts: [String] {
        worklaneButtons.map(\.overflowTextForTesting)
    }

    var addWorklaneContentMinX: CGFloat {
        addWorklaneButton.contentMinX(in: self)
    }

    var addWorklaneWidthConstraintConstant: CGFloat {
        addWorklaneWidthConstraint?.constant ?? 0
    }

    var addWorklaneContentMidX: CGFloat {
        addWorklaneButton.contentMidX(in: self)
    }

    var addWorklaneIconAlpha: CGFloat {
        addWorklaneButton.iconAlpha
    }

    var addWorklaneTitleAlpha: CGFloat {
        addWorklaneButton.titleAlpha
    }

    var addWorklaneBackgroundAlpha: CGFloat {
        addWorklaneButton.backgroundAlpha
    }

    var addWorklaneBorderAlpha: CGFloat {
        addWorklaneButton.borderAlpha
    }

    var addWorklaneUsesPointingHandCursor: Bool {
        addWorklaneButton.usesPointingHandCursorForTesting
    }

    func setAddWorklaneHoveredForTesting(_ isHovered: Bool) {
        addWorklaneButton.setHoveredForTesting(isHovered)
    }

    var resizeHandleMinX: CGFloat {
        resizeHandleView.frame.minX
    }

    var resizeHandleMaxX: CGFloat {
        resizeHandleView.frame.maxX
    }

    var resizeHandleFillAlpha: CGFloat {
        resizeHandleView.fillAlpha
    }

    var resizeHandleWidthForTesting: CGFloat {
        resizeHandleView.frame.width
    }

    var isResizeHandleHidden: Bool {
        resizeHandleView.isHidden
    }

    var trailingEdgeHitTargetsResizeHandle: Bool {
        hitTest(NSPoint(x: bounds.maxX - 1, y: bounds.midY)) === resizeHandleView
    }

    func hitTargetsResizeHandle(atX x: CGFloat) -> Bool {
        hitTest(NSPoint(x: x, y: bounds.midY)) === resizeHandleView
    }

    var appearanceMatchForTesting: NSAppearance.Name? {
        appearance?.bestMatch(from: [.darkAqua, .aqua])
    }

    var shimmerDriverIsRunningForTesting: Bool {
        shimmerCoordinator.isRunningForTesting
    }

    func updateShimmerVisibilityForTesting() {
        syncShimmerVisibility()
    }

    var isUpdateRowHiddenForTesting: Bool {
        updateAvailableRowView.isHidden
    }

    var isUpdateAvailableRowVisible: Bool {
        !updateAvailableRowView.isHidden
    }

    var updateAvailableRowHeightForTesting: CGFloat {
        updateAvailableRowView.frame.height
    }

    func performUpdateAvailableRowClickForTesting() {
        updateAvailableRowView.performClickForTesting()
    }

    func proposedResizeWidthForTesting(
        startWidth: CGFloat,
        translation: CGFloat,
        availableWidth: CGFloat?
    ) -> CGFloat {
        resolvedResizeWidth(
            startWidth: startWidth,
            translation: translation,
            availableWidth: availableWidth
        )
    }
}

private extension SidebarView {
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

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

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
        let windowRenderable: Bool
        if let window {
            let isOccluded: Bool
            if Self.isRunningTests {
                isOccluded = false
            } else {
                let occlusionState = window.occlusionState
                isOccluded = !occlusionState.isEmpty && !occlusionState.contains(.visible)
            }
            windowRenderable = window.isVisible && !window.isMiniaturized && !isOccluded
        } else {
            windowRenderable = false
        }
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

private final class FlippedSidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarUpdateAvailableRowView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 12
        static let iconLabelSpacing: CGFloat = 8
        static let iconSize: CGFloat = 14
        static let fontSize: CGFloat = 13
        static let nestedBottomRadius = ChromeGeometry.innerRadius(
            outerRadius: ShellMetrics.sidebarRadius,
            inset: ShellMetrics.sidebarContentInset
        )
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Update available")
    private let contentStack = NSStackView()
    var onPressed: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = Layout.nestedBottomRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner,
        ]
        setAccessibilityLabel("Update available")
        setAccessibilityRole(.button)

        iconView.image = NSImage(
            systemSymbolName: "archivebox.fill",
            accessibilityDescription: "Update available"
        )?.withSymbolConfiguration(.init(pointSize: Layout.iconSize, weight: .semibold))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: Layout.fontSize, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = Layout.iconLabelSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        let clickGestureRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleClickGesture)
        )
        addGestureRecognizer(clickGestureRecognizer)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Layout.horizontalPadding
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Layout.horizontalPadding
            ),
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
        ])
    }

    @objc
    private func handleClickGesture() {
        onPressed?()
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        let tint = NSColor.systemBlue
        let background = theme.sidebarBackground
            .mixed(towards: tint, amount: theme.sidebarBackground.isDarkThemeColor ? 0.34 : 0.16)
            .withAlphaComponent(theme.sidebarBackground.isDarkThemeColor ? 0.80 : 0.94)
        let text = tint
            .mixed(towards: theme.primaryText, amount: theme.sidebarBackground.isDarkThemeColor ? 0.14 : 0.06)
            .withAlphaComponent(0.98)
        let border = tint.withAlphaComponent(theme.sidebarBackground.isDarkThemeColor ? 0.22 : 0.16)

        titleLabel.textColor = text
        iconView.contentTintColor = text

        performThemeAnimation(animated: animated) {
            self.layer?.cornerRadius = Layout.nestedBottomRadius
            self.layer?.maskedCorners = [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
            self.layer?.borderWidth = 1
        }
    }

    func performClickForTesting() {
        onPressed?()
    }
}

private final class SidebarCreateWorklaneButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New worklane")
    private let contentStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var backgroundColorForTesting = NSColor.clear
    private var borderColorForTesting = NSColor.clear
    private(set) var isHovered = false

    override var isHighlighted: Bool {
        didSet {
            applyCurrentAppearance(animated: true)
        }
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentStack.fittingSize
        return NSSize(
            width: contentSize.width + (ShellMetrics.sidebarCreateWorklaneHorizontalInset * 2),
            height: ShellMetrics.sidebarCreateWorklaneButtonHeight
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

    private func setup() {
        title = ""
        setAccessibilityLabel("New worklane")
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        font = NSFont.systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCreateWorklaneButtonHeight).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New worklane"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = ShellMetrics.sidebarCreateWorklaneIconSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        let leading = contentStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ShellMetrics.sidebarCreateWorklaneHorizontalInset
        )
        leading.priority = .defaultHigh

        let trailing = contentStack.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -ShellMetrics.sidebarCreateWorklaneHorizontalInset
        )
        trailing.priority = .defaultHigh

        let iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            leading,
            trailing,
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        if let cell = cell as? NSButtonCell {
            cell.alignment = .left
            cell.imagePosition = .noImage
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else {
            return
        }

        isHovered = true
        applyCurrentAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        applyCurrentAppearance(animated: true)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        titleLabel.stringValue = "New worklane"
        invalidateIntrinsicContentSize()
        applyCurrentAppearance(animated: animated)
    }

    var titleText: String {
        titleLabel.stringValue
    }

    var iconAlpha: CGFloat {
        iconView.contentTintColor?.alphaComponent ?? 0
    }

    var titleAlpha: CGFloat {
        titleLabel.textColor?.alphaComponent ?? 0
    }

    var backgroundAlpha: CGFloat {
        backgroundColorForTesting.alphaComponent
    }

    var borderAlpha: CGFloat {
        borderColorForTesting.alphaComponent
    }

    var usesPointingHandCursorForTesting: Bool {
        true
    }

    func contentMinX(in view: NSView) -> CGFloat {
        view.convert(contentStack.bounds, from: contentStack).minX
    }

    func contentMidX(in view: NSView) -> CGFloat {
        view.convert(contentStack.bounds, from: contentStack).midX
    }

    func setHoveredForTesting(_ isHovered: Bool) {
        self.isHovered = isHovered
        applyCurrentAppearance(animated: false)
    }

    private func applyCurrentAppearance(animated: Bool) {
        let isEmphasized = isHovered || isHighlighted
        let titleColor = isEmphasized
            ? currentTheme.primaryText.withAlphaComponent(0.96)
            : currentTheme.secondaryText.withAlphaComponent(0.90)
        let iconColor = isEmphasized
            ? currentTheme.secondaryText.withAlphaComponent(0.92)
            : currentTheme.tertiaryText.withAlphaComponent(0.68)
        let backgroundColor: NSColor
        if isEmphasized {
            let hoverMix: CGFloat = currentTheme.sidebarBackground.isDarkThemeColor ? 0.12 : 0.18
            backgroundColor = currentTheme.sidebarBackground
                .mixed(towards: currentTheme.primaryText, amount: hoverMix)
                .withAlphaComponent(min(1, currentTheme.sidebarBackground.alphaComponent + 0.10))
        } else {
            backgroundColor = .clear
        }

        titleLabel.textColor = titleColor
        iconView.contentTintColor = iconColor
        backgroundColorForTesting = backgroundColor
        borderColorForTesting = .clear

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 0
        }
    }
}

private final class SidebarResizeHandleView: NSView {
    var onPan: ((NSPanGestureRecognizer) -> Void)?

    private var panRecognizer: NSPanGestureRecognizer?
    private var trackingArea: NSTrackingArea?
    private(set) var isEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("Resize sidebar")
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
        panRecognizer = recognizer
        updateIndicatorAppearance(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidatePointerAffordances()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else {
            return
        }

        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else {
            return
        }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        guard isEnabled else {
            return
        }

        NSCursor.resizeLeftRight.set()
    }

    func apply(theme _: ZenttyTheme, animated: Bool) {
        updateIndicatorAppearance(animated: animated)
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        panRecognizer?.isEnabled = isEnabled
        isHidden = !isEnabled
        invalidatePointerAffordances()
        updateIndicatorAppearance(animated: false)
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard isEnabled else {
            return
        }
        onPan?(recognizer)
    }

    private func updateIndicatorAppearance(animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func invalidatePointerAffordances() {
        updateTrackingAreas()
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    var fillAlpha: CGFloat {
        (layer?.backgroundColor)
            .flatMap { NSColor(cgColor: $0) }?
            .alphaComponent ?? 0
    }
}
