import AppKit

@MainActor
final class SidebarView: NSView {
    private enum Layout {
        static let contentInset: CGFloat = ShellMetrics.sidebarContentInset
        static let topInset: CGFloat = ShellMetrics.sidebarTopInset
        static let bottomInset: CGFloat = ShellMetrics.sidebarBottomInset
        static let resizeHandleWidth: CGFloat = 4
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
    private let listScrollView = NSScrollView()
    private let listDocumentView = FlippedSidebarDocumentView()
    private let listStack = NSStackView()
    private let addWorklaneButton = SidebarFooterButton()
    private let resizeHandleView = SidebarResizeHandleView()
    private let shimmerCoordinator = SidebarShimmerCoordinator()

    private var worklaneButtons: [SidebarWorklaneRowButton] = []
    private var worklaneSummaries: [WorklaneSidebarSummary] = []
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var resizeStartWidth: CGFloat = SidebarWidthPreference.defaultWidth
    private var trackingArea: NSTrackingArea?
    private var isResizeEnabled = true

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
        addWorklaneButton.target = self
        addWorklaneButton.action = #selector(handleCreateWorklane)

        resizeHandleView.translatesAutoresizingMaskIntoConstraints = false
        resizeHandleView.onPan = { [weak self] recognizer in
            self?.handleResizePan(recognizer)
        }

        addSubview(backgroundView)
        addSubview(listScrollView)
        addSubview(resizeHandleView)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            listScrollView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.topInset),
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

            if let lastWorklaneButton = worklaneButtons.last {
                listStack.setCustomSpacing(8, after: lastWorklaneButton)
            }

            addWorklaneButton.configure(theme: currentTheme, animated: false)
            listStack.addArrangedSubview(addWorklaneButton)
            NSLayoutConstraint.activate([
                addWorklaneButton.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                addWorklaneButton.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            ])
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

    func setResizeEnabled(_ isEnabled: Bool) {
        isResizeEnabled = isEnabled
        resizeHandleView.setEnabled(isEnabled)
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
                    availableWidth: window?.screen?.visibleFrame.width
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
        true
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

    var addWorklaneContentMidX: CGFloat {
        addWorklaneButton.contentMidX(in: self)
    }

    var addWorklaneIconAlpha: CGFloat {
        addWorklaneButton.iconAlpha
    }

    var addWorklaneTitleAlpha: CGFloat {
        addWorklaneButton.titleAlpha
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

private final class SidebarFooterButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New worklane")
    private let contentStack = NSStackView()

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
        layer?.masksToBounds = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellMetrics.footerHeight).isActive = true

        iconView.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New worklane"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = ShellMetrics.sidebarFooterIconSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: ShellMetrics.sidebarRowHorizontalInset),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ShellMetrics.sidebarRowHorizontalInset),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        if let cell = cell as? NSButtonCell {
            cell.alignment = .left
            cell.imagePosition = .noImage
        }
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        let titleColor = theme.secondaryText.withAlphaComponent(0.90)
        let iconColor = theme.tertiaryText.withAlphaComponent(0.68)
        titleLabel.textColor = titleColor
        titleLabel.stringValue = "New worklane"
        iconView.contentTintColor = iconColor

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 0
        }
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

    func contentMinX(in view: NSView) -> CGFloat {
        view.convert(contentStack.bounds, from: contentStack).minX
    }

    func contentMidX(in view: NSView) -> CGFloat {
        view.convert(contentStack.bounds, from: contentStack).midX
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
