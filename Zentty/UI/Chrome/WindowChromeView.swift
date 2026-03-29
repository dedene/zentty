import AppKit

struct WindowChromeOpenWithState: Equatable {
    let title: String
    let icon: NSImage?
    let isPrimaryEnabled: Bool
    let isMenuEnabled: Bool
}

@MainActor
final class WindowChromeView: NSView {
    static let preferredHeight: CGFloat = ChromeGeometry.headerHeight
    private static let minimumBootstrapLaneWidth: CGFloat = 160
    private static let minimumRowHeight: CGFloat = 22
    private static let proxyIconSize = NSSize(width: 14, height: 14)
    private static let openWithControlWidth: CGFloat = 66
    private static let openWithControlHeight: CGFloat = 30
    private static let openWithPrimaryWidth: CGFloat = 40
    private static let openWithMenuWidth: CGFloat = 24
    private static let openWithSectionSpacing: CGFloat = 14
    private static let openWithSegmentInset: CGFloat = 2
    fileprivate static let leadingItemSpacing: CGFloat = 10
    fileprivate static let reviewChipSpacing: CGFloat = 8
    fileprivate static let sectionSpacing: CGFloat = 12
    private static let readableBranchWidth = measureLabelWidth(
        text: "develop",
        font: .monospacedSystemFont(ofSize: 12, weight: .medium),
        lineBreakMode: .byTruncatingMiddle
    )

    var leadingVisibleInset: CGFloat = 0 {
        didSet {
            guard abs(oldValue - leadingVisibleInset) > 0.5 else {
                return
            }

            needsLayout = true
        }
    }

    private let attentionChipView = WorklaneAttentionChipView()
    private let rowContainerView = NSView()
    private let focusedProxyIconView = WindowChromeProxyIconView()
    private let openWithContainerView = NSView()
    private let openWithPrimaryBackgroundView = NSView()
    private let openWithMenuBackgroundView = NSView()
    private let openWithPrimaryButton = WindowChromeSegmentButton()
    private let openWithMenuButton = WindowChromeSegmentButton()
    private let openWithDividerView = NSView()
    private let focusedLabel = WindowChromeView.makeLabel(
        text: "",
        color: .secondaryLabelColor,
        font: .systemFont(ofSize: 12, weight: .medium),
        lineBreakMode: .byTruncatingTail
    )
    private let branchLabel = WindowChromeBranchLabel()
    private let pullRequestButton = WindowChromePullRequestButton(title: "", target: nil, action: nil)
    private let urlOpener: (URL) -> Void
    private let pathRevealer: (URL) -> Void
    private let computerLocationOpener: (URL) -> Void

    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var currentSummary = WorklaneChromeSummary(
        attention: nil,
        focusedLabel: nil,
        cwdPath: nil,
        branch: nil,
        branchURL: nil,
        pullRequest: nil,
        reviewChips: []
    )
    private var currentOpenWithState: WindowChromeOpenWithState?
    private var displayedReviewChips: [WorklaneReviewChip] = []
    private var reviewChipViews: [WindowChromeReviewChipView] = []
    private var branchURL: URL?
    private var pullRequestURL: URL?
    private var rowLeadingConstraint: NSLayoutConstraint?
    private var rowCenterYConstraint: NSLayoutConstraint?
    private var rowWidthConstraint: NSLayoutConstraint?
    private var rowHeightConstraint: NSLayoutConstraint?
    private var hasEstablishedRenderableLayout = false
    private var lastRowLayoutPlan = RowLayoutPlan.empty
    var onOpenWithPrimaryAction: (() -> Void)?
    var onOpenWithMenuAction: (() -> Void)?

    init(
        frame frameRect: NSRect,
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        pathRevealer: @escaping (URL) -> Void = { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path) },
        computerLocationOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.urlOpener = urlOpener
        self.pathRevealer = pathRevealer
        self.computerLocationOpener = computerLocationOpener
        super.init(frame: frameRect)
        setup()
    }

    convenience init(
        urlOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        pathRevealer: @escaping (URL) -> Void = { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path) },
        computerLocationOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.init(
            frame: .zero,
            urlOpener: urlOpener,
            pathRevealer: pathRevealer,
            computerLocationOpener: computerLocationOpener
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutOpenWithControl()
        syncVisibleRowContent(forceChipRefresh: false)
        layoutRowContent()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        focusedProxyIconView.isHidden = true
        focusedProxyIconView.alphaValue = 0
        focusedProxyIconView.revealPath = pathRevealer
        focusedProxyIconView.openComputerLocation = computerLocationOpener
        focusedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focusedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        branchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        branchLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        branchLabel.target = self
        branchLabel.action = #selector(openBranch)
        branchLabel.onHoverChanged = { [weak self] in
            self?.updateBranchAppearance(animated: false)
        }

        pullRequestButton.isBordered = false
        pullRequestButton.bezelStyle = .inline
        pullRequestButton.font = .systemFont(ofSize: 12, weight: .semibold)
        pullRequestButton.setButtonType(.momentaryChange)
        pullRequestButton.target = self
        pullRequestButton.action = #selector(openPullRequest)
        pullRequestButton.lineBreakMode = .byClipping
        pullRequestButton.cell?.wraps = false
        pullRequestButton.focusRingType = .none
        pullRequestButton.onHoverChanged = { [weak self] in
            self?.updatePullRequestAppearance(animated: false)
        }

        openWithContainerView.wantsLayer = true
        openWithContainerView.layer?.cornerRadius = Self.openWithControlHeight / 2
        openWithContainerView.layer?.cornerCurve = .continuous
        openWithContainerView.layer?.shadowOpacity = 1
        openWithContainerView.layer?.shadowRadius = 12
        openWithContainerView.layer?.shadowOffset = CGSize(width: 0, height: 8)

        [openWithPrimaryBackgroundView, openWithMenuBackgroundView].forEach {
            $0.wantsLayer = true
            $0.layer?.cornerCurve = .continuous
            openWithContainerView.addSubview($0)
        }

        openWithPrimaryButton.isBordered = false
        openWithPrimaryButton.imagePosition = .imageOnly
        openWithPrimaryButton.focusRingType = .none
        openWithPrimaryButton.target = self
        openWithPrimaryButton.action = #selector(handleOpenWithPrimaryAction)
        openWithPrimaryButton.setAccessibilityRole(.button)
        openWithPrimaryButton.imageScaling = .scaleProportionallyDown
        openWithPrimaryButton.onInteractionStateChanged = { [weak self] in
            self?.updateOpenWithAppearance(animated: true)
        }

        openWithMenuButton.isBordered = false
        openWithMenuButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Show Open With menu"
        )
        openWithMenuButton.imagePosition = .imageOnly
        openWithMenuButton.focusRingType = .none
        openWithMenuButton.target = self
        openWithMenuButton.action = #selector(handleOpenWithMenuAction)
        openWithMenuButton.imageScaling = .scaleProportionallyDown
        openWithMenuButton.onInteractionStateChanged = { [weak self] in
            self?.updateOpenWithAppearance(animated: true)
        }

        openWithDividerView.wantsLayer = true

        rowContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowContainerView)
        addSubview(openWithContainerView)
        openWithContainerView.addSubview(openWithDividerView)
        openWithContainerView.addSubview(openWithPrimaryButton)
        openWithContainerView.addSubview(openWithMenuButton)
        [attentionChipView, focusedProxyIconView, focusedLabel, branchLabel, pullRequestButton].forEach {
            rowContainerView.addSubview($0)
        }

        rowLeadingConstraint = rowContainerView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ChromeGeometry.headerHorizontalInset
        )
        rowCenterYConstraint = rowContainerView.centerYAnchor.constraint(equalTo: centerYAnchor)
        rowWidthConstraint = rowContainerView.widthAnchor.constraint(equalToConstant: 0)
        rowHeightConstraint = rowContainerView.heightAnchor.constraint(equalToConstant: Self.minimumRowHeight)

        NSLayoutConstraint.activate([
            rowLeadingConstraint,
            rowCenterYConstraint,
            rowWidthConstraint,
            rowHeightConstraint,
        ].compactMap { $0 })

        apply(theme: currentTheme, animated: false)
        render(summary: currentSummary)
        render(openWith: currentOpenWithState)
    }

    func render(summary: WorklaneChromeSummary) {
        currentSummary = summary
        pullRequestURL = summary.pullRequest?.url

        attentionChipView.render(attention: summary.attention)

        let focusedText = summary.focusedLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        focusedLabel.stringValue = focusedText
        focusedLabel.isHidden = focusedText.isEmpty
        renderFocusedProxyIcon()

        let branchText = summary.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        branchLabel.stringValue = branchText
        branchLabel.isHidden = branchText.isEmpty
        branchURL = summary.branchURL
        let isBranchClickable = branchURL != nil && !branchText.isEmpty
        branchLabel.isInteractive = isBranchClickable
        branchLabel.toolTip = isBranchClickable ? "Open branch on remote" : nil

        pullRequestButton.title = summary.pullRequest.map { "PR #\($0.number)" } ?? ""
        pullRequestButton.isHidden = summary.pullRequest == nil
        updatePullRequestInteraction()
        updatePullRequestAppearance(animated: false)

        syncVisibleRowContent(forceChipRefresh: true)
        needsLayout = true
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        attentionChipView.apply(theme: theme, animated: animated)

        focusedLabel.textColor = theme.secondaryText
        renderFocusedProxyIcon()
        updateBranchAppearance(animated: animated)
        updatePullRequestAppearance(animated: animated)
        reviewChipViews.forEach { $0.apply(theme: theme, animated: animated) }
        updateOpenWithAppearance(animated: animated)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.topChromeBackground.cgColor
        }
    }

    func render(openWith state: WindowChromeOpenWithState?) {
        currentOpenWithState = state

        guard let state else {
            openWithContainerView.isHidden = true
            needsLayout = true
            return
        }

        openWithContainerView.isHidden = false
        openWithPrimaryButton.image = state.icon ?? NSImage(
            systemSymbolName: "square.and.arrow.up.on.square",
            accessibilityDescription: state.title
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        openWithPrimaryButton.isEnabled = state.isPrimaryEnabled
        openWithPrimaryButton.toolTip = state.isPrimaryEnabled ? "Open focused pane in \(state.title)" : "Open With unavailable"
        openWithPrimaryButton.setAccessibilityLabel("Open focused pane in \(state.title)")
        openWithMenuButton.isEnabled = state.isMenuEnabled
        openWithMenuButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Show Open With menu"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        openWithMenuButton.toolTip = "Show Open With menu"
        openWithMenuButton.setAccessibilityLabel("Show Open With menu")
        updateOpenWithAppearance(animated: false)
        needsLayout = true
    }

    @objc
    private func openBranch() {
        guard branchLabel.isInteractive, let branchURL else {
            return
        }

        urlOpener(branchURL)
    }

    @objc
    private func openPullRequest() {
        guard pullRequestButton.isEnabled, let pullRequestURL else {
            return
        }

        urlOpener(pullRequestURL)
    }

    @objc
    private func handleOpenWithPrimaryAction() {
        guard openWithPrimaryButton.isEnabled else {
            return
        }

        onOpenWithPrimaryAction?()
    }

    @objc
    private func handleOpenWithMenuAction() {
        guard openWithMenuButton.isEnabled else {
            return
        }

        onOpenWithMenuAction?()
    }

    private func updateBranchAppearance(animated: Bool) {
        let isHovered = branchLabel.isHovered && branchLabel.isInteractive
        let color = isHovered ? currentTheme.secondaryText : currentTheme.tertiaryText
        branchLabel.textColor = color
    }

    private func updatePullRequestInteraction() {
        guard let pullRequest = currentSummary.pullRequest else {
            pullRequestButton.isEnabled = false
            pullRequestButton.isInteractive = false
            pullRequestButton.toolTip = nil
            return
        }

        let isClickable = pullRequest.url != nil
        pullRequestButton.isEnabled = isClickable
        pullRequestButton.isInteractive = isClickable
        pullRequestButton.toolTip = isClickable ? "Open pull request #\(pullRequest.number) in browser" : nil
        pullRequestButton.setAccessibilityLabel("Pull request #\(pullRequest.number)")
        pullRequestButton.setAccessibilityHelp(
            isClickable
                ? "Opens pull request #\(pullRequest.number) in browser"
                : "Pull request link unavailable"
        )
    }

    private func updatePullRequestAppearance(animated: Bool) {
        let palette = pullRequestPalette(
            for: currentSummary.pullRequest,
            isHovered: pullRequestButton.isHovered,
            isInteractive: pullRequestButton.isInteractive
        )
        pullRequestButton.applyAppearance(
            background: palette.background,
            border: palette.border,
            text: palette.text,
            font: .systemFont(ofSize: 12, weight: .semibold),
            animated: animated
        )
    }

    private func updateOpenWithAppearance(animated: Bool) {
        let primaryTint = openWithPrimaryButton.isEnabled
            ? currentTheme.openWithChromePrimaryTint
            : currentTheme.openWithChromePrimaryTint.withAlphaComponent(0.48)
        let menuTint = openWithMenuButton.isEnabled
            ? currentTheme.openWithChromeChevronTint
            : currentTheme.openWithChromeChevronTint.withAlphaComponent(0.42)
        let primaryBackground = segmentBackgroundColor(
            isEnabled: openWithPrimaryButton.isEnabled,
            isHovered: openWithPrimaryButton.isHovered,
            isPressed: openWithPrimaryButton.isPressed
        )
        let menuBackground = segmentBackgroundColor(
            isEnabled: openWithMenuButton.isEnabled,
            isHovered: openWithMenuButton.isHovered,
            isPressed: openWithMenuButton.isPressed
        )
        performThemeAnimation(animated: animated) {
            self.openWithContainerView.layer?.backgroundColor = self.currentTheme.openWithChromeBackground.cgColor
            self.openWithContainerView.layer?.borderWidth = 1
            self.openWithContainerView.layer?.borderColor = self.currentTheme.openWithChromeBorder.cgColor
            self.openWithContainerView.layer?.shadowColor = self.currentTheme.openWithPopoverShadow
                .withAlphaComponent(0.45)
                .cgColor
            self.openWithDividerView.layer?.backgroundColor = self.currentTheme.openWithChromeDivider.cgColor
            self.openWithPrimaryBackgroundView.layer?.backgroundColor = primaryBackground.cgColor
            self.openWithMenuBackgroundView.layer?.backgroundColor = menuBackground.cgColor
            self.openWithPrimaryButton.contentTintColor = primaryTint
            self.openWithMenuButton.contentTintColor = menuTint
        }
    }

    private func segmentBackgroundColor(
        isEnabled: Bool,
        isHovered: Bool,
        isPressed: Bool
    ) -> NSColor {
        guard isEnabled else {
            return .clear
        }

        if isPressed {
            return currentTheme.openWithChromePressedBackground
        }

        if isHovered {
            return currentTheme.openWithChromeHoverBackground
        }

        return .clear
    }

    private func pullRequestPalette(
        for pullRequest: WorklanePullRequestSummary?,
        isHovered: Bool,
        isInteractive: Bool
    ) -> (background: NSColor, border: NSColor, text: NSColor) {
        let background = currentTheme.contextStripBackground
        let neutralBorder = currentTheme.contextStripBorder
        let neutralText = currentTheme.secondaryText
        guard let pullRequest else {
            return (background, neutralBorder, neutralText)
        }

        let accent = githubStateColor(for: pullRequest.state)
        let textMix = isHovered && isInteractive ? 0.12 : 0.20
        let borderMix = isHovered && isInteractive ? 0.28 : 0.40
        let text = accent
            .mixed(towards: currentTheme.primaryText, amount: textMix)
            .withAlphaComponent(isInteractive ? 0.96 : 0.84)
        let border = accent
            .mixed(towards: neutralBorder, amount: borderMix)
            .withAlphaComponent(isInteractive ? 0.72 : 0.58)
        return (background, border, text)
    }

    private func githubStateColor(for state: WorklanePullRequestState) -> NSColor {
        switch state {
        case .draft:
            return NSColor(hexString: "#59636E") ?? .systemGray
        case .open:
            return NSColor(hexString: "#1A7F37") ?? .systemGreen
        case .merged:
            return NSColor(hexString: "#8250DF") ?? .systemPurple
        case .closed:
            return NSColor(hexString: "#D1242F") ?? .systemRed
        }
    }

    private func syncVisibleRowContent(forceChipRefresh: Bool) {
        guard canRenderRowContent else {
            updateReviewChipViews(chips: [])
            return
        }

        updateReviewChipViews(force: forceChipRefresh)
    }

    private func updateReviewChipViews(force: Bool) {
        let desiredChips = currentSummary.reviewChips
        guard force || desiredChips != displayedReviewChips else {
            return
        }

        updateReviewChipViews(chips: desiredChips)
    }

    private func updateReviewChipViews(chips: [WorklaneReviewChip]) {
        displayedReviewChips = chips
        reviewChipViews.forEach { $0.removeFromSuperview() }
        reviewChipViews = chips.map { chip in
            let view = WindowChromeReviewChipView(chip: chip)
            view.apply(theme: currentTheme, animated: false)
            rowContainerView.addSubview(view)
            return view
        }
    }

    private func layoutRowContent() {
        let leadingViews = visibleLeadingViews()
        let chipViews = reviewChipViews
        guard !leadingViews.isEmpty || !chipViews.isEmpty else {
            rowContainerView.isHidden = true
            lastRowLayoutPlan = .empty
            return
        }

        let lane = visibleLaneFrame
        guard lane.width > 0.5, bounds.height >= Self.minimumRowHeight else {
            rowContainerView.isHidden = true
            lastRowLayoutPlan = .empty
            return
        }

        let rowHeight = Self.minimumRowHeight
        let rowWidth = lane.width
        guard rowWidth > 0 else {
            rowContainerView.isHidden = true
            lastRowLayoutPlan = .empty
            return
        }

        let originX = lane.minX

        rowContainerView.isHidden = false
        rowLeadingConstraint?.constant = originX
        rowCenterYConstraint?.constant = 0
        rowWidthConstraint?.constant = rowWidth
        rowHeightConstraint?.constant = rowHeight
        hasEstablishedRenderableLayout = true
        rowContainerView.layoutSubtreeIfNeeded()

        let layoutPlan = makeLayoutPlan(
            leadingViews: leadingViews,
            chipViews: chipViews,
            availableWidth: rowWidth
        )
        lastRowLayoutPlan = layoutPlan
        layout(items: layoutPlan.items, availableWidth: rowWidth, rowHeight: rowHeight)
    }

    private func layoutOpenWithControl() {
        guard currentOpenWithState != nil else {
            openWithContainerView.isHidden = true
            openWithContainerView.frame = .zero
            return
        }

        let width = Self.openWithControlWidth
        let height = Self.openWithControlHeight
        let originX = max(
            ChromeGeometry.headerHorizontalInset,
            bounds.width - ChromeGeometry.headerHorizontalInset - width
        )
        let originY = floor((bounds.height - height) / 2)
        openWithContainerView.frame = NSRect(x: originX, y: originY, width: width, height: height)
        openWithPrimaryBackgroundView.frame = NSRect(
            x: Self.openWithSegmentInset,
            y: Self.openWithSegmentInset,
            width: Self.openWithPrimaryWidth - Self.openWithSegmentInset,
            height: height - (Self.openWithSegmentInset * 2)
        )
        openWithPrimaryBackgroundView.layer?.cornerRadius = openWithPrimaryBackgroundView.frame.height / 2
        openWithMenuBackgroundView.frame = NSRect(
            x: width - Self.openWithMenuWidth + 1,
            y: Self.openWithSegmentInset,
            width: Self.openWithMenuWidth - Self.openWithSegmentInset,
            height: height - (Self.openWithSegmentInset * 2)
        )
        openWithMenuBackgroundView.layer?.cornerRadius = openWithMenuBackgroundView.frame.height / 2
        openWithPrimaryButton.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.openWithPrimaryWidth,
            height: height
        )
        openWithDividerView.frame = NSRect(
            x: Self.openWithPrimaryWidth,
            y: 7,
            width: 1,
            height: height - 14
        )
        openWithMenuButton.frame = NSRect(
            x: width - Self.openWithMenuWidth,
            y: 0,
            width: Self.openWithMenuWidth,
            height: height
        )
    }

    private func makeLayoutPlan(
        leadingViews: [NSView],
        chipViews: [WindowChromeReviewChipView],
        availableWidth: CGFloat
    ) -> RowLayoutPlan {
        let rowItems = leadingViews.map(makeRowItem(for:)) + chipViews.map(makeReviewChipRowItem(for:))
        let plannerItems = rowItems.map { rowItem in
            WindowChromeRowLayoutPlanner.Item(
                kind: rowItem.kind,
                preferredWidth: rowItem.preferredWidth,
                minimumWidth: rowItem.minimumWidth
            )
        }
        let plannerPlan = WindowChromeRowLayoutPlanner.plan(
            availableWidth: availableWidth,
            items: plannerItems
        )

        guard !rowItems.isEmpty else {
            return RowLayoutPlan(
                items: [],
                preferredTotalWidth: 0,
                finalTotalWidth: 0,
                overflowBeforeCompression: 0,
                overflowAfterChipEviction: 0,
                didDropReviewChips: false,
                didCompressItems: false
            )
        }

        let plannedItems = zip(rowItems, plannerPlan.items).map { rowItem, plannedItem in
            RowItem(
                view: rowItem.view,
                width: plannedItem.assignedWidth,
                preferredWidth: rowItem.preferredWidth,
                minimumWidth: rowItem.minimumWidth,
                kind: rowItem.kind
            )
        }
        return RowLayoutPlan(
            items: plannedItems.filter { $0.width > 0.5 },
            preferredTotalWidth: plannerPlan.preferredTotalWidth,
            finalTotalWidth: plannerPlan.finalTotalWidth,
            overflowBeforeCompression: plannerPlan.overflowBeforeCompression,
            overflowAfterChipEviction: plannerPlan.overflowAfterChipEviction,
            didDropReviewChips: plannerPlan.didDropReviewChips,
            didCompressItems: plannerPlan.didCompressItems
        )
    }

    private func makeRowItem(for view: NSView) -> RowItem {
        let preferredWidth = intrinsicWidth(for: view)
        let kind = kind(for: view)
        return RowItem(
            view: view,
            width: preferredWidth,
            preferredWidth: preferredWidth,
            minimumWidth: minimumWidth(for: view, preferredWidth: preferredWidth, kind: kind),
            kind: kind
        )
    }

    private func makeReviewChipRowItem(for view: WindowChromeReviewChipView) -> RowItem {
        let preferredWidth = intrinsicWidth(for: view)
        return RowItem(
            view: view,
            width: preferredWidth,
            preferredWidth: preferredWidth,
            minimumWidth: 0,
            kind: .reviewChip
        )
    }

    private func kind(for view: NSView) -> WindowChromeRowLayoutPlanner.Kind {
        switch view {
        case let attentionChip as WorklaneAttentionChipView where attentionChip === attentionChipView:
            return .attention
        case let imageView as WindowChromeProxyIconView where imageView === focusedProxyIconView:
            return .proxyIcon
        case let label as NSTextField where label === focusedLabel:
            return .focusedLabel
        case let label as WindowChromeBranchLabel where label === branchLabel:
            return .branch
        case let button as NSButton where button === pullRequestButton:
            return .pullRequest
        default:
            return .reviewChip
        }
    }

    private func minimumWidth(
        for view: NSView,
        preferredWidth: CGFloat,
        kind: WindowChromeRowLayoutPlanner.Kind
    ) -> CGFloat {
        switch kind {
        case .proxyIcon:
            return preferredWidth
        case .branch:
            return min(preferredWidth, Self.readableBranchWidth)
        case .pullRequest:
            return preferredWidth
        case .attention, .focusedLabel, .reviewChip:
            return 0
        }
    }

    private func layout(items: [RowItem], availableWidth: CGFloat, rowHeight: CGFloat) {
        visibleLeadingViews().forEach { $0.frame = .zero }
        reviewChipViews.forEach { $0.frame = .zero }

        let contentWidth = totalWidth(for: items)
        var cursorX = max(0, floor((availableWidth - contentWidth) / 2))

        for (index, item) in items.enumerated() {
            if index > 0 {
                cursorX += spacing(between: items[index - 1].kind, and: item.kind)
            }

            let intrinsicHeight = item.view.intrinsicContentSize.height
            let itemHeight = item.kind == .reviewChip ? rowHeight : min(rowHeight, max(0, intrinsicHeight))
            let originY = floor((rowHeight - itemHeight) / 2)
            item.view.frame = NSRect(
                x: cursorX,
                y: originY,
                width: item.width,
                height: itemHeight
            )
            cursorX += item.width
        }
    }

    private func totalSpacing(for items: [RowItem]) -> CGFloat {
        totalSpacing(for: items.map { RowWidthDescriptor(width: $0.width, kind: $0.kind) })
    }

    private func totalSpacing(for items: [RowWidthDescriptor]) -> CGFloat {
        guard items.count > 1 else {
            return 0
        }

        return zip(items, items.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + spacing(between: pair.0.kind, and: pair.1.kind)
        }
    }

    private func totalWidth(for items: [RowItem]) -> CGFloat {
        items.reduce(CGFloat.zero) { $0 + $1.width } + totalSpacing(for: items)
    }

    private func totalWidth(for items: [RowWidthDescriptor]) -> CGFloat {
        items.reduce(CGFloat.zero) { $0 + $1.width } + totalSpacing(for: items)
    }

    private func overflowWidth(for items: [RowItem], availableWidth: CGFloat) -> CGFloat {
        let visibleItems = items.filter { $0.width > 0.5 }
        return max(0, totalWidth(for: visibleItems) - availableWidth)
    }

    private func spacing(
        between previousKind: WindowChromeRowLayoutPlanner.Kind,
        and nextKind: WindowChromeRowLayoutPlanner.Kind
    ) -> CGFloat {
        switch (previousKind, nextKind) {
        case (.proxyIcon, .focusedLabel), (.focusedLabel, .proxyIcon):
            return 4
        case (.reviewChip, .reviewChip):
            return Self.reviewChipSpacing
        case (.reviewChip, _), (_, .reviewChip):
            return Self.sectionSpacing
        default:
            return Self.leadingItemSpacing
        }
    }

    private var effectiveLeadingVisibleInset: CGFloat {
        let minimumInset = ChromeGeometry.headerHorizontalInset
        let maximumInset = max(minimumInset, bounds.width - ChromeGeometry.headerHorizontalInset)
        return min(max(leadingVisibleInset, minimumInset), maximumInset)
    }

    var visibleLaneFrame: NSRect {
        let minX = effectiveLeadingVisibleInset
        let trailingInset = ChromeGeometry.headerHorizontalInset + openWithReservedWidth
        let maxX = max(minX, bounds.width - trailingInset)
        return NSRect(x: minX, y: 0, width: maxX - minX, height: bounds.height)
    }

    private var openWithReservedWidth: CGFloat {
        guard currentOpenWithState != nil else {
            return 0
        }

        return Self.openWithControlWidth + Self.openWithSectionSpacing
    }

    private var canRenderRowContent: Bool {
        guard bounds.height >= Self.minimumRowHeight else {
            return false
        }

        let minimumLaneWidth = hasEstablishedRenderableLayout ? 0.5 : Self.minimumBootstrapLaneWidth
        return visibleLaneFrame.width >= minimumLaneWidth
    }

    private func visibleLeadingViews() -> [NSView] {
        [attentionChipView, focusedProxyIconView, focusedLabel, branchLabel, pullRequestButton]
            .filter { !$0.isHidden }
    }

    private func renderFocusedProxyIcon() {
        focusedProxyIconView.render(
            cwdPath: WorklaneContextFormatter.trimmed(currentSummary.cwdPath),
            tintColor: currentTheme.secondaryText,
            size: Self.proxyIconSize
        )
    }

    private func intrinsicWidth(for view: NSView) -> CGFloat {
        switch view {
        case let attentionChip as WorklaneAttentionChipView:
            return attentionChip.preferredWidthForCurrentContent
        case let label as NSTextField:
            return Self.requiredSingleLineWidth(for: label)
        case let button as NSButton:
            return Self.requiredSingleLineWidth(for: button)
        default:
            return view.fittingSize.width
        }
    }

    private static func makeLabel(
        text: String,
        color: NSColor,
        font: NSFont,
        lineBreakMode: NSLineBreakMode
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = lineBreakMode
        label.usesSingleLineMode = true
        return label
    }

    private static func measureLabelWidth(
        text: String,
        font: NSFont,
        lineBreakMode: NSLineBreakMode
    ) -> CGFloat {
        let label = makeLabel(
            text: text,
            color: .labelColor,
            font: font,
            lineBreakMode: lineBreakMode
        )
        return requiredSingleLineWidth(for: label)
    }

    private static func requiredSingleLineWidth(for label: NSTextField) -> CGFloat {
        let fittingWidth = label.fittingSize.width
        let intrinsicWidth = label.intrinsicContentSize.width
        let cellWidth = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width ?? 0
        return ceil(max(fittingWidth, intrinsicWidth, cellWidth))
    }

    private static func requiredSingleLineWidth(for button: NSButton) -> CGFloat {
        if let pullRequestButton = button as? WindowChromePullRequestButton {
            return pullRequestButton.requiredWidthForSingleLineLayout
        }

        let fittingWidth = button.fittingSize.width
        let intrinsicWidth = button.intrinsicContentSize.width
        let cellWidth = button.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: 10_000, height: Self.minimumRowHeight)
        ).width ?? 0
        return ceil(max(fittingWidth, intrinsicWidth, cellWidth))
    }

    var titleText: String { "" }
    var isAttentionHidden: Bool { attentionChipView.isHidden }
    var attentionText: String { attentionChipView.stateTextForTesting }
    var attentionArtifactText: String { attentionChipView.artifactTextForTesting }
    var isFocusedProxyIconHidden: Bool { focusedProxyIconView.isHidden }
    var focusedProxyIconCwdPath: String? { focusedProxyIconView.cwdPath }
    var focusedProxyIconAlphaValue: CGFloat { focusedProxyIconView.alphaValue }
    var focusedProxyIconTintTokenForTesting: String { focusedProxyIconView.contentTintColor?.themeToken ?? "" }
    var isFocusedProxyIconTemplate: Bool { focusedProxyIconView.image?.isTemplate == true }
    var isFocusedProxyIconUsingPopupMenu: Bool { focusedProxyIconView.usesPopupMenuForTesting }
    var focusedProxyIconFrame: NSRect { focusedProxyIconView.frame }
    var focusedLabelText: String { focusedLabel.stringValue }
    var focusedLabelFrame: NSRect { focusedLabel.frame }
    var branchText: String { branchLabel.stringValue }
    var isBranchInteractive: Bool { branchLabel.isInteractive }
    var branchToolTip: String { branchLabel.toolTip ?? "" }
    var pullRequestText: String { pullRequestButton.title }
    var isPullRequestEnabled: Bool { pullRequestButton.isEnabled }
    var pullRequestToolTip: String { pullRequestButton.toolTip ?? "" }
    var isPullRequestCompressed: Bool {
        pullRequestButton.frame.width > 0 && pullRequestButton.frame.width < Self.requiredSingleLineWidth(for: pullRequestButton)
    }
    var pullRequestFrameWidth: CGFloat { pullRequestButton.frame.width }
    var pullRequestIntrinsicWidth: CGFloat { Self.requiredSingleLineWidth(for: pullRequestButton) }
    var pullRequestCellRequiredWidthForTesting: CGFloat {
        pullRequestButton.requiredWidthForSingleLineLayout
    }
    var pullRequestTitleWidthForTesting: CGFloat { pullRequestButton.titleWidthForTesting }
    var pullRequestBackgroundTokenForTesting: String {
        pullRequestButton.backgroundColorForTesting.themeToken
    }
    var pullRequestTextColorTokenForTesting: String {
        pullRequestButton.titleColorForTesting.themeToken
    }
    var pullRequestBorderColorTokenForTesting: String {
        pullRequestButton.borderColorForTesting.themeToken
    }
    var pullRequestTextAlphaForTesting: CGFloat {
        pullRequestButton.titleColorForTesting.srgbClamped.alphaComponent
    }
    var pullRequestBorderAlphaForTesting: CGFloat {
        pullRequestButton.borderColorForTesting.srgbClamped.alphaComponent
    }
    var reviewChipTexts: [String] { displayedReviewChips.map(\.text) }
    var isBranchMonospaced: Bool {
        branchLabel.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }
    var rowLineCount: Int {
        let labelsStaySingleLine = [focusedLabel, branchLabel]
            .filter { !$0.isHidden }
            .allSatisfy { $0.usesSingleLineMode && $0.lineBreakMode != .byWordWrapping }
        let pullRequestStaysSingleLine = pullRequestButton.isHidden || (pullRequestButton.cell?.wraps == false)
        return labelsStaySingleLine && pullRequestStaysSingleLine ? 1 : 2
    }
    var isFocusedLabelCompressed: Bool {
        focusedLabel.frame.width > 0 && focusedLabel.frame.width < Self.requiredSingleLineWidth(for: focusedLabel)
    }
    var didCompressItems: Bool { lastRowLayoutPlan.didCompressItems }
    var preferredTotalWidth: CGFloat { lastRowLayoutPlan.preferredTotalWidth }
    var finalTotalWidth: CGFloat { lastRowLayoutPlan.finalTotalWidth }
    var overflowBeforeCompression: CGFloat { lastRowLayoutPlan.overflowBeforeCompression }
    var overflowAfterChipEviction: CGFloat { lastRowLayoutPlan.overflowAfterChipEviction }
    var focusedLabelFrameWidth: CGFloat { focusedLabel.frame.width }
    var focusedLabelIntrinsicWidth: CGFloat { Self.requiredSingleLineWidth(for: focusedLabel) }
    var branchFrameWidth: CGFloat { branchLabel.frame.width }
    var branchIntrinsicWidth: CGFloat { Self.requiredSingleLineWidth(for: branchLabel) }
    var rowFrame: NSRect { rowContainerView.frame }
    var openWithControlFrame: NSRect { openWithContainerView.frame }
    var openWithPrimaryFrame: NSRect { openWithPrimaryButton.frame }
    var openWithMenuFrame: NSRect { openWithMenuButton.frame }
    var openWithMenuAnchorRect: NSRect { openWithContainerView.frame }
    var openWithBackgroundTokenForTesting: String {
        openWithContainerView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }
    var openWithDividerTokenForTesting: String {
        openWithDividerView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }
    var openWithDividerAlphaForTesting: CGFloat {
        openWithDividerView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.srgbClamped.alphaComponent ?? 0
    }
    var openWithPrimaryTintTokenForTesting: String { openWithPrimaryButton.contentTintColor?.themeToken ?? "" }
    var openWithMenuTintTokenForTesting: String { openWithMenuButton.contentTintColor?.themeToken ?? "" }

    func performOpenWithPrimaryClickForTesting() {
        openWithPrimaryButton.performClick(openWithPrimaryButton)
    }

    func performOpenWithMenuClickForTesting() {
        openWithMenuButton.performClick(openWithMenuButton)
    }

    func focusedProxyIconContextMenuPathsForTesting() -> [String] {
        focusedProxyIconView.contextMenuPathsForTesting()
    }

    func focusedProxyIconContextMenuTitlesForTesting() -> [String] {
        focusedProxyIconView.contextMenuTitlesForTesting()
    }

    func focusedLabelContextMenuPathsForTesting() -> [String] {
        guard let event = Self.contextMenuEventForTesting() else {
            return []
        }

        return focusedLabel.menu(for: event)?.items.compactMap { ($0.representedObject as? URL)?.path } ?? []
    }

    func performFocusedProxyIconMenuSelectionForTesting(path: String) {
        focusedProxyIconView.performMenuSelectionForTesting(path: path)
    }

    func performFocusedProxyIconComputerMenuSelectionForTesting() {
        focusedProxyIconView.performComputerMenuSelectionForTesting()
    }

    func performFocusedProxyIconDoubleClickForTesting() {
        focusedProxyIconView.performDoubleClickForTesting()
    }

    func focusedProxyIconDragFileURLForTesting() -> URL? {
        focusedProxyIconView.dragFileURLForTesting()
    }

    func focusedProxyIconDragPasteboardWriterTypeForTesting() -> String {
        focusedProxyIconView.dragPasteboardWriterTypeForTesting()
    }

    func focusedProxyIconCapturesHitPointForTesting(_ localPoint: NSPoint) -> Bool {
        guard let superview = focusedProxyIconView.superview else { return false }
        let superviewPoint = focusedProxyIconView.convert(localPoint, to: superview)
        return focusedProxyIconView.hitTest(superviewPoint) === focusedProxyIconView
    }

    func focusedProxyIconLeadingPaddingPointInWindowForTesting() -> NSPoint? {
        guard focusedProxyIconView.isHidden == false, focusedProxyIconView.alphaValue > 0 else {
            return nil
        }

        let point = NSPoint(x: 2, y: floor(focusedProxyIconView.bounds.height / 2))
        return focusedProxyIconView.convert(point, to: nil)
    }

    func containsFocusedProxyIconPointInWindow(_ point: NSPoint) -> Bool {
        guard focusedProxyIconView.isHidden == false, focusedProxyIconView.alphaValue > 0 else {
            return false
        }

        let localPoint = focusedProxyIconView.convert(point, from: nil)
        return focusedProxyIconView.bounds.contains(localPoint)
    }

    func deliverFocusedProxyMouseDown(with event: NSEvent) {
        focusedProxyIconView.mouseDown(with: event)
    }

    func focusedProxyIconCapturesWindowHitPointForTesting(_ windowPoint: NSPoint) -> Bool {
        guard focusedProxyIconView.isHidden == false, focusedProxyIconView.alphaValue > 0 else {
            return false
        }
        guard let superview = focusedProxyIconView.superview else { return false }
        let superviewPoint = superview.convert(windowPoint, from: nil)
        return focusedProxyIconView.hitTest(superviewPoint) === focusedProxyIconView
    }

    var isFocusedProxyIconWindowDragSuppressedForTesting: Bool {
        focusedProxyIconView.isWindowDragSuppressedForTesting
    }

    func seedFocusedProxyIconWindowDragSuppressionForTesting(window: NSWindow) {
        focusedProxyIconView.seedWindowDragSuppressionForTesting(window: window)
    }

    func setFocusedProxyIconDragSessionActiveForTesting(_ active: Bool) {
        focusedProxyIconView.setDragSessionActiveForTesting(active)
    }

    private static func contextMenuEventForTesting() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    }
}

private final class WindowChromeProxyIconView: NSView, NSDraggingSource {
    private static let accessibilityDescription = "Focused working directory"
    private static let menuIconSize = NSSize(width: 16, height: 16)
    private static let minimumHitTargetSize = NSSize(width: 30, height: 22)
    fileprivate static let rootVolumeFallbackTitle = "Macintosh HD"

    private let iconView = WindowChromePassiveImageView()
    private(set) var cwdPath: String?
    private var currentDirectoryURL: URL?
    private var iconSize: NSSize = .zero
    private(set) var contentTintColor: NSColor?
    private var suppressedWindow: NSWindow?
    private var previousWindowMovableState: Bool?
    private var isDragSessionActive = false
    private var didArmWindowDragSuppression = false
    private var lastHandledMouseDownTimestamp: TimeInterval = -1
    var revealPath: (URL) -> Void = { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path) }
    var openComputerLocation: (URL) -> Void = { NSWorkspace.shared.open($0) }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard
            isHidden == false,
            alphaValue > 0,
            currentDirectoryURL != nil,
            frame.contains(point)
        else {
            return nil
        }

        maybeDisableWindowDraggingEarly()
        return self
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let baseSize = iconSize == .zero ? NSSize(width: 14, height: 14) : iconSize
        return NSSize(
            width: max(baseSize.width, Self.minimumHitTargetSize.width),
            height: max(baseSize.height, Self.minimumHitTargetSize.height)
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard currentDirectoryURL != nil else { return }
        let expanded = bounds.insetBy(dx: -8, dy: -8)
        let area = NSTrackingArea(
            rect: expanded,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard currentDirectoryURL != nil, let window, window.isMovable else { return }
        previousWindowMovableState = window.isMovable
        suppressedWindow = window
        window.isMovable = false
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragSessionActive else { return }
        restoreWindowDraggingIfNeeded()
    }

    override func layout() {
        super.layout()

        let iconOrigin = NSPoint(
            x: max(0, floor(bounds.width - iconSize.width)),
            y: floor((bounds.height - iconSize.height) / 2)
        )
        iconView.frame = NSRect(origin: iconOrigin, size: iconSize)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.timestamp != lastHandledMouseDownTimestamp else { return }
        lastHandledMouseDownTimestamp = event.timestamp

        guard let currentDirectoryURL else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            revealCurrentDirectoryInFinder()
            return
        }

        suppressWindowDraggingIfNeeded()
        beginDragSession(with: currentDirectoryURL, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard isDragSessionActive == false else {
            return
        }

        restoreWindowDraggingIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard currentDirectoryURL != nil else {
            super.rightMouseDown(with: event)
            return
        }

        presentPathMenu(with: event)
    }

    func render(cwdPath: String?, tintColor: NSColor, size: NSSize) {
        iconSize = size
        invalidateIntrinsicContentSize()
        self.cwdPath = cwdPath
        contentTintColor = nil
        needsLayout = true

        guard let trimmedPath = WorklaneContextFormatter.trimmed(cwdPath) else {
            iconView.image = nil
            currentDirectoryURL = nil
            isHidden = true
            alphaValue = 0
            if isDragSessionActive == false {
                restoreWindowDraggingIfNeeded()
            }
            return
        }

        let image = NSWorkspace.shared.icon(forFile: trimmedPath)
        image.size = size

        iconView.image = image
        iconView.contentTintColor = nil
        currentDirectoryURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        isHidden = false
        alphaValue = 1
    }

    var image: NSImage? { iconView.image }

    func contextMenuPathsForTesting() -> [String] {
        pathMenuItems().map(\.url.path)
    }

    func contextMenuTitlesForTesting() -> [String] {
        pathMenuItems().map(\.title) + [Self.computerName]
    }

    func performMenuSelectionForTesting(path: String) {
        revealPath(URL(fileURLWithPath: path, isDirectory: true))
    }

    func performComputerMenuSelectionForTesting() {
        handleComputerMenuSelection(NSMenuItem())
    }

    func performDoubleClickForTesting() {
        revealCurrentDirectoryInFinder()
    }

    func dragFileURLForTesting() -> URL? {
        currentDirectoryURL
    }

    func dragPasteboardWriterTypeForTesting() -> String {
        currentDirectoryURL == nil ? "" : String(describing: NSURL.self)
    }

    var usesPopupMenuForTesting: Bool { true }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        setAccessibilityLabel(Self.accessibilityDescription)
    }

    private func presentPathMenu(with event: NSEvent) {
        guard let menu = makePathMenu() else {
            return
        }

        let menuLocation = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func makePathMenu() -> NSMenu? {
        let items = pathMenuItems()
        guard items.isEmpty == false else {
            return nil
        }

        let menu = NSMenu(title: "")
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(handlePathMenuSelection(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.url
            menuItem.image = Self.menuIcon(for: item.url)
            menu.addItem(menuItem)
        }

        let computerItem = NSMenuItem(title: Self.computerName, action: #selector(handleComputerMenuSelection(_:)), keyEquivalent: "")
        computerItem.target = self
        computerItem.image = Self.computerIcon()
        menu.addItem(computerItem)
        return menu
    }

    @objc
    private func handlePathMenuSelection(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }

        revealPath(url)
    }

    @objc
    private func handleComputerMenuSelection(_: NSMenuItem) {
        openComputerLocation(URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func pathMenuItems() -> [WindowChromeProxyIconPathMenuItem] {
        WindowChromeProxyIconPathHierarchy.items(for: cwdPath)
    }

    private func beginDragSession(with currentDirectoryURL: URL, event: NSEvent) {
        let draggingItem = NSDraggingItem(pasteboardWriter: currentDirectoryURL as NSURL)
        let dragImage = NSWorkspace.shared.icon(forFile: currentDirectoryURL.path)
        dragImage.size = iconSize
        draggingItem.setDraggingFrame(iconView.frame, contents: dragImage)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func suppressWindowDraggingIfNeeded() {
        guard suppressedWindow == nil, let window else {
            return
        }
        guard (window as? ProxyWindowDragSuppressionControlling)?.isProxyWindowDragSuppressionActive != true else {
            return
        }

        suppressedWindow = window
        previousWindowMovableState = window.isMovable
        if window.isMovable {
            window.isMovable = false
        }
    }

    private func maybeDisableWindowDraggingEarly() {
        guard !didArmWindowDragSuppression else {
            return
        }
        guard let eventType = NSApp.currentEvent?.type,
              eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return
        }

        didArmWindowDragSuppression = true
        suppressWindowDraggingIfNeeded()
    }

    func armWindowDragSuppressionIfNeeded() {
        maybeDisableWindowDraggingEarly()
    }

    private func restoreWindowDraggingIfNeeded() {
        guard let suppressedWindow else {
            didArmWindowDragSuppression = false
            return
        }

        if let previousWindowMovableState, suppressedWindow.isMovable != previousWindowMovableState {
            suppressedWindow.isMovable = previousWindowMovableState
        }

        self.suppressedWindow = nil
        previousWindowMovableState = nil
        didArmWindowDragSuppression = false
    }

    func restoreWindowDragSuppressionIfNeeded() {
        restoreWindowDraggingIfNeeded()
    }

    private static func menuIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = menuIconSize
        return icon
    }

    private func revealCurrentDirectoryInFinder() {
        guard let currentDirectoryURL else {
            return
        }

        revealPath(currentDirectoryURL)
    }

    private static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func computerIcon() -> NSImage {
        let icon = NSImage(named: NSImage.computerName) ?? NSImage()
        icon.size = menuIconSize
        return icon
    }

    func draggingSession(
        _: NSDraggingSession,
        willBeginAt _: NSPoint
    ) {
        isDragSessionActive = true
    }

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(
        _: NSDraggingSession,
        endedAt _: NSPoint,
        operation _: NSDragOperation
    ) {
        isDragSessionActive = false
        restoreWindowDraggingIfNeeded()
        (window as? ProxyWindowDragSuppressionControlling)?.restoreProxySuppression()
    }

    func ignoreModifierKeys(for _: NSDraggingSession) -> Bool {
        true
    }

    var isWindowDragSuppressedForTesting: Bool { suppressedWindow != nil }

    func seedWindowDragSuppressionForTesting(window: NSWindow) {
        suppressedWindow = window
        previousWindowMovableState = true
        if window.isMovable {
            window.isMovable = false
        }
    }

    func setDragSessionActiveForTesting(_ active: Bool) {
        isDragSessionActive = active
    }

    func armWindowDragSuppressionForTesting(window: NSWindow) {
        didArmWindowDragSuppression = true
        seedWindowDragSuppressionForTesting(window: window)
    }
}

private final class WindowChromePassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct WindowChromeProxyIconPathMenuItem: Equatable {
    let url: URL

    var title: String {
        guard url.path == "/" else {
            return FileManager.default.displayName(atPath: url.path)
        }

        if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
            return volumeName
        }
        return WindowChromeProxyIconView.rootVolumeFallbackTitle
    }
}

private enum WindowChromeProxyIconPathHierarchy {
    static func items(for cwdPath: String?) -> [WindowChromeProxyIconPathMenuItem] {
        guard let trimmedPath = WorklaneContextFormatter.trimmed(cwdPath), !trimmedPath.isEmpty else {
            return []
        }

        var currentURL = URL(fileURLWithPath: trimmedPath, isDirectory: true).standardizedFileURL
        var urls: [URL] = []

        while true {
            urls.append(currentURL)
            guard currentURL.path != "/" else {
                break
            }
            currentURL = currentURL.deletingLastPathComponent()
        }

        return urls.map(WindowChromeProxyIconPathMenuItem.init(url:))
    }
}

private final class WindowChromeSegmentButton: NSButton {
    var onInteractionStateChanged: (() -> Void)?
    private(set) var isHovered = false
    private(set) var isPressed = false
    private var trackingAreaValue: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }

        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else {
            return
        }

        isHovered = true
        onInteractionStateChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        onInteractionStateChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onInteractionStateChanged?()
        super.mouseDown(with: event)
        isPressed = false
        onInteractionStateChanged?()
    }
}

private struct RowLayoutPlan {
    let items: [RowItem]
    let preferredTotalWidth: CGFloat
    let finalTotalWidth: CGFloat
    let overflowBeforeCompression: CGFloat
    let overflowAfterChipEviction: CGFloat
    let didDropReviewChips: Bool
    let didCompressItems: Bool

    static let empty = RowLayoutPlan(
        items: [],
        preferredTotalWidth: 0,
        finalTotalWidth: 0,
        overflowBeforeCompression: 0,
        overflowAfterChipEviction: 0,
        didDropReviewChips: false,
        didCompressItems: false
    )
}

private struct RowItem {
    let view: NSView
    var width: CGFloat
    let preferredWidth: CGFloat
    let minimumWidth: CGFloat
    let kind: WindowChromeRowLayoutPlanner.Kind
}

private struct RowWidthDescriptor {
    let width: CGFloat
    let kind: WindowChromeRowLayoutPlanner.Kind
}

private final class WindowChromePullRequestButtonCell: NSButtonCell {
    override func cellSize(forBounds rect: NSRect) -> NSSize {
        var size = super.cellSize(forBounds: rect)
        let attributed = attributedTitle.length > 0 ? attributedTitle : NSAttributedString(
            string: title,
            attributes: [.font: font ?? .systemFont(ofSize: 12, weight: .semibold)]
        )
        let titleWidth = attributed.boundingRect(
            with: NSSize(width: 10_000, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width
        size.width = ceil(titleWidth + WindowChromePullRequestButton.horizontalPadding * 2)
        return size
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let insetFrame = frame.insetBy(dx: WindowChromePullRequestButton.horizontalPadding, dy: 0)
        return super.drawTitle(title, withFrame: insetFrame, in: controlView)
    }
}

private final class WindowChromePullRequestButton: NSButton {
    private static let minimumHeight: CGFloat = 20
    static let horizontalPadding: CGFloat = 10

    var onHoverChanged: (() -> Void)?
    var isInteractive = false {
        didSet {
            guard oldValue != isInteractive else {
                return
            }

            if !isInteractive {
                isHovered = false
            }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var trackingAreaValue: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var titleColorForTesting = NSColor.clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var attributedTitle: NSAttributedString {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(
            width: requiredWidthForSingleLineLayout,
            height: max(Self.minimumHeight, ceil(base.height + 4))
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func commonInit() {
        if !(cell is WindowChromePullRequestButtonCell) {
            cell = WindowChromePullRequestButtonCell(textCell: title)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
            self.trackingAreaValue = nil
        }

        guard isInteractive else {
            return
        }

        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isInteractive else {
            return
        }

        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractive else {
            super.cursorUpdate(with: event)
            return
        }

        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isInteractive, !isHovered else {
            return
        }

        isHovered = true
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        onHoverChanged?()
    }

    func applyAppearance(
        background: NSColor,
        border: NSColor,
        text: NSColor,
        font: NSFont,
        animated: Bool
    ) {
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        titleColorForTesting = text
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: text,
            ]
        )

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
        }
    }

    var requiredWidthForSingleLineLayout: CGFloat {
        ceil(titleWidthForTesting + Self.horizontalPadding * 2)
    }

    var titleWidthForTesting: CGFloat {
        let currentTitle = attributedTitle.length > 0 ? attributedTitle : NSAttributedString(
            string: title,
            attributes: [.font: font ?? .systemFont(ofSize: 12, weight: .semibold)]
        )
        return ceil(
            currentTitle.boundingRect(
                with: NSSize(width: 10_000, height: 100),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width
        )
    }

    var backgroundColorForTesting: NSColor {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear
    }

    var borderColorForTesting: NSColor {
        layer?.borderColor.flatMap(NSColor.init(cgColor:)) ?? .clear
    }
}

private final class WindowChromeBranchLabel: NSTextField {
    var onHoverChanged: (() -> Void)?
    var isInteractive = false {
        didSet {
            guard oldValue != isInteractive else {
                return
            }

            if !isInteractive {
                isHovered = false
            }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }

    private(set) var isHovered = false
    private var trackingAreaValue: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        lineBreakMode = .byTruncatingMiddle
        usesSingleLineMode = true
        textColor = .tertiaryLabelColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
            self.trackingAreaValue = nil
        }

        guard isInteractive else {
            return
        }

        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isInteractive else {
            return
        }

        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractive else {
            super.cursorUpdate(with: event)
            return
        }

        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isInteractive, !isHovered else {
            return
        }

        isHovered = true
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        onHoverChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive, let action = action, let target = target else {
            super.mouseDown(with: event)
            return
        }

        NSApp.sendAction(action, to: target, from: self)
    }
}

private final class WindowChromeReviewChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let chip: WorklaneReviewChip

    init(chip: WorklaneReviewChip) {
        self.chip = chip
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.stringValue = chip.text
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = true
        addSubview(label)
    }

    override func layout() {
        super.layout()
        let labelHeight = min(bounds.height, label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: 10,
            y: floor((bounds.height - labelHeight) / 2),
            width: max(0, bounds.width - 20),
            height: labelHeight
        )
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let palette = colors(for: theme)
        label.textColor = palette.text

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = palette.background.cgColor
            self.layer?.borderColor = palette.border.cgColor
        }
    }

    private func colors(for theme: ZenttyTheme) -> (background: NSColor, border: NSColor, text: NSColor) {
        let baseBackground = theme.contextStripBackground
        let baseBorder = theme.contextStripBorder
        switch chip.style {
        case .neutral:
            return (
                background: baseBackground,
                border: baseBorder,
                text: theme.secondaryText
            )
        case .success:
            return (
                background: baseBackground.mixed(towards: .systemGreen, amount: 0.18),
                border: baseBorder.mixed(towards: .systemGreen, amount: 0.34),
                text: theme.primaryText
            )
        case .warning:
            return (
                background: baseBackground.mixed(towards: .systemOrange, amount: 0.20),
                border: baseBorder.mixed(towards: .systemOrange, amount: 0.36),
                text: theme.primaryText
            )
        case .danger:
            return (
                background: baseBackground.mixed(towards: .systemRed, amount: 0.20),
                border: baseBorder.mixed(towards: .systemRed, amount: 0.38),
                text: theme.primaryText
            )
        case .info:
            return (
                background: baseBackground.mixed(towards: theme.worklaneChipBackground, amount: 0.24),
                border: baseBorder.mixed(towards: .systemBlue, amount: 0.28),
                text: theme.primaryText
            )
        }
    }

    var text: String { label.stringValue }

    static func preferredWidth(for chip: WorklaneReviewChip) -> CGFloat {
        let label = NSTextField(labelWithString: chip.text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        return ceil(max(label.fittingSize.width, label.intrinsicContentSize.width)) + 20
    }
}
