import AppKit

final class SidebarWorkspaceRowButton: NSButton {
    private enum Layout {
        static let contentInset = ShellMetrics.sidebarRowHorizontalInset
    }

    let workspaceID: WorkspaceID?

    private let leadingAccessoryContainer = NSView()
    private let leadingAccessoryView = NSImageView()
    private let topLabel = NSTextField(labelWithString: "")
    private let primaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let overflowLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let bodyStack = NSStackView()
    private let contentStack = NSStackView()
    private let artifactButton = NSButton(title: "", target: nil, action: nil)

    private var detailLabels: [NSTextField] = []
    private var currentSummary: WorkspaceSidebarSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var artifactURL: URL?
    private var heightConstraint: NSLayoutConstraint?
    private var leadingAccessoryWidthConstraint: NSLayoutConstraint?
    private var currentLeadingAccessorySymbolName: String?

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

        configureLabel(
            topLabel,
            font: ShellMetrics.sidebarTitleFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            primaryLabel,
            font: ShellMetrics.sidebarPrimaryFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            statusLabel,
            font: ShellMetrics.sidebarStatusFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            overflowLabel,
            font: ShellMetrics.sidebarOverflowFont(),
            lineBreakMode: .byTruncatingTail
        )

        leadingAccessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        leadingAccessoryView.translatesAutoresizingMaskIntoConstraints = false
        leadingAccessoryView.imageScaling = .scaleProportionallyDown
        leadingAccessoryView.contentTintColor = .labelColor
        leadingAccessoryContainer.addSubview(leadingAccessoryView)

        let leadingAccessoryWidthConstraint = leadingAccessoryContainer.widthAnchor.constraint(equalToConstant: 0)
        self.leadingAccessoryWidthConstraint = leadingAccessoryWidthConstraint

        NSLayoutConstraint.activate([
            leadingAccessoryWidthConstraint,
            leadingAccessoryContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: ShellMetrics.sidebarLeadingAccessorySize),
            leadingAccessoryView.leadingAnchor.constraint(equalTo: leadingAccessoryContainer.leadingAnchor),
            leadingAccessoryView.centerYAnchor.constraint(equalTo: leadingAccessoryContainer.centerYAnchor),
            leadingAccessoryView.widthAnchor.constraint(equalToConstant: ShellMetrics.sidebarLeadingAccessorySize),
            leadingAccessoryView.heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarLeadingAccessorySize),
        ])

        textStack.orientation = .vertical
        textStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bodyStack.orientation = .horizontal
        bodyStack.spacing = 0
        bodyStack.alignment = .top
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(leadingAccessoryContainer)
        bodyStack.addArrangedSubview(textStack)

        artifactButton.isBordered = false
        artifactButton.bezelStyle = .inline
        artifactButton.font = .systemFont(ofSize: 11, weight: .semibold)
        artifactButton.target = self
        artifactButton.action = #selector(openArtifact)
        artifactButton.setButtonType(.momentaryChange)
        artifactButton.contentTintColor = .labelColor
        artifactButton.isHidden = true
        artifactButton.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.spacing = 8
        contentStack.alignment = .top
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(bodyStack)
        contentStack.addArrangedSubview(artifactButton)

        addSubview(contentStack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCompactRowHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: ShellMetrics.sidebarRowTopInset),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.contentInset),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ShellMetrics.sidebarRowBottomInset),
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
        reservesLeadingAccessoryGutter: Bool,
        theme: ZenttyTheme,
        animated: Bool
    ) {
        currentSummary = summary
        currentTheme = theme

        let layout = SidebarWorkspaceRowLayout(summary: summary)

        topLabel.stringValue = summary.topLabel ?? ""
        primaryLabel.stringValue = summary.primaryText
        statusLabel.stringValue = summary.statusText ?? ""
        overflowLabel.stringValue = summary.overflowText ?? ""
        configureDetailLabels(for: summary.detailLines)
        configureLeadingAccessory(
            accessory: summary.leadingAccessory,
            reservesLeadingAccessoryGutter: reservesLeadingAccessoryGutter
        )

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

    private func configureDetailLabels(for detailLines: [WorkspaceSidebarDetailLine]) {
        while detailLabels.count < detailLines.count {
            let label = NSTextField(labelWithString: "")
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

    private func configureLeadingAccessory(
        accessory: WorkspaceSidebarLeadingAccessory?,
        reservesLeadingAccessoryGutter: Bool
    ) {
        leadingAccessoryWidthConstraint?.constant = reservesLeadingAccessoryGutter
            ? ShellMetrics.sidebarLeadingAccessoryGutterWidth
            : 0

        guard
            reservesLeadingAccessoryGutter,
            let accessory,
            let image = NSImage(
                systemSymbolName: accessory.symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(
                .init(pointSize: 12, weight: .semibold)
            )
        else {
            leadingAccessoryView.image = nil
            leadingAccessoryView.isHidden = true
            currentLeadingAccessorySymbolName = nil
            return
        }

        leadingAccessoryView.image = image
        leadingAccessoryView.isHidden = false
        currentLeadingAccessorySymbolName = accessory.symbolName
    }

    private func applyCurrentAppearance(animated: Bool) {
        guard let summary = currentSummary else {
            return
        }

        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText

        topLabel.textColor = summary.isActive
            ? activeTextColor.withAlphaComponent(0.66)
            : currentTheme.tertiaryText
        primaryLabel.textColor = summary.isActive ? activeTextColor : inactiveTextColor
        statusLabel.textColor = statusTextColor(for: summary)
        overflowLabel.textColor = summary.isActive
            ? activeTextColor.withAlphaComponent(0.54)
            : currentTheme.tertiaryText
        artifactButton.contentTintColor = summary.isActive ? activeTextColor : inactiveTextColor
        leadingAccessoryView.contentTintColor = summary.isActive
            ? activeTextColor.withAlphaComponent(0.78)
            : currentTheme.secondaryText

        for (index, detailLabel) in detailLabels.enumerated() {
            guard summary.detailLines.indices.contains(index) else {
                continue
            }

            detailLabel.textColor = detailTextColor(
                for: summary.detailLines[index].emphasis,
                summary: summary
            )
        }

        let activeBackground = currentTheme.sidebarButtonActiveBackground
        let hoverBackground = currentTheme.sidebarButtonHoverBackground
        let inactiveBackground = currentTheme.sidebarButtonInactiveBackground
        let activeBorder = currentTheme.sidebarButtonActiveBorder
        let inactiveBorder = currentTheme.sidebarButtonInactiveBorder.withAlphaComponent(isHovered ? 0.16 : 0.10)

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

    private func detailTextColor(
        for emphasis: WorkspaceSidebarDetailEmphasis,
        summary: WorkspaceSidebarSummary
    ) -> NSColor {
        switch emphasis {
        case .primary:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.78)
                : currentTheme.secondaryText
        case .secondary:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        }
    }

    private func label(for row: WorkspaceRowTextRow) -> NSTextField {
        switch row {
        case .topLabel:
            topLabel
        case .primary:
            primaryLabel
        case .status:
            statusLabel
        case .detail(let index):
            detailLabels[index]
        case .overflow:
            overflowLabel
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

    var detailTextsForTesting: [String] {
        detailLabels.prefix(currentSummary?.detailLines.count ?? 0).map(\.stringValue)
    }

    var overflowTextForTesting: String {
        currentSummary?.overflowText ?? ""
    }

    var leadingAccessorySymbolNameForTesting: String {
        currentLeadingAccessorySymbolName ?? ""
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        view.convert(primaryLabel.bounds, from: primaryLabel).minX
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
}

private extension WorkspaceSidebarLeadingAccessory {
    var symbolName: String {
        switch self {
        case .home:
            return "house"
        case .agent(let tool):
            return tool.sidebarSymbolName
        }
    }
}

private extension AgentTool {
    var sidebarSymbolName: String {
        switch self {
        case .claudeCode:
            return "sparkles"
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .openCode:
            return "curlybraces.square"
        case .custom:
            return "sparkles"
        }
    }
}
