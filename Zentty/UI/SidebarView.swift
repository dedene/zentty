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
        workspaceSummaries.map { $0.attentionText ?? $0.summaryText }
    }

    var workspaceDetailTextsForTesting: [String] {
        workspaceSummaries.map(\.detailText)
    }

    var workspaceButtonsForTesting: [NSButton] {
        workspaceButtons
    }

    var addWorkspaceTitleForTesting: String {
        addWorkspaceButton.title
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

    var resizeHandleMinXForTesting: CGFloat {
        resizeHandleView.frame.minX
    }

    var resizeHandleMaxXForTesting: CGFloat {
        resizeHandleView.frame.maxX
    }

    var resizeHandleFillAlphaForTesting: CGFloat {
        resizeHandleView.fillAlphaForTesting
    }
}

private final class FlippedSidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class WorkspaceRowButton: NSButton {
    let workspaceID: WorkspaceID?

    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()

    private var currentSummary: WorkspaceSidebarSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

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
        layer?.cornerRadius = ShellMetrics.rowRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarRowHeight),

            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
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

        titleLabel.stringValue = summary.title
        titleLabel.isHidden = !summary.showsGeneratedTitle
        summaryLabel.stringValue = summary.attentionText ?? summary.summaryText
        detailLabel.stringValue = summary.detailText
        detailLabel.isHidden = summary.detailText.isEmpty

        textStack.setViews(
            [titleLabel, summaryLabel, detailLabel].filter { !$0.isHidden },
            in: .top
        )

        applyCurrentAppearance(animated: animated)
    }

    private func applyCurrentAppearance(animated: Bool) {
        guard let summary = currentSummary else {
            return
        }

        titleLabel.textColor = currentTheme.tertiaryText
        summaryLabel.textColor = summary.isActive ? currentTheme.primaryText : currentTheme.secondaryText
        detailLabel.textColor = currentTheme.tertiaryText

        let activeBackground = currentTheme.sidebarButtonActiveBackground
        let inactiveAlpha = currentTheme.sidebarButtonInactiveBackground.srgbClamped.alphaComponent
        let hoverBackground = currentTheme.sidebarButtonInactiveBackground
            .mixed(towards: currentTheme.sidebarButtonActiveBackground, amount: 0.18)
            .withAlphaComponent(min(inactiveAlpha + 0.08, 0.24))
        let inactiveBackground = currentTheme.sidebarButtonInactiveBackground
        let activeBorder = currentTheme.sidebarButtonActiveBorder
        let inactiveBorder = currentTheme.sidebarBorder.withAlphaComponent(self.isHovered ? 0.14 : 0.08)

        performThemeAnimation(animated: animated) {
            self.layer?.zPosition = summary.isActive ? 10 : 0
            self.layer?.backgroundColor = (
                summary.isActive
                    ? activeBackground
                    : (self.isHovered ? hoverBackground : inactiveBackground)
            ).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = 1
            self.layer?.shadowColor = NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = summary.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }
}

private final class SidebarFooterButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        title = "New workspace"
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New workspace"
        )
        imagePosition = .imageLeading
        contentTintColor = .secondaryLabelColor
        font = NSFont.systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = ShellMetrics.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellMetrics.footerHeight).isActive = true

        if let cell = cell as? NSButtonCell {
            cell.alignment = .left
            cell.imageScaling = .scaleProportionallyDown
        }
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        contentTintColor = theme.secondaryText

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        attributedTitle = NSAttributedString(
            string: "New workspace",
            attributes: [
                .foregroundColor: theme.secondaryText,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .paragraphStyle: paragraphStyle,
            ]
        )

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 0
        }
    }
}

private final class SidebarResizeHandleView: NSView {
    var onPan: ((NSPanGestureRecognizer) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    func apply() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        onPan?(recognizer)
    }

    var fillAlphaForTesting: CGFloat {
        (layer?.backgroundColor)
            .flatMap { NSColor(cgColor: $0) }?
            .alphaComponent ?? 0
    }
}
