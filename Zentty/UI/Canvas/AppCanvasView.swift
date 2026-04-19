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
    }

    private enum TextLayout {
        static let topInset: CGFloat = 5
        static let bottomInset: CGFloat = 4
        static let verticalSafety: CGFloat = 2
    }

    var onClick: (() -> Void)?

    private let textContentLayer = CALayer()
    private let leftBorderLineLayer = CALayer()
    private let rightBorderLineLayer = CALayer()
    private let textFont = NSFont.systemFont(ofSize: Layout.paneContextFontSize, weight: .semibold)
    private var textColorToken = ""
    private var naturalTextWidth: CGFloat = 0
    private var currentAttributedText = NSAttributedString(string: "")
    private var currentTextRect: CGRect = .zero
    private let currentTruncationMode: CATextLayerTruncationMode = .middle

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

    func measure(text: String, maxWidth: CGFloat) -> CGSize {
        naturalTextWidth = ceil(Self.naturalTextWidth(for: text, font: textFont))
        let textHeight = ceil(Self.textLineHeight(for: textFont))
        return CGSize(
            width: min(maxWidth, naturalTextWidth + (Layout.paneContextHorizontalPadding * 2)),
            height: max(
                Layout.paneContextMinHeight,
                textHeight + TextLayout.topInset + TextLayout.bottomInset + TextLayout.verticalSafety
            )
        )
    }

    func render(
        text: String,
        isFocused: Bool,
        theme: ZenttyTheme,
        backingScaleFactor: CGFloat
    ) {
        let textColor = (isFocused
            ? theme.paneBorderFocused
            : theme.paneBorderUnfocused).brightenedForLabel
        let textHeight = ceil(Self.textLineHeight(for: textFont))
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: textFont,
                .foregroundColor: textColor,
            ]
        )

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
    }

    private static func naturalTextWidth(for text: String, font: NSFont) -> CGFloat {
        NSAttributedString(
            string: text,
            attributes: [.font: font]
        ).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width
    }

    private static func textLineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

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
        set { paneStripView.setLeadingVisibleInset(newValue, animated: false) }
    }
    let paneStripView: PaneStripView
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

        NSLayoutConstraint.activate([
            paneStripView.topAnchor.constraint(equalTo: topAnchor),
            paneStripView.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStripView.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneStripView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        paneStripView.apply(theme: currentTheme, animated: false)
        paneStripView.setLeadingVisibleInset(0, animated: false)
    }

    func render(
        worklaneName: String,
        state: PaneStripState,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        showsPaneLabels: Bool = AppConfig.Panes.default.showLabels,
        inactivePaneOpacity: CGFloat = AppConfig.Panes.default.inactiveOpacity,
        theme: ZenttyTheme,
        leadingVisibleInset: CGFloat? = nil,
        animated: Bool = true,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        apply(theme: theme, animated: animated)
        if let leadingVisibleInset,
           abs(paneStripView.leadingVisibleInset - leadingVisibleInset) > 0.001 {
            paneStripView.transition(
                to: state,
                paneBorderContextByPaneID: paneBorderContextByPaneID,
                showsPaneLabels: showsPaneLabels,
                inactivePaneOpacity: inactivePaneOpacity,
                leadingVisibleInset: leadingVisibleInset,
                animated: animated,
                duration: duration,
                timingFunction: timingFunction
            )
        } else {
            paneStripView.render(
                state,
                paneBorderContextByPaneID: paneBorderContextByPaneID,
                showsPaneLabels: showsPaneLabels,
                inactivePaneOpacity: inactivePaneOpacity,
                leadingVisibleInset: leadingVisibleInset,
                animated: animated,
                duration: duration,
                timingFunction: timingFunction
            )
        }
    }

    func focusCurrentPaneIfNeeded() {
        paneStripView.focusCurrentPaneIfNeeded()
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
        }

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
