import AppKit
import QuartzCore

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
    private let backingScaleFactorProvider: () -> CGFloat
    private let insetBorderLayer = CALayer()
    private let statusOverlayView = NSView()
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private(set) var paneID: PaneID
    private var titleTextStorage: String
    private var statusState: StatusState = .hidden
    private var runtimeObserverID: UUID?
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
        backingScaleFactorProvider: @escaping () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 1 }
    ) {
        self.paneID = pane.id
        self.titleTextStorage = pane.title
        self.runtime = runtime
        self.backingScaleFactorProvider = backingScaleFactorProvider
        self.currentTheme = theme
        self.currentEmphasis = emphasis
        self.currentIsFocused = isFocused
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = true
        setup()
        render(pane: pane, width: width, height: height, emphasis: emphasis, isFocused: isFocused)
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
        layer?.masksToBounds = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let terminalHostView = runtime.hostView
        terminalHostView.removeFromSuperview()
        addSubview(terminalHostView)
        addSubview(statusOverlayView)

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
        apply(theme: currentTheme, animated: false)

        NSLayoutConstraint.activate([
            terminalHostView.topAnchor.constraint(equalTo: topAnchor),
            terminalHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalHostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalHostView.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusOverlayView.topAnchor.constraint(equalTo: topAnchor),
            statusOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func render(
        pane: PaneState, width: CGFloat, height: CGFloat, emphasis: CGFloat, isFocused: Bool
    ) {
        paneID = pane.id
        titleTextStorage = pane.title
        currentEmphasis = emphasis
        currentIsFocused = isFocused
        runtime.update(pane: pane)

        frame.size = NSSize(width: width, height: height)
        updateInsetBorderLayer()
        applyVisualState(animated: false)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        statusTitleLabel.textColor = theme.failurePrimaryText
        statusMessageLabel.textColor = theme.failureSecondaryText
        performThemeAnimation(animated: animated) {
            self.statusOverlayView.layer?.backgroundColor = theme.failureOverlayBackground.cgColor
        }
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

    override func layout() {
        super.layout()
        updateInsetBorderLayer()
    }

    var titleTextForTesting: String {
        titleTextStorage
    }

    var statusTitleForTesting: String {
        statusTitleLabel.stringValue
    }

    var statusMessageForTesting: String {
        statusMessageLabel.stringValue
    }

    var isStatusOverlayHiddenForTesting: Bool {
        statusOverlayView.isHidden
    }

    var isRetryButtonHiddenForTesting: Bool {
        retryButton.isHidden
    }

    var isCloseButtonHiddenForTesting: Bool {
        closeButton.isHidden
    }

    var retryButtonForTesting: NSButton {
        retryButton
    }

    var closeButtonForTesting: NSButton {
        closeButton
    }

    var usesInsetBorderLayerForTesting: Bool {
        insetBorderLayer.superlayer === layer
    }

    var insetBorderLineWidthForTesting: CGFloat {
        insetBorderLayer.borderWidth
    }

    var insetBorderFrameForTesting: CGRect {
        insetBorderLayer.frame
    }

    var insetBorderInsetForTesting: CGFloat {
        insetBorderLayer.frame.minX
    }

    var insetBorderCornerRadiusForTesting: CGFloat {
        insetBorderLayer.cornerRadius
    }

    var insetBorderCornerCurveForTesting: CALayerCornerCurve {
        insetBorderLayer.cornerCurve
    }

    private func setupInsetBorderLayer() {
        insetBorderLayer.backgroundColor = NSColor.clear.cgColor
        insetBorderLayer.borderWidth = Layout.borderWidth
        insetBorderLayer.cornerCurve = .continuous
        insetBorderLayer.zPosition = 10
        layer?.addSublayer(insetBorderLayer)
        updateInsetBorderLayer()
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
        max(1, window?.backingScaleFactor ?? layer?.contentsScale ?? backingScaleFactorProvider())
    }

    private func setupStatusOverlay() {
        statusOverlayView.wantsLayer = true
        statusOverlayView.layer?.backgroundColor = currentTheme.failureOverlayBackground.cgColor
        statusOverlayView.translatesAutoresizingMaskIntoConstraints = false
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

        NSLayoutConstraint.activate([
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
        ])
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
            statusOverlayView.isHidden = true
            statusTitleLabel.stringValue = ""
            statusMessageLabel.stringValue = ""
            retryButton.isHidden = true
            closeButton.isHidden = true
        case .startupFailure(let message):
            statusOverlayView.isHidden = false
            statusTitleLabel.stringValue = "Pane failed to start"
            statusMessageLabel.stringValue = message
            retryButton.isHidden = false
            closeButton.isHidden = false
        }
    }

    private func applyVisualState(animated: Bool) {
        let theme = currentTheme
        let emphasis = currentEmphasis
        let isFocused = currentIsFocused
        performThemeAnimation(animated: animated) {
            self.insetBorderLayer.borderColor =
                (isFocused
                ? theme.paneBorderFocused
                : theme.paneBorderUnfocused).cgColor
            self.layer?.backgroundColor =
                (isFocused
                ? theme.paneFillFocused
                : theme.startupSurface).cgColor
            self.layer?.shadowColor = theme.paneShadow.cgColor
        }
        layer?.shadowOpacity = Float(max(0, emphasis - 0.88) * 2.2)
        layer?.shadowRadius = 6 + max(0, emphasis - 0.92) * 24
        alphaValue = 0.9 + (emphasis - 0.9) * 0.5
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
