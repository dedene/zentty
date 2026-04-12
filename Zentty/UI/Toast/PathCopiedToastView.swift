import AppKit
import QuartzCore

@MainActor
final class PathCopiedToastView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 9
        static let interItemSpacing: CGFloat = 8
        static let iconPointSize: CGFloat = 13
        static let minimumWidth: CGFloat = 136
        static let minimumHeight: CGFloat = 34
        static let cornerRadius: CGFloat = 17
        static let displayDuration: TimeInterval = 1.5
        static let fadeInDuration: TimeInterval = 0.22
        static let fadeOutDuration: TimeInterval = 0.18
        static let bottomOffset: CGFloat = 32
        static let entranceOffsetY: CGFloat = -4
        static let exitOffsetY: CGFloat = -2
        static let initialScale: CGFloat = 0.985
    }

    private let surfaceView = GlassSurfaceView(style: .toast)
    private let contentStackView = NSStackView()
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "Path copied")
    private var dismissWorkItem: DispatchWorkItem?
    private var restingFrame: CGRect = .zero

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
        dismissWorkItem?.cancel()
        removeFromSuperview()

        apply(theme: theme)
        layoutSubtreeIfNeeded()

        let fittingSize = self.fittingSize
        let width = max(Layout.minimumWidth, ceil(fittingSize.width))
        let height = max(Layout.minimumHeight, ceil(fittingSize.height))
        restingFrame = CGRect(
            x: round(parentView.bounds.midX - width / 2),
            y: Layout.bottomOffset,
            width: width,
            height: height
        )

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

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.displayDuration, execute: workItem)
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

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        contentStackView.addArrangedSubview(iconView)

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

            iconView.widthAnchor.constraint(equalToConstant: Layout.iconPointSize + 4),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconPointSize + 4),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumWidth),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumHeight),
        ])
    }

    private func apply(theme: ZenttyTheme) {
        let isDark = theme.sidebarGlassAppearance == .dark
        appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        surfaceView.apply(theme: theme, animated: false)

        let labelColor = theme.openWithPopoverText.withAlphaComponent(isDark ? 0.96 : 0.92)
        messageLabel.textColor = labelColor
        messageLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Layout.iconPointSize,
            weight: .semibold,
            scale: .medium
        )
        let icon = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Path copied"
        )?.withSymbolConfiguration(symbolConfiguration)
        iconView.image = icon
        iconView.contentTintColor = labelColor.withAlphaComponent(isDark ? 0.96 : 0.88)
        let shadowColor = theme.openWithPopoverShadow
            .mixed(towards: .black, amount: 0.52)
            .withAlphaComponent(isDark ? 0.42 : 0.18)

        layer?.shadowColor = shadowColor.cgColor
        layer?.shadowRadius = isDark ? 16 : 14
        layer?.shadowOffset = CGSize(width: 0, height: 8)
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
            MainActor.assumeIsolated {
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
}
