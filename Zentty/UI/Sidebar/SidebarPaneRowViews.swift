import AppKit

// MARK: - Leaf Components

final class SidebarStaticLabel: NSTextField {
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

final class SidebarPrimaryTextContainerView: NSView {
    override var allowsVibrancy: Bool {
        false
    }
}

// MARK: - SidebarPanePrimaryRowView

@MainActor
final class SidebarPanePrimaryRowView: NSView {
    private let textContainer = SidebarPrimaryTextContainerView()
    private let baseLabel = SidebarStaticLabel()
    private let shimmerLabel = SidebarShimmerTextView()
    private let trailingLabelView = SidebarStaticLabel()
    private let stack = NSStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var presentationMode: SidebarPaneRowPresentationMode = .inline
    private var requestedLineCount: Int = 1

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

    var renderedTrailingTextColorForTesting: NSColor {
        trailingLabelView.textColor ?? .clear
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: heightConstraint?.constant ?? ShellMetrics.sidebarPrimaryLineHeight
        )
    }

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
        updateAdaptiveHeight()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textContainer.addSubview(baseLabel)
        textContainer.addSubview(shimmerLabel)

        baseLabel.font = ShellMetrics.sidebarPrimaryFont()
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.translatesAutoresizingMaskIntoConstraints = false
        baseLabel.maximumNumberOfLines = 1
        baseLabel.cell?.wraps = false
        baseLabel.cell?.usesSingleLineMode = true

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
        stack.alignment = .top
        stack.spacing = SidebarPaneRowPresentationMode.inlineSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textContainer)
        stack.addArrangedSubview(trailingLabelView)
        addSubview(stack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarPrimaryLineHeight)
        heightConstraint.priority = .defaultHigh
        self.heightConstraint = heightConstraint
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
            heightConstraint,
        ])
    }

    /// Surgical primary-text update for the volatile agent title fast path.
    /// Writes the new text into baseLabel and shimmerLabel without touching
    /// trailing text, presentation mode, line count, or layout. Idempotent.
    func setPrimaryText(_ text: String) {
        guard primaryText != text else { return }
        primaryText = text
        baseLabel.stringValue = text
        shimmerLabel.stringValue = text
    }

    func configure(
        primaryText: String,
        trailingText: String?,
        presentationMode: SidebarPaneRowPresentationMode,
        lineCount: Int
    ) {
        self.primaryText = primaryText
        self.trailingText = trailingText
        self.presentationMode = presentationMode
        requestedLineCount = lineCount
        baseLabel.stringValue = primaryText
        shimmerLabel.stringValue = primaryText
        trailingLabelView.stringValue = trailingText ?? ""
        trailingLabelView.isHidden = (trailingText?.isEmpty ?? true)
        applyPresentationMode(lineCount: lineCount)
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
        // The pane row primary stays single-line with tail truncation (see
        // `applyPresentationMode`) so the shimmer overlay always has a line
        // to clip against — hiding it on wrap would kill the shimmer on
        // running agents.
        shimmerLabel.isHidden = false
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

    private func applyPresentationMode(lineCount: Int) {
        // The pane row primary is intentionally single-line with tail
        // truncation. `SidebarShimmerTextView` is a single-line CoreText
        // renderer, so keeping this label one line wide is what allows
        // running agents to shimmer. Long titles simply truncate.
        //
        // Note: we still honour `presentationMode == .adaptive` for the
        // inline trailing label. In adaptive mode the branch moves to the
        // status row (via `paneRowStatusTrailingLayout`), so hiding the
        // inline trailing here prevents it from appearing in both places.
        let movesTrailingToStatusRow = presentationMode == .adaptive
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.maximumNumberOfLines = 1
        baseLabel.cell?.wraps = false
        baseLabel.cell?.usesSingleLineMode = true
        trailingLabelView.isHidden =
            movesTrailingToStatusRow || (trailingText?.isEmpty ?? true)
        stack.alignment = .centerY
        heightConstraint?.constant = ShellMetrics.sidebarPrimaryLineHeight
        invalidateIntrinsicContentSize()
    }

    private func updateAdaptiveHeight() {
        // The pane row primary is always single-line — no adaptive height.
    }
}

// MARK: - SidebarPaneTextRowView

@MainActor
final class SidebarPaneTextRowView: NSView {
    private static let symbolPointSize: CGFloat = 11

    private let iconView = NSImageView()
    private let textContainer = SidebarPrimaryTextContainerView()
    private let baseLabel = SidebarStaticLabel()
    private let shimmerLabel = SidebarShimmerTextView()
    private let trailingLabelView = SidebarStaticLabel()
    private let contentStack = NSStackView()

    private(set) var text: String = ""
    private(set) var symbolName: String = ""
    private(set) var textColor: NSColor = .secondaryLabelColor
    private(set) var trailingText: String?
    private(set) var trailingTextColor: NSColor = .secondaryLabelColor
    private var rowLineHeight: CGFloat = ShellMetrics.sidebarStatusLineHeight
    private var heightConstraint: NSLayoutConstraint?
    private var trailingWidthConstraint: NSLayoutConstraint?
    private var lineCount = 1

    init(font: NSFont, lineHeight: CGFloat) {
        super.init(frame: .zero)
        setup(font: font, lineHeight: lineHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(font: NSFont, lineHeight: CGFloat) {
        rowLineHeight = lineHeight
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
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
        trailingLabelView.font = ShellMetrics.sidebarDetailFont()
        trailingLabelView.alignment = .right
        trailingLabelView.lineBreakMode = .byTruncatingMiddle
        trailingLabelView.translatesAutoresizingMaskIntoConstraints = false
        trailingLabelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabelView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(trailingLabelView)
        addSubview(contentStack)

        baseLabel.font = font
        baseLabel.lineBreakMode = .byTruncatingTail
        baseLabel.translatesAutoresizingMaskIntoConstraints = false
        baseLabel.maximumNumberOfLines = 1
        baseLabel.cell?.wraps = false
        baseLabel.cell?.usesSingleLineMode = true

        shimmerLabel.font = font
        shimmerLabel.lineHeight = lineHeight
        shimmerLabel.lineBreakMode = .byTruncatingTail
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false

        let heightConstraint = heightAnchor.constraint(equalToConstant: lineHeight)
        heightConstraint.priority = .defaultHigh
        self.heightConstraint = heightConstraint
        let trailingWidthConstraint = trailingLabelView.widthAnchor.constraint(equalToConstant: 0)
        self.trailingWidthConstraint = trailingWidthConstraint

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
            heightConstraint,
            trailingWidthConstraint,
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: heightConstraint?.constant ?? rowLineHeight
        )
    }

    override func layout() {
        super.layout()
        updateResolvedTrailingVisibility()
    }

    func configure(
        text: String,
        symbolName: String?,
        trailingText: String?,
        trailingWidth: CGFloat,
        lineCount: Int
    ) {
        self.text = text
        self.symbolName = symbolName ?? ""
        self.trailingText = trailingText
        let showsTrailingTextInLeadingSlot = rendersTrailingTextInLeadingSlot
        let leadingText = showsTrailingTextInLeadingSlot ? (trailingText ?? "") : text

        baseLabel.stringValue = leadingText
        shimmerLabel.stringValue = leadingText
        iconView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .semibold))
        }
        iconView.isHidden = showsTrailingTextInLeadingSlot || iconView.image == nil
        trailingLabelView.stringValue = showsTrailingTextInLeadingSlot ? "" : (trailingText ?? "")
        trailingLabelView.isHidden = showsTrailingTextInLeadingSlot || (trailingText?.isEmpty ?? true)
        trailingWidthConstraint?.constant = showsTrailingTextInLeadingSlot || trailingText == nil ? 0 : trailingWidth
        applyPresentation(lineCount: lineCount)
    }

    func applyColors(
        textColor: NSColor,
        trailingTextColor: NSColor?,
        isShimmering: Bool,
        shimmerColor: NSColor,
        reducedMotion: Bool
    ) {
        self.textColor = textColor
        self.trailingTextColor = trailingTextColor ?? .clear
        let dimmedColor = isShimmering
            ? textColor.withAlphaComponent(textColor.alphaComponent * 0.90)
            : textColor
        let leadingTextColor = rendersTrailingTextInLeadingSlot
            ? (trailingTextColor ?? textColor)
            : dimmedColor
        baseLabel.textColor = leadingTextColor
        iconView.contentTintColor = dimmedColor
        trailingLabelView.textColor = trailingTextColor
        shimmerLabel.isShimmering = isShimmering && lineCount == 1 && rendersTrailingTextInLeadingSlot == false
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

    var isTrailingVisibleForTesting: Bool {
        trailingLabelView.isHidden == false
    }

    private func applyPresentation(lineCount: Int) {
        let clampedLineCount = max(1, min(2, lineCount))
        let wraps = clampedLineCount > 1

        self.lineCount = clampedLineCount
        baseLabel.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        baseLabel.maximumNumberOfLines = wraps ? clampedLineCount : 1
        baseLabel.cell?.wraps = wraps
        baseLabel.cell?.usesSingleLineMode = wraps == false
        shimmerLabel.isHidden = wraps
        contentStack.alignment = wraps ? .top : .centerY
        trailingLabelView.isHidden = wraps || rendersTrailingTextInLeadingSlot || (trailingText?.isEmpty ?? true)
        heightConstraint?.constant = rowLineHeight * CGFloat(clampedLineCount)
        invalidateIntrinsicContentSize()
    }

    private func updateResolvedTrailingVisibility() {
        guard let trailingText, trailingText.isEmpty == false else {
            trailingLabelView.isHidden = true
            return
        }

        guard rendersTrailingTextInLeadingSlot == false else {
            trailingLabelView.isHidden = true
            return
        }

        guard lineCount == 1 else {
            trailingLabelView.isHidden = true
            return
        }

        let availableTextWidth = max(0, textContainer.bounds.width)
        guard availableTextWidth > 0 else {
            trailingLabelView.isHidden = false
            return
        }

        let font = baseLabel.font ?? ShellMetrics.sidebarStatusFont()
        let measuredTextWidth = Self.measuredWidth(for: text, font: font)
        let measuredLineCount = Self.measuredLineCount(
            for: text,
            font: font,
            lineHeight: rowLineHeight,
            width: availableTextWidth
        )
        trailingLabelView.isHidden =
            measuredTextWidth > availableTextWidth + 0.5
            || measuredLineCount > 1
    }

    private static func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        SidebarTextMetrics.measuredWidth(for: text, font: font)
    }

    private static func measuredLineCount(
        for text: String,
        font: NSFont,
        lineHeight: CGFloat,
        width: CGFloat
    ) -> Int {
        SidebarTextMetrics.measuredLineCount(for: text, font: font, lineHeight: lineHeight, width: width)
    }

    private var rendersTrailingTextInLeadingSlot: Bool {
        Self.hasVisibleText(text) == false && Self.hasVisibleText(trailingText)
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else {
            return false
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
