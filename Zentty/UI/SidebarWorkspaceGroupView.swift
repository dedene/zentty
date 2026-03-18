import AppKit

// MARK: - WorkspaceGroupView

final class WorkspaceGroupView: NSView {
    let workspaceID: WorkspaceID
    var onSelectWorkspace: ((WorkspaceID) -> Void)?
    var onToggleExpansion: ((WorkspaceID) -> Void)?
    var onFocusPane: ((WorkspaceID, PaneID) -> Void)?

    private let headerRow: WorkspaceHeaderRow
    private let paneStack = NSStackView()
    private var paneSubRows: [PaneSubRow] = []
    private var isExpanded = false
    private var currentHeader: WorkspaceHeaderSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(workspaceID: WorkspaceID) {
        self.workspaceID = workspaceID
        self.headerRow = WorkspaceHeaderRow(workspaceID: workspaceID)
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.rowRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.target = self
        headerRow.action = #selector(handleHeaderClick)
        headerRow.onDisclosureToggle = { [weak self] in
            guard let self else { return }
            self.onToggleExpansion?(self.workspaceID)
        }

        paneStack.orientation = .vertical
        paneStack.alignment = .width
        paneStack.spacing = 0
        paneStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerRow)
        addSubview(paneStack)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor),

            paneStack.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            paneStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneStack.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        applyGroupAppearance(animated: true)
        headerRow.applyTextColors(theme: currentTheme, isHovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyGroupAppearance(animated: true)
        headerRow.applyTextColors(theme: currentTheme, isHovered: false)
    }

    func configure(
        with node: WorkspaceSidebarNode,
        isExpanded: Bool,
        theme: ZenttyTheme,
        animated: Bool
    ) {
        self.isExpanded = isExpanded
        self.currentHeader = node.header
        self.currentTheme = theme

        let groupLayout = SidebarWorkspaceGroupLayout(
            headerStatusText: node.header.statusText,
            headerContextText: node.header.gitContext,
            paneCount: node.header.paneCount,
            isExpanded: isExpanded
        )

        headerRow.configure(
            with: node.header,
            theme: theme,
            animated: animated,
            visibleRows: groupLayout.headerVisibleRows,
            headerHeight: groupLayout.headerHeight,
            isExpanded: isExpanded
        )

        rebuildPaneSubRows(from: node.panes, theme: theme)
        paneStack.isHidden = !isExpanded || node.panes.isEmpty
        applyGroupAppearance(animated: animated)
    }

    private func applyGroupAppearance(animated: Bool) {
        guard let header = currentHeader else { return }

        let activeBackground = currentTheme.sidebarButtonActiveBackground
        let hoverBackground = currentTheme.sidebarButtonHoverBackground
        let inactiveBackground = currentTheme.sidebarButtonInactiveBackground
        let activeBorder = currentTheme.sidebarButtonActiveBorder
        let inactiveBorder = currentTheme.sidebarButtonInactiveBorder.withAlphaComponent(isHovered ? 0.16 : 0.10)

        performThemeAnimation(animated: animated) {
            self.layer?.zPosition = header.isActive ? 10 : 0
            self.layer?.backgroundColor = (
                header.isActive
                    ? activeBackground
                    : (self.isHovered ? hoverBackground : inactiveBackground)
            ).cgColor
            self.layer?.borderColor = (header.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = header.isActive ? 0.8 : 1
            self.layer?.shadowColor = NSColor.black.withAlphaComponent(header.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = header.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        headerRow.setDisclosureExpanded(expanded)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                self.paneStack.isHidden = !expanded
                self.superview?.layoutSubtreeIfNeeded()
            }
        } else {
            paneStack.isHidden = !expanded
        }
    }

    private func rebuildPaneSubRows(from panes: [PaneSidebarSummary], theme: ZenttyTheme) {
        paneStack.arrangedSubviews.forEach { view in
            paneStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        paneSubRows.removeAll(keepingCapacity: true)

        for pane in panes {
            let row = PaneSubRow(paneID: pane.paneID)
            row.configure(with: pane, theme: theme)
            row.onSelect = { [weak self] in
                guard let self else { return }
                self.onFocusPane?(self.workspaceID, pane.paneID)
            }
            paneSubRows.append(row)
            paneStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: paneStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: paneStack.trailingAnchor),
            ])
        }
    }

    @objc
    private func handleHeaderClick() {
        onSelectWorkspace?(workspaceID)
    }

    // MARK: - Testing Accessors

    var headerPrimaryTextForTesting: String {
        headerRow.primaryTextForTesting
    }

    var paneLabelsForTesting: [String] {
        paneSubRows.map(\.labelTextForTesting)
    }

    var isExpandedForTesting: Bool {
        isExpanded
    }

    var headerButtonForTesting: NSButton {
        headerRow
    }

    var headerArtifactTextForTesting: String {
        headerRow.artifactTextForTesting
    }

    var headerAttentionSymbolNameForTesting: String? {
        headerRow.attentionSymbolNameForTesting
    }
}

// MARK: - WorkspaceHeaderRow

private let needsInputSymbolName = "bell.badge.fill"

final class WorkspaceHeaderRow: NSButton {
    let workspaceID: WorkspaceID?
    var onDisclosureToggle: (() -> Void)?

    private let primaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let statusRowStack = NSStackView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let contentStack = NSStackView()
    private let artifactButton = NSButton(title: "", target: nil, action: nil)
    private let disclosureButton = NSButton()
    private let paneCountLabel = NSTextField(labelWithString: "")

    private var currentHeader: WorkspaceHeaderSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var heightConstraint: NSLayoutConstraint?
    private var artifactURL: URL?
    private var isHovered = false

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
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        primaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.isHidden = true

        statusRowStack.orientation = .horizontal
        statusRowStack.alignment = .centerY
        statusRowStack.spacing = 5
        statusRowStack.translatesAutoresizingMaskIntoConstraints = false
        statusRowStack.setHuggingPriority(.defaultHigh, for: .horizontal)
        statusRowStack.addArrangedSubview(statusIconView)
        statusRowStack.addArrangedSubview(statusLabel)

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

        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .regularSquare
        disclosureButton.setButtonType(.momentaryChange)
        disclosureButton.target = self
        disclosureButton.action = #selector(handleDisclosureClick)
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isHidden = true

        paneCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        paneCountLabel.alignment = .center
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        paneCountLabel.isHidden = true

        contentStack.orientation = .horizontal
        contentStack.spacing = 8
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(artifactButton)

        addSubview(disclosureButton)
        addSubview(paneCountLabel)
        addSubview(contentStack)

        let defaultHeight = WorkspaceRowLayoutMetrics.sidebar.height(for: [.primary])
        let heightConstraint = heightAnchor.constraint(equalToConstant: defaultHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellMetrics.sidebarRowHorizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.sidebarRowHorizontalInset),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            paneCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            paneCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        with header: WorkspaceHeaderSummary,
        theme: ZenttyTheme,
        animated: Bool,
        visibleRows: [WorkspaceRowTextRow],
        headerHeight: CGFloat,
        isExpanded: Bool
    ) {
        currentHeader = header
        currentTheme = theme

        primaryLabel.stringValue = header.primaryText
        statusLabel.stringValue = header.statusText ?? ""
        statusLabel.isHidden = !visibleRows.contains(.status)
        let symbolName = statusSymbolName(for: header)
        statusIconView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: header.statusText)
        }
        statusIconView.isHidden = symbolName == nil
        contextLabel.stringValue = header.gitContext
        contextLabel.isHidden = !visibleRows.contains(.context)
        artifactURL = header.artifactLink?.url
        artifactButton.title = header.artifactLink?.label ?? ""
        artifactButton.isHidden = header.artifactLink == nil

        textStack.setViews(
            visibleRows.map(view(for:)),
            in: .top
        )
        heightConstraint?.constant = headerHeight

        // Disclosure / pane count
        let showDisclosure = header.paneCount > 1
        disclosureButton.isHidden = !showDisclosure
        paneCountLabel.isHidden = !showDisclosure

        if showDisclosure {
            let chevron = isExpanded ? "chevron.down" : "chevron.right"
            disclosureButton.image = NSImage(
                systemSymbolName: chevron,
                accessibilityDescription: isExpanded ? "Collapse" : "Expand"
            )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            paneCountLabel.stringValue = "\(header.paneCount)"
        }

        applyTextColors(theme: theme, isHovered: false)
    }

    func setDisclosureExpanded(_ expanded: Bool) {
        let chevron = expanded ? "chevron.down" : "chevron.right"
        disclosureButton.image = NSImage(
            systemSymbolName: chevron,
            accessibilityDescription: expanded ? "Collapse" : "Expand"
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    }

    func applyTextColors(theme: ZenttyTheme, isHovered: Bool) {
        guard let header = currentHeader else { return }
        currentTheme = theme

        let activeTextColor = theme.sidebarButtonActiveText
        let inactiveTextColor = theme.sidebarButtonInactiveText

        primaryLabel.textColor = header.isActive ? activeTextColor : inactiveTextColor
        contextLabel.textColor = header.isActive
            ? activeTextColor.withAlphaComponent(0.78)
            : theme.tertiaryText
        let statusColor = statusTextColor(for: header)
        statusLabel.textColor = statusColor
        statusIconView.contentTintColor = statusColor
        artifactButton.contentTintColor = header.isActive ? activeTextColor : inactiveTextColor
        disclosureButton.contentTintColor = header.isActive
            ? activeTextColor.withAlphaComponent(0.60)
            : theme.tertiaryText
        paneCountLabel.textColor = header.isActive
            ? activeTextColor.withAlphaComponent(0.60)
            : theme.tertiaryText
    }

    private func statusTextColor(for header: WorkspaceHeaderSummary) -> NSColor {
        switch header.attentionState {
        case .needsInput:
            return NSColor.systemBlue
        case .unresolvedStop:
            return NSColor.systemOrange
        case .running:
            return header.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.74)
                : currentTheme.secondaryText
        case .completed:
            return header.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        case nil:
            return header.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.74)
                : currentTheme.secondaryText
        }
    }

    private func view(for row: WorkspaceRowTextRow) -> NSView {
        switch row {
        case .topLabel:
            return primaryLabel
        case .primary:
            return primaryLabel
        case .status:
            return statusRowStack
        case .context:
            return contextLabel
        case .detail:
            return contextLabel
        case .overflow:
            return contextLabel
        }
    }

    private func statusSymbolName(for header: WorkspaceHeaderSummary) -> String? {
        switch header.attentionState {
        case .needsInput:
            return needsInputSymbolName
        default:
            return nil
        }
    }

    @objc
    private func openArtifact() {
        guard let artifactURL else { return }
        NSWorkspace.shared.open(artifactURL)
    }

    @objc
    private func handleDisclosureClick() {
        onDisclosureToggle?()
    }

    // MARK: - Testing Accessors

    var primaryTextForTesting: String {
        primaryLabel.stringValue
    }

    var artifactTextForTesting: String {
        artifactButton.title
    }

    var attentionSymbolNameForTesting: String? {
        switch currentHeader?.attentionState {
        case .needsInput:
            return needsInputSymbolName
        default:
            return nil
        }
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        view.convert(primaryLabel.bounds, from: primaryLabel).minX
    }
}

// MARK: - PaneSubRow

final class PaneSubRow: NSButton {
    let paneID: PaneID
    var onSelect: (() -> Void)?

    private let statusIndicator = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let gitContextLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()

    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    init(paneID: PaneID) {
        self.paneID = paneID
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
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(handleClick)

        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.setContentHuggingPriority(.required, for: .horizontal)
        statusIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        gitContextLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        gitContextLabel.lineBreakMode = .byTruncatingTail
        gitContextLabel.translatesAutoresizingMaskIntoConstraints = false
        gitContextLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        gitContextLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(statusIndicator)
        rowStack.addArrangedSubview(label)
        rowStack.addArrangedSubview(gitContextLabel)

        addSubview(rowStack)

        let leadingInset = ShellMetrics.sidebarRowHorizontalInset + ShellMetrics.paneSubRowIndent
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ShellMetrics.paneSubRowHeight),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.sidebarRowHorizontalInset),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 12),
            statusIndicator.heightAnchor.constraint(equalToConstant: 12),
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
        applyHoverState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyHoverState()
    }

    func configure(with pane: PaneSidebarSummary, theme: ZenttyTheme) {
        currentTheme = theme
        label.stringValue = pane.primaryText

        let hasGitContext = !pane.gitContext.isEmpty
        gitContextLabel.stringValue = pane.gitContext
        gitContextLabel.isHidden = !hasGitContext

        // Status indicator
        let (symbolName, symbolSize, tintColor) = statusIndicatorConfig(
            for: pane.attentionState,
            theme: theme
        )
        statusIndicator.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium))
        statusIndicator.contentTintColor = tintColor

        // Text colors
        let textColor = pane.isFocused
            ? theme.sidebarButtonActiveText
            : theme.sidebarButtonInactiveText
        label.textColor = textColor
        gitContextLabel.textColor = pane.isFocused
            ? textColor.withAlphaComponent(0.60)
            : theme.tertiaryText

        applyHoverState()
    }

    private func statusIndicatorConfig(
        for attention: WorkspaceAttentionState?,
        theme: ZenttyTheme
    ) -> (symbolName: String, pointSize: CGFloat, color: NSColor) {
        switch attention {
        case .needsInput:
            return ("bell.badge.fill", 11, NSColor.systemBlue)
        case .unresolvedStop:
            return ("circle.fill", 8, NSColor.systemOrange)
        case .running:
            return ("circle.fill", 8, NSColor.systemGreen)
        case .completed, nil:
            return ("circle.fill", 8, theme.tertiaryText)
        }
    }

    private func applyHoverState() {
        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = self.isHovered
                ? self.currentTheme.sidebarButtonHoverBackground.cgColor
                : NSColor.clear.cgColor
        }
    }

    @objc
    private func handleClick() {
        onSelect?()
    }

    // MARK: - Testing Accessors

    var labelTextForTesting: String {
        label.stringValue
    }
}
