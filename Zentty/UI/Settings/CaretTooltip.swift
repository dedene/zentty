import AppKit

/// An `NSImageView` that reports mouse enter/exit immediately and carries the text
/// its tooltip should show. Used by the agent-integration status glyphs to drive the
/// custom `CaretTooltip` instead of the slow, unstyleable system tooltip.
@MainActor
final class HoverImageView: NSImageView {
    /// Text shown by the caret tooltip on hover. `nil` means no tooltip (the glyph is
    /// hidden, or the row has nothing to explain).
    var tooltipText: String?
    var onEnter: ((HoverImageView) -> Void)?
    var onExit: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        // `.activeInKeyWindow` keeps the tracking tied to the focused Settings window
        // and fires the moment the pointer enters — no native tooltip delay.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard tooltipText != nil else { return }
        onEnter?(self)
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}

/// A lightweight, instant hover tooltip rendered as a borderless child panel: a
/// rounded bubble with a caret pointing at the anchor. Built as a custom panel (not
/// `NSPopover`) so it can appear instantly, sit to the *left* of its anchor with the
/// caret on the right, and wear a flat look that matches `SettingsCardView` rather
/// than the translucent popover chrome.
@MainActor
final class CaretTooltip {
    private var panel: NSPanel?
    private let bubble = CaretTooltipBubbleView()

    /// Layout constants. `gap` is the breathing room between the caret tip and the
    /// anchor; `maxTextWidth` bounds wrapping so long paths don't make a wide bubble.
    private enum Layout {
        static let gap: CGFloat = 7
        static let caretWidth: CGFloat = 7
        static let maxTextWidth: CGFloat = 260
        static let screenMargin: CGFloat = 8
    }

    /// Show the tooltip for `text`, positioned relative to `anchor` (typically the
    /// status glyph). Reuses the same panel across calls so hovering row-to-row just
    /// repositions one window.
    func show(text: String, relativeTo anchor: NSView, in window: NSWindow) {
        bubble.text = text

        let textSize = bubble.measure(maxTextWidth: Layout.maxTextWidth)
        let bubbleSize = bubble.bubbleSize(forTextSize: textSize)
        let panelSize = CGSize(width: bubbleSize.width + Layout.caretWidth, height: bubbleSize.height)

        let panel = panel ?? makePanel(in: window)
        self.panel = panel
        panel.appearance = window.effectiveAppearance
        panel.setContentSize(panelSize)
        bubble.frame = CGRect(origin: .zero, size: panelSize)

        // Anchor centre in screen space.
        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        let anchorCenterY = anchorOnScreen.midY

        let visible = (anchor.window?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame
            ?? window.frame

        // Preferred: left of the anchor, caret on the right edge pointing right.
        var caretOnRight = true
        var originX = anchorOnScreen.minX - panelSize.width - Layout.gap
        // Flip to the right side if there's no room on the left.
        if originX < visible.minX + Layout.screenMargin {
            caretOnRight = false
            originX = anchorOnScreen.maxX + Layout.gap
        }

        // Vertically centre on the anchor, then clamp into the visible screen.
        var originY = anchorCenterY - panelSize.height / 2
        originY = max(
            visible.minY + Layout.screenMargin,
            min(originY, visible.maxY - panelSize.height - Layout.screenMargin)
        )

        // The caret tip tracks the anchor centre even after the bubble was clamped,
        // so it keeps pointing at the icon near the screen edges. Clamp it away from
        // the rounded corners.
        let rawCaretY = anchorCenterY - originY
        bubble.configureCaret(onRight: caretOnRight, tipY: rawCaretY)

        panel.setFrameOrigin(CGPoint(x: originX, y: originY))
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(in window: NSWindow) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.contentView = bubble
        return panel
    }
}

/// Draws the tooltip bubble: a rounded rect plus a triangular caret on one side.
@MainActor
final class CaretTooltipBubbleView: NSView {
    private enum Layout {
        static let cornerRadius: CGFloat = 7
        static let caretWidth: CGFloat = 7
        static let caretHeight: CGFloat = 12
        static let textInsetX: CGFloat = 10
        static let textInsetY: CGFloat = 7
    }

    var text: String = "" {
        didSet {
            label.stringValue = text
            needsDisplay = true
        }
    }

    private var caretOnRight = true
    private var caretTipY: CGFloat = 0

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        // Laid out manually via `frame` in `layoutLabel()`, so keep autoresizing.
        field.translatesAutoresizingMaskIntoConstraints = true
        field.isSelectable = false
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    /// Size the wrapped text occupies, capped at `maxTextWidth`. Uses the field's
    /// intrinsic size under a bounded wrap width (the AppKit-reliable path; NSTextField
    /// has no `sizeThatFits`).
    func measure(maxTextWidth: CGFloat) -> CGSize {
        label.preferredMaxLayoutWidth = maxTextWidth
        label.invalidateIntrinsicContentSize()
        let fitting = label.intrinsicContentSize
        return CGSize(width: ceil(min(fitting.width, maxTextWidth)), height: ceil(fitting.height))
    }

    /// Bubble size (excluding caret) for a measured text size.
    func bubbleSize(forTextSize textSize: CGSize) -> CGSize {
        CGSize(
            width: textSize.width + Layout.textInsetX * 2,
            height: textSize.height + Layout.textInsetY * 2
        )
    }

    func configureCaret(onRight: Bool, tipY rawTipY: CGFloat) {
        caretOnRight = onRight
        let half = Layout.caretHeight / 2
        let minY = Layout.cornerRadius + half
        let maxY = bounds.height - Layout.cornerRadius - half
        caretTipY = minY <= maxY ? min(max(rawTipY, minY), maxY) : bounds.midY
        layoutLabel()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutLabel()
    }

    private func layoutLabel() {
        // The bubble occupies all of `bounds` except the caret column on one side.
        let bubbleX = caretOnRight ? 0 : Layout.caretWidth
        let bubbleWidth = bounds.width - Layout.caretWidth
        label.frame = CGRect(
            x: bubbleX + Layout.textInsetX,
            y: Layout.textInsetY,
            width: max(0, bubbleWidth - Layout.textInsetX * 2),
            height: max(0, bounds.height - Layout.textInsetY * 2)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor = isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : .white
        let border = isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.14)

        let path = bubblePath()
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A single continuous rounded-rect-plus-caret outline. Tracing it as one path
    /// (detouring out to the caret tip along the relevant edge) avoids the seam a
    /// separate triangle would leave where its base meets the bubble — for both fill
    /// and stroke. Inset by 0.5 keeps the 1pt stroke crisp.
    private func bubblePath() -> NSBezierPath {
        let r = Layout.cornerRadius
        let caretW = Layout.caretWidth
        let half = Layout.caretHeight / 2

        let minX = (caretOnRight ? 0.5 : caretW + 0.5)
        let maxX = bounds.width - (caretOnRight ? caretW + 0.5 : 0.5)
        let minY: CGFloat = 0.5
        let maxY = bounds.height - 0.5

        let path = NSBezierPath()
        path.move(to: NSPoint(x: minX + r, y: maxY))            // top edge start
        path.line(to: NSPoint(x: maxX - r, y: maxY))            // → along top
        path.appendArc(                                         // top-right corner
            withCenter: NSPoint(x: maxX - r, y: maxY - r),
            radius: r, startAngle: 90, endAngle: 0, clockwise: true
        )
        if caretOnRight {                                       // ↓ right edge w/ caret
            path.line(to: NSPoint(x: maxX, y: caretTipY + half))
            path.line(to: NSPoint(x: maxX + caretW, y: caretTipY))
            path.line(to: NSPoint(x: maxX, y: caretTipY - half))
        }
        path.line(to: NSPoint(x: maxX, y: minY + r))
        path.appendArc(                                         // bottom-right corner
            withCenter: NSPoint(x: maxX - r, y: minY + r),
            radius: r, startAngle: 0, endAngle: -90, clockwise: true
        )
        path.line(to: NSPoint(x: minX + r, y: minY))           // ← along bottom
        path.appendArc(                                         // bottom-left corner
            withCenter: NSPoint(x: minX + r, y: minY + r),
            radius: r, startAngle: 270, endAngle: 180, clockwise: true
        )
        if !caretOnRight {                                      // ↑ left edge w/ caret
            path.line(to: NSPoint(x: minX, y: caretTipY - half))
            path.line(to: NSPoint(x: minX - caretW, y: caretTipY))
            path.line(to: NSPoint(x: minX, y: caretTipY + half))
        }
        path.line(to: NSPoint(x: minX, y: maxY - r))
        path.appendArc(                                         // top-left corner
            withCenter: NSPoint(x: minX + r, y: maxY - r),
            radius: r, startAngle: 180, endAngle: 90, clockwise: true
        )
        path.close()
        return path
    }
}
