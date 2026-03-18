import AppKit

final class WindowChromeView: NSView {
    static let preferredHeight: CGFloat = ChromeGeometry.headerHeight
    private static let minimumBootstrapLaneWidth: CGFloat = 160
    private static let minimumRowHeight: CGFloat = 22
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

    private let attentionChipView = WorkspaceAttentionChipView()
    private let rowContainerView = NSView()
    private let focusedLabel = WindowChromeView.makeLabel(
        text: "",
        color: .secondaryLabelColor,
        font: .systemFont(ofSize: 12, weight: .medium),
        lineBreakMode: .byTruncatingTail
    )
    private let branchLabel = WindowChromeView.makeLabel(
        text: "",
        color: .tertiaryLabelColor,
        font: .monospacedSystemFont(ofSize: 12, weight: .medium),
        lineBreakMode: .byTruncatingMiddle
    )
    private let pullRequestButton = NSButton(title: "", target: nil, action: nil)

    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var currentSummary = WorkspaceChromeSummary(
        attention: nil,
        focusedLabel: nil,
        branch: nil,
        pullRequest: nil,
        reviewChips: []
    )
    private var displayedReviewChips: [WorkspaceReviewChip] = []
    private var reviewChipViews: [WindowChromeReviewChipView] = []
    private var pullRequestURL: URL?
    private var rowLeadingConstraint: NSLayoutConstraint?
    private var rowCenterYConstraint: NSLayoutConstraint?
    private var rowWidthConstraint: NSLayoutConstraint?
    private var rowHeightConstraint: NSLayoutConstraint?
    private var hasEstablishedRenderableLayout = false
    private var lastRowLayoutPlan = RowLayoutPlan.empty

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        syncVisibleRowContent(forceChipRefresh: false)
        layoutRowContent()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        focusedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focusedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        branchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        branchLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        pullRequestButton.isBordered = false
        pullRequestButton.bezelStyle = .inline
        pullRequestButton.font = .systemFont(ofSize: 12, weight: .semibold)
        pullRequestButton.setButtonType(.momentaryChange)
        pullRequestButton.target = self
        pullRequestButton.action = #selector(openPullRequest)
        pullRequestButton.lineBreakMode = .byClipping
        pullRequestButton.cell?.wraps = false

        rowContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowContainerView)
        [attentionChipView, focusedLabel, branchLabel, pullRequestButton].forEach {
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
    }

    func render(summary: WorkspaceChromeSummary) {
        currentSummary = summary
        pullRequestURL = summary.pullRequest?.url

        attentionChipView.render(attention: summary.attention)

        let focusedText = summary.focusedLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        focusedLabel.stringValue = focusedText
        focusedLabel.isHidden = focusedText.isEmpty

        let branchText = summary.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        branchLabel.stringValue = branchText
        branchLabel.isHidden = branchText.isEmpty

        pullRequestButton.title = summary.pullRequest.map { "PR #\($0.number)" } ?? ""
        pullRequestButton.isHidden = summary.pullRequest == nil

        syncVisibleRowContent(forceChipRefresh: true)
        needsLayout = true
    }

    func render(
        workspaceName: String,
        state: PaneStripState,
        metadata: TerminalMetadata?,
        attention: WorkspaceAttentionSummary?
    ) {
        let summary = WorkspaceChromeSummary(
            attention: attention,
            focusedLabel: metadata?.title ?? metadata?.processName ?? state.focusedPane?.title,
            branch: metadata?.gitBranch,
            pullRequest: nil,
            reviewChips: []
        )
        render(summary: summary)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        attentionChipView.apply(theme: theme, animated: animated)

        focusedLabel.textColor = theme.secondaryText
        branchLabel.textColor = theme.tertiaryText
        pullRequestButton.contentTintColor = theme.secondaryText
        reviewChipViews.forEach { $0.apply(theme: theme, animated: animated) }

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.topChromeBackground.cgColor
        }
    }

    @objc
    private func openPullRequest() {
        guard let pullRequestURL else {
            return
        }

        NSWorkspace.shared.open(pullRequestURL)
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

    private func updateReviewChipViews(chips: [WorkspaceReviewChip]) {
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
        case let attentionChip as WorkspaceAttentionChipView where attentionChip === attentionChipView:
            return .attention
        case let label as NSTextField where label === focusedLabel:
            return .focusedLabel
        case let label as NSTextField where label === branchLabel:
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

    private var visibleLaneFrame: NSRect {
        let minX = effectiveLeadingVisibleInset
        let maxX = max(minX, bounds.width - ChromeGeometry.headerHorizontalInset)
        return NSRect(x: minX, y: 0, width: maxX - minX, height: bounds.height)
    }

    private var canRenderRowContent: Bool {
        guard bounds.height >= Self.minimumRowHeight else {
            return false
        }

        let minimumLaneWidth = hasEstablishedRenderableLayout ? 0.5 : Self.minimumBootstrapLaneWidth
        return visibleLaneFrame.width >= minimumLaneWidth
    }

    private func visibleLeadingViews() -> [NSView] {
        [attentionChipView, focusedLabel, branchLabel, pullRequestButton]
            .filter { !$0.isHidden }
    }

    private func intrinsicWidth(for view: NSView) -> CGFloat {
        switch view {
        case let attentionChip as WorkspaceAttentionChipView:
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
        ceil(max(button.fittingSize.width, button.intrinsicContentSize.width))
    }

    var titleTextForTesting: String { "" }
    var isAttentionHiddenForTesting: Bool { attentionChipView.isHidden }
    var attentionTextForTesting: String { attentionChipView.stateTextForTesting }
    var attentionArtifactTextForTesting: String { attentionChipView.artifactTextForTesting }
    var focusedLabelTextForTesting: String { focusedLabel.stringValue }
    var branchTextForTesting: String { branchLabel.stringValue }
    var pullRequestTextForTesting: String { pullRequestButton.title }
    var isPullRequestCompressedForTesting: Bool {
        pullRequestButton.frame.width > 0 && pullRequestButton.frame.width < Self.requiredSingleLineWidth(for: pullRequestButton)
    }
    var pullRequestFrameWidthForTesting: CGFloat { pullRequestButton.frame.width }
    var pullRequestIntrinsicWidthForTesting: CGFloat { Self.requiredSingleLineWidth(for: pullRequestButton) }
    var reviewChipTextsForTesting: [String] { displayedReviewChips.map(\.text) }
    var isBranchMonospacedForTesting: Bool {
        branchLabel.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }
    var rowLineCountForTesting: Int {
        let labelsStaySingleLine = [focusedLabel, branchLabel]
            .filter { !$0.isHidden }
            .allSatisfy { $0.usesSingleLineMode && $0.lineBreakMode != .byWordWrapping }
        let pullRequestStaysSingleLine = pullRequestButton.isHidden || (pullRequestButton.cell?.wraps == false)
        return labelsStaySingleLine && pullRequestStaysSingleLine ? 1 : 2
    }
    var isFocusedLabelCompressedForTesting: Bool {
        focusedLabel.frame.width > 0 && focusedLabel.frame.width < Self.requiredSingleLineWidth(for: focusedLabel)
    }
    var didCompressItemsForTesting: Bool { lastRowLayoutPlan.didCompressItems }
    var preferredTotalWidthForTesting: CGFloat { lastRowLayoutPlan.preferredTotalWidth }
    var finalTotalWidthForTesting: CGFloat { lastRowLayoutPlan.finalTotalWidth }
    var overflowBeforeCompressionForTesting: CGFloat { lastRowLayoutPlan.overflowBeforeCompression }
    var overflowAfterChipEvictionForTesting: CGFloat { lastRowLayoutPlan.overflowAfterChipEviction }
    var focusedLabelFrameWidthForTesting: CGFloat { focusedLabel.frame.width }
    var focusedLabelIntrinsicWidthForTesting: CGFloat { Self.requiredSingleLineWidth(for: focusedLabel) }
    var branchFrameWidthForTesting: CGFloat { branchLabel.frame.width }
    var branchIntrinsicWidthForTesting: CGFloat { Self.requiredSingleLineWidth(for: branchLabel) }
    var leadingVisibleInsetForTesting: CGFloat { leadingVisibleInset }
    var visibleLaneFrameForTesting: NSRect { visibleLaneFrame }
    var rowFrameForTesting: NSRect { rowContainerView.frame }
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

private final class WindowChromeReviewChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let chip: WorkspaceReviewChip

    init(chip: WorkspaceReviewChip) {
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
                background: baseBackground.mixed(towards: theme.workspaceChipBackground, amount: 0.24),
                border: baseBorder.mixed(towards: .systemBlue, amount: 0.28),
                text: theme.primaryText
            )
        }
    }

    var textForTesting: String { label.stringValue }

    static func preferredWidth(for chip: WorkspaceReviewChip) -> CGFloat {
        let label = NSTextField(labelWithString: chip.text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        return ceil(max(label.fittingSize.width, label.intrinsicContentSize.width)) + 20
    }
}
