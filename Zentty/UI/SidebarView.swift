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
    var onFocusPane: ((WorkspaceID, PaneID) -> Void)?

    private let backgroundView = GlassSurfaceView(style: .sidebar)
    private let listScrollView = NSScrollView()
    private let listDocumentView = FlippedSidebarDocumentView()
    private let listStack = NSStackView()
    private let addWorkspaceButton = SidebarFooterButton()
    private let resizeHandleView = SidebarResizeHandleView()

    private var expandedWorkspaceIDs: Set<WorkspaceID> = []
    private var workspaceGroupViews: [WorkspaceGroupView] = []
    private var currentNodes: [WorkspaceSidebarNode] = []
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
        nodes: [WorkspaceSidebarNode],
        theme: ZenttyTheme
    ) {
        currentNodes = nodes
        apply(theme: theme, animated: true)

        // Auto-expand active multi-pane workspace
        for node in nodes where node.header.isActive && node.header.paneCount > 1 {
            expandedWorkspaceIDs.insert(node.header.workspaceID)
        }

        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        workspaceGroupViews.removeAll(keepingCapacity: true)

        for node in nodes {
            let isExpanded = node.header.paneCount > 1 && expandedWorkspaceIDs.contains(node.header.workspaceID)
            let groupView = WorkspaceGroupView(workspaceID: node.header.workspaceID)
            groupView.onSelectWorkspace = { [weak self] id in self?.onSelectWorkspace?(id) }
            groupView.onToggleExpansion = { [weak self] id in self?.toggleExpansion(id) }
            groupView.onFocusPane = { [weak self] wid, pid in self?.onFocusPane?(wid, pid) }
            groupView.configure(with: node, isExpanded: isExpanded, theme: currentTheme, animated: false)
            workspaceGroupViews.append(groupView)
            listStack.addArrangedSubview(groupView)
            NSLayoutConstraint.activate([
                groupView.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                groupView.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            ])
        }

        // Footer button
        if let lastGroup = workspaceGroupViews.last {
            listStack.setCustomSpacing(8, after: lastGroup)
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

        workspaceGroupViews.enumerated().forEach { index, groupView in
            guard currentNodes.indices.contains(index) else { return }
            let isExpanded = currentNodes[index].header.paneCount > 1 && expandedWorkspaceIDs.contains(currentNodes[index].header.workspaceID)
            groupView.configure(with: currentNodes[index], isExpanded: isExpanded, theme: theme, animated: animated)
        }
    }

    private func toggleExpansion(_ workspaceID: WorkspaceID) {
        if expandedWorkspaceIDs.contains(workspaceID) {
            expandedWorkspaceIDs.remove(workspaceID)
        } else {
            expandedWorkspaceIDs.insert(workspaceID)
        }
        if let index = currentNodes.firstIndex(where: { $0.header.workspaceID == workspaceID }),
           index < workspaceGroupViews.count {
            let isExpanded = expandedWorkspaceIDs.contains(workspaceID)
            workspaceGroupViews[index].setExpanded(isExpanded, animated: true)
        }
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
        currentNodes.map(\.header.primaryText)
    }

    var workspaceContextTextsForTesting: [String] {
        currentNodes.map(\.header.gitContext)
    }

    var workspaceArtifactTextsForTesting: [String] {
        workspaceGroupViews.map(\.headerArtifactTextForTesting)
    }

    var workspaceAttentionSymbolsForTesting: [String?] {
        workspaceGroupViews.map(\.headerAttentionSymbolNameForTesting)
    }

    var workspaceButtonsForTesting: [NSButton] {
        workspaceGroupViews.compactMap(\.headerButtonForTesting)
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
        guard let firstGroup = workspaceGroupViews.first else {
            return .greatestFiniteMagnitude
        }

        let groupFrame = convert(firstGroup.bounds, from: firstGroup)
        return listScrollView.frame.maxY - groupFrame.maxY
    }

    var firstWorkspaceMinYForTesting: CGFloat {
        guard let firstGroup = workspaceGroupViews.first else {
            return 0
        }

        return convert(firstGroup.bounds, from: firstGroup).minY
    }

    var firstWorkspaceMaxYForTesting: CGFloat {
        guard let firstGroup = workspaceGroupViews.first else {
            return 0
        }

        return convert(firstGroup.bounds, from: firstGroup).maxY
    }

    var addWorkspaceMinYForTesting: CGFloat {
        convert(addWorkspaceButton.bounds, from: addWorkspaceButton).minY
    }

    var addWorkspaceMaxYForTesting: CGFloat {
        convert(addWorkspaceButton.bounds, from: addWorkspaceButton).maxY
    }

    var firstWorkspaceWidthForTesting: CGFloat {
        workspaceGroupViews.first.map { convert($0.bounds, from: $0).width } ?? 0
    }

    var firstWorkspacePrimaryMinXForTesting: CGFloat {
        (workspaceGroupViews.first?.headerButtonForTesting as? WorkspaceHeaderRow)
            .map { $0.primaryMinX(in: self) } ?? 0
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
