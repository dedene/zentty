import AppKit

// MARK: - WorkspaceGroupView

@MainActor
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
