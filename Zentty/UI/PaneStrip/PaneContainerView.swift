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

@MainActor
final class PaneContainerView: NSView {
    enum Layout {
        static let borderWidth: CGFloat = 1
        static let cornerRadius: CGFloat = ChromeGeometry.paneRadius
        static let overlayInset: CGFloat = 18
        static let overlayButtonTopSpacing: CGFloat = 14
        static let overlayButtonHeight: CGFloat = 30
        static let inactivePaneAlpha: CGFloat = 0.7
    }

    private enum StatusState: Equatable {
        case hidden
        case startupFailure(message: String)
    }

    private let runtime: PaneRuntime
    private let contentClipView = NSView()
    private let terminalAnchorView = TerminalAnchorView()
    private let terminalHostView: TerminalPaneHostView
    private let backingScaleFactorProvider: () -> CGFloat
    private let insetBorderLayer = CALayer()
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
    private var currentIsFocused: Bool
    var onSelected: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
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
        contentClipView.addSubview(terminalAnchorView)
        terminalAnchorView.addSubview(terminalHostView)
        contentClipView.addSubview(statusOverlayView)

        terminalHostView.onFocusDidChange = { [weak self] isFocused in
            guard isFocused else {
                return
            }

            self?.onSelected?()
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
        presentationAlpha(forEmphasis: emphasis, allowInactiveDimming: true)
    }

    static func presentationAlpha(
        forEmphasis emphasis: CGFloat,
        allowInactiveDimming: Bool
    ) -> CGFloat {
        guard allowInactiveDimming else {
            return 1
        }

        return emphasis >= 0.999 ? 1 : Layout.inactivePaneAlpha
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        animated: Bool
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            animated: animated,
            useNeutralBackground: false
        )
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        animated: Bool,
        useNeutralBackground: Bool = false
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            animatedVisualState: animated,
            useNeutralBackground: useNeutralBackground
        )
    }

    func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool
    ) {
        render(
            pane: pane,
            emphasis: emphasis,
            isFocused: isFocused,
            animatedVisualState: false,
            useNeutralBackground: false
        )
    }

    private func render(
        pane: PaneState,
        emphasis: CGFloat,
        isFocused: Bool,
        animatedVisualState: Bool,
        useNeutralBackground: Bool
    ) {
        paneID = pane.id
        titleTextStorage = pane.title
        currentEmphasis = emphasis
        currentIsFocused = isFocused
        runtime.update(pane: pane)
        updateInsetBorderLayer()
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
        runtime.hostView.focusTerminal()
    }

    func activateSessionIfNeeded() {
        layoutSubtreeIfNeeded()
        runtime.ensureStarted()
    }

    func setTerminalViewportSyncSuspended(_ suspended: Bool) {
        terminalHostView.setViewportSyncSuspended(suspended)
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
        isInsetBorderAnimationManaged = true
        let backingScaleFactor = resolvedBackingScaleFactor
        let inset = ChromeGeometry.paneBorderInset(backingScaleFactor: backingScaleFactor)
        let insetRect = CGRect(origin: .zero, size: targetSize).insetBy(dx: inset, dy: inset)
        let cornerRadius = max(0, Layout.cornerRadius - inset)
        insetBorderLayer.contentsScale = backingScaleFactor
        insetBorderLayer.frame = insetRect
        insetBorderLayer.cornerRadius = cornerRadius
    }

    func syncInsetBorderNow() {
        isInsetBorderAnimationManaged = false
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
        insetBorderLayer.borderWidth
    }

    var insetBorderFrame: CGRect {
        insetBorderLayer.frame
    }

    var insetBorderInset: CGFloat {
        insetBorderLayer.frame.minX
    }

    var insetBorderCornerRadius: CGFloat {
        insetBorderLayer.cornerRadius
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
        guard let cgColor = insetBorderLayer.borderColor, let color = NSColor(cgColor: cgColor)
        else {
            return nil
        }

        return color.themeToken
    }

    var shadowOpacityForTesting: Float {
        layer?.shadowOpacity ?? 0
    }

    var shadowRadiusForTesting: CGFloat {
        layer?.shadowRadius ?? 0
    }

    var hasPaneContextChrome: Bool {
        false
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

    private func setupInsetBorderLayer() {
        insetBorderLayer.backgroundColor = NSColor.clear.cgColor
        insetBorderLayer.borderWidth = Layout.borderWidth
        insetBorderLayer.cornerCurve = .continuous
        insetBorderLayer.zPosition = 10
        layer?.addSublayer(insetBorderLayer)
        updateInsetBorderLayer()
    }

    private var savedBorderColor: CGColor?

    func applyZoomBorderCompensation(zoomScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insetBorderLayer.borderWidth = Layout.borderWidth / max(0.1, zoomScale)

        // Boost border opacity so it's clearly visible at small scale
        savedBorderColor = insetBorderLayer.borderColor
        if let current = insetBorderLayer.borderColor,
            let nsColor = NSColor(cgColor: current)
        {
            insetBorderLayer.borderColor = nsColor.withAlphaComponent(0.4).cgColor
        }
        CATransaction.commit()
    }

    func resetZoomBorderCompensation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insetBorderLayer.borderWidth = Layout.borderWidth
        if let saved = savedBorderColor {
            insetBorderLayer.borderColor = saved
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
        insetBorderLayer.cornerRadius = cornerRadius
        CATransaction.commit()
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
            self.insetBorderLayer.borderColor = borderColor
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
}
