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

/// Paints a soft colored halo on the interior of the inset border stroke.
///
/// Rendering recipe: concentric rounded strokes centred on the inset border
/// path, widest+faintest first, each subsequent stroke narrower and more
/// saturated. The overlap approximates a gaussian falloff without relying on
/// CAShapeLayer's path (which doesn't follow bounds animations). By deriving
/// the stroke rect from `bounds` inside `draw(in:)` and enabling
/// `needsDisplayOnBoundsChange`, the halo re-renders every animation frame
/// and tracks pane resizes cleanly.
private final class PaneFocusGlowLayer: CALayer {
    var glowColorValue: CGColor? {
        didSet {
            guard oldValue != glowColorValue else { return }
            setNeedsDisplay()
        }
    }

    var glowBlurRadius: CGFloat = 2 {
        didSet {
            guard oldValue != glowBlurRadius else { return }
            setNeedsDisplay()
        }
    }

    var strokeInset: CGFloat = 0 {
        didSet {
            guard oldValue != strokeInset else { return }
            setNeedsDisplay()
        }
    }

    var strokeCornerRadius: CGFloat = 0 {
        didSet {
            guard oldValue != strokeCornerRadius else { return }
            setNeedsDisplay()
        }
    }

    /// Rectangle (in layer-local coords) to punch out of the halo — matches
    /// the border-context label's frame so the glow doesn't bleed through its
    /// transparent background. `.zero` disables.
    var labelGapRect: CGRect = .zero {
        didSet {
            guard oldValue != labelGapRect else { return }
            setNeedsDisplay()
        }
    }

    override init() {
        super.init()
        backgroundColor = NSColor.clear.cgColor
        needsDisplayOnBoundsChange = true
        zPosition = 9
        contentsGravity = .resize
        isOpaque = false
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        if let layer = layer as? PaneFocusGlowLayer {
            glowColorValue = layer.glowColorValue
            glowBlurRadius = layer.glowBlurRadius
            strokeInset = layer.strokeInset
            strokeCornerRadius = layer.strokeCornerRadius
            labelGapRect = layer.labelGapRect
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(in context: CGContext) {
        guard let cgColor = glowColorValue, glowBlurRadius > 0 else { return }
        guard let baseColor = NSColor(cgColor: cgColor), baseColor.alphaComponent > 0 else {
            return
        }

        let innerRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        guard innerRect.width > 0, innerRect.height > 0 else { return }

        let radius = max(0, strokeCornerRadius)
        let path = CGPath(
            roundedRect: innerRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // `baseColor.alphaComponent` is the focusedGlow intensity knob. Each
        // band's alpha is a fraction of that. Widths scale off the "blur
        // radius equivalent" — wider bands extend inward (and outward, but the
        // outward portion is invisible behind the inset border stroke).
        let intensity = baseColor.alphaComponent
        let bands: [(width: CGFloat, alphaFraction: CGFloat)] = [
            (width: glowBlurRadius * 3.0, alphaFraction: 0.10),
            (width: glowBlurRadius * 2.0, alphaFraction: 0.22),
            (width: glowBlurRadius * 1.2, alphaFraction: 0.40),
            (width: glowBlurRadius * 0.6, alphaFraction: 0.65),
        ]

        context.saveGState()
        if labelGapRect.width > 0, labelGapRect.height > 0 {
            let cutout = CGMutablePath()
            // Pad the clip region to comfortably cover every concentric stroke.
            cutout.addRect(bounds.insetBy(dx: -(glowBlurRadius * 4), dy: -(glowBlurRadius * 4)))
            cutout.addRect(labelGapRect)
            context.addPath(cutout)
            context.clip(using: .evenOdd)
        }
        for band in bands where band.width > 0 {
            let alpha = min(1, intensity * band.alphaFraction)
            guard alpha > 0 else { continue }
            context.setStrokeColor(baseColor.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(band.width)
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }
}

private extension PaneCommand {
    var contextMenuSelector: Selector {
        switch self {
        case .splitRightVisibly:
            #selector(MainWindowController.forceSplitRight(_:))
        case .addPaneRightWithoutResizing:
            #selector(MainWindowController.forceAddPaneRight(_:))
        default:
            #selector(MainWindowController.addPaneRight(_:))
        }
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
    private let focusGlowLayer = PaneFocusGlowLayer()
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
    private var viewportDiagnosticsWorklaneID: WorklaneID?
    private var viewportDiagnosticsLaneRole: TerminalViewportLaneRole = .unknown
    private var viewportDiagnosticsIsZoomedOut = false
    private var isInsetBorderAnimationManaged = false
    private var currentTheme: ZenttyTheme
    private var currentEmphasis: CGFloat
    private var currentBorderGapWidth: CGFloat = 0
    private var currentBorderContext: PaneBorderContextDisplayModel?
    private var currentIsFocused: Bool
    private var isZoomedOutBackdropVisible = false
    private var currentWorklaneColor: WorklaneColor?
    private var lastRenderedSearchState = PaneSearchState()
    var rightPaneCommandPresentationProvider: (() -> PaneRightCommandPresentation)?
    var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?
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
        initialViewportSyncSuspended: Bool = false,
        viewportDiagnosticsWorklaneID: WorklaneID? = nil,
        viewportDiagnosticsLaneRole: TerminalViewportLaneRole = .unknown,
        viewportDiagnosticsIsZoomedOut: Bool = false,
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
        self.viewportDiagnosticsWorklaneID = viewportDiagnosticsWorklaneID
        self.viewportDiagnosticsLaneRole = viewportDiagnosticsLaneRole
        self.viewportDiagnosticsIsZoomedOut = viewportDiagnosticsIsZoomedOut
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = true
        updateTerminalViewportDiagnosticsContext()
        if initialViewportSyncSuspended {
            TerminalViewportDiagnostics.shared.record(.initialSuspension, context: viewportDiagnosticsContext())
            terminalHostView.setViewportSyncSuspended(true)
        }
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
            initialViewportSyncSuspended: false,
            viewportDiagnosticsWorklaneID: nil,
            viewportDiagnosticsLaneRole: .unknown,
            viewportDiagnosticsIsZoomedOut: false,
            backingScaleFactorProvider: { NSScreen.main?.backingScaleFactor ?? 1 }
        )
    }

    convenience init(
        pane: PaneState,
        width: CGFloat,
        height: CGFloat,
        emphasis: CGFloat,
        isFocused: Bool,
        runtime: PaneRuntime,
        theme: ZenttyTheme,
        backingScaleFactorProvider: @escaping () -> CGFloat
    ) {
        self.init(
            pane: pane,
            width: width,
            height: height,
            emphasis: emphasis,
            isFocused: isFocused,
            runtime: runtime,
            theme: theme,
            initialViewportSyncSuspended: false,
            viewportDiagnosticsWorklaneID: nil,
            viewportDiagnosticsLaneRole: .unknown,
            viewportDiagnosticsIsZoomedOut: false,
            backingScaleFactorProvider: backingScaleFactorProvider
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
        updateTerminalViewportDiagnosticsContext()
        TerminalViewportDiagnostics.shared.record(.paneContainerReparent, context: viewportDiagnosticsContext())

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
        worklaneColor: WorklaneColor? = nil,
        animated: Bool
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            borderContext: borderContext,
            worklaneColor: worklaneColor,
            animated: animated,
            useNeutralBackground: false
        )
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel? = nil,
        worklaneColor: WorklaneColor? = nil,
        animated: Bool,
        useNeutralBackground: Bool = false
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            borderContext: borderContext,
            worklaneColor: worklaneColor,
            animatedVisualState: animated,
            useNeutralBackground: useNeutralBackground
        )
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel? = nil,
        worklaneColor: WorklaneColor? = nil
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            borderContext: borderContext,
            worklaneColor: worklaneColor,
            animatedVisualState: false,
            useNeutralBackground: false
        )
    }

    private func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        borderContext: PaneBorderContextDisplayModel?,
        worklaneColor: WorklaneColor?,
        animatedVisualState: Bool,
        useNeutralBackground: Bool
    ) {
        paneID = pane.id
        titleTextStorage = pane.title
        currentEmphasis = emphasis
        currentIsFocused = isFocused
        currentBorderContext = borderContext
        currentWorklaneColor = worklaneColor
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
            TerminalViewportDiagnostics.shared.record(.paneContainerSessionActivate, context: viewportDiagnosticsContext())
            runtime.ensureStarted()
        }
    }

    func configureViewportDiagnostics(
        worklaneID: WorklaneID?,
        laneRole: TerminalViewportLaneRole,
        isZoomedOut: Bool
    ) {
        viewportDiagnosticsWorklaneID = worklaneID
        viewportDiagnosticsLaneRole = laneRole
        viewportDiagnosticsIsZoomedOut = isZoomedOut
        updateTerminalViewportDiagnosticsContext()
    }

    func setTerminalViewportSyncSuspended(_ suspended: Bool) {
        needsLayout = true
        if suspended {
            guard ownsTerminalHostView else { return }
            updateTerminalViewportDiagnosticsContext(isViewportSyncSuspended: true)
            terminalHostView.setViewportSyncSuspended(true)
            syncFramesForCurrentBounds()
        } else {
            syncFramesForCurrentBounds()
            guard ownsTerminalHostView else { return }
            updateTerminalViewportDiagnosticsContext(isViewportSyncSuspended: false)
            terminalHostView.setViewportSyncSuspended(false)
        }
    }

    func prepareSuspendedTerminalLayoutForPreviewMount() {
        guard ownsTerminalHostView else { return }
        setTerminalViewportSyncSuspended(true)
        terminalHostView.needsLayout = true
        terminalHostView.layoutSubtreeIfNeeded()
    }

    func forceTerminalViewportSync() {
        needsLayout = true
        syncFramesForCurrentBounds()
        guard ownsTerminalHostView else { return }
        terminalHostView.forceViewportSync()
    }

    func setZoomedOutBackdropVisible(
        _ visible: Bool,
        animated: Bool,
        animationDuration: CFTimeInterval = ZenttyTheme.animationDuration
    ) {
        guard isZoomedOutBackdropVisible != visible else {
            return
        }

        isZoomedOutBackdropVisible = visible
        applyVisualState(animated: animated, animationDuration: animationDuration)
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
    }

    func endVerticalFreeze() {
        guard isTerminalAnimationFrozen else {
            return
        }

        isTerminalAnimationFrozen = false
        terminalHostView.autoresizingMask = [.width, .height]
        needsLayout = true
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
        syncFramesForCurrentBounds()
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

    var focusGlowColorTokenForTesting: String? {
        guard let cgColor = focusGlowLayer.glowColorValue,
              let color = NSColor(cgColor: cgColor)
        else {
            return nil
        }
        return color.themeToken
    }

    var focusGlowBlurRadiusForTesting: CGFloat {
        focusGlowLayer.glowBlurRadius
    }

    var focusGlowFrameForTesting: CGRect {
        focusGlowLayer.frame
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
        layer?.addSublayer(focusGlowLayer)
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
            focusGlowLayer.frame = .zero
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
        focusGlowLayer.contentsScale = backingScaleFactor
        focusGlowLayer.frame = bounds
        focusGlowLayer.strokeInset = inset
        focusGlowLayer.strokeCornerRadius = cornerRadius
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
            focusGlowLayer.labelGapRect = .zero
            return
        }

        let borderContext = currentBorderContext
        let prefixGlyph = teamPrefixGlyph(for: borderContext)
        let text = borderContext?.text ?? ""
        // Show the inset when there's either shell-context text OR a team
        // marker to render. A leader pane with no shell context still gets
        // its glyph.
        guard !text.isEmpty || prefixGlyph != nil else {
            borderContextView.isHidden = true
            setBorderLabelGap(width: 0)
            focusGlowLayer.labelGapRect = .zero
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
            focusGlowLayer.labelGapRect = .zero
            return
        }

        let size = borderContextView.measure(
            text: text,
            maxWidth: maxWidth,
            prefixGlyph: prefixGlyph
        )
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
            text: text,
            isFocused: currentIsFocused,
            theme: currentTheme,
            backingScaleFactor: resolvedBackingScaleFactor,
            prefixGlyph: prefixGlyph
        )
        setBorderLabelGap(width: size.width)
        focusGlowLayer.labelGapRect = targetFrame
        if borderContextView.onClick != nil {
            window?.invalidateCursorRects(for: borderContextView)
        }
    }

    private func teamPrefixGlyph(for context: PaneBorderContextDisplayModel?) -> String? {
        guard let context else { return nil }
        if context.isAgentTeamLeader {
            return PaneBorderContextInsetView.leaderGlyph
        }
        if context.isAgentTeamMember {
            return PaneBorderContextInsetView.memberGlyph
        }
        return nil
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
        customMenu.addItem(makeContextMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            symbolName: "doc.on.doc"
        ))
        customMenu.addItem(makeContextMenuItem(
            title: "Clean Copy",
            action: #selector(MainWindowController.cleanCopy(_:)),
            symbolName: "sparkles.rectangle.stack",
            fallbackSymbolName: "doc.on.doc"
        ))
        customMenu.addItem(makeContextMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            symbolName: "clipboard"
        ))
        customMenu.addItem(.separator())
        let rightPaneCommandPresentation = rightPaneCommandPresentationProvider?() ?? .addsToWorklane
        customMenu.addItem(makeContextMenuItem(
            title: rightPaneCommandPresentation.primaryTitle,
            action: #selector(MainWindowController.addPaneRight(_:)),
            symbolName: "arrow.right.square",
            fallbackSymbolName: "arrow.right"
        ))
        customMenu.addItem(makeContextMenuItem(
            title: "New Pane Below",
            action: #selector(MainWindowController.addPaneDown(_:)),
            symbolName: "arrow.down.square",
            fallbackSymbolName: "arrow.down"
        ))
        customMenu.addItem(makeContextMenuItem(
            title: rightPaneCommandPresentation.forceOppositeTitle,
            action: rightPaneCommandPresentation.forceOppositeCommand.contextMenuSelector,
            symbolName: "rectangle.split.2x1",
            fallbackSymbolName: "arrow.right"
        ))
        customMenu.addItem(.separator())
        let moveToWindowItem = makeContextMenuItem(
            title: "Move Pane to New Window",
            action: #selector(MainWindowController.movePaneToNewWindow(_:)),
            symbolName: "macwindow.badge.plus",
            fallbackSymbolName: "macwindow"
        )
        moveToWindowItem.representedObject = paneID
        customMenu.addItem(moveToWindowItem)
        if let catalog = moveToWorklaneCatalogProvider?(paneID), catalog.hasAnyDestination {
            let parentItem = NSMenuItem(
                title: "Move Pane to Worklane",
                action: nil,
                keyEquivalent: ""
            )
            parentItem.image = NSImage(systemSymbolName: "rectangle.stack",
                                       accessibilityDescription: "Move Pane to Worklane")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            parentItem.submenu = buildMoveToWorklaneSubmenu(catalog: catalog, paneID: paneID)
            customMenu.addItem(parentItem)
        }
        customMenu.addItem(.separator())
        customMenu.addItem(makeContextMenuItem(
            title: "Close Pane",
            action: #selector(MainWindowController.closeFocusedPane(_:)),
            symbolName: "rectangle.badge.minus",
            fallbackSymbolName: "xmark.square"
        ))

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

    private func makeContextMenuItem(
        title: String,
        action: Selector,
        symbolName: String,
        fallbackSymbolName: String? = nil
    ) -> NSMenuItem {
        SidebarContextMenu.item(
            title: title,
            action: action,
            target: nil,
            symbolName: symbolName,
            fallbackSymbolName: fallbackSymbolName
        )
    }

    private func buildMoveToWorklaneSubmenu(
        catalog: WorklaneDestinationCatalog,
        paneID: PaneID
    ) -> NSMenu {
        MoveToWorklaneMenuBuilder.makeSubmenu(catalog: catalog, paneID: paneID)
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
             #selector(MainWindowController.addPaneUp(_:)),
             #selector(MainWindowController.forceSplitRight(_:)),
             #selector(MainWindowController.forceAddPaneRight(_:)):
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

    private var ownsTerminalHostView: Bool {
        terminalHostView.superview === terminalAnchorView
    }

    private func syncFramesForCurrentBounds() {
        contentClipView.frame = bounds
        terminalAnchorView.frame = contentClipView.bounds
        guard ownsTerminalHostView else { return }
        if !isTerminalAnimationFrozen {
            terminalHostView.frame = terminalAnchorView.bounds
        }
        updateTerminalViewportDiagnosticsContext()
        TerminalViewportDiagnostics.shared.record(.paneContainerFrameSync, context: viewportDiagnosticsContext())
    }

    private func updateTerminalViewportDiagnosticsContext(isViewportSyncSuspended: Bool? = nil) {
        terminalHostView.updateViewportDiagnosticsContext(
            viewportDiagnosticsContext(isViewportSyncSuspended: isViewportSyncSuspended)
        )
    }

    private func viewportDiagnosticsContext(
        isViewportSyncSuspended: Bool? = nil
    ) -> TerminalViewportDiagnostics.Context {
        TerminalViewportDiagnostics.Context(
            paneID: paneID,
            worklaneID: viewportDiagnosticsWorklaneID,
            laneRole: viewportDiagnosticsLaneRole,
            isZoomedOut: viewportDiagnosticsIsZoomedOut,
            isViewportSyncSuspended: isViewportSyncSuspended,
            windowAttached: window != nil,
            containerBounds: bounds,
            terminalHostBounds: terminalHostView.bounds
        )
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

    private func applyVisualState(
        animated: Bool,
        animationDuration: CFTimeInterval = ZenttyTheme.animationDuration,
        useNeutralBackground: Bool = false
    ) {
        let theme = currentTheme
        let emphasis = currentEmphasis
        let isFocused = currentIsFocused
        let worklaneColor = currentWorklaneColor
        let paneFillColor =
            useNeutralBackground
            ? theme.startupSurface
            : zoomAwarePaneFillColor(theme: theme, isFocused: isFocused)
        let terminalBackingColor =
            useNeutralBackground
            ? theme.startupSurface
            : zoomAwareTerminalBackingColor(theme: theme, isFocused: isFocused)
        let shadowOpacity = Float(max(0, emphasis - 0.88) * 2.2)
        let shadowRadius = 6 + max(0, emphasis - 0.92) * 24

        let focusedStroke: NSColor
        if let worklaneColor {
            focusedStroke = worklaneColor.tint(alpha: WorklaneColor.Alpha.focusedBorder)
        } else {
            focusedStroke = theme.paneBorderFocused
        }

        let glowColor: CGColor?
        if isFocused, let worklaneColor {
            glowColor = worklaneColor.tint(alpha: WorklaneColor.Alpha.focusedGlow).cgColor
        } else {
            glowColor = nil
        }

        performThemeAnimation(animated: animated, duration: animationDuration) {
            let borderColor = self.zoomAwareBorderColor(
                theme: theme,
                focusedStroke: focusedStroke,
                isFocused: isFocused
            )
            self.insetBorderLayer.strokeColorValue = borderColor
            self.insetBorderLayer.strokeWidth = self.zoomAwareBorderWidth(isFocused: isFocused)
            self.focusGlowLayer.glowColorValue = glowColor
            self.layer?.shadowColor = theme.paneShadow.cgColor
            self.layer?.shadowOpacity = shadowOpacity
            self.layer?.shadowRadius = shadowRadius
        }
        updateLayerBackground(
            layer,
            color: paneFillColor.cgColor,
            animated: animated && !useNeutralBackground,
            duration: animationDuration
        )
        updateLayerBackground(
            contentClipView.layer,
            color: terminalBackingColor.cgColor,
            animated: animated,
            duration: animationDuration
        )
        updateLayerBackground(
            terminalHostView.layer,
            color: terminalBackingColor.cgColor,
            animated: animated,
            duration: animationDuration
        )
    }

    private func updateLayerBackground(
        _ layer: CALayer?,
        color: CGColor,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        guard let layer else { return }
        let previousColor = (layer.presentation() ?? layer).backgroundColor ?? layer.backgroundColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()

        guard animated, let previousColor, previousColor != color else {
            return
        }

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = previousColor
        animation.toValue = color
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "backgroundColor")
    }

    private func zoomAwarePaneFillColor(theme: ZenttyTheme, isFocused: Bool) -> NSColor {
        if isZoomedOutBackdropVisible {
            return theme.paneZoomFillUnfocused
        }

        return isFocused ? theme.paneFillFocused : theme.paneFillUnfocused
    }

    private func zoomAwareBorderColor(
        theme: ZenttyTheme,
        focusedStroke: NSColor,
        isFocused: Bool
    ) -> CGColor {
        if isFocused {
            return focusedStroke.cgColor
        }

        if isZoomedOutBackdropVisible {
            return theme.paneZoomBorderUnfocused.cgColor
        }

        return theme.paneBorderUnfocused.cgColor
    }

    private func zoomAwareBorderWidth(isFocused: Bool) -> CGFloat {
        if !isFocused, isZoomedOutBackdropVisible {
            return Layout.borderWidth * 1.5
        }

        return Layout.borderWidth
    }

    private func zoomAwareTerminalBackingColor(theme: ZenttyTheme, isFocused: Bool) -> NSColor {
        if isZoomedOutBackdropVisible {
            return zoomAwarePaneFillColor(theme: theme, isFocused: isFocused)
        }

        return theme.startupSurface
    }

    private func applyThemeColors(_ theme: ZenttyTheme, animated: Bool = false) {
        statusTitleLabel.textColor = theme.failurePrimaryText
        statusMessageLabel.textColor = theme.failureSecondaryText
        performThemeAnimation(animated: animated) {
            let terminalBackingColor = self.zoomAwareTerminalBackingColor(
                theme: theme,
                isFocused: self.currentIsFocused
            )
            self.contentClipView.layer?.backgroundColor = terminalBackingColor.cgColor
            self.terminalHostView.layer?.backgroundColor = terminalBackingColor.cgColor
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
