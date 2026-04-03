import AppKit

@MainActor
final class SidebarView: NSView {
    private enum Layout {
        static let contentInset: CGFloat = ShellMetrics.sidebarContentInset
        static let headerHeight: CGFloat = ShellMetrics.sidebarHeaderHeight
        static let bottomInset: CGFloat = ShellMetrics.sidebarBottomInset
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
    var onResized: ((CGFloat) -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let backgroundView = GlassSurfaceView(style: .sidebar)
    private let headerView = NSView()
    private let listScrollView = NSScrollView()
    private let listDocumentView = FlippedSidebarDocumentView()
    private let listStack = NSStackView()
    private let addWorklaneButton = SidebarCreateWorklaneButton()
    private let resizeHandleView = SidebarResizeHandleView()
    private let shimmerCoordinator = SidebarShimmerCoordinator()

    private var worklaneButtons: [SidebarWorklaneRowButton] = []
    private var worklaneSummaries: [WorklaneSidebarSummary] = []
    private var addWorklaneLeadingConstraint: NSLayoutConstraint?
    private var addWorklaneWidthConstraint: NSLayoutConstraint?
    private var addWorklaneCenterYConstraint: NSLayoutConstraint?
    private var headerTopConstraint: NSLayoutConstraint?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var headerPinnedContentMinX = Layout.defaultHeaderContentMinX
    private var headerVisibilityMode: SidebarVisibilityMode = .pinnedOpen
    private var resizeStartWidth: CGFloat = SidebarWidthPreference.defaultWidth
    private var trackingArea: NSTrackingArea?
    private var isResizeEnabled = true
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

        addSubview(backgroundView)
        addSubview(headerView)
        addSubview(listScrollView)
        addSubview(resizeHandleView)

        headerView.addSubview(addWorklaneButton)

        let addWorklaneLeadingConstraint = addWorklaneButton.leadingAnchor.constraint(
            equalTo: headerView.leadingAnchor,
            constant: Layout.contentInset
        )
        self.addWorklaneLeadingConstraint = addWorklaneLeadingConstraint
        let addWorklaneWidthConstraint = addWorklaneButton.widthAnchor.constraint(
            equalToConstant: 0
        )
        self.addWorklaneWidthConstraint = addWorklaneWidthConstraint
        let addWorklaneCenterYConstraint = addWorklaneButton.centerYAnchor.constraint(
            equalTo: headerView.centerYAnchor
        )
        self.addWorklaneCenterYConstraint = addWorklaneCenterYConstraint

        let headerTopConstraint = headerView.topAnchor.constraint(equalTo: topAnchor)
        self.headerTopConstraint = headerTopConstraint

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
            listScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.bottomInset),

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

    func render(
        summaries: [WorklaneSidebarSummary],
        theme: ZenttyTheme
    ) {
        let previousActiveID = worklaneSummaries.first(where: \.isActive)?.worklaneID
        worklaneSummaries = summaries

        let oldIDs = worklaneButtons.map(\.worklaneID)
        let newIDs = summaries.map(\.worklaneID)

        if oldIDs == newIDs {
            apply(theme: theme, animated: true)
        } else {
            apply(theme: theme, animated: true)

            listStack.arrangedSubviews.forEach { view in
                listStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            worklaneButtons.removeAll(keepingCapacity: true)

            for summary in summaries {
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
                button.configure(
                    with: summary,
                    theme: currentTheme,
                    animated: false
                )
                worklaneButtons.append(button)
                listStack.addArrangedSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
                ])
            }
        }

        worklaneButtons.forEach { $0.setShimmerCoordinator(shimmerCoordinator) }
        syncShimmerVisibility()

        let newActiveID = summaries.first(where: \.isActive)?.worklaneID
        if newActiveID != previousActiveID, let newActiveID {
            listStack.layoutSubtreeIfNeeded()
            scrollToWorklane(id: newActiveID)
        }
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
                SidebarWidthPreference.clamped(
                    resizeStartWidth + translation,
                    availableWidth: window?.contentView?.bounds.width
                )
            )
        default:
            break
        }
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
}

private extension SidebarView {
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
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

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
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = ShellMetrics.sidebarCreateWorklaneIconSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
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
