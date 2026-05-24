import AppKit

struct PaneSplitBehaviorPreviewLayout: Equatable {
    struct Arrow: Equatable {
        var start: CGPoint
        var end: CGPoint
    }

    struct DottedPane: Equatable {
        var frame: CGRect
    }

    struct Outcome: Equatable {
        var label: String
        var windowFrame: CGRect
        var solidPaneFrames: [CGRect]
        var dottedOutsidePane: DottedPane?
        var scrollArrow: Arrow?
        var shrinkArrows: [Arrow]
    }

    var mode: PaneSplitBehaviorMode
    var bounds: CGRect
    var beforeWindowFrame: CGRect?
    var beforePaneFrame: CGRect?
    var outcomes: [Outcome]

    init(mode: PaneSplitBehaviorMode, bounds: CGRect) {
        self.mode = mode
        self.bounds = bounds

        let rect = bounds.insetBy(dx: 3, dy: 4)
        let topLabelHeight: CGFloat = 12
        let diagramTop = rect.minY + topLabelHeight
        let diagramHeight = max(34, rect.height - topLabelHeight - 3)
        let diagramRect = CGRect(
            x: rect.minX,
            y: diagramTop,
            width: rect.width,
            height: diagramHeight
        )

        switch mode {
        case .adaptive:
            let gap: CGFloat = 16
            let outcomeWidth = floor((diagramRect.width - gap) / 2)
            let narrowSlot = CGRect(
                x: diagramRect.minX,
                y: diagramRect.minY + 11,
                width: outcomeWidth,
                height: max(24, diagramRect.height - 17)
            )
            let narrowWindow = CGRect(
                x: narrowSlot.minX,
                y: narrowSlot.minY,
                width: outcomeWidth * 0.58,
                height: narrowSlot.height
            )
            let wideWindow = CGRect(
                x: narrowSlot.maxX + gap,
                y: narrowSlot.minY,
                width: outcomeWidth,
                height: narrowSlot.height
            )

            self.beforeWindowFrame = nil
            self.beforePaneFrame = nil
            self.outcomes = [
                Self.worklaneAddOutcome(
                    label: "Narrow",
                    windowFrame: narrowWindow,
                    outsideMaxX: narrowSlot.maxX
                ),
                Self.splitOutcome(label: "Wide", windowFrame: wideWindow, includeShrinkArrows: false),
            ]
        case .alwaysSplit:
            let pair = Self.beforeAfterWindows(in: diagramRect, afterWindowScale: 1)
            self.beforeWindowFrame = pair.before
            self.beforePaneFrame = Self.beforePane(in: pair.before)
            self.outcomes = [
                Self.splitOutcome(label: "After", windowFrame: pair.after, includeShrinkArrows: true),
            ]
        case .alwaysAdd:
            let pair = Self.beforeAfterWindows(in: diagramRect, afterWindowScale: 0.64)
            self.beforeWindowFrame = pair.before
            self.beforePaneFrame = Self.beforePane(in: pair.before)
            self.outcomes = [
                Self.worklaneAddOutcome(label: "After", windowFrame: pair.after, outsideMaxX: diagramRect.maxX),
            ]
        }
    }

    private static func beforeAfterWindows(in rect: CGRect, afterWindowScale: CGFloat) -> (before: CGRect, after: CGRect) {
        let gap: CGFloat = 20
        let columnWidth = floor((rect.width - gap) / 2)
        let windowHeight = max(28, rect.height - 17)
        let y = rect.minY + 11
        let before = CGRect(x: rect.minX, y: y, width: columnWidth, height: windowHeight)
        let afterWidth = floor(columnWidth * afterWindowScale)
        let after = CGRect(x: rect.minX + columnWidth + gap, y: y, width: afterWidth, height: windowHeight)
        return (before, after)
    }

    private static func beforePane(in windowFrame: CGRect) -> CGRect {
        windowFrame.insetBy(dx: 5, dy: 6)
    }

    private static func splitOutcome(
        label: String,
        windowFrame: CGRect,
        includeShrinkArrows: Bool
    ) -> Outcome {
        let gap: CGFloat = 4
        let insetWindow = windowFrame.insetBy(dx: 5, dy: 6)
        let paneWidth = max(1, floor((insetWindow.width - gap) / 2))
        let leftPane = CGRect(
            x: insetWindow.minX,
            y: insetWindow.minY,
            width: paneWidth,
            height: insetWindow.height
        )
        let rightPane = CGRect(
            x: leftPane.maxX + gap,
            y: insetWindow.minY,
            width: max(1, insetWindow.maxX - leftPane.maxX - gap),
            height: insetWindow.height
        )
        let centerY = windowFrame.midY
        let shrinkArrows = includeShrinkArrows
            ? [
                Arrow(
                    start: CGPoint(x: windowFrame.minX - 7, y: centerY),
                    end: CGPoint(x: windowFrame.minX + 2, y: centerY)
                ),
                Arrow(
                    start: CGPoint(x: windowFrame.maxX + 7, y: centerY),
                    end: CGPoint(x: windowFrame.maxX - 2, y: centerY)
                ),
            ]
            : []

        return Outcome(
            label: label,
            windowFrame: windowFrame,
            solidPaneFrames: [leftPane, rightPane],
            dottedOutsidePane: nil,
            scrollArrow: nil,
            shrinkArrows: shrinkArrows
        )
    }

    private static func worklaneAddOutcome(
        label: String,
        windowFrame: CGRect,
        outsideMaxX: CGFloat
    ) -> Outcome {
        let pane = Self.beforePane(in: windowFrame)
        let outsideGap: CGFloat = 9
        let outsideWidth = min(
            max(26, windowFrame.width * 0.56),
            max(24, outsideMaxX - windowFrame.maxX - outsideGap)
        )
        let outsidePane = CGRect(
            x: windowFrame.maxX + outsideGap,
            y: pane.minY,
            width: outsideWidth,
            height: pane.height
        )
        let arrowY = windowFrame.maxY + 5
        let scrollArrow: Arrow? = outsidePane.width > 0
            ? Arrow(
                start: CGPoint(x: windowFrame.maxX - 4, y: arrowY),
                end: CGPoint(x: min(outsidePane.midX, outsideMaxX - 4), y: arrowY)
            )
            : nil

        return Outcome(
            label: label,
            windowFrame: windowFrame,
            solidPaneFrames: [pane],
            dottedOutsidePane: DottedPane(frame: outsidePane),
            scrollArrow: scrollArrow,
            shrinkArrows: []
        )
    }
}

@MainActor
final class PaneSplitBehaviorOptionView: NSControl {
    let mode: PaneSplitBehaviorMode

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateAppearance()
        }
    }

    private let previewView: PaneSplitBehaviorPreviewView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField

    init(mode: PaneSplitBehaviorMode, title: String, subtitle: String) {
        self.mode = mode
        self.previewView = PaneSplitBehaviorPreviewView(mode: mode)
        self.titleLabel = NSTextField(labelWithString: title)
        self.subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(previewView)
        previewView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        stackView.addArrangedSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 3
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 184),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseSurfaceColor = isDarkMode
            ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.17, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let selectedBackgroundColor =
            baseSurfaceColor.blended(
                withFraction: isDarkMode ? 0.24 : 0.12,
                of: .controlAccentColor
            ) ?? NSColor.controlAccentColor.withAlphaComponent(isDarkMode ? 0.24 : 0.12)
        let highlightedBackgroundColor =
            baseSurfaceColor.blended(
                withFraction: isDarkMode ? 0.16 : 0.08,
                of: .controlAccentColor
            ) ?? NSColor.controlAccentColor.withAlphaComponent(isDarkMode ? 0.16 : 0.08)

        if isSelected {
            layer?.backgroundColor = resolvedCGColor(selectedBackgroundColor)
            layer?.borderColor = resolvedCGColor(.controlAccentColor)
        } else if isHighlighted {
            layer?.backgroundColor = resolvedCGColor(highlightedBackgroundColor)
            layer?.borderColor = resolvedCGColor(NSColor.controlAccentColor.withAlphaComponent(0.5))
        } else {
            layer?.backgroundColor = resolvedCGColor(baseSurfaceColor)
            layer?.borderColor = resolvedCGColor(isDarkMode
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.12))
        }
        previewView.isSelected = isSelected
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolvedColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB) ?? color
        }
        return resolvedColor.cgColor
    }
}

@MainActor
private final class PaneSplitBehaviorPreviewView: NSView {
    let mode: PaneSplitBehaviorMode

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(mode: PaneSplitBehaviorMode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let layout = PaneSplitBehaviorPreviewLayout(mode: mode, bounds: bounds)
        let accent = NSColor.controlAccentColor
        let solidFill = accent.withAlphaComponent(isSelected ? 0.92 : 0.72)
        let secondaryFill = accent.withAlphaComponent(isSelected ? 0.72 : 0.54)
        let stroke = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        let labelColor = NSColor.secondaryLabelColor.withAlphaComponent(0.85)

        if let beforeWindowFrame = layout.beforeWindowFrame,
           let beforePaneFrame = layout.beforePaneFrame
        {
            drawLabel("Before", above: beforeWindowFrame, color: labelColor)
            drawWindow(beforeWindowFrame, stroke: stroke)
            drawPane(beforePaneFrame, color: solidFill)
        }

        for outcome in layout.outcomes {
            drawLabel(outcome.label, above: outcome.windowFrame, color: labelColor)
            drawWindow(outcome.windowFrame, stroke: stroke)
            for (index, paneFrame) in outcome.solidPaneFrames.enumerated() {
                drawPane(paneFrame, color: index == 0 ? solidFill : secondaryFill)
            }
            if let dottedOutsidePane = outcome.dottedOutsidePane {
                drawDottedPane(dottedOutsidePane.frame, color: accent.withAlphaComponent(isSelected ? 0.9 : 0.7))
            }
            if let scrollArrow = outcome.scrollArrow {
                drawArrow(scrollArrow, color: accent.withAlphaComponent(0.85))
            }
            outcome.shrinkArrows.forEach {
                drawArrow($0, color: stroke)
            }
        }

        if mode == .adaptive,
           let first = layout.outcomes.first,
           let second = layout.outcomes.dropFirst().first
        {
            drawThresholdTick(
                x: (first.windowFrame.maxX + second.windowFrame.minX) / 2,
                yRange: first.windowFrame.minY...first.windowFrame.maxY
            )
        }
    }

    private func drawLabel(_ text: String, above rect: CGRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attributes)
        let point = CGPoint(
            x: rect.midX - (size.width / 2),
            y: max(0, rect.minY - size.height - 3)
        )
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawWindow(_ rect: CGRect, stroke: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.26).setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1.25
        path.stroke()
    }

    private func drawPane(_ rect: CGRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
    }

    private func drawDottedPane(_ rect: CGRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        color.withAlphaComponent(0.08).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    private func drawArrow(_ arrow: PaneSplitBehaviorPreviewLayout.Arrow, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: arrow.start)
        path.line(to: arrow.end)
        color.setStroke()
        path.lineWidth = 1.25
        path.stroke()

        let angle = atan2(arrow.end.y - arrow.start.y, arrow.end.x - arrow.start.x)
        let headLength: CGFloat = 4
        let headAngle: CGFloat = .pi / 6
        let left = CGPoint(
            x: arrow.end.x - headLength * cos(angle - headAngle),
            y: arrow.end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: arrow.end.x - headLength * cos(angle + headAngle),
            y: arrow.end.y - headLength * sin(angle + headAngle)
        )
        let head = NSBezierPath()
        head.move(to: left)
        head.line(to: arrow.end)
        head.line(to: right)
        head.lineWidth = 1.25
        head.stroke()
    }

    private func drawThresholdTick(x: CGFloat, yRange: ClosedRange<CGFloat>) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x, y: yRange.lowerBound - 5))
        path.line(to: CGPoint(x: x, y: yRange.upperBound + 5))
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.setLineDash([2, 2], count: 2, phase: 0)
        path.stroke()
    }
}
