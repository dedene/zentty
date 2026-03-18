import AppKit

final class SidebarView: NSView {
    private enum Layout {
        static let contentInset: CGFloat = ShellMetrics.sidebarContentInset
        static let topInset: CGFloat = ShellMetrics.sidebarTopInset
        static let bottomInset: CGFloat = ShellMetrics.sidebarBottomInset
    }

    var onSelectWorkspace: ((WorkspaceID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onResizeWidth: ((CGFloat) -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let backgroundView = GlassSurfaceView(style: .sidebar)
    private let listScrollView = NSScrollView()
    private let listDocumentView = FlippedSidebarDocumentView()
    private let listStack = NSStackView()
    private let addWorkspaceButton = SidebarFooterButton()
    private let resizeHandleView = SidebarResizeHandleView()

    private var workspaceButtons: [WorkspaceRowButton] = []
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
            resizeHandleView.centerXAnchor.constraint(equalTo: trailingAnchor),
            resizeHandleView.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandleView.widthAnchor.constraint(equalToConstant: 12),
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

    func render(
        summaries: [WorkspaceSidebarSummary],
        theme: ZenttyTheme
    ) {
        workspaceSummaries = summaries
        apply(theme: theme, animated: true)

        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        workspaceButtons.removeAll(keepingCapacity: true)

        for summary in summaries {
            let button = WorkspaceRowButton(workspaceID: summary.workspaceID)
            button.target = self
            button.action = #selector(handleWorkspaceButton(_:))
            button.configure(with: summary, theme: currentTheme, animated: false)
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

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        addWorkspaceButton.configure(theme: theme, animated: animated)
        resizeHandleView.apply()
        backgroundView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }

        workspaceButtons.enumerated().forEach { index, button in
            guard workspaceSummaries.indices.contains(index) else {
                return
            }
            button.configure(with: workspaceSummaries[index], theme: theme, animated: animated)
        }
    }

    func setResizeEnabled(_ isEnabled: Bool) {
        isResizeEnabled = isEnabled
        resizeHandleView.setEnabled(isEnabled)
    }

    @objc
    private func handleWorkspaceButton(_ sender: WorkspaceRowButton) {
        guard let workspaceID = sender.workspaceID else {
            return
        }

        onSelectWorkspace?(workspaceID)
    }

    @objc
    private func handleCreateWorkspace() {
        onCreateWorkspace?()
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
            onResizeWidth?(SidebarWidthPreference.clamped(resizeStartWidth + translation))
        default:
            break
        }
    }

    var workspacePrimaryTextsForTesting: [String] {
        workspaceSummaries.map(\.primaryText)
    }

    var workspaceContextTextsForTesting: [String] {
        workspaceSummaries.map(\.contextText)
    }

    var workspaceArtifactTextsForTesting: [String] {
        workspaceButtons.map(\.artifactTextForTesting)
    }

    var workspaceButtonsForTesting: [NSButton] {
        workspaceButtons
    }

    var addWorkspaceTitleForTesting: String {
        addWorkspaceButton.titleTextForTesting
    }

    var isHeaderHiddenForTesting: Bool {
        true
    }

    var hasVisibleDividerForTesting: Bool {
        false
    }

    var firstWorkspaceTopInsetForTesting: CGFloat {
        guard let firstButton = workspaceButtons.first else {
            return .greatestFiniteMagnitude
        }

        let buttonFrame = convert(firstButton.bounds, from: firstButton)
        return listScrollView.frame.maxY - buttonFrame.maxY
    }

    var firstWorkspaceMinYForTesting: CGFloat {
        guard let firstButton = workspaceButtons.first else {
            return 0
        }

        return convert(firstButton.bounds, from: firstButton).minY
    }

    var firstWorkspaceMaxYForTesting: CGFloat {
        guard let firstButton = workspaceButtons.first else {
            return 0
        }

        return convert(firstButton.bounds, from: firstButton).maxY
    }

    var addWorkspaceMinYForTesting: CGFloat {
        convert(addWorkspaceButton.bounds, from: addWorkspaceButton).minY
    }

    var addWorkspaceMaxYForTesting: CGFloat {
        convert(addWorkspaceButton.bounds, from: addWorkspaceButton).maxY
    }

    var firstWorkspaceWidthForTesting: CGFloat {
        workspaceButtons.first.map { convert($0.bounds, from: $0).width } ?? 0
    }

    var firstWorkspacePrimaryMinXForTesting: CGFloat {
        workspaceButtons.first.map { $0.primaryMinX(in: self) } ?? 0
    }

    var addWorkspaceContentMinXForTesting: CGFloat {
        addWorkspaceButton.contentMinX(in: self)
    }

    var addWorkspaceContentMidXForTesting: CGFloat {
        addWorkspaceButton.contentMidX(in: self)
    }

    var addWorkspaceIconAlphaForTesting: CGFloat {
        addWorkspaceButton.iconAlphaForTesting
    }

    var addWorkspaceTitleAlphaForTesting: CGFloat {
        addWorkspaceButton.titleAlphaForTesting
    }

    var resizeHandleMinXForTesting: CGFloat {
        resizeHandleView.frame.minX
    }

    var resizeHandleMaxXForTesting: CGFloat {
        resizeHandleView.frame.maxX
    }

    var resizeHandleFillAlphaForTesting: CGFloat {
        resizeHandleView.fillAlphaForTesting
    }

    var isResizeHandleHiddenForTesting: Bool {
        resizeHandleView.isHidden
    }
}

private final class FlippedSidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class WorkspaceRowButton: NSButton {
    let workspaceID: WorkspaceID?

    private let titleLabel = NSTextField(labelWithString: "")
    private let primaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let contentStack = NSStackView()
    private let artifactButton = NSButton(title: "", target: nil, action: nil)

    private var currentSummary: WorkspaceSidebarSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var artifactURL: URL?
    private var heightConstraint: NSLayoutConstraint?

    init(workspaceID: WorkspaceID?) {
        self.workspaceID = workspaceID
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        primaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        contextLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        artifactButton.isBordered = false
        artifactButton.bezelStyle = .inline
        artifactButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        artifactButton.target = self
        artifactButton.action = #selector(openArtifact)
        artifactButton.setButtonType(.momentaryChange)
        artifactButton.contentTintColor = .labelColor
        artifactButton.isHidden = true

        contentStack.orientation = .horizontal
        contentStack.spacing = 8
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(artifactButton)

        addSubview(contentStack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarExpandedRowHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellMetrics.sidebarRowHorizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.sidebarRowHorizontalInset),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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

    func configure(
        with summary: WorkspaceSidebarSummary,
        theme: ZenttyTheme,
        animated: Bool
    ) {
        currentSummary = summary
        currentTheme = theme
        let layout = SidebarWorkspaceRowLayout(summary: summary)

        titleLabel.stringValue = summary.title
        titleLabel.isHidden = !layout.visibleTextRows.contains(.title)
        primaryLabel.stringValue = summary.primaryText
        statusLabel.stringValue = summary.statusText ?? ""
        statusLabel.isHidden = !layout.visibleTextRows.contains(.status)
        contextLabel.stringValue = summary.contextText
        contextLabel.isHidden = !layout.visibleTextRows.contains(.context)
        artifactURL = summary.artifactLink?.url
        artifactButton.title = summary.artifactLink?.label ?? ""
        artifactButton.isHidden = summary.artifactLink == nil

        textStack.setViews(
            layout.visibleTextRows.map(label(for:)),
            in: .top
        )
        heightConstraint?.constant = layout.rowHeight

        applyCurrentAppearance(animated: animated)
    }

    private func applyCurrentAppearance(animated: Bool) {
        guard let summary = currentSummary else {
            return
        }

        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText

        titleLabel.textColor = summary.isActive
            ? activeTextColor.withAlphaComponent(0.66)
            : currentTheme.tertiaryText
        primaryLabel.textColor = summary.isActive ? activeTextColor : inactiveTextColor
        contextLabel.textColor = summary.isActive
            ? activeTextColor.withAlphaComponent(0.78)
            : currentTheme.tertiaryText
        statusLabel.textColor = statusTextColor(for: summary)
        artifactButton.contentTintColor = summary.isActive ? activeTextColor : inactiveTextColor

        let activeBackground = currentTheme.sidebarButtonActiveBackground
        let hoverBackground = currentTheme.sidebarButtonHoverBackground
        let inactiveBackground = currentTheme.sidebarButtonInactiveBackground
        let activeBorder = currentTheme.sidebarButtonActiveBorder
        let inactiveBorder = currentTheme.sidebarButtonInactiveBorder.withAlphaComponent(self.isHovered ? 0.16 : 0.10)

        performThemeAnimation(animated: animated) {
            self.layer?.zPosition = summary.isActive ? 10 : 0
            self.layer?.backgroundColor = (
                summary.isActive
                    ? activeBackground
                    : (self.isHovered ? hoverBackground : inactiveBackground)
            ).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = summary.isActive ? 0.8 : 1
            self.layer?.shadowColor = NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = summary.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func statusTextColor(for summary: WorkspaceSidebarSummary) -> NSColor {
        switch summary.attentionState {
        case .needsInput:
            return NSColor.systemBlue
        case .unresolvedStop:
            return NSColor.systemOrange
        case .running:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.74)
                : currentTheme.secondaryText
        case .completed:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        case nil:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.74)
                : currentTheme.secondaryText
        }
    }

    private func label(for row: WorkspaceRowTextRow) -> NSTextField {
        switch row {
        case .title:
            titleLabel
        case .primary:
            primaryLabel
        case .status:
            statusLabel
        case .context:
            contextLabel
        }
    }

    @objc
    private func openArtifact() {
        guard let artifactURL else {
            return
        }

        NSWorkspace.shared.open(artifactURL)
    }

    var artifactTextForTesting: String {
        artifactButton.title
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        view.convert(primaryLabel.bounds, from: primaryLabel).minX
    }
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

    var titleTextForTesting: String {
        titleLabel.stringValue
    }

    var iconAlphaForTesting: CGFloat {
        iconView.contentTintColor?.alphaComponent ?? 0
    }

    var titleAlphaForTesting: CGFloat {
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
    private(set) var isEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
        panRecognizer = recognizer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else {
            return
        }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    func apply() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        panRecognizer?.isEnabled = isEnabled
        isHidden = !isEnabled
        discardCursorRects()
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard isEnabled else {
            return
        }
        onPan?(recognizer)
    }

    var fillAlphaForTesting: CGFloat {
        (layer?.backgroundColor)
            .flatMap { NSColor(cgColor: $0) }?
            .alphaComponent ?? 0
    }
}
