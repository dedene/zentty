import AppKit
import QuartzCore

@MainActor
final class PaneBorderContextInsetView: NSView {
    enum Layout {
        static let paneContextLeadingInset: CGFloat = 24
        static let paneContextTrailingGutter: CGFloat = 16
        static let paneContextHorizontalPadding: CGFloat = 7
        static let paneContextMinHeight: CGFloat = 16
        static let paneContextFontSize: CGFloat = 10

        @MainActor
        static var paneContextPreferredHeight: CGFloat {
            let font = NSFont.systemFont(ofSize: paneContextFontSize, weight: .semibold)
            let textHeight = ceil(PaneBorderContextInsetView.textLineHeight(for: font))
            return max(
                paneContextMinHeight,
                textHeight
                    + TextLayout.topInset
                    + TextLayout.bottomInset
                    + TextLayout.verticalSafety
            )
        }
    }

    private enum TextLayout {
        static let topInset: CGFloat = 5
        static let bottomInset: CGFloat = 4
        static let verticalSafety: CGFloat = 2
    }

    var onClick: (() -> Void)? {
        didSet {
            updateCopyAffordanceState()
        }
    }

    private let textContentLayer = CALayer()
    private let leftBorderLineLayer = CALayer()
    private let rightBorderLineLayer = CALayer()
    private let textFont = NSFont.systemFont(ofSize: Layout.paneContextFontSize, weight: .semibold)
    private let nameFont = NSFont.systemFont(ofSize: Layout.paneContextFontSize, weight: .bold)
    /// Separates a float's bold name from its cwd.
    static let nameSeparator = " \u{00B7} "
    private var textColorToken = ""
    private var naturalTextWidth: CGFloat = 0
    private var currentAttributedText = NSAttributedString(string: "")
    private var currentTextRect: CGRect = .zero
    private let currentTruncationMode: CATextLayerTruncationMode = .middle
    private var shortcutManager = ShortcutManager(shortcuts: .default)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let pointInSelf = superview.map { convert(point, from: $0) } ?? point
        guard onClick != nil, bounds.contains(pointInSelf) else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard onClick != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    func measure(text: String, name: String? = nil, maxWidth: CGFloat, prefixGlyph: String? = nil) -> CGSize {
        let displayText = attributedText(text: text, name: name, prefixGlyph: prefixGlyph, color: nil)
        naturalTextWidth = ceil(Self.naturalTextWidth(for: displayText))
        return CGSize(
            width: min(maxWidth, naturalTextWidth + (Layout.paneContextHorizontalPadding * 2)),
            height: Layout.paneContextPreferredHeight
        )
    }

    func render(
        text: String,
        name: String? = nil,
        isFocused: Bool,
        theme: ZenttyTheme,
        backingScaleFactor: CGFloat,
        prefixGlyph: String? = nil
    ) {
        let textColor = (isFocused
            ? theme.paneBorderFocused
            : theme.paneBorderUnfocused).brightenedForLabel
        let textHeight = ceil(Self.textLineHeight(for: textFont))
        let attributedText = attributedText(text: text, name: name, prefixGlyph: prefixGlyph, color: textColor)

        let borderColor = (isFocused
            ? theme.paneBorderFocused
            : theme.paneBorderUnfocused).cgColor
        let lineHeight = max(1, 1 / backingScaleFactor)
        textColorToken = textColor.themeToken

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.clear.cgColor
        let lineY = (bounds.height - lineHeight) / 2
        leftBorderLineLayer.frame = CGRect(
            x: 0,
            y: lineY,
            width: 0,
            height: lineHeight
        )
        rightBorderLineLayer.frame = CGRect(
            x: bounds.width,
            y: lineY,
            width: 0,
            height: lineHeight
        )
        leftBorderLineLayer.backgroundColor = borderColor
        rightBorderLineLayer.backgroundColor = borderColor
        currentAttributedText = attributedText
        let availableHeight = max(0, bounds.height - TextLayout.topInset - TextLayout.bottomInset)
        let drawingHeight = min(availableHeight, textHeight + TextLayout.verticalSafety)
        let drawingY = TextLayout.topInset + max(0, floor((availableHeight - drawingHeight) / 2))
        currentTextRect = Self.alignedRect(
            CGRect(
                x: Layout.paneContextHorizontalPadding,
                y: drawingY,
                width: max(0, bounds.width - (Layout.paneContextHorizontalPadding * 2)),
                height: drawingHeight
            ),
            scale: backingScaleFactor
        )
        textContentLayer.frame = currentTextRect
        textContentLayer.contentsScale = backingScaleFactor
        textContentLayer.contents = Self.renderTextImage(
            attributedText,
            size: currentTextRect.size,
            scale: backingScaleFactor
        )
        CATransaction.commit()
    }

    var textForTesting: String {
        currentAttributedText.string
    }

    var attributedTextForTesting: NSAttributedString {
        currentAttributedText
    }

    /// `prefixGlyph` + bold `name` + " · " + `text`. A float shows its name
    /// first; tiles pass no name and keep the plain cwd label.
    private func attributedText(
        text: String,
        name: String?,
        prefixGlyph: String?,
        color: NSColor?
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        var nameAttributes: [NSAttributedString.Key: Any] = [.font: nameFont]
        if let color {
            attributes[.foregroundColor] = color
            nameAttributes[.foregroundColor] = color
        }
        let result = NSMutableAttributedString()
        if let prefixGlyph, !prefixGlyph.isEmpty {
            result.append(NSAttributedString(string: prefixGlyph, attributes: attributes))
        }
        if let name, !name.isEmpty {
            result.append(NSAttributedString(string: name, attributes: nameAttributes))
            if !text.isEmpty {
                result.append(NSAttributedString(string: Self.nameSeparator, attributes: attributes))
            }
        }
        if !text.isEmpty {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    var textColorTokenForTesting: String {
        textColorToken
    }

    var textFrameForTesting: CGRect {
        currentTextRect
    }

    var naturalTextWidthForTesting: CGFloat {
        naturalTextWidth
    }

    var leftBorderFrameForTesting: CGRect {
        leftBorderLineLayer.frame
    }

    var rightBorderFrameForTesting: CGRect {
        rightBorderLineLayer.frame
    }

    var truncationModeForTesting: CATextLayerTruncationMode {
        currentTruncationMode
    }

    var usesCATextLayerForTesting: Bool {
        layer?.sublayers?.contains(where: { $0 is CATextLayer }) ?? false
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        textContentLayer.zPosition = 1
        leftBorderLineLayer.zPosition = 1
        rightBorderLineLayer.zPosition = 1
        layer?.addSublayer(textContentLayer)
        layer?.addSublayer(leftBorderLineLayer)
        layer?.addSublayer(rightBorderLineLayer)
        updateCopyAffordanceState()
    }

    private var showsCopyAffordance: Bool {
        onClick != nil
    }

    private func updateCopyAffordanceState() {
        toolTip = showsCopyAffordance
            ? CommandTooltipFormatter.title(
                "Copy Path",
                commandID: .copyFocusedPanePath,
                shortcutManager: shortcutManager
            )
            : nil
    }

    func updateShortcutTooltip(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        updateCopyAffordanceState()
    }

    private static func naturalTextWidth(for text: NSAttributedString) -> CGFloat {
        text.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width
    }

    private static func textLineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// Eight-spoked asterisk + space marking a Claude Code agent-teams leader
    /// pane. Matches the glyph Claude Code itself prints in its window title.
    static let leaderGlyph = "\u{2733} "
    /// Middle dot + space marking a Claude Code agent-teams column member
    /// (non-leader) in the border-context inset.
    static let memberGlyph = "\u{00B7} "

    private static func renderTextImage(
        _ attributedText: NSAttributedString,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.scaleBy(x: scale, y: scale)

        let line = CTLineCreateWithAttributedString(attributedText)
        let availableWidth = Double(size.width)
        let drawLine: CTLine
        if CTLineGetTypographicBounds(line, nil, nil, nil) > availableWidth {
            let truncAttrs = attributedText.attributes(at: 0, effectiveRange: nil)
            let token = NSAttributedString(string: "\u{2026}", attributes: truncAttrs)
            let tokenLine = CTLineCreateWithAttributedString(token)
            drawLine = CTLineCreateTruncatedLine(line, availableWidth, .middle, tokenLine) ?? line
        } else {
            drawLine = line
        }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(drawLine, &ascent, &descent, nil)
        let lineHeight = ascent + descent
        let bottomPadding = max(0, (size.height - lineHeight) / 2)

        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: bottomPadding + descent)
        CTLineDraw(drawLine, context)

        return context.makeImage()
    }

    private static func alignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else {
            return rect.integral
        }

        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

@MainActor
final class AppCanvasView: NSView {
    var leadingVisibleInset: CGFloat {
        get { paneStripView.leadingVisibleInset }
        set {
            paneStripView.setLeadingVisibleInset(newValue, animated: false)
            layoutFloatLayer()
        }
    }
    let paneStripView: PaneStripView
    /// Floats and PiPs of the active worklane, above the strip.
    let floatLayerView: FloatLayerView
    /// Minimized floats of the active worklane, in flow below the strip.
    let pillBarView = PillBarView()
    /// Hover peek above a pill (the pane's live terminal); front-most.
    let pillPeekView = PillPeekView()
    /// The pill peek started or stopped drawing a pane live.
    var onPillPeekChanged: (() -> Void)?
    /// Height the pill bar takes from the strip (0 while there are no pills).
    private(set) var pillBarReservedHeight: CGFloat = 0
    /// The strip's height changed because the pill bar showed or left.
    var onPaneViewportHeightChanged: (() -> Void)?
    private var stripBottomConstraint: NSLayoutConstraint?
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    init(
        frame frameRect: NSRect = .zero,
        runtimeRegistry: PaneRuntimeRegistry,
        backingScaleFactorProvider: @escaping () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 1 }
    ) {
        self.paneStripView = PaneStripView(
            runtimeRegistry: runtimeRegistry,
            backingScaleFactorProvider: backingScaleFactorProvider
        )
        self.floatLayerView = FloatLayerView(runtimeRegistry: runtimeRegistry)
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.contentShellRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        paneStripView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneStripView)
        addSubview(floatLayerView)
        // Above the floats: a float can sit behind the bar, never on its pills.
        addSubview(pillBarView)
        addSubview(pillPeekView)
        pillBarView.isHidden = true
        pillBarView.onPeekChanged = { [weak self] item, pillFrame in
            self?.updatePeek(item, pillFrame: pillFrame)
        }
        wirePillPeek()
        // Floats and PiPs move between renders (gestures, settles): keep the
        // strip's terminals ignoring the pointer under where they are now.
        floatLayerView.onOccludingFramesChanged = { [weak paneStripView, weak floatLayerView] in
            guard let paneStripView, let floatLayerView else { return }
            paneStripView.setFloatOcclusionRects(floatLayerView.occludingFrames(in: paneStripView))
            paneStripView.setFloatCursorExclusionRects(floatLayerView.cursorOwningFrames(in: paneStripView))
        }
        floatLayerView.dockColumnsProvider = { [weak paneStripView, weak floatLayerView] in
            guard let paneStripView, let floatLayerView else { return [] }
            return paneStripView.dockHitTestColumns(in: floatLayerView)
        }

        let stripBottomConstraint = paneStripView.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.stripBottomConstraint = stripBottomConstraint
        NSLayoutConstraint.activate([
            paneStripView.topAnchor.constraint(equalTo: topAnchor),
            paneStripView.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStripView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripBottomConstraint,
        ])

        paneStripView.apply(theme: currentTheme, animated: false)
        paneStripView.setLeadingVisibleInset(0, animated: false)
        pillPeekView.apply(theme: currentTheme)
    }

    override func layout() {
        super.layout()
        layoutFloatLayer()
    }

    /// The float layer covers the visible canvas, right of the sidebar inset;
    /// the pill bar is its bottom `PillBarLayout.barHeight`.
    private func layoutFloatLayer() {
        let inset = min(max(0, leadingVisibleInset), bounds.width)
        let frame = NSRect(
            x: bounds.minX + inset, y: bounds.minY,
            width: bounds.width - inset, height: bounds.height
        )
        if floatLayerView.frame != frame {
            floatLayerView.frame = frame
        }
        let barFrame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: PillBarLayout.barHeight)
        if pillBarView.frame != barFrame {
            pillBarView.frame = barFrame
        }
    }

    /// The strip's height: the canvas minus the pill bar while it shows.
    var paneViewportHeight: CGFloat {
        max(0, bounds.height - pillBarReservedHeight)
    }

    /// Shows the pill bar (strip shrinks) or removes it (strip grows). The
    /// strip frame changes right away so the render that follows animates
    /// the reflow instead of a layout pass snapping it.
    private func setPillBarReservedHeight(_ height: CGFloat, animated: Bool) {
        guard height != pillBarReservedHeight else { return }
        pillBarReservedHeight = height
        stripBottomConstraint?.constant = -height
        if bounds.height > 0 {
            paneStripView.frame = NSRect(
                x: bounds.minX,
                y: bounds.minY + height,
                width: bounds.width,
                height: max(0, bounds.height - height)
            )
        }
        paneStripView.animatesNextViewportResize = animated
        floatLayerView.bottomInset = height
        onPaneViewportHeightChanged?()
    }

    /// Refreshes the pills (status, name, cwd) without a canvas render. The
    /// set of pills must be unchanged; structure changes render the canvas.
    func updatePills(_ pills: PillBarContent) {
        guard pills.items.map(\.paneID) == pillBarView.content.items.map(\.paneID) else { return }
        pillBarView.render(pills, theme: currentTheme)
        pillPeekView.updateStatus(pills.items)
    }

    func render(
        state: PaneStripState,
        floats: FloatLayerContent = .empty,
        pills: PillBarContent = .empty,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        showsPaneLabels: Bool = AppConfig.Panes.default.showLabels,
        inactivePaneOpacity: CGFloat = AppConfig.Panes.default.inactiveOpacity,
        smoothScrollingEnabled: Bool = AppConfig.Panes.default.smoothScrollingEnabled,
        showPaneBorders: Bool = AppConfig.Panes.default.showBorders,
        focusFollowsMouseEnabled: Bool = AppConfig.Panes.default.focusFollowsMouse,
        focusFollowsMouseDelay: AppConfig.Panes.FocusFollowsMouseDelay = AppConfig.Panes.default.focusFollowsMouseDelay,
        worklaneColor: WorklaneColor? = nil,
        theme: ZenttyTheme,
        leadingVisibleInset: CGFloat? = nil,
        animated: Bool = true,
        transitionDirection: WorklaneTransitionDirection? = nil,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        let floatTransitionStart = captureFloatTransitionStart()
        apply(theme: theme, animated: animated)
        paneStripView.floatHoldsFocus = floats.ownsFocus
        paneStripView.showsEmptyStripHint = state.panes.isEmpty && !floats.floats.isEmpty
        setPillBarReservedHeight(pills.isEmpty ? 0 : PillBarLayout.barHeight, animated: animated)
        defer {
            paneStripView.animatesNextViewportResize = false
            // Strip first (it releases a lifted pane's host view), then the
            // layer at its final frame (it borrows that host view).
            layoutFloatLayer()
            // A peeked pane that stops being a pill goes back before the
            // layer mounts it (restore, auto-pop) or it is gone (close).
            pillPeekView.release(keeping: Set(pills.items.map(\.paneID)))
            pillBarView.render(pills, theme: theme, closing: FloatModeTransition.closingPills(
                from: floatTransitionStart.content,
                oldPillIDs: floatTransitionStart.pillIDs,
                to: floats,
                newPillIDs: Set(pills.items.map(\.paneID)),
                stripPaneIDs: Set(state.panes.map(\.id))
            ))
            let floatTransitions = prepareFloatTransitions(from: floatTransitionStart, to: floats, strip: state)
            floatLayerView.render(
                floats,
                theme: theme,
                showPaneBorders: showPaneBorders,
                smoothScrollingEnabled: smoothScrollingEnabled
            )
            finishFloatTransitions(floatTransitions, from: floatTransitionStart)
            paneStripView.setFloatOcclusionRects(floatLayerView.occludingFrames(in: paneStripView))
            paneStripView.setFloatCursorExclusionRects(floatLayerView.cursorOwningFrames(in: paneStripView))
        }
        if let leadingVisibleInset,
           abs(paneStripView.leadingVisibleInset - leadingVisibleInset) > 0.001 {
            paneStripView.transition(
                to: state,
                paneBorderContextByPaneID: paneBorderContextByPaneID,
                showsPaneLabels: showsPaneLabels,
                inactivePaneOpacity: inactivePaneOpacity,
                smoothScrollingEnabled: smoothScrollingEnabled,
                showPaneBorders: showPaneBorders,
                focusFollowsMouseEnabled: focusFollowsMouseEnabled,
                focusFollowsMouseDelay: focusFollowsMouseDelay,
                worklaneColor: worklaneColor,
                leadingVisibleInset: leadingVisibleInset,
                animated: animated,
                transitionDirection: transitionDirection,
                duration: duration,
                timingFunction: timingFunction
            )
        } else {
            paneStripView.render(
                state,
                paneBorderContextByPaneID: paneBorderContextByPaneID,
                showsPaneLabels: showsPaneLabels,
                inactivePaneOpacity: inactivePaneOpacity,
                smoothScrollingEnabled: smoothScrollingEnabled,
                showPaneBorders: showPaneBorders,
                focusFollowsMouseEnabled: focusFollowsMouseEnabled,
                focusFollowsMouseDelay: focusFollowsMouseDelay,
                worklaneColor: worklaneColor,
                leadingVisibleInset: leadingVisibleInset,
                animated: animated,
                transitionDirection: transitionDirection,
                duration: duration,
                timingFunction: timingFunction
            )
        }
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        paneStripView.updateShortcutTooltips(shortcutManager)
        floatLayerView.updateShortcutTooltips(shortcutManager)
    }

    func focusCurrentPaneIfNeeded() {
        if floatLayerView.focusOwningFloatIfNeeded() {
            return
        }
        paneStripView.focusCurrentPaneIfNeeded()
    }

    /// A strip pane's frame in float-layer coordinates (where a lifted float
    /// starts), or nil when the pane is not mounted in the strip.
    func tileFrameInFloatLayer(for paneID: PaneID) -> CGRect? {
        paneStripView.convertPaneFrame(paneID, to: floatLayerView)
    }

    func cancelPendingPaneStripScrollSwitchGesture() {
        paneStripView.cancelScrollSwitchGesture()
    }

    func settlePaneStripPresentationNow() {
        paneStripView.settlePresentationNow()
    }

    func prepareForTestingTearDown() {
        paneStripView.prepareForTestingTearDown()
    }

    func centerFocusedInteriorPaneOnNextRender() {
        paneStripView.centerFocusedInteriorPaneOnNextRender()
    }

    func shiftPaneStripTargetOffsetOnNextRender(by delta: CGFloat) {
        paneStripView.shiftTargetOffsetOnNextRender(by: delta)
    }

    func clearPendingPaneStripTargetOffsetOverride() {
        paneStripView.clearPendingTargetOffsetOverride()
    }

    func setLeadingVisibleInset(
        _ leadingVisibleInset: CGFloat,
        animated: Bool,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        paneStripView.setLeadingVisibleInset(
            leadingVisibleInset,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
        layoutFloatLayer()
    }

    func updateMetadata(for paneID: PaneID, metadata: TerminalMetadata) {
        _ = paneID
        _ = metadata
    }

    var lastPaneStripRenderWasAnimatedForTesting: Bool {
        paneStripView.lastRenderWasAnimated
    }

    var paneStripRenderCountForTesting: Int {
        paneStripView.renderInvocationCount
    }

    var lastLeadingVisibleInsetForTesting: CGFloat {
        paneStripView.leadingVisibleInsetForTesting
    }

    var currentPaneStripScrollOffset: CGFloat {
        paneStripView.currentScrollOffset
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let didChange = theme != currentTheme
        currentTheme = theme

        if didChange {
            paneStripView.apply(theme: theme, animated: animated)
            pillPeekView.apply(theme: theme)
        }

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
