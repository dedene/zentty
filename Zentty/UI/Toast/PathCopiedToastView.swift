import AppKit
import QuartzCore

@MainActor
final class PathCopiedToastView: NSView {
    @MainActor
    final class ProgressHandle {
        private weak var toast: PathCopiedToastView?

        fileprivate init(toast: PathCopiedToastView) {
            self.toast = toast
        }

        func updateProgress(fraction: Double, message: String) {
            toast?.updateProgress(fraction: fraction, message: message)
        }

        func finish(message: String, icon: String) {
            toast?.finish(message: message, icon: icon)
        }

        func fail(message: String) {
            toast?.fail(message: message)
        }
    }

    private enum Layout {
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 9
        static let interItemSpacing: CGFloat = 8
        static let iconPointSize: CGFloat = 13
        static let minimumWidth: CGFloat = 136
        static let minimumHeight: CGFloat = 34
        static let cornerRadius: CGFloat = 17
        static let displayDuration: TimeInterval = 1.5
        static let failureDisplayDuration: TimeInterval = 2.5
        static let fadeInDuration: TimeInterval = 0.22
        static let fadeOutDuration: TimeInterval = 0.18
        static let bottomOffset: CGFloat = 32
        static let entranceOffsetY: CGFloat = -4
        static let exitOffsetY: CGFloat = -2
        static let initialScale: CGFloat = 0.985
    }

    private enum ToastMode: Equatable {
        case idle
        case transient
        case progress
        case finished
        case failed
    }

    private struct ProgressMessageOverride {
        var token: UUID
        var restoreMessage: String
    }

    private let surfaceView = GlassSurfaceView(style: .toast)
    private let contentStackView = NSStackView()
    private let iconContainerView = NSView()
    private let iconView = NSImageView()
    private let progressView = ToastCircularProgressView()
    private let messageLabel = NSTextField(labelWithString: "Path copied")
    private var dismissWorkItem: DispatchWorkItem?
    private var progressMessageOverrideWorkItem: DispatchWorkItem?
    private var progressMessageOverride: ProgressMessageOverride?
    private var restingFrame: CGRect = .zero
    private var mode: ToastMode = .idle
    private var currentTheme: ZenttyTheme?
    private var currentLabelColor: NSColor = .labelColor
    private var currentIconSymbolName: String?

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
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Layout.cornerRadius,
            cornerHeight: Layout.cornerRadius,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(in parentView: NSView, theme: ZenttyTheme) {
        show(message: "Path copied", in: parentView, theme: theme)
    }

    func show(message: String, in parentView: NSView, theme: ZenttyTheme) {
        guard mode != .progress else {
            return
        }

        mode = .transient
        clearProgressMessageOverride()
        setSymbolIcon("checkmark.circle.fill", accessibilityDescription: message)
        present(message: message, in: parentView, theme: theme, autoDismissAfter: Layout.displayDuration)
    }

    func beginProgress(
        message: String,
        in parentView: NSView,
        theme: ZenttyTheme
    ) -> ProgressHandle {
        mode = .progress
        clearProgressMessageOverride()
        progressView.fraction = 0
        showProgressIcon()
        present(message: message, in: parentView, theme: theme, autoDismissAfter: nil)
        return ProgressHandle(toast: self)
    }

    func updateProgress(fraction: Double, message: String) {
        guard mode == .progress else {
            return
        }

        progressView.fraction = max(0, min(1, fraction))
        if var progressMessageOverride {
            progressMessageOverride.restoreMessage = message
            self.progressMessageOverride = progressMessageOverride
        } else {
            messageLabel.stringValue = message
            updateFrameForCurrentContent()
        }
    }

    func finish(message: String, icon: String) {
        guard mode == .progress else {
            return
        }

        mode = .finished
        clearProgressMessageOverride()
        setSymbolIcon(icon, accessibilityDescription: message)
        messageLabel.stringValue = message
        updateFrameForCurrentContent()
        scheduleDismiss(after: Layout.displayDuration)
    }

    func fail(message: String) {
        guard mode == .progress else {
            return
        }

        mode = .failed
        clearProgressMessageOverride()
        setSymbolIcon("xmark.circle.fill", accessibilityDescription: message)
        messageLabel.stringValue = message
        updateFrameForCurrentContent()
        scheduleDismiss(after: Layout.failureDisplayDuration)
    }

    func temporarilyShowProgressMessage(_ message: String, duration: TimeInterval) {
        guard mode == .progress else {
            return
        }

        let token = UUID()
        progressMessageOverrideWorkItem?.cancel()
        progressMessageOverride = ProgressMessageOverride(token: token, restoreMessage: messageLabel.stringValue)
        messageLabel.stringValue = message
        updateFrameForCurrentContent()

        let workItem = DispatchWorkItem { [weak self] in
            MainActorShim.assumeIsolated {
                guard
                    let self,
                    self.mode == .progress,
                    let progressMessageOverride = self.progressMessageOverride,
                    progressMessageOverride.token == token
                else {
                    return
                }

                self.progressMessageOverride = nil
                self.messageLabel.stringValue = progressMessageOverride.restoreMessage
                self.updateFrameForCurrentContent()
            }
        }
        progressMessageOverrideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    var isProgressActive: Bool {
        mode == .progress
    }

    private func present(
        message: String,
        in parentView: NSView,
        theme: ZenttyTheme,
        autoDismissAfter duration: TimeInterval?
    ) {
        messageLabel.stringValue = message
        dismissWorkItem?.cancel()
        removeFromSuperview()

        currentTheme = theme
        apply(theme: theme)
        layoutSubtreeIfNeeded()
        updateRestingFrame(in: parentView)

        frame = restingFrame.offsetBy(dx: 0, dy: Layout.entranceOffsetY)
        autoresizingMask = []
        alphaValue = 0
        layer?.transform = CATransform3DMakeScale(Layout.initialScale, Layout.initialScale, 1)

        parentView.addSubview(self)
        layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.animator().frame = self.restingFrame
        }
        animateScale(from: Layout.initialScale, to: 1, duration: Layout.fadeInDuration, timing: .easeOut)

        if let duration {
            scheduleDismiss(after: duration)
        }
    }

    private func updateRestingFrame(in parentView: NSView) {
        let fittingSize = self.fittingSize
        let width = max(Layout.minimumWidth, ceil(fittingSize.width))
        let height = max(Layout.minimumHeight, ceil(fittingSize.height))
        restingFrame = CGRect(
            x: round(parentView.bounds.midX - width / 2),
            y: Layout.bottomOffset,
            width: width,
            height: height
        )
    }

    private func updateFrameForCurrentContent() {
        guard let parentView = superview else {
            return
        }

        updateRestingFrame(in: parentView)
        frame = restingFrame
        layoutSubtreeIfNeeded()
    }

    private func scheduleDismiss(after duration: TimeInterval) {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func clearProgressMessageOverride() {
        progressMessageOverrideWorkItem?.cancel()
        progressMessageOverrideWorkItem = nil
        progressMessageOverride = nil
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)

        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = Layout.interItemSpacing
        surfaceView.addSubview(contentStackView)

        iconContainerView.translatesAutoresizingMaskIntoConstraints = false
        iconContainerView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconContainerView.setContentHuggingPriority(.required, for: .horizontal)
        contentStackView.addArrangedSubview(iconContainerView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconContainerView.addSubview(iconView)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        iconContainerView.addSubview(progressView)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byClipping
        messageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        messageLabel.setContentHuggingPriority(.required, for: .horizontal)
        contentStackView.addArrangedSubview(messageLabel)

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStackView.leadingAnchor.constraint(
                equalTo: surfaceView.leadingAnchor,
                constant: Layout.horizontalPadding
            ),
            contentStackView.trailingAnchor.constraint(
                equalTo: surfaceView.trailingAnchor,
                constant: -Layout.horizontalPadding
            ),
            contentStackView.topAnchor.constraint(
                equalTo: surfaceView.topAnchor,
                constant: Layout.verticalPadding
            ),
            contentStackView.bottomAnchor.constraint(
                equalTo: surfaceView.bottomAnchor,
                constant: -Layout.verticalPadding
            ),

            iconContainerView.widthAnchor.constraint(equalToConstant: Layout.iconPointSize + 4),
            iconContainerView.heightAnchor.constraint(equalToConstant: Layout.iconPointSize + 4),
            iconView.leadingAnchor.constraint(equalTo: iconContainerView.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconContainerView.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: iconContainerView.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconContainerView.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: iconContainerView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: iconContainerView.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: iconContainerView.topAnchor),
            progressView.bottomAnchor.constraint(equalTo: iconContainerView.bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumWidth),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumHeight),
        ])
    }

    private func apply(theme: ZenttyTheme) {
        let isDark = theme.sidebarGlassAppearance == .dark
        appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        surfaceView.apply(theme: theme, animated: false)

        let labelColor = theme.openWithPopoverText.withAlphaComponent(isDark ? 0.96 : 0.92)
        currentLabelColor = labelColor
        messageLabel.textColor = labelColor
        messageLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        iconView.contentTintColor = labelColor.withAlphaComponent(isDark ? 0.96 : 0.88)
        progressView.tintColor = iconView.contentTintColor ?? labelColor
        let shadowColor = theme.openWithPopoverShadow
            .mixed(towards: .black, amount: 0.52)
            .withAlphaComponent(isDark ? 0.42 : 0.18)

        layer?.shadowColor = shadowColor.cgColor
        layer?.shadowRadius = isDark ? 16 : 14
        layer?.shadowOffset = CGSize(width: 0, height: 8)
    }

    private func setSymbolIcon(_ symbolName: String, accessibilityDescription: String) {
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Layout.iconPointSize,
            weight: .semibold,
            scale: .medium
        )
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(symbolConfiguration)
        iconView.contentTintColor = currentLabelColor
        iconView.isHidden = false
        progressView.isHidden = true
        currentIconSymbolName = symbolName
    }

    private func showProgressIcon() {
        iconView.isHidden = true
        progressView.isHidden = false
        currentIconSymbolName = nil
    }

    private func dismiss() {
        dismissWorkItem?.cancel()
        let destinationFrame = restingFrame.offsetBy(dx: 0, dy: Layout.exitOffsetY)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.animator().frame = destinationFrame
        }, completionHandler: { [weak self] in
            MainActorShim.assumeIsolated {
                self?.mode = .idle
                self?.removeFromSuperview()
            }
        })
        animateScale(from: 1, to: 0.985, duration: Layout.fadeOutDuration, timing: .easeIn)
    }

    private func animateScale(
        from startScale: CGFloat,
        to endScale: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard let layer else { return }

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DMakeScale(startScale, startScale, 1)
        animation.toValue = CATransform3DMakeScale(endScale, endScale, 1)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.transform = CATransform3DMakeScale(endScale, endScale, 1)
        layer.add(animation, forKey: "toastScale")
    }

    var isProgressActiveForTesting: Bool {
        isProgressActive
    }

    var messageForTesting: String {
        messageLabel.stringValue
    }

    var progressFractionForTesting: Double {
        progressView.fraction
    }

    var iconSymbolNameForTesting: String? {
        currentIconSymbolName
    }
}

@MainActor
private final class ToastCircularProgressView: NSView {
    private var fractionStorage: Double = 0

    var fraction: Double {
        get {
            fractionStorage
        }
        set {
            fractionStorage = max(0, min(1, newValue))
            needsDisplay = true
        }
    }

    var tintColor: NSColor = .labelColor {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        let side = min(bounds.width, bounds.height) - 2
        let rect = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )

        let background = NSBezierPath(ovalIn: rect)
        background.lineWidth = 1.6
        tintColor.withAlphaComponent(0.24).setStroke()
        background.stroke()

        let progress = NSBezierPath()
        progress.lineWidth = 1.8
        progress.lineCapStyle = .round
        let center = NSPoint(x: rect.midX, y: rect.midY)
        progress.appendArc(
            withCenter: center,
            radius: side / 2,
            startAngle: 90,
            endAngle: 90 - (360 * CGFloat(fraction)),
            clockwise: true
        )
        tintColor.setStroke()
        progress.stroke()
    }
}
