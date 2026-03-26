import AppKit

@MainActor
final class SidebarView: NSView {
    private enum Layout {
        static let contentInset: CGFloat = ShellMetrics.sidebarContentInset
        static let topInset: CGFloat = ShellMetrics.sidebarTopInset
        static let bottomInset: CGFloat = ShellMetrics.sidebarBottomInset
        static let resizeHandleWidth: CGFloat = 12
    }

    var onWorkspaceSelected: ((WorkspaceID) -> Void)?
    var onPaneSelected: ((WorkspaceID, PaneID) -> Void)?
    var onCloseWorkspaceRequested: ((WorkspaceID, PaneID) -> Void)?
    var onClosePaneRequested: ((WorkspaceID, PaneID) -> Void)?
    var onSplitHorizontalRequested: ((WorkspaceID, PaneID) -> Void)?
    var onSplitVerticalRequested: ((WorkspaceID, PaneID) -> Void)?
    var onNewWorkspaceRequested: (() -> Void)?
    var onResized: ((CGFloat) -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let backgroundView = GlassSurfaceView(style: .sidebar)
    private let listScrollView = NSScrollView()
    private let listDocumentView = FlippedSidebarDocumentView()
    private let listStack = NSStackView()
    private let addWorkspaceButton = SidebarFooterButton()
    private let resizeHandleView = SidebarResizeHandleView()

    private var workspaceButtons: [SidebarWorkspaceRowButton] = []
    private var workspaceSummaries: [WorkspaceSidebarSummary] = []
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

        addWorkspaceButton.translatesAutoresizingMaskIntoConstraints = false
        addWorkspaceButton.target = self
        addWorkspaceButton.action = #selector(handleCreateWorkspace)

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isResizeEnabled, !resizeHandleView.isHidden, resizeHandleView.frame.contains(point) else {
            return super.hitTest(point)
        }

        return resizeHandleView
    }

    func render(
        summaries: [WorkspaceSidebarSummary],
        theme: ZenttyTheme
    ) {
        let previousActiveID = workspaceSummaries.first(where: \.isActive)?.workspaceID
        workspaceSummaries = summaries

        let oldIDs = workspaceButtons.map(\.workspaceID)
        let newIDs = summaries.map(\.workspaceID)

        if oldIDs == newIDs {
            apply(theme: theme, animated: true)
        } else {
            apply(theme: theme, animated: true)

            listStack.arrangedSubviews.forEach { view in
                listStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            workspaceButtons.removeAll(keepingCapacity: true)

            for summary in summaries {
                let button = SidebarWorkspaceRowButton(workspaceID: summary.workspaceID)
                button.target = self
                button.action = #selector(handleWorkspaceButton(_:))

                let workspaceID = summary.workspaceID
                button.onPaneSelected = { [weak self] paneID in
                    self?.onPaneSelected?(workspaceID, paneID)
                }
                button.onCloseWorkspaceRequested = { [weak self] paneID in
                    self?.onCloseWorkspaceRequested?(workspaceID, paneID)
                }
                button.onClosePaneRequested = { [weak self] paneID in
                    self?.onClosePaneRequested?(workspaceID, paneID)
                }
                button.onSplitHorizontalRequested = { [weak self] paneID in
                    self?.onSplitHorizontalRequested?(workspaceID, paneID)
                }
                button.onSplitVerticalRequested = { [weak self] paneID in
                    self?.onSplitVerticalRequested?(workspaceID, paneID)
                }

                button.configure(
                    with: summary,
                    theme: currentTheme,
                    animated: false
                )
                workspaceButtons.append(button)
                listStack.addArrangedSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
                ])
            }

            if let lastWorkspaceButton = workspaceButtons.last {
                listStack.setCustomSpacing(8, after: lastWorkspaceButton)
            }

            addWorkspaceButton.configure(theme: currentTheme, animated: false)
            listStack.addArrangedSubview(addWorkspaceButton)
            NSLayoutConstraint.activate([
                addWorkspaceButton.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                addWorkspaceButton.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            ])
        }

        let newActiveID = summaries.first(where: \.isActive)?.workspaceID
        if newActiveID != previousActiveID, let newActiveID {
            listStack.layoutSubtreeIfNeeded()
            scrollToWorkspace(id: newActiveID)
        }
    }

    private func scrollToWorkspace(id: WorkspaceID) {
        guard let index = workspaceSummaries.firstIndex(where: { $0.workspaceID == id }),
              workspaceButtons.indices.contains(index) else {
            return
        }
        let button = workspaceButtons[index]
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
        addWorkspaceButton.configure(theme: theme, animated: animated)
        resizeHandleView.apply(theme: theme, animated: animated)
        backgroundView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }

        workspaceButtons.enumerated().forEach { index, button in
            guard workspaceSummaries.indices.contains(index) else {
                return
            }
            button.configure(
                with: workspaceSummaries[index],
                theme: theme,
                animated: animated
            )
        }
    }

    func setResizeEnabled(_ isEnabled: Bool) {
        isResizeEnabled = isEnabled
        resizeHandleView.setEnabled(isEnabled)
    }

    @objc
    private func handleWorkspaceButton(_ sender: SidebarWorkspaceRowButton) {
        guard let workspaceID = sender.workspaceID else {
            return
        }

        onWorkspaceSelected?(workspaceID)
    }

    @objc
    private func handleCreateWorkspace() {
        onNewWorkspaceRequested?()
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

    var workspacePrimaryTexts: [String] {
        workspaceSummaries.map(\.primaryText)
    }

    var workspaceContextTexts: [String] {
        workspaceSummaries.map(\.contextText)
    }

    var workspaceButtonsForTesting: [NSButton] {
        workspaceButtons
    }

    var addWorkspaceTitle: String {
        addWorkspaceButton.titleText
    }

    var isHeaderHidden: Bool {
        true
    }

    var hasVisibleDivider: Bool {
        false
    }

    var firstWorkspaceTopInset: CGFloat {
        guard let firstButton = workspaceButtons.first else {
            return .greatestFiniteMagnitude
        }

        let buttonFrame = convert(firstButton.bounds, from: firstButton)
        return listScrollView.frame.maxY - buttonFrame.maxY
    }

    var firstWorkspaceMinY: CGFloat {
        guard let firstButton = workspaceButtons.first else {
            return 0
        }

        return convert(firstButton.bounds, from: firstButton).minY
    }

    var firstWorkspaceMaxY: CGFloat {
        guard let firstButton = workspaceButtons.first else {
            return 0
        }

        return convert(firstButton.bounds, from: firstButton).maxY
    }

    var addWorkspaceMinY: CGFloat {
        convert(addWorkspaceButton.bounds, from: addWorkspaceButton).minY
    }

    var addWorkspaceMaxY: CGFloat {
        convert(addWorkspaceButton.bounds, from: addWorkspaceButton).maxY
    }

    var firstWorkspaceWidth: CGFloat {
        workspaceButtons.first.map { convert($0.bounds, from: $0).width } ?? 0
    }

    var firstWorkspacePrimaryMinX: CGFloat {
        workspaceButtons.first.map { $0.primaryMinX(in: self) } ?? 0
    }

    var secondWorkspacePrimaryMinX: CGFloat {
        guard workspaceButtons.count > 1 else {
            return 0
        }

        return workspaceButtons[1].primaryMinX(in: self)
    }

    var workspaceDetailTexts: [[String]] {
        workspaceButtons.map(\.detailTextsForTesting)
    }

    var workspaceOverflowTexts: [String] {
        workspaceButtons.map(\.overflowTextForTesting)
    }

    var addWorkspaceContentMinX: CGFloat {
        addWorkspaceButton.contentMinX(in: self)
    }

    var addWorkspaceContentMidX: CGFloat {
        addWorkspaceButton.contentMidX(in: self)
    }

    var addWorkspaceIconAlpha: CGFloat {
        addWorkspaceButton.iconAlpha
    }

    var addWorkspaceTitleAlpha: CGFloat {
        addWorkspaceButton.titleAlpha
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

    var isResizeHandleHidden: Bool {
        resizeHandleView.isHidden
    }

    var trailingEdgeHitTargetsResizeHandle: Bool {
        hitTest(NSPoint(x: bounds.maxX - 1, y: bounds.midY)) === resizeHandleView
    }

    var appearanceMatchForTesting: NSAppearance.Name? {
        appearance?.bestMatch(from: [.darkAqua, .aqua])
    }
}

private final class FlippedSidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarFooterButton: NSButton {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New workspace")
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
        setAccessibilityLabel("New workspace")
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
            accessibilityDescription: "New workspace"
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
        titleLabel.stringValue = "New workspace"
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
