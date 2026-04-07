import AppKit
import QuartzCore

struct PaneBorderChromeSnapshot: Equatable {
    let paneID: PaneID
    let frame: CGRect
    let isFocused: Bool
    let emphasis: CGFloat
    let borderContext: PaneBorderContextDisplayModel?
}

@MainActor
final class PaneBorderContextOverlayView: NSView {
    private enum Layout {
        static let paneContextLeadingInset: CGFloat = 24
        static let paneContextTrailingGutter: CGFloat = 16
        static let paneContextHorizontalPadding: CGFloat = 7
        static let paneContextMinHeight: CGFloat = 16
        static let paneContextFontSize: CGFloat = 10
    }

    var onPathClicked: ((PaneID) -> Void)?

    private var currentSnapshots: [PaneBorderChromeSnapshot] = []
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private let backingScaleFactorProvider: () -> CGFloat
    private var itemViewsByPaneID: [PaneID: PaneBorderContextInsetView] = [:]

    init(
        frame frameRect: NSRect = .zero,
        backingScaleFactorProvider: @escaping () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 1 }
    ) {
        self.backingScaleFactorProvider = backingScaleFactorProvider
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onPathClicked != nil else { return nil }
        let localPoint = convert(point, from: superview)
        for (_, itemView) in itemViewsByPaneID where !itemView.isHidden {
            if itemView.frame.contains(localPoint) {
                return self
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        for (paneID, itemView) in itemViewsByPaneID where !itemView.isHidden {
            if itemView.frame.contains(localPoint) {
                onPathClicked?(paneID)
                return
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard onPathClicked != nil else { return }
        for (_, itemView) in itemViewsByPaneID where !itemView.isHidden {
            addCursorRect(itemView.frame, cursor: .pointingHand)
        }
    }

    func render(snapshots: [PaneBorderChromeSnapshot], theme: ZenttyTheme, animated: Bool = false) {
        currentSnapshots = snapshots
        currentTheme = theme
        reconcileItemViews()
        layoutItemViews(animated: animated)
    }

    override func layout() {
        super.layout()
        layoutItemViews()
    }

    var paneContextTextsForTesting: [PaneID: String] {
        itemViewsByPaneID.mapValues(\.textForTesting)
    }

    var paneContextFramesForTesting: [PaneID: CGRect] {
        itemViewsByPaneID.mapValues(\.frame)
    }

    var paneContextTextColorTokensForTesting: [PaneID: String] {
        itemViewsByPaneID.mapValues(\.textColorTokenForTesting)
    }

    var paneContextTextFramesForTesting: [PaneID: CGRect] {
        itemViewsByPaneID.mapValues(\.textFrameForTesting)
    }

    var paneContextNaturalTextWidthsForTesting: [PaneID: CGFloat] {
        itemViewsByPaneID.mapValues(\.naturalTextWidthForTesting)
    }

    var paneContextTextTruncationModesForTesting: [PaneID: CATextLayerTruncationMode] {
        itemViewsByPaneID.mapValues(\.truncationModeForTesting)
    }

    var paneContextLeftBorderFramesForTesting: [PaneID: CGRect] {
        itemViewsByPaneID.mapValues(\.leftBorderFrameForTesting)
    }

    var paneContextRightBorderFramesForTesting: [PaneID: CGRect] {
        itemViewsByPaneID.mapValues(\.rightBorderFrameForTesting)
    }

    var paneContextUsesCATextLayerForTesting: [PaneID: Bool] {
        itemViewsByPaneID.mapValues(\.usesCATextLayerForTesting)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func reconcileItemViews() {
        let nextSnapshots = currentSnapshots.filter { $0.borderContext != nil }
        let nextPaneIDs = Set(nextSnapshots.map(\.paneID))
        let obsoletePaneIDs = Set(itemViewsByPaneID.keys).subtracting(nextPaneIDs)

        for paneID in obsoletePaneIDs {
            itemViewsByPaneID[paneID]?.removeFromSuperview()
            itemViewsByPaneID.removeValue(forKey: paneID)
        }

        for snapshot in nextSnapshots where itemViewsByPaneID[snapshot.paneID] == nil {
            let itemView = PaneBorderContextInsetView()
            itemViewsByPaneID[snapshot.paneID] = itemView
            addSubview(itemView)
        }
    }

    private func layoutItemViews(animated: Bool = false) {
        let backingScaleFactor = max(1, window?.backingScaleFactor ?? backingScaleFactorProvider())
        let borderInset = ChromeGeometry.paneBorderInset(backingScaleFactor: backingScaleFactor)
        let borderWidth: CGFloat = 1

        let applyFrames = {
            for snapshot in self.currentSnapshots {
                guard let itemView = self.itemViewsByPaneID[snapshot.paneID] else {
                    continue
                }

                guard let borderContext = snapshot.borderContext else {
                    itemView.isHidden = true
                    continue
                }

                let maxWidth = max(
                    0,
                    snapshot.frame.width - Layout.paneContextLeadingInset - Layout.paneContextTrailingGutter
                )
                guard maxWidth > 24 else {
                    itemView.isHidden = true
                    continue
                }

                let size = itemView.measure(text: borderContext.text, maxWidth: maxWidth)
                let borderLineY = snapshot.frame.maxY - borderInset - (borderWidth / 2)
                let targetFrame = CGRect(
                    x: snapshot.frame.minX + Layout.paneContextLeadingInset,
                    y: borderLineY - (size.height / 2),
                    width: size.width,
                    height: size.height
                )
                if animated {
                    itemView.animator().frame = targetFrame
                } else {
                    itemView.frame = targetFrame
                }
                itemView.isHidden = false
                itemView.render(
                    text: borderContext.text,
                    isFocused: snapshot.isFocused,
                    theme: self.currentTheme,
                    backingScaleFactor: backingScaleFactor
                )
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PaneStripMotionController.defaultAnimationDuration
                context.timingFunction = PaneStripMotionController.defaultAnimationTimingFunction
                context.allowsImplicitAnimation = true
                applyFrames()
            }
        } else {
            applyFrames()
        }

        if onPathClicked != nil {
            window?.invalidateCursorRects(for: self)
        }
    }

    private final class PaneBorderContextInsetView: NSView {
        private let textContentLayer = CALayer()
        private let leftBorderLineLayer = CALayer()
        private let rightBorderLineLayer = CALayer()
        private let textFont = NSFont.systemFont(ofSize: Layout.paneContextFontSize, weight: .semibold)
        private var textColorToken = ""
        private var naturalTextWidth: CGFloat = 0
        private var currentAttributedText = NSAttributedString(string: "")
        private var currentTextRect: CGRect = .zero
        private let currentTruncationMode: CATextLayerTruncationMode = .middle

        private enum TextLayout {
            static let topInset: CGFloat = 5
            static let bottomInset: CGFloat = 4
            static let verticalSafety: CGFloat = 2
            static let borderCoverTopBleed: CGFloat = 1
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
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

    func centerFocusedInteriorPaneOnNextRender() {
        paneStripView.centerFocusedInteriorPaneOnNextRender()
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
