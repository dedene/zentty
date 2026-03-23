import AppKit
import CoreText
import QuartzCore

@MainActor
final class SidebarWorkspaceRowButton: NSButton {
    private enum Layout {
        static let contentInset = ShellMetrics.sidebarRowHorizontalInset
        static let primaryTextLeadingInset: CGFloat = 0
    }

    let workspaceID: WorkspaceID?

    private let leadingAccessoryContainer = NSView()
    private let leadingAccessoryView = NSImageView()
    private let topLabel = SidebarStaticLabel()
    private let primaryTextContainer = SidebarPrimaryTextContainerView()
    private let primaryBaseLabel = SidebarStaticLabel()
    private let primaryLabel = SidebarShimmerTextView()
    private let statusLabel = SidebarStaticLabel()
    private let stateBadgeIconView = NSImageView()
    private let stateBadgeLabel = SidebarStaticLabel()
    private let stateBadgeStack = NSStackView()
    private let overflowLabel = SidebarStaticLabel()
    private let textStack = NSStackView()
    private let bodyStack = NSStackView()
    private let contentStack = NSStackView()
    private let artifactButton = NSButton(title: "", target: nil, action: nil)

    private var detailLabels: [SidebarStaticLabel] = []
    private var currentSummary: WorkspaceSidebarSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var artifactURL: URL?
    private var heightConstraint: NSLayoutConstraint?
    private var leadingAccessoryWidthConstraint: NSLayoutConstraint?
    private var currentLeadingAccessorySymbolName: String?
    private var isWorking = false
    private let reducedMotionProvider: () -> Bool

    init(
        workspaceID: WorkspaceID?,
        reducedMotionProvider: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.workspaceID = workspaceID
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
            statusLabel,
            font: ShellMetrics.sidebarStatusFont(),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            stateBadgeLabel,
            font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            overflowLabel,
            font: ShellMetrics.sidebarOverflowFont(),
            lineBreakMode: .byTruncatingTail
        )
        stateBadgeIconView.translatesAutoresizingMaskIntoConstraints = false
        stateBadgeIconView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        stateBadgeIconView.setContentHuggingPriority(.required, for: .horizontal)
        stateBadgeIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stateBadgeStack.orientation = .horizontal
        stateBadgeStack.alignment = .centerY
        stateBadgeStack.spacing = 5
        stateBadgeStack.translatesAutoresizingMaskIntoConstraints = false
        stateBadgeStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stateBadgeStack.addArrangedSubview(stateBadgeIconView)
        stateBadgeStack.addArrangedSubview(stateBadgeLabel)

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
            primaryBaseLabel.topAnchor.constraint(equalTo: primaryTextContainer.topAnchor),
            primaryBaseLabel.leadingAnchor.constraint(equalTo: primaryTextContainer.leadingAnchor, constant: Layout.primaryTextLeadingInset),
            primaryBaseLabel.trailingAnchor.constraint(equalTo: primaryTextContainer.trailingAnchor),
            primaryBaseLabel.bottomAnchor.constraint(equalTo: primaryTextContainer.bottomAnchor),
            primaryLabel.topAnchor.constraint(equalTo: primaryTextContainer.topAnchor),
            primaryLabel.leadingAnchor.constraint(equalTo: primaryTextContainer.leadingAnchor),
            primaryLabel.trailingAnchor.constraint(equalTo: primaryTextContainer.trailingAnchor),
            primaryLabel.bottomAnchor.constraint(equalTo: primaryTextContainer.bottomAnchor),
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
            primaryTextContainer.heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarPrimaryLineHeight),
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
        isWorking = summary.isWorking

        let layout = SidebarWorkspaceRowLayout(summary: summary)

        topLabel.stringValue = summary.topLabel ?? ""
        primaryBaseLabel.stringValue = summary.primaryText
        primaryLabel.stringValue = summary.primaryText
        statusLabel.stringValue = summary.statusText ?? ""
        stateBadgeLabel.stringValue = summary.stateBadgeText ?? ""
        overflowLabel.stringValue = summary.overflowText ?? ""
        configureStateBadge(for: summary)
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

        appearance = NSAppearance(named: currentTheme.sidebarGlassAppearance.nsAppearanceName)
        updateShimmerState()

        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText

        topLabel.textColor = topLabelTextColor(
            for: summary,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        primaryBaseLabel.textColor = primaryTextColor(
            for: summary,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
        statusLabel.textColor = statusTextColor(for: summary)
        stateBadgeLabel.textColor = stateBadgeTextColor(for: summary)
        stateBadgeIconView.contentTintColor = stateBadgeLabel.textColor
        overflowLabel.textColor = summary.isActive
            ? activeTextColor.withAlphaComponent(0.54)
            : currentTheme.tertiaryText
        artifactButton.contentTintColor = summary.isActive ? activeTextColor : inactiveTextColor
        leadingAccessoryView.contentTintColor = leadingAccessoryColor(for: summary, activeTextColor: activeTextColor)

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
            self.layer?.backgroundColor = self.backgroundColor(
                isActive: summary.isActive,
                activeBackground: activeBackground,
                hoverBackground: hoverBackground,
                inactiveBackground: inactiveBackground
            ).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = summary.isActive ? 0.8 : 1
            self.layer?.shadowColor = NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor
            self.layer?.shadowOpacity = 1
            self.layer?.shadowRadius = summary.isActive ? 12 : 4
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func configureStateBadge(for summary: WorkspaceSidebarSummary) {
        guard let symbolName = stateBadgeSymbolName(for: summary) else {
            stateBadgeIconView.image = nil
            return
        }

        stateBadgeIconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: summary.stateBadgeText
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
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

            return activeBackground
                .mixed(towards: currentTheme.sidebarGradientStart.brightenedForLabel, amount: 0.12)
        }

        if isHovered {
            return hoverBackground
        }

        guard isWorking else {
            return inactiveBackground
        }

        let base = inactiveBackground
            .mixed(towards: currentTheme.sidebarGradientStart, amount: 0.18)
        return base.withAlphaComponent(currentTheme.reducedTransparency ? 0.92 : 1)
    }

    private func updateShimmerState() {
        let isActive = currentSummary?.isActive ?? false
        let activeTextColor = currentTheme.sidebarButtonActiveText
        let inactiveTextColor = currentTheme.sidebarButtonInactiveText
        primaryLabel.isShimmering = isWorking
        primaryLabel.reducedMotion = reducedMotionProvider()
        primaryLabel.shimmerColor = workingTextHighlightColor(
            isActive: isActive,
            activeTextColor: activeTextColor,
            inactiveTextColor: inactiveTextColor
        )
            .withAlphaComponent(shimmerHighlightAlpha(isActive: isActive))
    }

    private func primaryTextColor(
        for summary: WorkspaceSidebarSummary,
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

    private func topLabelTextColor(
        for summary: WorkspaceSidebarSummary,
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

    private func leadingAccessoryColor(
        for summary: WorkspaceSidebarSummary,
        activeTextColor: NSColor
    ) -> NSColor {
        guard summary.isWorking else {
            return summary.isActive
                ? activeTextColor.withAlphaComponent(0.78)
                : currentTheme.secondaryText
        }

        let emphasis = workingTextHighlightColor(
            isActive: summary.isActive,
            activeTextColor: activeTextColor,
            inactiveTextColor: currentTheme.sidebarButtonInactiveText
        )
            .withAlphaComponent(summary.isActive ? 0.94 : 0.88)

        return summary.isActive
            ? emphasis
            : emphasis
    }

    private func workingTextHighlightColor(
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        if isActive {
            return activeTextColor.mixed(towards: .white, amount: 0.10)
        }

        return inactiveTextColor.mixed(towards: currentTheme.sidebarWorkingTextHighlight, amount: 0.58)
    }

    private func shimmerHighlightAlpha(isActive: Bool) -> CGFloat {
        if currentTheme.reducedTransparency {
            return isActive ? 0.24 : 0.18
        }

        return isActive ? 0.38 : 0.28
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

    private func stateBadgeTextColor(for summary: WorkspaceSidebarSummary) -> NSColor {
        switch summary.attentionState {
        case .needsInput:
            return NSColor.systemBlue
        case .unresolvedStop:
            return NSColor.systemOrange
        case .running:
            return NSColor.systemGreen
        case .completed:
            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.70)
                : currentTheme.secondaryText
        case nil:
            if summary.isWorking {
                return NSColor.systemGreen
            }

            return summary.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        }
    }

    private func stateBadgeSymbolName(for summary: WorkspaceSidebarSummary) -> String? {
        switch summary.attentionState {
        case .needsInput:
            return "bell.badge.fill"
        case .unresolvedStop:
            return "exclamationmark.circle.fill"
        case .running:
            return "circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case nil:
            if summary.isWorking {
                return "circle.fill"
            }
            if summary.stateBadgeText != nil {
                return "pause.circle.fill"
            }
            return nil
        }
    }

    private func label(for row: WorkspaceRowTextRow) -> NSView {
        switch row {
        case .topLabel:
            topLabel
        case .primary:
            primaryTextContainer
        case .status:
            statusLabel
        case .stateBadge:
            stateBadgeStack
        case .context:
            detailLabels.first ?? overflowLabel
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

    var statusTextForTesting: String {
        statusLabel.stringValue
    }

    var topLabelColorForTesting: NSColor {
        topLabel.textColor ?? .clear
    }

    var stateBadgeTextForTesting: String {
        stateBadgeLabel.stringValue
    }

    var leadingAccessorySymbolNameForTesting: String {
        currentLeadingAccessorySymbolName ?? ""
    }

    var isWorkingForTesting: Bool {
        isWorking
    }

    var shimmerIsAnimatingForTesting: Bool {
        primaryLabel.shimmerIsAnimating
    }

    var shimmerColorForTesting: NSColor {
        primaryLabel.shimmerColor
    }

    var primaryTextColorForTesting: NSColor {
        primaryBaseLabel.textColor ?? .clear
    }

    var primaryRowIndexForTesting: Int? {
        textStack.arrangedSubviews.firstIndex(of: primaryTextContainer)
    }

    var backgroundColorForTesting: NSColor? {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
    }

    var appearanceMatchForTesting: NSAppearance.Name? {
        appearance?.bestMatch(from: [.darkAqua, .aqua])
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        view.convert(primaryBaseLabel.bounds, from: primaryBaseLabel).minX
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
    private enum Animation {
        static let duration: CFTimeInterval = 1.05
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
            updateAnimationState()
            needsDisplay = true
        }
    }

    var reducedMotion: Bool = false {
        didSet {
            guard oldValue != reducedMotion else { return }
            updateAnimationState()
            needsDisplay = true
        }
    }

    private var shimmerTimer: Timer?
    private var shimmerStartTime: CFTimeInterval?
    private var shimmerProgress: CGFloat = 0
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
        shimmerTimer != nil
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
        guard newSuperview == nil else {
            return
        }

        shimmerTimer?.invalidate()
        shimmerTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard
            let context = NSGraphicsContext.current?.cgContext,
            let layout = layoutSnapshot(forWidth: bounds.width)
        else {
            return
        }

        guard isShimmering else {
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
        let bandWidth = max(32, min(availableWidth * 0.7, max(layout.width * 0.9, 32)))
        let originX: CGFloat
        if reducedMotion {
            originX = Self.textLeadingInset + (availableWidth / 2) - (bandWidth / 2)
        } else {
            let travel = availableWidth + bandWidth
            originX = Self.textLeadingInset - bandWidth + (travel * shimmerProgress)
        }

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                shimmerColor.withAlphaComponent(0).cgColor,
                shimmerColor.cgColor,
                shimmerColor.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) else {
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

        if
            let cachedLayout,
            abs(cachedWidth - width) <= .ulpOfOne,
            cachedStringValue == stringValue,
            cachedFont == font,
            cachedLineBreakMode == lineBreakMode
        {
            return cachedLayout
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: stringValue, attributes: attributes)
        )
        let drawLine = truncatedLine(from: line, attributes: attributes, availableWidth: availableWidth)

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

                var transform = CGAffineTransform(
                    translationX: lineOrigin.x + positions[index].x,
                    y: lineOrigin.y + positions[index].y
                )
                glyphPath.addPath(path, transform: transform)
            }
        }

        return glyphPath
    }

    private func updateAnimationState() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil

        guard isShimmering, reducedMotion == false else {
            shimmerProgress = 0.5
            shimmerStartTime = nil
            return
        }

        shimmerStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: Animation.frameInterval, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.handleShimmerTick()
            }
        }
        shimmerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleShimmerTick() {
        guard let shimmerStartTime else {
            return
        }

        let elapsed = CACurrentMediaTime() - shimmerStartTime
        shimmerProgress = CGFloat((elapsed / Animation.duration).truncatingRemainder(dividingBy: 1))
        needsDisplay = true
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

private final class SidebarPrimaryTextContainerView: NSView {
    override var allowsVibrancy: Bool {
        false
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
