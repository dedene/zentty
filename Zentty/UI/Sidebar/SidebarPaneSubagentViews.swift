import AppKit

enum SidebarSubagentBadgeMetrics {
    static let height: CGFloat = 12
    static let minimumWidth: CGFloat = 12
    static let horizontalPadding: CGFloat = 3.5
    static let spacing: CGFloat = 4
}

/// Inbox-style count badge shown in the pane status line while subagents run.
/// Hover uses the native tooltip; the click is routed by `SidebarPaneRowButton`
/// (which owns hit testing for the whole pane row) through `subagentBadgeFrame`.
@MainActor
final class SidebarSubagentBadgeView: NSView {
    private let label = SidebarStaticLabel()
    private(set) var summary: PaneAgentSubagentSummary?
    private(set) var fillColor: NSColor = .labelColor
    private(set) var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: SidebarSubagentBadgeMetrics.height)
    }

    var preferredWidth: CGFloat {
        guard summary?.isEmpty == false else { return 0 }
        let textWidth = SidebarTextMetrics.measuredWidth(for: label.stringValue, font: Self.font)
        return max(SidebarSubagentBadgeMetrics.minimumWidth, ceil(textWidth) + SidebarSubagentBadgeMetrics.horizontalPadding * 2)
    }

    var badgeTextForTesting: String { label.stringValue }
    var fillColorForTesting: NSColor { fillColor }

    private static let font: NSFont = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)

    private func setup() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = Self.font
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
        ])
        setAccessibilityRole(.button)
        isHidden = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func configure(summary: PaneAgentSubagentSummary?, isExpanded: Bool) {
        self.summary = summary
        self.isExpanded = isExpanded
        guard let summary, !summary.isEmpty else {
            isHidden = true
            toolTip = nil
            label.stringValue = ""
            setAccessibilityLabel("")
            invalidateIntrinsicContentSize()
            return
        }

        label.stringValue = summary.badgeText
        toolTip = summary.tooltipText
        setAccessibilityLabel(summary.accessibilityText)
        isHidden = false
        applyColors()
        invalidateIntrinsicContentSize()
    }

    func applyFillColor(_ color: NSColor) {
        fillColor = color
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = fillColor.cgColor
        label.textColor = Self.contrastingTextColor(for: fillColor)
        layer?.borderWidth = isExpanded ? 1.5 : 0
        layer?.borderColor = fillColor.withAlphaComponent(0.35).cgColor
    }

    private static func contrastingTextColor(for fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }
}

/// Quote-style list of running subagents grouped by model and agent type,
/// rendered under the pane status line once the badge is clicked.
///
///     │ 2 × opus   general-purpose
///     │ 1 × sonnet codex-review
@MainActor
final class SidebarPaneSubagentListView: NSView {
    private enum Layout {
        static let ruleWidth: CGFloat = 2
        static let ruleSpacing: CGFloat = 8
        static let columnSpacing: CGFloat = 5
    }

    private struct LineViews {
        let count: SidebarStaticLabel
        let model: SidebarStaticLabel
        let detail: SidebarStaticLabel
    }

    private let ruleView = NSView()
    private var lines: [LineViews] = []
    private(set) var groups: [PaneAgentSubagentGroup] = []
    private var primaryColor: NSColor = .labelColor
    private var secondaryColor: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func height(forGroupCount count: Int) -> CGFloat {
        CGFloat(max(1, count)) * ShellMetrics.sidebarDetailLineHeight
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(forGroupCount: groups.count))
    }

    override func layout() {
        super.layout()
        layoutLines()
    }

    var lineTextsForTesting: [String] {
        lines.prefix(groups.count).map { line in
            [line.count.stringValue, line.model.stringValue, line.detail.stringValue]
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        ruleView.wantsLayer = true
        ruleView.layer?.cornerRadius = Layout.ruleWidth / 2
        addSubview(ruleView)
        isHidden = true
    }

    func configure(summary: PaneAgentSubagentSummary?) {
        groups = summary?.groups ?? []
        ensureCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let line = lines[index]
            line.count.stringValue = group.leadingText
            line.model.stringValue = group.modelText
            line.detail.stringValue = group.trailingText ?? ""
            line.count.isHidden = false
            line.model.isHidden = false
            line.detail.isHidden = line.detail.stringValue.isEmpty
        }
        for line in lines.dropFirst(groups.count) {
            line.count.isHidden = true
            line.model.isHidden = true
            line.detail.isHidden = true
        }
        isHidden = groups.isEmpty
        setAccessibilityLabel(summary?.accessibilityText ?? "")
        applyColors()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyColors(primary: NSColor, secondary: NSColor) {
        primaryColor = primary
        secondaryColor = secondary
        applyColors()
    }

    private func applyColors() {
        ruleView.layer?.backgroundColor = secondaryColor.withAlphaComponent(0.35).cgColor
        for line in lines {
            line.count.textColor = primaryColor
            line.model.textColor = primaryColor
            line.detail.textColor = secondaryColor
        }
    }

    private func ensureCapacity(_ count: Int) {
        while lines.count < count {
            let countLabel = makeLabel(font: .monospacedDigitSystemFont(ofSize: ShellMetrics.sidebarDetailFont().pointSize, weight: .medium))
            let modelLabel = makeLabel(font: ShellMetrics.sidebarDetailFont())
            let detailLabel = makeLabel(font: ShellMetrics.sidebarDetailFont())
            detailLabel.lineBreakMode = .byTruncatingTail
            lines.append(LineViews(count: countLabel, model: modelLabel, detail: detailLabel))
        }
    }

    private func makeLabel(font: NSFont) -> SidebarStaticLabel {
        let label = SidebarStaticLabel()
        label.font = font
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        return label
    }

    private func layoutLines() {
        let lineHeight = ShellMetrics.sidebarDetailLineHeight
        ruleView.frame = NSRect(x: 0, y: 1, width: Layout.ruleWidth, height: max(0, bounds.height - 2))
        let leading = Layout.ruleWidth + Layout.ruleSpacing
        let countWidth = lines.prefix(groups.count)
            .map { SidebarTextMetrics.measuredWidth(for: $0.count.stringValue, font: $0.count.font ?? ShellMetrics.sidebarDetailFont()) }
            .max() ?? 0

        for (index, line) in lines.prefix(groups.count).enumerated() {
            // Flipped coordinates are not used here: first group sits at the top.
            let y = bounds.height - lineHeight * CGFloat(index + 1)
            var x = leading
            line.count.frame = NSRect(x: x, y: y, width: ceil(countWidth), height: lineHeight)
            x += ceil(countWidth) + Layout.columnSpacing
            let modelWidth = ceil(SidebarTextMetrics.measuredWidth(for: line.model.stringValue, font: line.model.font ?? ShellMetrics.sidebarDetailFont()))
            let availableModelWidth = max(0, bounds.width - x)
            line.model.frame = NSRect(x: x, y: y, width: min(modelWidth, availableModelWidth), height: lineHeight)
            x += min(modelWidth, availableModelWidth) + Layout.columnSpacing
            line.detail.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x), height: lineHeight)
        }
    }
}
