import AppKit
import QuartzCore

@MainActor
final class PathCopiedToastView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 5
        static let cornerRadius: CGFloat = 6
        static let fontSize: CGFloat = 11
        static let borderWidth: CGFloat = 0.5
        static let displayDuration: TimeInterval = 1.5
        static let fadeInDuration: CFTimeInterval = 0.15
        static let fadeOutDuration: CFTimeInterval = 0.25
        static let bottomOffset: CGFloat = 32
    }

    private let backdropLayer = CALayer()
    private let textContentLayer = CALayer()
    private let textFont = NSFont.systemFont(ofSize: Layout.fontSize, weight: .medium)
    private var dismissWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        layer?.masksToBounds = false
        backdropLayer.cornerRadius = Layout.cornerRadius
        backdropLayer.cornerCurve = .continuous
        backdropLayer.borderWidth = Layout.borderWidth
        backdropLayer.zPosition = 0
        textContentLayer.zPosition = 1
        layer?.addSublayer(backdropLayer)
        layer?.addSublayer(textContentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(in parentView: NSView, theme: ZenttyTheme) {
        dismissWorkItem?.cancel()
        removeFromSuperview()

        let message = "Path copied"
        let backingScale = parentView.window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2)
        let textColor = theme.openWithPopoverText
        let attributedText = NSAttributedString(
            string: message,
            attributes: [.font: textFont, .foregroundColor: textColor]
        )
        let textSize = attributedText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        let textWidth = ceil(textSize.width)
        let textHeight = ceil(textSize.height)
        let viewWidth = textWidth + Layout.horizontalPadding * 2
        let viewHeight = textHeight + Layout.verticalPadding * 2

        frame = CGRect(
            x: round(parentView.bounds.midX - viewWidth / 2),
            y: Layout.bottomOffset,
            width: viewWidth,
            height: viewHeight
        )
        autoresizingMask = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        backdropLayer.backgroundColor = theme.openWithPopoverBackground.cgColor
        backdropLayer.borderColor = theme.openWithPopoverBorder.withAlphaComponent(0.5).cgColor

        let textRect = CGRect(
            x: Layout.horizontalPadding,
            y: Layout.verticalPadding,
            width: textWidth,
            height: textHeight
        )
        textContentLayer.frame = textRect
        textContentLayer.contentsScale = backingScale
        textContentLayer.contents = renderTextImage(attributedText, size: textRect.size, scale: backingScale)
        CATransaction.commit()

        parentView.addSubview(self)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.displayDuration, execute: workItem)
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
            }
        })
    }

    private func renderTextImage(
        _ attributedText: NSAttributedString,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        let line = CTLineCreateWithAttributedString(attributedText)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
