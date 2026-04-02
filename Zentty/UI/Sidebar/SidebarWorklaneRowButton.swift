import AppKit
import CoreText
import QuartzCore

private enum SidebarShimmerTreatment {
    case highlight
    case shadow
}

private enum SidebarShimmerPhaseOffset {
    private static let range: ClosedRange<CGFloat> = 0.03...0.21
    private static let seed: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    static func forIdentifier(_ identifier: String?) -> CGFloat {
        guard let identifier, identifier.isEmpty == false else {
            return 0
        }

        var hash = seed
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }

        let fraction = CGFloat(hash & 0xFFFF) / CGFloat(UInt16.max)
        return range.lowerBound + ((range.upperBound - range.lowerBound) * fraction)
    }

    static func wrapped(_ phase: CGFloat) -> CGFloat {
        let wrappedPhase = phase.truncatingRemainder(dividingBy: 1)
        return wrappedPhase >= 0 ? wrappedPhase : wrappedPhase + 1
    }
}

@MainActor
final class SidebarWorklaneRowButton: NSButton {
    private enum Layout {
        static let contentInset = min(
            ShellMetrics.sidebarPaneRowHorizontalInset,
            ShellMetrics.sidebarWorklaneTextHorizontalInset
        )
        static let textContentInset = ShellMetrics.sidebarWorklaneTextHorizontalInset
        static let textWrapperInset = max(0, textContentInset - contentInset)
        static let paneWrapperInset = max(0, ShellMetrics.sidebarPaneRowHorizontalInset - contentInset)
        static let primaryTextLeadingInset: CGFloat = 0
        static let panePrimaryTrailingSpacing: CGFloat = 6
        static let trailingSpillThresholdRatio: CGFloat = 0.5
    }

    let worklaneID: WorklaneID?

    private let topLabel = SidebarStaticLabel()
    private let primaryTextContainer = SidebarPrimaryTextContainerView()
    private let primaryBaseLabel = SidebarStaticLabel()
    private let primaryLabel = SidebarShimmerTextView()
    private let statusIconView = NSImageView()
    private let statusTextContainer = SidebarPrimaryTextContainerView()
    private let statusBaseLabel = SidebarStaticLabel()
    private let statusLabel = SidebarShimmerTextView()
    private let statusContentStack = NSStackView()
    private let overflowLabel = SidebarStaticLabel()
    private let textStack = NSStackView()

    private var detailLabels: [SidebarStaticLabel] = []
    private var panePrimaryRows: [SidebarPanePrimaryRowView] = []
    private var paneDetailLabels: [SidebarStaticLabel] = []
    private var paneStatusRows: [SidebarPaneTextRowView] = []
    private var paneRowButtons: [SidebarPaneRowButton] = []
    private var paneRowContainers: [SidebarInsetContainerView] = []
    private var currentSummary: WorklaneSidebarSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var currentStatusSymbolName = ""
    private var isHovered = false
    private var isPaneRowHovered = false
    private var trackingArea: NSTrackingArea?
    private var heightConstraint: NSLayoutConstraint?
    private var textStackTopConstraint: NSLayoutConstraint?
    private var textStackBottomConstraint: NSLayoutConstraint?
    private var isWorking = false
    private var isApplyingResolvedSummary = false
    private var shimmerCoordinator: SidebarShimmerCoordinator?
    private let reducedMotionProvider: () -> Bool

    var onPaneSelected: ((PaneID) -> Void)?
    var onCloseWorklaneRequested: ((PaneID) -> Void)?
    var onClosePaneRequested: ((PaneID) -> Void)?
    var onSplitHorizontalRequested: ((PaneID) -> Void)?
    var onSplitVerticalRequested: ((PaneID) -> Void)?

    init(
        worklaneID: WorklaneID?,
        reducedMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.worklaneID = worklaneID
        self.reducedMotionProvider = reducedMotionProvider
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.size.width
        super.setFrameSize(newSize)

        guard abs(previousWidth - newSize.width) > .ulpOfOne else {
            return
        }

        applyResolvedSummary(animated: false)
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
            primaryBaseLabel,
            font: ShellMetrics.sidebarPrimaryFont(),
            lineBreakMode: .byTruncatingTail
        )
        primaryLabel.font = ShellMetrics.sidebarPrimaryFont()
        primaryLabel.lineHeight = ShellMetrics.sidebarPrimaryLineHeight
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryTextContainer.translatesAutoresizingMaskIntoConstraints = false
        primaryTextContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryTextContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryTextContainer.addSubview(primaryBaseLabel)
        primaryTextContainer.addSubview(primaryLabel)
        configureLabel(
            statusBaseLabel,
            font: ShellMetrics.sidebarStatusFont(),
            lineBreakMode: .byTruncatingTail
        )
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.imageScaling = .scaleProportionallyDown
        statusIconView.setContentHuggingPriority(.required, for: .horizontal)
        statusIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.font = ShellMetrics.sidebarStatusFont()
        statusLabel.lineHeight = ShellMetrics.sidebarStatusLineHeight
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusTextContainer.translatesAutoresizingMaskIntoConstraints = false
        statusTextContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusTextContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusTextContainer.addSubview(statusBaseLabel)
        statusTextContainer.addSubview(statusLabel)
        statusContentStack.orientation = .horizontal
        statusContentStack.alignment = .centerY
        statusContentStack.spacing = 4
        statusContentStack.translatesAutoresizingMaskIntoConstraints = false
        statusContentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusContentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusContentStack.addArrangedSubview(statusIconView)
        statusContentStack.addArrangedSubview(statusTextContainer)
        configureLabel(
            overflowLabel,
            font: ShellMetrics.sidebarOverflowFont(),
            lineBreakMode: .byTruncatingTail
        )

        NSLayoutConstraint.activate([
            primaryBaseLabel.topAnchor.constraint(equalTo: primaryTextContainer.topAnchor),
            primaryBaseLabel.leadingAnchor.constraint(
                equalTo: primaryTextContainer.leadingAnchor,
                constant: Layout.primaryTextLeadingInset),
            primaryBaseLabel.trailingAnchor.constraint(
                equalTo: primaryTextContainer.trailingAnchor),
            primaryBaseLabel.bottomAnchor.constraint(equalTo: primaryTextContainer.bottomAnchor),
            primaryLabel.topAnchor.constraint(equalTo: primaryTextContainer.topAnchor),
            primaryLabel.leadingAnchor.constraint(equalTo: primaryTextContainer.leadingAnchor),
            primaryLabel.trailingAnchor.constraint(equalTo: primaryTextContainer.trailingAnchor),
            primaryLabel.bottomAnchor.constraint(equalTo: primaryTextContainer.bottomAnchor),
            statusBaseLabel.topAnchor.constraint(equalTo: statusTextContainer.topAnchor),
            statusBaseLabel.leadingAnchor.constraint(equalTo: statusTextContainer.leadingAnchor),
            statusBaseLabel.trailingAnchor.constraint(equalTo: statusTextContainer.trailingAnchor),
            statusBaseLabel.bottomAnchor.constraint(equalTo: statusTextContainer.bottomAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusTextContainer.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusTextContainer.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: statusTextContainer.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: statusTextContainer.bottomAnchor),
            statusIconView.widthAnchor.constraint(equalToConstant: 11),
            statusIconView.heightAnchor.constraint(equalToConstant: 11),
        ])

        textStack.orientation = .vertical
        textStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(textStack)

        let heightConstraint = heightAnchor.constraint(
            equalToConstant: ShellMetrics.sidebarCompactRowHeight)
        self.heightConstraint = heightConstraint
        let textStackTopConstraint = textStack.topAnchor.constraint(
            equalTo: topAnchor,
            constant: ShellMetrics.sidebarRowTopInset
        )
        self.textStackTopConstraint = textStackTopConstraint
        let textStackBottomConstraint = textStack.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -ShellMetrics.sidebarRowBottomInset
        )
        self.textStackBottomConstraint = textStackBottomConstraint

        NSLayoutConstraint.activate([
            heightConstraint,
            textStackTopConstraint,
            textStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Layout.contentInset),
            textStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Layout.contentInset),
            textStackBottomConstraint,
            primaryTextContainer.heightAnchor.constraint(
                equalToConstant: ShellMetrics.sidebarPrimaryLineHeight),
            statusTextContainer.heightAnchor.constraint(
                equalToConstant: ShellMetrics.sidebarStatusLineHeight),
            statusContentStack.heightAnchor.constraint(
                equalToConstant: ShellMetrics.sidebarStatusLineHeight),
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }

        let pointInSelf = convert(point, from: superview)
        guard bounds.contains(pointInSelf), !isHidden, alphaValue > 0 else {
            return nil
        }

        let activePaneCount = currentSummary?.paneRows.count ?? 0
        for paneButton in paneRowButtons.prefix(activePaneCount)
        where paneButton.superview != nil && !paneButton.isHidden {
            let pointInPane = paneButton.convert(point, from: superview)
            if paneButton.bounds.contains(pointInPane) {
                return paneButton
            }
        }

        return self
    }

    func paneRowHoverChanged(isHovered: Bool) {
        isPaneRowHovered = isHovered
        applyCurrentAppearance(animated: true)
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        shimmerCoordinator = coordinator
        primaryLabel.shimmerCoordinator = coordinator
        statusLabel.shimmerCoordinator = coordinator
        panePrimaryRows.forEach { $0.setShimmerCoordinator(coordinator) }
        paneStatusRows.forEach { $0.setShimmerCoordinator(coordinator) }
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        primaryLabel.isVisibleForSharedAnimation = isVisible
        statusLabel.isVisibleForSharedAnimation = isVisible
        panePrimaryRows.forEach { $0.setShimmerVisibility(isVisible) }
        paneStatusRows.forEach { $0.setShimmerVisibility(isVisible) }
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard wantsLayer, let layer else { return }
        if highlighted {
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = 0.5
            layer.shadowRadius = 6
            layer.shadowOffset = .zero
        } else {
            layer.shadowOpacity = 0
        }
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
        with summary: WorklaneSidebarSummary,
        theme: ZenttyTheme,
        animated: Bool
    ) {
        currentSummary = summary
        currentTheme = theme
        isWorking = summary.isWorking
        let worklanePhaseOffset = SidebarShimmerPhaseOffset.forIdentifier(summary.worklaneID.rawValue)
        primaryLabel.shimmerPhaseOffset = worklanePhaseOffset
        statusLabel.shimmerPhaseOffset = worklanePhaseOffset
        applyResolvedSummary(animated: animated)
    }

    private func applyResolvedSummary(animated: Bool) {
        guard let summary = currentSummary, isApplyingResolvedSummary == false else {
            return
        }

        isApplyingResolvedSummary = true
        defer { isApplyingResolvedSummary = false }

        let resolvedSummary = resolvedSummary(for: summary)
        let layout = SidebarWorklaneRowLayout(summary: resolvedSummary)
        applyTextStackVerticalInsets(hasPaneRows: resolvedSummary.paneRows.isEmpty == false)

        topLabel.stringValue = resolvedSummary.topLabel ?? ""
        overflowLabel.stringValue = resolvedSummary.overflowText ?? ""
        if resolvedSummary.paneRows.isEmpty {
            primaryBaseLabel.stringValue = resolvedSummary.primaryText
            primaryLabel.stringValue = resolvedSummary.primaryText
            let statusCopy = resolvedStatusCopy(
                statusText: resolvedSummary.statusText,
                attentionState: resolvedSummary.attentionState,
                interactionKind: resolvedSummary.interactionKind,
                interactionLabel: resolvedSummary.interactionLabel
            )
            statusBaseLabel.stringValue = statusCopy
            statusLabel.stringValue = statusCopy
            currentStatusSymbolName = resolvedStatusSymbolName(
                statusSymbolName: resolvedSummary.statusSymbolName,
                attentionState: resolvedSummary.attentionState,
                interactionKind: resolvedSummary.interactionKind,
                interactionSymbolName: resolvedSummary.interactionSymbolName
            )
            statusIconView.image =
                currentStatusSymbolName.isEmpty
                ? nil
                : NSImage(systemSymbolName: currentStatusSymbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            statusIconView.isHidden = statusIconView.image == nil
            configureDetailLabels(for: resolvedSummary.detailLines)
        } else {
            primaryBaseLabel.stringValue = ""
            primaryLabel.stringValue = ""
            statusBaseLabel.stringValue = ""
            statusLabel.stringValue = ""
            currentStatusSymbolName = ""
            statusIconView.image = nil
            statusIconView.isHidden = true
            configurePaneRows(for: resolvedSummary.paneRows)
        }

        textStack.setViews(
            groupedViews(for: layout),
            in: .top
        )
        heightConstraint?.constant = layout.rowHeight

        applyCurrentAppearance(animated: animated)
    }

    private func applyTextStackVerticalInsets(hasPaneRows: Bool) {
        textStackTopConstraint?.constant = hasPaneRows
            ? ShellMetrics.sidebarPaneRowVerticalInset
            : ShellMetrics.sidebarRowTopInset
        textStackBottomConstraint?.constant = hasPaneRows
            ? -ShellMetrics.sidebarPaneRowVerticalInset
            : -ShellMetrics.sidebarRowBottomInset
    }

    private func resolvedSummary(for summary: WorklaneSidebarSummary) -> WorklaneSidebarSummary {
        guard summary.paneRows.count == 1 else {
            return summary
        }

        let resolvedPaneRows = summary.paneRows.map(resolvedPaneRow(_:))
        guard resolvedPaneRows != summary.paneRows else {
            return summary
        }

        return WorklaneSidebarSummary(
            worklaneID: summary.worklaneID,
            badgeText: summary.badgeText,
            topLabel: summary.topLabel,
            primaryText: summary.primaryText,
            focusedPaneLineIndex: summary.focusedPaneLineIndex,
            statusText: summary.statusText,
            statusSymbolName: summary.statusSymbolName,
            detailLines: summary.detailLines,
            paneRows: resolvedPaneRows,
            overflowText: summary.overflowText,
            attentionState: summary.attentionState,
            interactionKind: summary.interactionKind,
            interactionLabel: summary.interactionLabel,
            interactionSymbolName: summary.interactionSymbolName,
            isWorking: summary.isWorking,
            isActive: summary.isActive
        )
    }

    private func resolvedPaneRow(_ paneRow: WorklaneSidebarPaneRow) -> WorklaneSidebarPaneRow {
        guard let trailingText = WorklaneContextFormatter.trimmed(paneRow.trailingText),
              WorklaneContextFormatter.trimmed(paneRow.detailText) == nil,
              shouldSpillTrailingText(trailingText) else {
            return paneRow
        }

        return WorklaneSidebarPaneRow(
            paneID: paneRow.paneID,
            primaryText: paneRow.primaryText,
            trailingText: nil,
            detailText: trailingText,
            statusText: paneRow.statusText,
            statusSymbolName: paneRow.statusSymbolName,
            attentionState: paneRow.attentionState,
            interactionKind: paneRow.interactionKind,
            interactionLabel: paneRow.interactionLabel,
            interactionSymbolName: paneRow.interactionSymbolName,
            isFocused: paneRow.isFocused,
            isWorking: paneRow.isWorking
        )
    }

    private func shouldSpillTrailingText(_ trailingText: String) -> Bool {
        let availableWidth =
            bounds.width
            - (ShellMetrics.sidebarPaneRowHorizontalInset * 2)
            - (ShellMetrics.sidebarPaneButtonHorizontalInset * 2)
        guard availableWidth > 0 else {
            return false
        }

        let maxTrailingWidth =
            (availableWidth * Layout.trailingSpillThresholdRatio)
            - Layout.panePrimaryTrailingSpacing
        guard maxTrailingWidth > 0 else {
            return true
        }

        return measuredWidth(
            for: trailingText,
            font: ShellMetrics.sidebarDetailFont()
        ) > maxTrailingWidth
    }

    private func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    private func configureDetailLabels(for detailLines: [WorklaneSidebarDetailLine]) {
        while detailLabels.count < detailLines.count {
            let label = SidebarStaticLabel()
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

    private func configurePaneRows(for paneRows: [WorklaneSidebarPaneRow]) {
        while panePrimaryRows.count < paneRows.count {
            panePrimaryRows.append(SidebarPanePrimaryRowView())
        }

        while paneDetailLabels.count < paneRows.count {
            let label = SidebarStaticLabel()
            configureLabel(
                label,
                font: ShellMetrics.sidebarDetailFont(),
                lineBreakMode: .byTruncatingMiddle
            )
            paneDetailLabels.append(label)
        }

        while paneStatusRows.count < paneRows.count {
            paneStatusRows.append(
                SidebarPaneTextRowView(
                    font: ShellMetrics.sidebarStatusFont(),
                    lineHeight: ShellMetrics.sidebarStatusLineHeight
                )
            )
        }

        while paneRowButtons.count < paneRows.count {
            let button = SidebarPaneRowButton()
            paneRowButtons.append(button)
            paneRowContainers.append(
                SidebarInsetContainerView(
                    contentView: button,
                    horizontalInset: Layout.paneWrapperInset,
                    referenceWidthView: textStack
                )
            )
        }

        for (index, paneRow) in paneRows.enumerated() {
            let panePhaseOffset = SidebarShimmerPhaseOffset.forIdentifier(paneRow.paneID.rawValue)
            panePrimaryRows[index].configure(
                primaryText: paneRow.primaryText,
                trailingText: paneRow.trailingText
            )
            panePrimaryRows[index].setShimmerPhaseOffset(panePhaseOffset)
            paneDetailLabels[index].stringValue = paneRow.detailText ?? ""
            paneStatusRows[index].configure(
                text: resolvedStatusCopy(
                    statusText: paneRow.statusText,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionLabel: paneRow.interactionLabel
                ),
                symbolName: resolvedStatusSymbolName(
                    statusSymbolName: paneRow.statusSymbolName,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionSymbolName: paneRow.interactionSymbolName
                )
            )
            paneStatusRows[index].setShimmerPhaseOffset(panePhaseOffset)

            let button = paneRowButtons[index]
            button.paneID = paneRow.paneID
            button.isLastPaneInWorklane = paneRows.count == 1
            button.setAccessibilityLabel(paneRow.primaryText)
            button.onPaneClicked = { [weak self] paneID in
                self?.onPaneSelected?(paneID)
            }
            button.onCloseWorklane = { [weak self] paneID in
                self?.onCloseWorklaneRequested?(paneID)
            }
            button.onClosePane = { [weak self] paneID in
                self?.onClosePaneRequested?(paneID)
            }
            button.onSplitHorizontal = { [weak self] paneID in
                self?.onSplitHorizontalRequested?(paneID)
            }
            button.onSplitVertical = { [weak self] paneID in
                self?.onSplitVerticalRequested?(paneID)
            }
            button.onHoverChanged = { [weak self] isHovered in
                self?.paneRowHoverChanged(isHovered: isHovered)
            }
        }
    }

    private func applyCurrentAppearance(animated: Bool) {
        guard let summary = currentSummary else {
            return
        }

        appearance = NSAppearance(named: currentTheme.sidebarGlassAppearance.nsAppearanceName)
        updateShimmerState()

        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText

        topLabel.textColor = topLabelTextColor(
            for: summary,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        overflowLabel.textColor =
            summary.isActive
            ? activeTextColor.withAlphaComponent(0.54)
            : currentTheme.tertiaryText

        if summary.paneRows.isEmpty {
            let primaryColor = primaryTextColor(
                for: summary,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            primaryBaseLabel.textColor = renderedBaseTextColor(
                primaryColor,
                isShimmering: summary.isWorking,
                treatment: .shadow
            )
            statusBaseLabel.textColor = statusTextColor(for: summary)
            statusIconView.contentTintColor =
                statusBaseLabel.textColor ?? currentTheme.secondaryText

            for (index, detailLabel) in detailLabels.enumerated() {
                guard summary.detailLines.indices.contains(index) else {
                    continue
                }

                detailLabel.textColor = detailTextColor(
                    for: summary.detailLines[index].emphasis,
                    summary: summary
                )
            }
        } else {
            applyPaneRowColors(
                paneRows: summary.paneRows,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
        }

        let paneRowHoverColor = currentTheme.sidebarButtonHoverBackground.withAlphaComponent(0.5)
        for button in paneRowButtons {
            button.updateTheme(hoverColor: paneRowHoverColor)
        }

        let activeBackground = currentTheme.sidebarButtonActiveBackground
        let hoverBackground = currentTheme.sidebarButtonHoverBackground
        let inactiveBackground = currentTheme.sidebarButtonInactiveBackground
        let activeBorder = currentTheme.sidebarButtonActiveBorder
        let inactiveBorder = currentTheme.sidebarButtonInactiveBorder.withAlphaComponent(
            isHovered ? 0.16 : 0.10)

        performThemeAnimation(animated: animated) {
            self.layer?.zPosition = summary.isActive ? 10 : 0
            self.layer?.backgroundColor =
                self.backgroundColor(
                    isActive: summary.isActive,
                    activeBackground: activeBackground,
                    hoverBackground: hoverBackground,
                    inactiveBackground: inactiveBackground
                ).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = summary.isActive ? 0.8 : 1
            self.layer?.shadowColor =
                NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = summary.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func backgroundColor(
        isActive: Bool,
        activeBackground: NSColor,
        hoverBackground: NSColor,
        inactiveBackground: NSColor
    ) -> NSColor {
        if isActive {
            guard isWorking else {
                return activeBackground
            }

            return
                activeBackground
                .mixed(towards: currentTheme.sidebarGradientStart.brightenedForLabel, amount: 0.12)
        }

        if isHovered && !isPaneRowHovered {
            return hoverBackground
        }

        return inactiveBackground
    }

    private func updateShimmerState() {
        guard let summary = currentSummary else {
            primaryLabel.isShimmering = false
            statusLabel.isShimmering = false
            return
        }

        let isActive = currentSummary?.isActive ?? false
        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText
        if summary.paneRows.isEmpty == false {
            primaryLabel.isShimmering = false
            statusLabel.isShimmering = false
            return
        }

        let primaryColor = primaryTextColor(
            for: summary,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        primaryLabel.isShimmering = isWorking
        primaryLabel.reducedMotion = reducedMotionProvider()
        primaryLabel.shimmerColor = shimmerColor(
            for: primaryColor,
            treatment: .shadow,
            isActive: isActive
        )
        let shimmersStatus =
            summary.attentionState == .running
            && summary.statusText == "Running"
        statusLabel.isShimmering = shimmersStatus
        statusLabel.reducedMotion = reducedMotionProvider()
        let shimmerBase = currentTheme.statusRunning.mixed(towards: .white, amount: 0.65)
        statusLabel.shimmerColor = shimmerColor(
            for: shimmerBase,
            treatment: .highlight,
            isActive: isActive
        )
    }

    private func primaryTextColor(
        for summary: WorklaneSidebarSummary,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        guard summary.isWorking else {
            return summary.isActive ? activeTextColor : inactiveTextColor
        }

        let emphasis = inactiveTextColor.mixed(
            towards: workingTextHighlightColor(
                isActive: false,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            ),
            amount: 0.34
        )

        return summary.isActive
            ? activeTextColor
            : emphasis
    }

    private func applyPaneRowColors(
        paneRows: [WorklaneSidebarPaneRow],
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) {
        for (index, paneRow) in paneRows.enumerated() {
            guard panePrimaryRows.indices.contains(index),
                paneDetailLabels.indices.contains(index),
                paneStatusRows.indices.contains(index)
            else {
                continue
            }

            let primaryColor = panePrimaryTextColor(
                for: paneRow,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            let trailingColor = paneTrailingTextColor(
                for: paneRow,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            panePrimaryRows[index].applyColors(
                primaryColor: primaryColor,
                trailingColor: trailingColor,
                isShimmering: paneRow.isWorking,
                shimmerColor: shimmerColor(
                    for: primaryColor,
                    treatment: .shadow,
                    isActive: currentSummary?.isActive ?? false
                ),
                reducedMotion: reducedMotionProvider()
            )
            paneDetailLabels[index].textColor = paneDetailTextColor(
                for: paneRow,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            paneStatusRows[index].applyColors(
                textColor: paneStatusTextColor(
                    for: paneRow,
                    activeTextColor: activeTextColor,
                    inactiveTextColor: inactiveTextColor
                ),
                isShimmering: paneRow.isWorking && paneRow.attentionState == .running,
                shimmerColor: shimmerColor(
                    for: currentTheme.statusRunning.mixed(towards: .white, amount: 0.65),
                    treatment: .highlight,
                    isActive: currentSummary?.isActive ?? false
                ),
                reducedMotion: reducedMotionProvider()
            )
        }
    }

    private func panePrimaryTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        let focusedBaseColor =
            (currentSummary?.isActive ?? false) ? activeTextColor : inactiveTextColor
        if paneRow.isWorking {
            let emphasis = focusedBaseColor.mixed(
                towards: workingTextHighlightColor(
                    isActive: currentSummary?.isActive ?? false,
                    activeTextColor: activeTextColor,
                    inactiveTextColor: inactiveTextColor
                ),
                amount: 0.34
            )
            return paneRow.isFocused ? focusedBaseColor : emphasis
        }

        return paneRow.isFocused ? focusedBaseColor : currentTheme.secondaryText
    }

    private func paneTrailingTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        let focusedBaseColor =
            (currentSummary?.isActive ?? false) ? activeTextColor : inactiveTextColor
        if paneRow.isWorking {
            let emphasis = workingTextHighlightColor(
                isActive: currentSummary?.isActive ?? false,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            return paneRow.isFocused
                ? emphasis.withAlphaComponent(0.78)
                : emphasis.withAlphaComponent(0.72)
        }

        return paneRow.isFocused
            ? focusedBaseColor.withAlphaComponent(0.62)
            : currentTheme.tertiaryText
    }

    private func paneDetailTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        let focusedBaseColor =
            (currentSummary?.isActive ?? false) ? activeTextColor : inactiveTextColor
        if paneRow.isWorking {
            let emphasis = workingTextHighlightColor(
                isActive: currentSummary?.isActive ?? false,
                activeTextColor: activeTextColor,
                inactiveTextColor: inactiveTextColor
            )
            return paneRow.isFocused
                ? emphasis.withAlphaComponent(0.68)
                : emphasis.withAlphaComponent(0.60)
        }

        return paneRow.isFocused
            ? focusedBaseColor.withAlphaComponent(0.62)
            : currentTheme.tertiaryText
    }

    private func topLabelTextColor(
        for summary: WorklaneSidebarSummary,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        guard summary.isWorking else {
            return summary.isActive
                ? activeTextColor.withAlphaComponent(0.66)
                : currentTheme.tertiaryText
        }

        let emphasis = workingTextHighlightColor(
            isActive: summary.isActive,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )

        return summary.isActive
            ? emphasis.withAlphaComponent(0.84)
            : emphasis.withAlphaComponent(0.78)
    }

    private func workingTextHighlightColor(
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        if isActive {
            return .white
        }

        return inactiveTextColor.mixed(towards: .white, amount: 0.72)
    }

    private func shimmerHighlightAlpha(isActive: Bool) -> CGFloat {
        if currentTheme.reducedTransparency {
            return isActive ? 1.0 : 0.60
        }

        return isActive ? 1.0 : 0.72
    }

    private func shadowShimmerAlpha(isActive: Bool) -> CGFloat {
        if currentTheme.reducedTransparency {
            return isActive ? 0.64 : 0.54
        }

        return isActive ? 0.72 : 0.60
    }

    private func shimmerColor(
        for baseTextColor: NSColor,
        treatment: SidebarShimmerTreatment,
        isActive: Bool
    ) -> NSColor {
        switch treatment {
        case .highlight:
            return baseTextColor.withAlphaComponent(shimmerHighlightAlpha(isActive: isActive))
        case .shadow:
            let shadowTarget = currentTheme.sidebarGlassAppearance == .dark
                ? NSColor.black
                : currentTheme.sidebarBackground
            return baseTextColor
                .mixed(towards: shadowTarget, amount: currentTheme.sidebarGlassAppearance == .dark ? 0.82 : 0.74)
                .withAlphaComponent(shadowShimmerAlpha(isActive: isActive))
        }
    }

    private func renderedBaseTextColor(
        _ textColor: NSColor,
        isShimmering: Bool,
        treatment: SidebarShimmerTreatment
    ) -> NSColor {
        guard isShimmering else {
            return textColor
        }

        switch treatment {
        case .highlight:
            return textColor.withAlphaComponent(textColor.alphaComponent * 0.90)
        case .shadow:
            return textColor
        }
    }

    private func resolvedStatusCopy(
        statusText: String?,
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?,
        interactionLabel: String?
    ) -> String {
        guard shouldPreferInteractionPresentation(
            attentionState: attentionState,
            interactionKind: interactionKind
        ) else {
            return statusText
                ?? interactionLabel
                ?? interactionKind?.defaultLabel
                ?? ""
        }

        let preferredLabel = interactionLabel ?? interactionKind?.defaultLabel ?? ""
        guard let statusText else {
            return preferredLabel
        }

        if let genericRange = statusText.range(
            of: PaneInteractionKind.genericInput.defaultLabel,
            options: [.caseInsensitive, .backwards]
        ) {
            return statusText.replacingCharacters(in: genericRange, with: preferredLabel)
        }

        return preferredLabel
    }

    private func resolvedStatusSymbolName(
        statusSymbolName: String?,
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?,
        interactionSymbolName: String?
    ) -> String {
        guard shouldPreferInteractionPresentation(
            attentionState: attentionState,
            interactionKind: interactionKind
        ) else {
            return statusSymbolName
                ?? interactionSymbolName
                ?? interactionKind?.defaultSymbolName
                ?? ""
        }

        return interactionSymbolName
            ?? interactionKind?.defaultSymbolName
            ?? statusSymbolName
            ?? ""
    }

    private func shouldPreferInteractionPresentation(
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind?
    ) -> Bool {
        attentionState == .needsInput
            && interactionKind != nil
            && interactionKind != .genericInput
    }

    private func statusTextColor(for summary: WorklaneSidebarSummary) -> NSColor {
        switch summary.attentionState {
        case .running:
            return currentTheme.statusRunning
        case .needsInput:
            return currentTheme.statusNeedsInput
        case .unresolvedStop:
            return currentTheme.statusStopped
        case .ready:
            return currentTheme.statusReady
        case nil:
            return currentTheme.secondaryText
        }
    }

    private func paneStatusTextColor(
        for paneRow: WorklaneSidebarPaneRow,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        switch paneRow.attentionState {
        case .running:
            return currentTheme.statusRunning
        case .needsInput:
            return currentTheme.statusNeedsInput
        case .unresolvedStop:
            return currentTheme.statusStopped
        case .ready:
            return currentTheme.statusReady
        case nil:
            return currentTheme.secondaryText
        }
    }

    private func detailTextColor(
        for emphasis: WorklaneSidebarDetailEmphasis,
        summary: WorklaneSidebarSummary
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

    private func groupedViews(for layout: SidebarWorklaneRowLayout) -> [NSView] {
        var views: [NSView] = []
        var currentPaneIndex: Int?

        for row in layout.visibleTextRows {
            switch row {
            case .panePrimary(let index):
                if index != currentPaneIndex {
                    currentPaneIndex = index
                    var subViews: [NSView] = [panePrimaryRows[index]]
                    for next in layout.visibleTextRows {
                        switch next {
                        case .paneDetail(let i) where i == index:
                            subViews.append(paneDetailLabels[i])
                        case .paneStatus(let i) where i == index:
                            subViews.append(paneStatusRows[i])
                        default:
                            break
                        }
                    }
                    paneRowButtons[index].setContent(subViews)
                    views.append(paneRowContainers[index])
                }
            case .paneDetail, .paneStatus:
                break
            default:
                currentPaneIndex = nil
                views.append(insetWrappedView(for: label(for: row)))
            }
        }

        return views
    }

    private func insetWrappedView(for view: NSView) -> NSView {
        return SidebarInsetContainerView(
            contentView: view,
            horizontalInset: Layout.textWrapperInset,
            referenceWidthView: textStack
        )
    }

    private func label(for row: WorklaneRowTextRow) -> NSView {
        switch row {
        case .topLabel:
            topLabel
        case .primary:
            primaryTextContainer
        case .status:
            statusContentStack
        case .panePrimary(let index):
            panePrimaryRows[index]
        case .paneDetail(let index):
            paneDetailLabels[index]
        case .paneStatus(let index):
            paneStatusRows[index]
        case .context:
            detailLabels.first ?? overflowLabel
        case .detail(let index):
            detailLabels[index]
        case .overflow:
            overflowLabel
        }
    }

    var detailTextsForTesting: [String] {
        if currentSummary?.paneRows.isEmpty == false {
            return
                paneDetailLabels
                .prefix(currentSummary?.paneRows.count ?? 0)
                .map(\.stringValue)
                .filter { $0.isEmpty == false }
        }

        return detailLabels.prefix(currentSummary?.detailLines.count ?? 0).map(\.stringValue)
    }

    var overflowTextForTesting: String {
        currentSummary?.overflowText ?? ""
    }

    var statusTextForTesting: String {
        if currentSummary?.paneRows.isEmpty == false {
            return paneStatusRows.first?.text ?? ""
        }

        return statusBaseLabel.stringValue
    }

    var statusTextColorForTesting: NSColor {
        if currentSummary?.paneRows.isEmpty == false {
            return paneStatusRows.first?.textColor ?? .clear
        }

        return statusBaseLabel.textColor ?? .clear
    }

    var statusSymbolNameForTesting: String {
        if currentSummary?.paneRows.isEmpty == false {
            return paneStatusRows.first?.symbolName ?? ""
        }

        return currentStatusSymbolName
    }

    var topLabelColorForTesting: NSColor {
        topLabel.textColor ?? .clear
    }

    var isWorkingForTesting: Bool {
        isWorking
    }

    var shimmerIsAnimatingForTesting: Bool {
        primaryLabel.shimmerIsAnimating
    }

    var statusShimmerIsAnimatingForTesting: Bool {
        statusLabel.shimmerIsAnimating
    }

    var shimmerCoordinatorIdentifierForTesting: ObjectIdentifier? {
        shimmerCoordinator.map(ObjectIdentifier.init)
    }

    var shimmerColorForTesting: NSColor {
        primaryLabel.shimmerColor
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        primaryLabel.shimmerPhaseOffsetForTesting
    }

    var statusShimmerPhaseOffsetForTesting: CGFloat {
        statusLabel.shimmerPhaseOffsetForTesting
    }

    var primaryTextColorForTesting: NSColor {
        primaryBaseLabel.textColor ?? .clear
    }

    var primaryRowIndexForTesting: Int? {
        if currentSummary?.paneRows.isEmpty == false {
            guard let firstPaneButton = paneRowButtons.first else {
                return nil
            }

            return textStack.arrangedSubviews.firstIndex(of: firstPaneButton)
        }

        return textStack.arrangedSubviews.firstIndex {
            $0 === primaryTextContainer || $0.containsDescendant(primaryTextContainer)
        }
    }

    var primaryTextsForTesting: [String] {
        panePrimaryRows.prefix(currentSummary?.paneRows.count ?? 0).map(\.primaryText)
    }

    var firstPanePrimaryTextColorForTesting: NSColor? {
        panePrimaryRows.first?.renderedPrimaryTextColorForTesting
    }

    var firstPanePrimaryShimmerColorForTesting: NSColor? {
        panePrimaryRows.first?.shimmerColorForTesting
    }

    var panePrimaryShimmerPhaseOffsetsForTesting: [CGFloat] {
        panePrimaryRows.prefix(currentSummary?.paneRows.count ?? 0).map(\.shimmerPhaseOffsetForTesting)
    }

    var primaryTrailingTextsForTesting: [String] {
        panePrimaryRows.prefix(currentSummary?.paneRows.count ?? 0).compactMap(\.trailingText)
    }

    var paneStatusTextsForTesting: [String] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .map(\.text)
            .filter { $0.isEmpty == false }
    }

    var paneStatusSymbolNamesForTesting: [String] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .map(\.symbolName)
            .filter { $0.isEmpty == false }
    }

    var paneStatusShimmerPhaseOffsetsForTesting: [CGFloat] {
        paneStatusRows.prefix(currentSummary?.paneRows.count ?? 0)
            .map(\.shimmerPhaseOffsetForTesting)
    }

    var paneRowWidthConstraintCountForTesting: Int {
        paneRowContainers.filter(\.hasActiveWidthConstraintForTesting).count
    }

    var firstPaneRowMinXForTesting: CGFloat? {
        paneRowButtons.first.map { convert($0.bounds, from: $0).minX }
    }

    var firstPaneRowMaxTrailingInsetForTesting: CGFloat? {
        paneRowButtons.first.map { bounds.maxX - convert($0.bounds, from: $0).maxX }
    }

    var firstPaneRowContentMinXForTesting: CGFloat? {
        paneRowButtons.first?.contentMinXForTesting
    }

    var firstPaneRowContentMaxTrailingInsetForTesting: CGFloat? {
        paneRowButtons.first?.contentMaxTrailingInsetForTesting
    }

    var firstPaneRowMinYForTesting: CGFloat? {
        paneRowButtons.first.map { convert($0.bounds, from: $0).minY }
    }

    var firstPaneRowMaxTopInsetForTesting: CGFloat? {
        paneRowButtons.first.map { bounds.maxY - convert($0.bounds, from: $0).maxY }
    }

    var firstPaneRowContentMinYForTesting: CGFloat? {
        paneRowButtons.first?.contentMinYForTesting
    }

    var firstPaneRowContentMaxTopInsetForTesting: CGFloat? {
        paneRowButtons.first?.contentMaxTopInsetForTesting
    }

    var firstPaneRowCornerRadiusForTesting: CGFloat? {
        paneRowButtons.first?.cornerRadiusForTesting
    }

    var primaryTextMinXForTesting: CGFloat? {
        guard currentSummary?.paneRows.isEmpty != false,
              let superview = primaryTextContainer.superview else {
            return nil
        }

        return convert(primaryTextContainer.frame, from: superview).minX
    }

    var primaryTextMaxTrailingInsetForTesting: CGFloat? {
        guard currentSummary?.paneRows.isEmpty != false,
              let superview = primaryTextContainer.superview else {
            return nil
        }

        let primaryTextFrame = convert(primaryTextContainer.frame, from: superview)
        return bounds.maxX - primaryTextFrame.maxX
    }

    var backgroundColorForTesting: NSColor? {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
    }

    var appearanceMatchForTesting: NSAppearance.Name? {
        appearance?.bestMatch(from: [.darkAqua, .aqua])
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        guard let superview = primaryTextContainer.superview else {
            return view.convert(primaryBaseLabel.bounds, from: primaryBaseLabel).minX
        }

        let primaryTextFrame = convert(primaryTextContainer.frame, from: superview)
        return view.convert(primaryTextFrame, from: self).minX
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

@MainActor
private final class SidebarShimmerTextView: NSView {
    fileprivate enum Animation {
        static let velocity: CGFloat = 130      // pts/sec — constant across all widths
        static let bandWidth: CGFloat = 48
        static let frameInterval: TimeInterval = 1.0 / 30.0
    }

    private static let textLeadingInset: CGFloat = 0

    struct LayoutSnapshot {
        let line: CTLine
        let glyphPath: CGPath
        let origin: CGPoint
        let width: CGFloat
    }

    var stringValue: String = "" {
        didSet {
            guard oldValue != stringValue else { return }
            invalidateLayout()
        }
    }

    var font: NSFont = .systemFont(ofSize: 13, weight: .semibold) {
        didSet {
            guard oldValue != font else { return }
            invalidateLayout()
        }
    }

    var lineBreakMode: NSLineBreakMode = .byTruncatingTail {
        didSet {
            guard oldValue != lineBreakMode else { return }
            invalidateLayout()
        }
    }

    var shimmerColor: NSColor = .clear {
        didSet {
            guard oldValue != shimmerColor else { return }
            needsDisplay = true
        }
    }

    var lineHeight: CGFloat = ShellMetrics.sidebarPrimaryLineHeight {
        didSet {
            guard oldValue != lineHeight else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isShimmering: Bool = false {
        didSet {
            guard oldValue != isShimmering else { return }
            refreshSharedShimmerParticipation()
            needsDisplay = true
        }
    }

    var reducedMotion: Bool = false {
        didSet {
            guard oldValue != reducedMotion else { return }
            refreshSharedShimmerParticipation()
            needsDisplay = true
        }
    }

    var isVisibleForSharedAnimation: Bool = false {
        didSet {
            guard oldValue != isVisibleForSharedAnimation else { return }
            refreshSharedShimmerParticipation()
        }
    }

    var shimmerPhaseOffset: CGFloat = 0 {
        didSet {
            guard oldValue != shimmerPhaseOffset else { return }
            needsDisplay = true
        }
    }

    weak var shimmerCoordinator: SidebarShimmerCoordinator? {
        didSet {
            guard oldValue !== shimmerCoordinator else {
                return
            }

            oldValue?.unregister(self)
            shimmerCoordinator?.register(self)
            refreshSharedShimmerParticipation()
        }
    }

    private var sharedShimmerPhase: CGFloat = 0.5
    private var sharedShimmerInSweep = false
    private var cachedWidth: CGFloat = -1
    private var cachedStringValue = ""
    private var cachedFont: NSFont?
    private var cachedLineBreakMode: NSLineBreakMode = .byTruncatingTail
    private var cachedLayout: LayoutSnapshot?

    override var isOpaque: Bool {
        false
    }

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredTextWidth + Self.textLeadingInset, height: lineHeight)
    }

    var shimmerIsAnimating: Bool {
        canAnimateSharedShimmer && sharedShimmerInSweep
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        shimmerPhaseOffset
    }

    private var preferredTextWidth: CGFloat {
        guard stringValue.isEmpty == false else {
            return 0
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: stringValue, attributes: attributes)
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.size.width
        super.setFrameSize(newSize)
        if abs(previousWidth - newSize.width) > .ulpOfOne {
            invalidateLayout()
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            isVisibleForSharedAnimation = false
        }
        refreshSharedShimmerParticipation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshSharedShimmerParticipation()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard
            let context = NSGraphicsContext.current?.cgContext,
            let layout = layoutSnapshot(forWidth: bounds.width)
        else {
            return
        }

        guard canAnimateSharedShimmer, sharedShimmerInSweep else {
            return
        }

        context.saveGState()
        context.addPath(layout.glyphPath)
        context.clip()
        drawShimmerOverlay(in: context, layout: layout)
        context.restoreGState()
    }

    private func drawShimmerOverlay(
        in context: CGContext,
        layout: LayoutSnapshot
    ) {
        let availableWidth = max(0, bounds.width - Self.textLeadingInset)
        let bandWidth = Animation.bandWidth
        let originX: CGFloat
        if reducedMotion {
            originX = Self.textLeadingInset + (availableWidth / 2) - (bandWidth / 2)
        } else {
            let travel = availableWidth + bandWidth
            let phase = SidebarShimmerPhaseOffset.wrapped(sharedShimmerPhase + shimmerPhaseOffset)
            originX = Self.textLeadingInset - bandWidth + (travel * phase)
        }

        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    shimmerColor.withAlphaComponent(0).cgColor,
                    shimmerColor.cgColor,
                    shimmerColor.withAlphaComponent(0).cgColor,
                ] as CFArray,
                locations: [0, 0.5, 1]
            )
        else {
            return
        }

        let start = CGPoint(x: originX, y: layout.origin.y)
        let end = CGPoint(x: originX + bandWidth, y: layout.origin.y)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }

    private func layoutSnapshot(forWidth width: CGFloat) -> LayoutSnapshot? {
        let availableWidth = width - Self.textLeadingInset
        guard availableWidth > 0, stringValue.isEmpty == false else {
            return nil
        }

        if let cachedLayout,
            abs(cachedWidth - width) <= .ulpOfOne,
            cachedStringValue == stringValue,
            cachedFont == font,
            cachedLineBreakMode == lineBreakMode
        {
            return cachedLayout
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: stringValue, attributes: attributes)
        )
        let drawLine = truncatedLine(
            from: line, attributes: attributes, availableWidth: availableWidth)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(drawLine, &ascent, &descent, nil))
        let totalLineHeight = ascent + descent
        let bottomPadding = max(0, (bounds.height - totalLineHeight) / 2)
        let origin = CGPoint(x: Self.textLeadingInset, y: bottomPadding + descent)
        let glyphPath = glyphPath(for: drawLine, lineOrigin: origin)
        let snapshot = LayoutSnapshot(
            line: drawLine,
            glyphPath: glyphPath,
            origin: origin,
            width: lineWidth
        )

        cachedWidth = width
        cachedStringValue = stringValue
        cachedFont = font
        cachedLineBreakMode = lineBreakMode
        cachedLayout = snapshot

        return snapshot
    }

    private func truncatedLine(
        from line: CTLine,
        attributes: [NSAttributedString.Key: Any],
        availableWidth: CGFloat
    ) -> CTLine {
        guard lineBreakMode == .byTruncatingTail else {
            return line
        }

        guard CTLineGetTypographicBounds(line, nil, nil, nil) > availableWidth else {
            return line
        }

        let token = NSAttributedString(string: "\u{2026}", attributes: attributes)
        let tokenLine = CTLineCreateWithAttributedString(token)
        return CTLineCreateTruncatedLine(line, Double(availableWidth), .end, tokenLine) ?? line
    }

    private func glyphPath(
        for line: CTLine,
        lineOrigin: CGPoint
    ) -> CGPath {
        let glyphPath = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as NSArray

        for case let run as CTRun in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else {
                continue
            }

            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontObject = attributes[kCTFontAttributeName] else {
                continue
            }
            let ctFont = fontObject as! CTFont

            var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
            var positions = Array(repeating: CGPoint.zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

            for index in 0..<glyphCount {
                guard let path = CTFontCreatePathForGlyph(ctFont, glyphs[index], nil) else {
                    continue
                }

                let transform = CGAffineTransform(
                    translationX: lineOrigin.x + positions[index].x,
                    y: lineOrigin.y + positions[index].y
                )
                glyphPath.addPath(path, transform: transform)
            }
        }

        return glyphPath
    }

    func applySharedShimmerState(phase: CGFloat, inSweep: Bool) {
        sharedShimmerPhase = phase
        sharedShimmerInSweep = inSweep
        needsDisplay = true
    }

    func resetSharedShimmerState() {
        sharedShimmerPhase = 0.5
        sharedShimmerInSweep = false
        needsDisplay = true
    }

    fileprivate var canAnimateSharedShimmer: Bool {
        isShimmering && isVisibleForSharedAnimation && reducedMotion == false
    }

    private func refreshSharedShimmerParticipation() {
        guard let shimmerCoordinator else {
            resetSharedShimmerState()
            return
        }

        shimmerCoordinator.labelStateDidChange()
        if canAnimateSharedShimmer {
            needsDisplay = true
        } else {
            resetSharedShimmerState()
        }
    }

    private func invalidateLayout() {
        cachedWidth = -1
        cachedStringValue = ""
        cachedFont = nil
        cachedLineBreakMode = lineBreakMode
        cachedLayout = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

@MainActor
final class SidebarShimmerCoordinator {
    private static let pauseRange: ClosedRange<CFTimeInterval> = 2.5...4.0

    private var labels: NSHashTable<SidebarShimmerTextView> = .weakObjects()
    private var timer: Timer?
    private var windowIsRenderable = false
    private var currentPhase: CGFloat = 0.5
    private var inSweep = false
    private var cycleStart: CFTimeInterval = 0
    private var pauseDuration: CFTimeInterval = 0

    var isRunningForTesting: Bool {
        timer != nil
    }

    static var pauseRangeForTesting: ClosedRange<CFTimeInterval> {
        pauseRange
    }

    fileprivate func register(_ label: SidebarShimmerTextView) {
        labels.add(label)
        label.applySharedShimmerState(phase: currentPhase, inSweep: inSweep)
        refreshAnimationState()
    }

    fileprivate func unregister(_ label: SidebarShimmerTextView) {
        labels.remove(label)
        refreshAnimationState()
    }

    func setWindowIsRenderable(_ isRenderable: Bool) {
        guard windowIsRenderable != isRenderable else {
            return
        }

        windowIsRenderable = isRenderable
        refreshAnimationState()
    }

    func labelStateDidChange() {
        refreshAnimationState()
    }

    private var activeLabels: [SidebarShimmerTextView] {
        labels.allObjects.filter { $0.canAnimateSharedShimmer }
    }

    private func refreshAnimationState() {
        let labels = activeLabels
        guard windowIsRenderable, labels.isEmpty == false else {
            stopTimer()
            currentPhase = 0.5
            inSweep = false
            labelsForDisplay().forEach { $0.resetSharedShimmerState() }
            return
        }

        if timer == nil {
            startTimer()
        }

        applyCurrentState(to: labels)
    }

    private func labelsForDisplay() -> [SidebarShimmerTextView] {
        labels.allObjects
    }

    private func startTimer() {
        cycleStart = CACurrentMediaTime()
        pauseDuration = .random(in: Self.pauseRange)
        inSweep = true
        currentPhase = 0

        let timer = Timer(
            timeInterval: SidebarShimmerTextView.Animation.frameInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard windowIsRenderable else {
            stopTimer()
            inSweep = false
            currentPhase = 0.5
            labelsForDisplay().forEach { $0.resetSharedShimmerState() }
            return
        }

        let labels = activeLabels
        guard labels.isEmpty == false else {
            stopTimer()
            inSweep = false
            currentPhase = 0.5
            labelsForDisplay().forEach { $0.resetSharedShimmerState() }
            return
        }

        let travelDistance = max(1, labels.map(\.bounds.width).max() ?? 1) + SidebarShimmerTextView.Animation.bandWidth
        let sweepDuration = CFTimeInterval(travelDistance / SidebarShimmerTextView.Animation.velocity)
        let cycleDuration = sweepDuration + pauseDuration
        let elapsed = CACurrentMediaTime() - cycleStart

        if elapsed >= cycleDuration {
            cycleStart = CACurrentMediaTime()
            pauseDuration = .random(in: Self.pauseRange)
            currentPhase = 0
            inSweep = true
        } else if elapsed < sweepDuration {
            currentPhase = CGFloat(elapsed / sweepDuration)
            inSweep = true
        } else {
            inSweep = false
        }

        applyCurrentState(to: labels)
    }

    private func applyCurrentState(to labels: [SidebarShimmerTextView]) {
        labels.forEach { $0.applySharedShimmerState(phase: currentPhase, inSweep: inSweep) }
    }
}

private final class SidebarStaticLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        stringValue = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }
}

private extension NSView {
    func containsDescendant(_ candidate: NSView) -> Bool {
        if self === candidate {
            return true
        }

        return subviews.contains { $0.containsDescendant(candidate) }
    }
}

private final class SidebarInsetContainerView: NSView {
    private weak var referenceWidthView: NSView?
    private var widthConstraint: NSLayoutConstraint?

    init(contentView: NSView, horizontalInset: CGFloat, referenceWidthView: NSView) {
        self.referenceWidthView = referenceWidthView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        widthConstraint?.isActive = false
        widthConstraint = nil

        guard superview != nil, let referenceWidthView else {
            return
        }

        let widthConstraint = widthAnchor.constraint(equalTo: referenceWidthView.widthAnchor)
        widthConstraint.isActive = true
        self.widthConstraint = widthConstraint
    }

    var hasActiveWidthConstraintForTesting: Bool {
        widthConstraint?.isActive == true
    }
}

private final class SidebarPrimaryTextContainerView: NSView {
    override var allowsVibrancy: Bool {
        false
    }
}

@MainActor
private final class SidebarPanePrimaryRowView: NSView {
    private let textContainer = SidebarPrimaryTextContainerView()
    private let baseLabel = SidebarStaticLabel()
    private let shimmerLabel = SidebarShimmerTextView()
    private let trailingLabelView = SidebarStaticLabel()
    private let stack = NSStackView()

    private(set) var primaryText: String = ""
    private(set) var trailingText: String?
    private(set) var primaryColor: NSColor = .labelColor
    private(set) var trailingColor: NSColor = .secondaryLabelColor

    var renderedPrimaryTextColorForTesting: NSColor {
        baseLabel.textColor ?? .clear
    }

    var shimmerColorForTesting: NSColor {
        shimmerLabel.shimmerColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textContainer.addSubview(baseLabel)
        textContainer.addSubview(shimmerLabel)

        baseLabel.font = ShellMetrics.sidebarPrimaryFont()
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.translatesAutoresizingMaskIntoConstraints = false

        shimmerLabel.font = ShellMetrics.sidebarPrimaryFont()
        shimmerLabel.lineHeight = ShellMetrics.sidebarPrimaryLineHeight
        shimmerLabel.lineBreakMode = .byTruncatingTail
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false

        trailingLabelView.font = ShellMetrics.sidebarDetailFont()
        trailingLabelView.alignment = .right
        trailingLabelView.lineBreakMode = .byTruncatingHead
        trailingLabelView.translatesAutoresizingMaskIntoConstraints = false
        trailingLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textContainer)
        stack.addArrangedSubview(trailingLabelView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            baseLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            baseLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            baseLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            baseLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            shimmerLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            shimmerLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            shimmerLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            shimmerLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarPrimaryLineHeight),
        ])
    }

    func configure(primaryText: String, trailingText: String?) {
        self.primaryText = primaryText
        self.trailingText = trailingText
        baseLabel.stringValue = primaryText
        shimmerLabel.stringValue = primaryText
        trailingLabelView.stringValue = trailingText ?? ""
        trailingLabelView.isHidden = (trailingText?.isEmpty ?? true)
    }

    func applyColors(
        primaryColor: NSColor,
        trailingColor: NSColor,
        isShimmering: Bool,
        shimmerColor: NSColor,
        reducedMotion: Bool
    ) {
        self.primaryColor = primaryColor
        self.trailingColor = trailingColor
        baseLabel.textColor = primaryColor
        trailingLabelView.textColor = trailingColor
        shimmerLabel.isShimmering = isShimmering
        shimmerLabel.reducedMotion = reducedMotion
        shimmerLabel.shimmerColor = shimmerColor
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        shimmerLabel.shimmerCoordinator = coordinator
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        shimmerLabel.isVisibleForSharedAnimation = isVisible
    }

    func setShimmerPhaseOffset(_ offset: CGFloat) {
        shimmerLabel.shimmerPhaseOffset = offset
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        shimmerLabel.shimmerPhaseOffsetForTesting
    }
}

@MainActor
private final class SidebarPaneTextRowView: NSView {
    private static let symbolPointSize: CGFloat = 11

    private let iconView = NSImageView()
    private let textContainer = SidebarPrimaryTextContainerView()
    private let baseLabel = SidebarStaticLabel()
    private let shimmerLabel = SidebarShimmerTextView()
    private let contentStack = NSStackView()

    private(set) var text: String = ""
    private(set) var symbolName: String = ""
    private(set) var textColor: NSColor = .secondaryLabelColor

    init(font: NSFont, lineHeight: CGFloat) {
        super.init(frame: .zero)
        setup(font: font, lineHeight: lineHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(font: NSFont, lineHeight: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textContainer.addSubview(baseLabel)
        textContainer.addSubview(shimmerLabel)
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(textContainer)
        addSubview(contentStack)

        baseLabel.font = font
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.translatesAutoresizingMaskIntoConstraints = false

        shimmerLabel.font = font
        shimmerLabel.lineHeight = lineHeight
        shimmerLabel.lineBreakMode = .byTruncatingTail
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.symbolPointSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.symbolPointSize),
            baseLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            baseLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            baseLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            baseLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            shimmerLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            shimmerLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            shimmerLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            shimmerLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: lineHeight),
        ])
    }

    func configure(text: String, symbolName: String?) {
        self.text = text
        self.symbolName = symbolName ?? ""
        baseLabel.stringValue = text
        shimmerLabel.stringValue = text
        iconView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .semibold))
        }
        iconView.isHidden = iconView.image == nil
    }

    func applyColors(
        textColor: NSColor,
        isShimmering: Bool,
        shimmerColor: NSColor,
        reducedMotion: Bool
    ) {
        self.textColor = textColor
        let dimmedColor = isShimmering
            ? textColor.withAlphaComponent(textColor.alphaComponent * 0.90)
            : textColor
        baseLabel.textColor = dimmedColor
        iconView.contentTintColor = dimmedColor
        shimmerLabel.isShimmering = isShimmering
        shimmerLabel.reducedMotion = reducedMotion
        shimmerLabel.shimmerColor = shimmerColor
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        shimmerLabel.shimmerCoordinator = coordinator
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        shimmerLabel.isVisibleForSharedAnimation = isVisible
    }

    func setShimmerPhaseOffset(_ offset: CGFloat) {
        shimmerLabel.shimmerPhaseOffset = offset
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        shimmerLabel.shimmerPhaseOffsetForTesting
    }
}

@MainActor
private final class SidebarPaneRowButton: NSButton {
    var paneID = PaneID("")
    var isLastPaneInWorklane = false
    var onPaneClicked: ((PaneID) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCloseWorklane: ((PaneID) -> Void)?
    var onClosePane: ((PaneID) -> Void)?
    var onSplitHorizontal: ((PaneID) -> Void)?
    var onSplitVertical: ((PaneID) -> Void)?

    private let contentStack = NSStackView()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var hoverBackgroundColor: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        wantsLayer = true
        layer?.cornerRadius = ShellMetrics.sidebarPaneButtonCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        contentStack.orientation = .vertical
        contentStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: topAnchor, constant: ShellMetrics.sidebarPaneButtonVerticalInset),
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: ShellMetrics.sidebarPaneButtonHorizontalInset),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -ShellMetrics.sidebarPaneButtonHorizontalInset),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -ShellMetrics.sidebarPaneButtonVerticalInset),
        ])

        target = self
        action = #selector(handleClick)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let pointInSelf = convert(point, from: superview)
        return bounds.contains(pointInSelf) ? self : nil
    }

    @objc private func handleClick() {
        onPaneClicked?(paneID)
    }

    func setContent(_ views: [NSView]) {
        contentStack.setViews(views, in: .top)
    }

    func updateTheme(hoverColor: NSColor) {
        hoverBackgroundColor = hoverColor
        updateHoverAppearance()
    }

    var contentMinXForTesting: CGFloat {
        contentStack.frame.minX
    }

    var contentMaxTrailingInsetForTesting: CGFloat {
        bounds.maxX - contentStack.frame.maxX
    }

    var contentMinYForTesting: CGFloat {
        contentStack.frame.minY
    }

    var contentMaxTopInsetForTesting: CGFloat {
        bounds.maxY - contentStack.frame.maxY
    }

    var cornerRadiusForTesting: CGFloat {
        layer?.cornerRadius ?? 0
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverAppearance()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverAppearance()
        onHoverChanged?(false)
    }

    override var isHighlighted: Bool {
        didSet {
            updateHoverAppearance()
        }
    }

    private func updateHoverAppearance() {
        let color: NSColor
        if isHighlighted {
            color = hoverBackgroundColor.withAlphaComponent(0.7)
        } else if isHovered {
            color = hoverBackgroundColor
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let closeWorklaneItem = NSMenuItem(
            title: "Close Worklane",
            action: #selector(handleCloseWorklane),
            keyEquivalent: ""
        )
        closeWorklaneItem.target = self
        menu.addItem(closeWorklaneItem)

        if !isLastPaneInWorklane {
            let closePaneItem = NSMenuItem(
                title: "Close Pane",
                action: #selector(handleClosePane),
                keyEquivalent: ""
            )
            closePaneItem.target = self
            menu.addItem(closePaneItem)
        }

        menu.addItem(NSMenuItem.separator())

        let splitHItem = NSMenuItem(
            title: "Split Horizontal",
            action: #selector(handleSplitHorizontal),
            keyEquivalent: ""
        )
        splitHItem.target = self
        menu.addItem(splitHItem)

        let splitVItem = NSMenuItem(
            title: "Split Vertical",
            action: #selector(handleSplitVertical),
            keyEquivalent: ""
        )
        splitVItem.target = self
        menu.addItem(splitVItem)

        return menu
    }

    @objc private func handleCloseWorklane() {
        onCloseWorklane?(paneID)
    }

    @objc private func handleClosePane() {
        onClosePane?(paneID)
    }

    @objc private func handleSplitHorizontal() {
        onSplitHorizontal?(paneID)
    }

    @objc private func handleSplitVertical() {
        onSplitVertical?(paneID)
    }
}
