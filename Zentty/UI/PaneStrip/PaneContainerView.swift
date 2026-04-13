import AppKit
import QuartzCore

@MainActor
final class TerminalAnchorView: NSView {
    enum Gravity {
        case top
        case bottom
    }

    var gravity: Gravity = .top {
        didSet {
            guard oldValue != gravity else { return }
            needsLayout = true
        }
    }

    override var isFlipped: Bool {
        gravity == .top
    }
}

private final class PaneInsetBorderLayer: CALayer {
    var strokeColorValue: CGColor? {
        didSet {
            guard oldValue != strokeColorValue else { return }
            setNeedsDisplay()
        }
    }

    var strokeWidth: CGFloat = 1 {
        didSet {
            guard oldValue != strokeWidth else { return }
            setNeedsDisplay()
        }
    }

    var visibleCornerRadius: CGFloat = 0 {
        didSet {
            guard oldValue != visibleCornerRadius else { return }
            setNeedsDisplay()
        }
    }

    var gapWidth: CGFloat = 0 {
        didSet {
            guard oldValue != gapWidth else { return }
            setNeedsDisplay()
        }
    }

    var gapMinX: CGFloat = 0 {
        didSet {
            guard oldValue != gapMinX else { return }
            setNeedsDisplay()
        }
    }

    var gapSuppressed = false {
        didSet {
            guard oldValue != gapSuppressed else { return }
            setNeedsDisplay()
        }
    }

    override init() {
        super.init()
        backgroundColor = NSColor.clear.cgColor
        needsDisplayOnBoundsChange = true
        zPosition = 10
        contentsGravity = .resize
        isOpaque = false
    }

    override init(layer: Any) {
        if let layer = layer as? PaneInsetBorderLayer {
            strokeColorValue = layer.strokeColorValue
            strokeWidth = layer.strokeWidth
            visibleCornerRadius = layer.visibleCornerRadius
            gapWidth = layer.gapWidth
            gapMinX = layer.gapMinX
            gapSuppressed = layer.gapSuppressed
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(in context: CGContext) {
        guard let strokeColorValue, bounds.width > 0, bounds.height > 0, strokeWidth > 0 else {
            return
        }

        let strokeRect = pixelSnappedStrokeRect(scale: max(1, contentsScale))
        guard !strokeRect.isEmpty else { return }

        let cornerRadius = max(0, visibleCornerRadius - (strokeWidth / 2))
        let path = CGPath(
            roundedRect: strokeRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        context.saveGState()
        context.setStrokeColor(strokeColorValue)
        context.setLineWidth(strokeWidth)
        context.setLineJoin(.round)

        if gapWidth > 0, !gapSuppressed {
            let clipPath = CGMutablePath()
            clipPath.addRect(bounds.insetBy(dx: -4, dy: -4))
            clipPath.addRect(gapRect(in: strokeRect))
            context.addPath(clipPath)
            context.clip(using: .evenOdd)
        }

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    var strokeRectForTesting: CGRect {
        pixelSnappedStrokeRect(scale: max(1, contentsScale))
    }

    private func pixelSnappedStrokeRect(scale: CGFloat) -> CGRect {
        let rootBounds = convert(bounds, to: nil)
        let snappedRootBounds = snappedStrokeRect(in: rootBounds, scale: scale, lineWidth: strokeWidth)
        return convert(snappedRootBounds, from: nil)
    }

    private func snappedStrokeRect(in bounds: CGRect, scale: CGFloat, lineWidth: CGFloat) -> CGRect {
        let halfLine = lineWidth / 2
        let minX = ceil((bounds.minX + halfLine) * scale) / scale
        let minY = ceil((bounds.minY + halfLine) * scale) / scale
        let maxX = floor((bounds.maxX - halfLine) * scale) / scale
        let maxY = floor((bounds.maxY - halfLine) * scale) / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func gapRect(in strokeRect: CGRect) -> CGRect {
        CGRect(
            x: gapMinX,
            y: strokeRect.maxY - (strokeWidth / 2) - 1,
            width: gapWidth,
            height: strokeWidth + 2
        )
    }
}

@MainActor
final class PaneContainerView: NSView {
    enum Layout {
        static let borderWidth: CGFloat = 1
        static let cornerRadius: CGFloat = ChromeGeometry.paneRadius
        static let overlayInset: CGFloat = 18
        static let overlayButtonTopSpacing: CGFloat = 14
        static let overlayButtonHeight: CGFloat = 30
    }

    private enum StatusState: Equatable {
        case hidden
        case startupFailure(message: String)
    }

    private let runtime: PaneRuntime
    private let contentClipView = NSView()
    private let terminalAnchorView = TerminalAnchorView()
    private let terminalHostView: TerminalPaneHostView
    private let borderContextView = PaneBorderContextInsetView()
    private let backingScaleFactorProvider: () -> CGFloat
    private let insetBorderLayer = PaneInsetBorderLayer()
    private let statusOverlayView = NSView()
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var statusOverlayConstraints: [NSLayoutConstraint] = []
    private(set) var paneID: PaneID
    private var titleTextStorage: String
    private var statusState: StatusState = .hidden
    private var runtimeObserverID: UUID?
    private(set) var isTerminalAnimationFrozen = false
    private var isInsetBorderAnimationManaged = false
    private var currentTheme: ZenttyTheme
    private var currentEmphasis: CGFloat
    private var currentBorderGapWidth: CGFloat = 0
    private var currentBorderContext: PaneBorderContextDisplayModel?
    private var currentIsFocused: Bool
    private var lastRenderedSearchState = PaneSearchState()
    private var suppressSelectionOnNextProgrammaticFocus = false
    var onSelected: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onBorderContextClicked: ((PaneID) -> Void)? {
        didSet {
            if onBorderContextClicked == nil {
                borderContextView.onClick = nil
            } else {
                borderContextView.onClick = { [weak self] in
                    guard let self else { return }
                    self.onBorderContextClicked?(self.paneID)
                }
            }
        }
    }
    var onSearchHUDVisibilityDidChange: ((Bool) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)? {
        didSet {
            terminalHostView.onScrollWheel = onScrollWheel
        }
    }
    var onMetadataDidChange: ((TerminalMetadata) -> Void)? {
        didSet {}
    }

    init(
        pane: PaneState,
        width: CGFloat,
        height: CGFloat,
        emphasis: CGFloat,
        isFocused: Bool,
        runtime: PaneRuntime,
        theme: ZenttyTheme,
        backingScaleFactorProvider: @escaping () -> CGFloat = {
            NSScreen.main?.backingScaleFactor ?? 1
        }
    ) {
        self.paneID = pane.id
        self.titleTextStorage = pane.title
        self.runtime = runtime
        self.terminalHostView = runtime.hostView
        self.backingScaleFactorProvider = backingScaleFactorProvider
        self.currentTheme = theme
        self.currentEmphasis = emphasis
        self.currentIsFocused = isFocused
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = true
        setup()
        render(pane: pane, emphasis: emphasis, isFocused: isFocused)
    }

    convenience init(
        pane: PaneState,
        width: CGFloat,
        height: CGFloat,
        emphasis: CGFloat,
        isFocused: Bool,
        runtime: PaneRuntime,
        theme: ZenttyTheme
    ) {
        self.init(
            pane: pane,
            width: width,
            height: height,
            emphasis: emphasis,
            isFocused: isFocused,
            runtime: runtime,
            theme: theme,
            backingScaleFactorProvider: { NSScreen.main?.backingScaleFactor ?? 1 }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = Layout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0
        layer?.shadowOffset = .zero
        layer?.masksToBounds = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentClipView.translatesAutoresizingMaskIntoConstraints = true
        contentClipView.autoresizingMask = [.width, .height]
        contentClipView.wantsLayer = true
        contentClipView.layer?.cornerRadius = Layout.cornerRadius
        contentClipView.layer?.cornerCurve = .continuous
        contentClipView.layer?.masksToBounds = true
        contentClipView.frame = bounds
        terminalAnchorView.translatesAutoresizingMaskIntoConstraints = true
        terminalAnchorView.autoresizingMask = [.width, .height]
        terminalAnchorView.frame = contentClipView.bounds
        terminalHostView.removeFromSuperview()
        terminalHostView.translatesAutoresizingMaskIntoConstraints = true
        terminalHostView.autoresizingMask = [.width, .height]
        terminalHostView.wantsLayer = true
        terminalHostView.layer?.cornerRadius = Layout.cornerRadius
        terminalHostView.layer?.cornerCurve = .continuous
        terminalHostView.layer?.masksToBounds = true
        terminalHostView.frame = terminalAnchorView.bounds
        statusOverlayView.translatesAutoresizingMaskIntoConstraints = true
        statusOverlayView.autoresizingMask = [.width, .height]
        statusOverlayView.frame = bounds
        addSubview(contentClipView)
        borderContextView.translatesAutoresizingMaskIntoConstraints = true
        borderContextView.autoresizingMask = []
        borderContextView.isHidden = true
        addSubview(borderContextView)
        contentClipView.addSubview(terminalAnchorView)
        terminalAnchorView.addSubview(terminalHostView)
        contentClipView.addSubview(statusOverlayView)

        terminalHostView.onFocusDidChange = { [weak self] isFocused in
            guard let self else { return }
            self.runtime.handleTerminalFocusChange(isFocused)
            if isFocused, self.suppressSelectionOnNextProgrammaticFocus {
                self.suppressSelectionOnNextProgrammaticFocus = false
                return
            }
            if !isFocused {
                self.suppressSelectionOnNextProgrammaticFocus = false
                return
            }
            self.onSelected?()
        }
        terminalHostView.onScrollWheel = onScrollWheel
        terminalHostView.onSearchQueryChange = { [weak self] query in
            self?.runtime.updateSearchNeedle(query)
        }
        terminalHostView.onSearchNext = { [weak self] in
            self?.runtime.findNext()
        }
        terminalHostView.onSearchPrevious = { [weak self] in
            self?.runtime.findPrevious()
        }
        terminalHostView.onSearchHide = { [weak self] in
            self?.runtime.hideSearchHUD()
            self?.focusTerminal()
        }
        terminalHostView.onSearchClose = { [weak self] in
            self?.runtime.endSearch()
            self?.focusTerminal()
        }
        terminalHostView.onSearchCornerChange = { [weak self] corner in
            self?.runtime.setSearchHUDCorner(corner)
        }
        terminalHostView.onSearchHUDFrameDidChange = { [weak self] in
            self?.updateSearchHUDMouseSuppression()
        }
        terminalHostView.contextMenuBuilder = { [weak self] _, systemMenu in
            self?.makeContextMenu(merging: systemMenu)
        }
        setupInsetBorderLayer()
        setupStatusOverlay()
        runtimeObserverID = runtime.addObserver { [weak self] snapshot in
            self?.handleRuntimeSnapshot(snapshot)
        }
        applyThemeColors(currentTheme)
        applyVisualState(animated: false)

    }

    static func presentationAlpha(forEmphasis emphasis: CGFloat) -> CGFloat {
        presentationAlpha(
            forEmphasis: emphasis,
            inactiveOpacity: AppConfig.Panes.default.inactiveOpacity,
            allowInactiveDimming: true
        )
    }

    static func presentationAlpha(
        forEmphasis emphasis: CGFloat,
        inactiveOpacity: CGFloat
    ) -> CGFloat {
        presentationAlpha(
            forEmphasis: emphasis,
            inactiveOpacity: inactiveOpacity,
            allowInactiveDimming: true
        )
    }

    static func presentationAlpha(
        forEmphasis emphasis: CGFloat,
        inactiveOpacity: CGFloat,
        allowInactiveDimming: Bool
    ) -> CGFloat {
        guard allowInactiveDimming else {
            return 1
        }

        return emphasis >= 0.999 ? 1 : inactiveOpacity
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel? = nil,
        animated: Bool
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            borderContext: borderContext,
            animated: animated,
            useNeutralBackground: false
        )
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel? = nil,
        animated: Bool,
        useNeutralBackground: Bool = false
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            borderContext: borderContext,
            animatedVisualState: animated,
            useNeutralBackground: useNeutralBackground
        )
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel? = nil
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            borderContext: borderContext,
            animatedVisualState: false,
            useNeutralBackground: false
        )
    }

    private func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel?,
        animatedVisualState: Bool,
        useNeutralBackground: Bool
    ) {
        paneID = pane.id
        titleTextStorage = pane.title
        currentEmphasis = emphasis
        currentIsFocused = isFocused
        currentBorderContext = borderContext
        runtime.update(pane: pane)
        updateInsetBorderLayer()
        updateBorderContextView()
        applyVisualState(animated: animatedVisualState, useNeutralBackground: useNeutralBackground)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        applyThemeColors(theme, animated: animated)
        applyVisualState(animated: animated)
    }

    override func mouseDown(with event: NSEvent) {
        onSelected?()
        focusTerminal()
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true {
            return
        }

        super.scrollWheel(with: event)
    }

    func prepareForRemoval() {
        if let runtimeObserverID {
            runtime.removeObserver(runtimeObserverID)
            self.runtimeObserverID = nil
        }
    }

    func focusTerminal() {
        let wasFocused = runtime.hostView.isTerminalFocused
        suppressSelectionOnNextProgrammaticFocus = false
        if runtime.hostView.focusTerminal(), !wasFocused {
            suppressSelectionOnNextProgrammaticFocus = true
        }
    }

    @discardableResult
    func focusTerminalIfReady() -> Bool {
        let wasFocused = runtime.hostView.isTerminalFocused
        suppressSelectionOnNextProgrammaticFocus = false
        let didFocus = runtime.hostView.focusTerminalIfReady()
        if didFocus, !wasFocused {
            suppressSelectionOnNextProgrammaticFocus = true
        }
        return didFocus
    }

    var isTerminalFocused: Bool {
        runtime.hostView.isTerminalFocused
    }

    var isSearchHUDVisible: Bool {
        lastRenderedSearchState.isHUDVisible
    }

    func activateSessionIfNeeded() {
        ZenttyPerformanceSignposts.interval("PaneContainerActivateSession") {
            layoutSubtreeIfNeeded()
            runtime.ensureStarted()
        }
    }

    func setTerminalViewportSyncSuspended(_ suspended: Bool) {
        needsLayout = true
        layoutSubtreeIfNeeded()
        terminalHostView.setViewportSyncSuspended(suspended)
    }

    func forceTerminalViewportSync() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        terminalHostView.forceViewportSync()
    }

    static let dragZoneHeight: CGFloat = 15

    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func beginVerticalFreeze(gravity: TerminalAnchorView.Gravity) {
        guard !isTerminalAnimationFrozen else {
            return
        }

        isTerminalAnimationFrozen = true
        terminalAnchorView.gravity = gravity
        terminalHostView.autoresizingMask = [.width]
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func endVerticalFreeze() {
        guard isTerminalAnimationFrozen else {
            return
        }

        isTerminalAnimationFrozen = false
        terminalHostView.autoresizingMask = [.width, .height]
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func animateInsetBorder(to targetSize: CGSize) {
        _ = targetSize
        if insetBorderLayer.frame == .zero, !bounds.isEmpty {
            updateInsetBorderLayer()
        }
        isInsetBorderAnimationManaged = true
        let backingScaleFactor = resolvedBackingScaleFactor
        insetBorderLayer.contentsScale = backingScaleFactor
        insetBorderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    func syncInsetBorderNow() {
        isInsetBorderAnimationManaged = false
        insetBorderLayer.autoresizingMask = []
        updateInsetBorderLayer()
    }

    override func layout() {
        super.layout()
        contentClipView.frame = bounds
        terminalAnchorView.frame = contentClipView.bounds
        if !isTerminalAnimationFrozen {
            let anchorBounds = terminalAnchorView.bounds
            terminalHostView.frame = CGRect(
                x: 0, y: 0,
                width: anchorBounds.width,
                height: anchorBounds.height
            )
        }
        if !isInsetBorderAnimationManaged {
            updateInsetBorderLayer()
        }
        statusOverlayView.frame = bounds
        updateBorderContextView()
        updateSearchHUDMouseSuppression()
    }

    var hasScrollback: Bool {
        runtime.hasScrollback
    }

    var titleText: String {
        titleTextStorage
    }

    var statusTitle: String {
        statusTitleLabel.stringValue
    }

    var statusMessage: String {
        statusMessageLabel.stringValue
    }

    var isStatusOverlayHidden: Bool {
        statusOverlayView.isHidden
    }

    var isRetryButtonHidden: Bool {
        retryButton.isHidden
    }

    var isCloseButtonHidden: Bool {
        closeButton.isHidden
    }

    var isSearchHUDHiddenForTesting: Bool {
        terminalHostView.isSearchHUDHiddenForTesting
    }

    var searchHUDFrameForTesting: CGRect {
        convert(terminalHostView.searchHUDFrameForTesting, from: terminalHostView)
    }

    var searchHUDCountTextForTesting: String {
        terminalHostView.searchHUDCountTextForTesting
    }

    var searchHUDNextButtonForTesting: PaneSearchHUDButton {
        terminalHostView.searchHUDNextButtonForTesting
    }

    var searchHUDPreviousButtonForTesting: PaneSearchHUDButton {
        terminalHostView.searchHUDPreviousButtonForTesting
    }

    var searchHUDCloseButtonForTesting: PaneSearchHUDButton {
        terminalHostView.searchHUDCloseButtonForTesting
    }

    var searchHUDQueryFieldForTesting: NSTextField {
        terminalHostView.searchHUDQueryFieldForTesting
    }

    var isSearchHUDSnapAnimationInFlightForTesting: Bool {
        terminalHostView.isSearchHUDSnapAnimationInFlightForTesting
    }

    var retryButtonForTesting: NSButton {
        retryButton
    }

    var closeButtonForTesting: NSButton {
        closeButton
    }

    var usesInsetBorderLayer: Bool {
        insetBorderLayer.superlayer === layer
    }

    var insetBorderLineWidth: CGFloat {
        insetBorderLayer.strokeWidth
    }

    var insetBorderFrame: CGRect {
        insetBorderLayer.frame
    }

    var insetBorderInset: CGFloat {
        insetBorderLayer.frame.minX
    }

    var insetBorderCornerRadius: CGFloat {
        insetBorderLayer.visibleCornerRadius
    }

    var insetBorderCornerCurve: CALayerCornerCurve {
        insetBorderLayer.cornerCurve
    }

    var backgroundColorTokenForTesting: String? {
        guard let cgColor = layer?.backgroundColor, let color = NSColor(cgColor: cgColor) else {
            return nil
        }

        return color.themeToken
    }

    var insetBorderColorToken: String? {
        guard let cgColor = insetBorderLayer.strokeColorValue, let color = NSColor(cgColor: cgColor)
        else {
            return nil
        }

        return color.themeToken
    }

    var insetBorderStrokeRectForTesting: CGRect {
        insetBorderLayer.strokeRectForTesting
    }

    var isInsetBorderGapSuppressedForTesting: Bool {
        insetBorderLayer.gapSuppressed
    }

    var shadowOpacityForTesting: Float {
        layer?.shadowOpacity ?? 0
    }

    var shadowRadiusForTesting: CGFloat {
        layer?.shadowRadius ?? 0
    }

    var hasPaneContextChrome: Bool {
        !borderContextView.isHidden
    }

    var statusOverlayFrame: CGRect {
        statusOverlayView.frame
    }

    var contentClipFrameForTesting: CGRect {
        contentClipView.frame
    }

    var contentClipBackgroundColorTokenForTesting: String? {
        guard let cgColor = contentClipView.layer?.backgroundColor,
            let color = NSColor(cgColor: cgColor)
        else {
            return nil
        }

        return color.themeToken
    }

    var terminalAnchorFrameForTesting: CGRect {
        terminalAnchorView.frame
    }

    var clipsContentToBounds: Bool {
        contentClipView.layer?.masksToBounds == true
    }

    var isTerminalAnimationFrozenForTesting: Bool {
        isTerminalAnimationFrozen
    }

    var borderLabelGapWidthForTesting: CGFloat {
        currentBorderGapWidth
    }

    var paneBorderContextTextForTesting: String? {
        guard !borderContextView.isHidden else { return nil }
        return borderContextView.textForTesting
    }

    var paneBorderContextFrameForTesting: CGRect? {
        guard !borderContextView.isHidden else { return nil }
        return borderContextView.frame
    }

    var paneBorderContextTextFrameForTesting: CGRect? {
        guard !borderContextView.isHidden else { return nil }
        return borderContextView.textFrameForTesting
    }

    var paneBorderContextNaturalTextWidthForTesting: CGFloat? {
        guard !borderContextView.isHidden else { return nil }
        return borderContextView.naturalTextWidthForTesting
    }

    var paneBorderContextTextTruncationModeForTesting: CATextLayerTruncationMode? {
        guard !borderContextView.isHidden else { return nil }
        return borderContextView.truncationModeForTesting
    }

    var interactiveBorderContextFrameInSelf: CGRect? {
        guard !borderContextView.isHidden, borderContextView.onClick != nil else { return nil }
        return borderContextView.frame
    }

    func hitTestBorderContext(
        _ point: CGPoint,
        from coordinateSpaceView: NSView
    ) -> PaneBorderContextInsetView? {
        guard let frame = interactiveBorderContextFrameInSelf else {
            return nil
        }

        let pointInSelf = convert(point, from: coordinateSpaceView)
        guard frame.contains(pointInSelf), let superview = borderContextView.superview else {
            return nil
        }

        let pointInBorderSuperview = superview.convert(point, from: coordinateSpaceView)
        return borderContextView.hitTest(pointInBorderSuperview) as? PaneBorderContextInsetView
    }

    func contextMenuForTesting(merging systemMenu: NSMenu? = nil) -> NSMenu? {
        makeContextMenu(merging: systemMenu)
    }

    func setBorderLabelGap(width: CGFloat) {
        guard currentBorderGapWidth != width else { return }
        currentBorderGapWidth = width
        updateBorderGapMask()
    }

    private func setupInsetBorderLayer() {
        insetBorderLayer.strokeWidth = Layout.borderWidth
        insetBorderLayer.cornerCurve = .continuous
        layer?.addSublayer(insetBorderLayer)
        updateInsetBorderLayer()
    }

    private var savedBorderColor: CGColor?

    func applyZoomBorderCompensation(zoomScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insetBorderLayer.strokeWidth = Layout.borderWidth / max(0.1, zoomScale)

        // Boost border opacity so it's clearly visible at small scale
        savedBorderColor = insetBorderLayer.strokeColorValue
        if let current = insetBorderLayer.strokeColorValue,
            let nsColor = NSColor(cgColor: current)
        {
            insetBorderLayer.strokeColorValue = nsColor.withAlphaComponent(0.4).cgColor
        }
        CATransaction.commit()
    }

    func resetZoomBorderCompensation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insetBorderLayer.strokeWidth = Layout.borderWidth
        if let saved = savedBorderColor {
            insetBorderLayer.strokeColorValue = saved
            savedBorderColor = nil
        }
        CATransaction.commit()
    }

    private func updateInsetBorderLayer() {
        guard !bounds.isEmpty else {
            insetBorderLayer.frame = .zero
            return
        }

        let backingScaleFactor = resolvedBackingScaleFactor
        let inset = ChromeGeometry.paneBorderInset(backingScaleFactor: backingScaleFactor)
        let insetRect = bounds.insetBy(dx: inset, dy: inset)
        let cornerRadius = max(0, Layout.cornerRadius - inset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insetBorderLayer.contentsScale = backingScaleFactor
        insetBorderLayer.frame = insetRect
        insetBorderLayer.visibleCornerRadius = cornerRadius
        insetBorderLayer.gapMinX =
            PaneBorderContextInsetView.Layout.paneContextLeadingInset - inset
        CATransaction.commit()

        updateBorderGapMask()
    }

    private func updateBorderGapMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insetBorderLayer.gapWidth = currentBorderGapWidth
        CATransaction.commit()
    }

    private func updateBorderContextView() {
        guard !bounds.isEmpty else {
            borderContextView.isHidden = true
            setBorderLabelGap(width: 0)
            return
        }

        guard let borderContext = currentBorderContext, !borderContext.text.isEmpty else {
            borderContextView.isHidden = true
            setBorderLabelGap(width: 0)
            return
        }

        let maxWidth = max(
            0,
            bounds.width
                - PaneBorderContextInsetView.Layout.paneContextLeadingInset
                - PaneBorderContextInsetView.Layout.paneContextTrailingGutter
        )
        guard maxWidth > 24 else {
            borderContextView.isHidden = true
            setBorderLabelGap(width: 0)
            return
        }

        let size = borderContextView.measure(text: borderContext.text, maxWidth: maxWidth)
        let targetFrame = paneBorderContextFrame(for: size)
        if borderContextView.frame == .zero {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderContextView.frame = targetFrame
            CATransaction.commit()
        } else {
            borderContextView.frame = targetFrame
        }
        borderContextView.isHidden = false
        borderContextView.render(
            text: borderContext.text,
            isFocused: currentIsFocused,
            theme: currentTheme,
            backingScaleFactor: resolvedBackingScaleFactor
        )
        setBorderLabelGap(width: size.width)
        if borderContextView.onClick != nil {
            window?.invalidateCursorRects(for: borderContextView)
        }
    }

    private func paneBorderContextFrame(for size: CGSize) -> CGRect {
        let borderLineY = insetBorderLayer.frame.maxY - (insetBorderLayer.strokeWidth / 2)
        let borderInset = ChromeGeometry.paneBorderInset(backingScaleFactor: resolvedBackingScaleFactor)
        let minX = insetBorderLayer.frame.minX
            + (PaneBorderContextInsetView.Layout.paneContextLeadingInset - borderInset)
        return CGRect(
            x: minX,
            y: borderLineY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    private func makeContextMenu(merging systemMenu: NSMenu?) -> NSMenu? {
        focusTerminal()

        let customMenu = NSMenu(title: "")
        customMenu.addItem(makeContextMenuItem(title: "Copy", action: #selector(NSText.copy(_:))))
        let cleanCopyItem = makeContextMenuItem(title: "Clean Copy", action: #selector(MainWindowController.cleanCopy(_:)))
        cleanCopyItem.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Clean Copy")
        customMenu.addItem(cleanCopyItem)
        customMenu.addItem(makeContextMenuItem(title: "Paste", action: #selector(NSText.paste(_:))))
        customMenu.addItem(.separator())
        customMenu.addItem(makeContextMenuItem(title: "Add Pane Right", action: #selector(MainWindowController.addPaneRight(_:))))
        customMenu.addItem(makeContextMenuItem(title: "Add Pane Left", action: #selector(MainWindowController.addPaneLeft(_:))))
        customMenu.addItem(makeContextMenuItem(title: "Add Pane Down", action: #selector(MainWindowController.addPaneDown(_:))))
        customMenu.addItem(makeContextMenuItem(title: "Add Pane Up", action: #selector(MainWindowController.addPaneUp(_:))))

        let mergedMenu = NSMenu(title: "")
        customMenu.items.forEach { mergedMenu.addItem($0.copy() as! NSMenuItem) }

        let systemItems = (systemMenu?.items ?? []).filter { item in
            item.isSeparatorItem || Self.shouldIncludeSystemContextMenuItem(item)
        }
        if !systemItems.isEmpty {
            mergedMenu.addItem(.separator())
            systemItems.forEach { mergedMenu.addItem($0.copy() as! NSMenuItem) }
        }

        return mergedMenu.items.isEmpty ? nil : mergedMenu
    }

    private func makeContextMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = nil
        return item
    }

    private static func shouldIncludeSystemContextMenuItem(_ item: NSMenuItem) -> Bool {
        if item.submenu != nil {
            return true
        }

        switch item.action {
        case #selector(NSText.copy(_:)),
             #selector(NSText.paste(_:)),
             #selector(MainWindowController.addPaneRight(_:)),
             #selector(MainWindowController.addPaneLeft(_:)),
             #selector(MainWindowController.addPaneDown(_:)),
             #selector(MainWindowController.addPaneUp(_:)):
            return false
        default:
            return true
        }
    }

    private var resolvedBackingScaleFactor: CGFloat {
        if let windowScale = window?.backingScaleFactor {
            return max(1, windowScale)
        }

        return max(1, backingScaleFactorProvider())
    }
    private func updateTerminalHostFrame() {
        terminalHostView.frame = terminalAnchorView.bounds
    }

    private func setupStatusOverlay() {
        statusOverlayView.wantsLayer = true
        statusOverlayView.layer?.backgroundColor = currentTheme.failureOverlayBackground.cgColor
        statusOverlayView.layer?.cornerRadius = Layout.cornerRadius
        statusOverlayView.layer?.cornerCurve = .continuous
        statusOverlayView.layer?.masksToBounds = true
        statusOverlayView.isHidden = true

        statusTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusTitleLabel.textColor = currentTheme.failurePrimaryText
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusMessageLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusMessageLabel.textColor = currentTheme.failureSecondaryText
        statusMessageLabel.maximumNumberOfLines = 0
        statusMessageLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(handleRetry)
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        statusOverlayView.addSubview(statusTitleLabel)
        statusOverlayView.addSubview(statusMessageLabel)
        statusOverlayView.addSubview(retryButton)
        statusOverlayView.addSubview(closeButton)

        statusOverlayConstraints = [
            statusTitleLabel.topAnchor.constraint(
                equalTo: statusOverlayView.topAnchor, constant: Layout.overlayInset),
            statusTitleLabel.leadingAnchor.constraint(
                equalTo: statusOverlayView.leadingAnchor, constant: Layout.overlayInset),
            statusTitleLabel.trailingAnchor.constraint(
                equalTo: statusOverlayView.trailingAnchor, constant: -Layout.overlayInset),

            statusMessageLabel.topAnchor.constraint(
                equalTo: statusTitleLabel.bottomAnchor, constant: 8),
            statusMessageLabel.leadingAnchor.constraint(equalTo: statusTitleLabel.leadingAnchor),
            statusMessageLabel.trailingAnchor.constraint(equalTo: statusTitleLabel.trailingAnchor),

            retryButton.topAnchor.constraint(
                equalTo: statusMessageLabel.bottomAnchor,
                constant: Layout.overlayButtonTopSpacing
            ),
            retryButton.leadingAnchor.constraint(equalTo: statusMessageLabel.leadingAnchor),
            retryButton.heightAnchor.constraint(equalToConstant: Layout.overlayButtonHeight),
            retryButton.bottomAnchor.constraint(
                lessThanOrEqualTo: statusOverlayView.bottomAnchor, constant: -Layout.overlayInset),

            closeButton.centerYAnchor.constraint(equalTo: retryButton.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: 10),
            closeButton.heightAnchor.constraint(equalToConstant: Layout.overlayButtonHeight),
        ]
    }

    private func handleMetadataDidChange(_ metadata: TerminalMetadata) {
        onMetadataDidChange?(metadata)
        updateStatus(.hidden)
    }

    private func handleRuntimeSnapshot(_ snapshot: PaneRuntimeSnapshot) {
        updateSearchHUD(snapshot.search)

        if let startupFailureMessage = snapshot.startupFailureMessage {
            updateStatus(.startupFailure(message: startupFailureMessage))
            return
        }

        guard snapshot.hasReceivedMetadata else {
            updateStatus(.hidden)
            return
        }

        handleMetadataDidChange(snapshot.metadata)
    }

    private func updateSearchHUD(_ search: PaneSearchState) {
        let didVisibilityChange = lastRenderedSearchState.isHUDVisible != search.isHUDVisible
        let didBecomeVisible = !lastRenderedSearchState.isHUDVisible && search.isHUDVisible
        lastRenderedSearchState = search
        terminalHostView.applySearchHUD(search)
        updateSearchHUDMouseSuppression()
        if didVisibilityChange {
            onSearchHUDVisibilityDidChange?(search.isHUDVisible)
        }

        guard didBecomeVisible else {
            return
        }

        runtime.prepareSearchFieldFocusTransfer()
        DispatchQueue.main.async { [weak self] in
            self?.terminalHostView.focusSearchField(selectAll: true)
        }
    }

    private func updateSearchHUDMouseSuppression() {
        var suppressionRects = [dragZoneSuppressionRect]
        if lastRenderedSearchState.isHUDVisible {
            suppressionRects.append(terminalHostView.searchHUDFrameInHostCoordinates)
        }

        terminalHostView.setMouseInteractionSuppressionRects(suppressionRects)
    }

    private var dragZoneSuppressionRect: CGRect {
        CGRect(
            x: 0,
            y: bounds.height - Self.dragZoneHeight,
            width: bounds.width,
            height: Self.dragZoneHeight
        )
    }

    private func updateStatus(_ state: StatusState) {
        guard statusState != state else {
            return
        }

        statusState = state

        switch state {
        case .hidden:
            NSLayoutConstraint.deactivate(statusOverlayConstraints)
            statusOverlayView.isHidden = true
            statusTitleLabel.stringValue = ""
            statusMessageLabel.stringValue = ""
            retryButton.isHidden = true
            closeButton.isHidden = true
        case .startupFailure(let message):
            NSLayoutConstraint.activate(statusOverlayConstraints)
            statusOverlayView.isHidden = false
            statusTitleLabel.stringValue = "Pane failed to start"
            statusMessageLabel.stringValue = message
            retryButton.isHidden = false
            closeButton.isHidden = false
        }
    }

    private func applyVisualState(animated: Bool, useNeutralBackground: Bool = false) {
        let theme = currentTheme
        let emphasis = currentEmphasis
        let isFocused = currentIsFocused
        let paneFillColor =
            useNeutralBackground
            ? theme.startupSurface
            : (isFocused ? theme.paneFillFocused : theme.paneFillUnfocused)
        let shadowOpacity = Float(max(0, emphasis - 0.88) * 2.2)
        let shadowRadius = 6 + max(0, emphasis - 0.92) * 24
        performThemeAnimation(animated: animated) {
            let borderColor =
                (isFocused
                ? theme.paneBorderFocused
                : theme.paneBorderUnfocused).cgColor
            self.insetBorderLayer.strokeColorValue = borderColor
            self.layer?.shadowColor = theme.paneShadow.cgColor
            self.layer?.shadowOpacity = shadowOpacity
            self.layer?.shadowRadius = shadowRadius
        }
        performThemeAnimation(animated: animated && !useNeutralBackground) {
            self.layer?.backgroundColor = paneFillColor.cgColor
        }
    }

    private func applyThemeColors(_ theme: ZenttyTheme, animated: Bool = false) {
        statusTitleLabel.textColor = theme.failurePrimaryText
        statusMessageLabel.textColor = theme.failureSecondaryText
        performThemeAnimation(animated: animated) {
            self.contentClipView.layer?.backgroundColor = theme.startupSurface.cgColor
            self.terminalHostView.layer?.backgroundColor = theme.startupSurface.cgColor
            self.statusOverlayView.layer?.backgroundColor = theme.failureOverlayBackground.cgColor
        }
    }

    @objc
    private func handleRetry() {
        runtime.retryStartSession()
    }

    @objc
    private func handleClose() {
        onCloseRequested?()
    }
    
    func configureSearchHUDSnapAnimationForTesting(
        _ runner: @escaping (CGPoint, @escaping () -> Void) -> Void
    ) {
        terminalHostView.configureSearchHUDSnapAnimationForTesting(runner)
    }

    func setSearchHUDOriginForTesting(_ origin: CGPoint) {
        terminalHostView.setSearchHUDOriginForTesting(origin)
    }

    func snapSearchHUDToNearestCornerForTesting() {
        terminalHostView.snapSearchHUDToNearestCornerForTesting()
    }

    func searchHUDFrame(for corner: PaneSearchHUDCorner) -> CGRect {
        convert(terminalHostView.searchHUDFrame(for: corner), from: terminalHostView)
    }
}
