import AppKit

@MainActor
final class KeyboardShortcutPreviewView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 8
        static let rowSpacing: CGFloat = 6
        static let cornerRadius: CGFloat = 7
        static let keyHeightRatio: CGFloat = 0.92
    }

    var model = KeyboardShortcutPreviewModel(
        geometry: .ansi,
        rows: [],
        primaryHighlightedKeyCode: nil,
        modifierHighlightStylesByKeyCode: [:]
    ) {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 182)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard model.rows.isEmpty == false else {
            return
        }

        let bounds = self.bounds.insetBy(dx: Layout.horizontalPadding, dy: Layout.verticalPadding)
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        let rowCount = CGFloat(model.rows.count)
        let rowHeight = max(
            16,
            ((bounds.height - (Layout.rowSpacing * (rowCount - 1))) / rowCount) * Layout.keyHeightRatio
        )
        let maxRowUnits = model.rows.map { rowSpanUnits($0.slots) }.max() ?? 1
        let unitWidth = max(10, bounds.width / maxRowUnits)
        let totalHeight = (rowHeight * rowCount) + (Layout.rowSpacing * (rowCount - 1))
        let startY = bounds.minY + max(0, (bounds.height - totalHeight) / 2)

        for (rowIndex, row) in model.rows.enumerated() {
            let rowWidth = rowSpanUnits(row.slots) * unitWidth
            let startX: CGFloat
            switch row.alignment {
            case .center:
                startX = bounds.minX + max(0, (bounds.width - rowWidth) / 2)
            case .trailing:
                startX = bounds.maxX - rowWidth
            }
            let rowY = startY + (CGFloat(rowIndex) * (rowHeight + Layout.rowSpacing))

            var cursorX = startX
            for (index, key) in row.slots.enumerated() {
                let keyRect = CGRect(x: cursorX, y: rowY, width: key.widthUnits * unitWidth, height: rowHeight)
                if key.isSpacer == false {
                    drawKey(key, in: keyRect)
                }
                cursorX += keyRect.width
                if shouldInsertSpacing(after: index, in: row.slots) {
                    cursorX += KeyboardPreviewLayoutMetrics.interKeySpacingUnits * unitWidth
                }
            }
        }
    }

    private func rowSpanUnits(_ row: [KeyboardPreviewKeySlot]) -> CGFloat {
        guard row.isEmpty == false else {
            return 0
        }

        let widths = row.reduce(CGFloat.zero) { $0 + $1.widthUnits }
        let adjacencyCount = zip(row, row.dropFirst()).reduce(0) { count, pair in
            count + (pair.0.isSpacer == false && pair.1.isSpacer == false ? 1 : 0)
        }

        return widths + (CGFloat(adjacencyCount) * KeyboardPreviewLayoutMetrics.interKeySpacingUnits)
    }

    private func shouldInsertSpacing(after index: Int, in row: [KeyboardPreviewKeySlot]) -> Bool {
        guard index < row.count - 1 else {
            return false
        }

        return row[index].isSpacer == false && row[index + 1].isSpacer == false
    }

    private func drawKey(_ key: KeyboardPreviewKeySlot, in rect: CGRect) {
        let highlightStyle = model.highlightStyle(for: key.keyCode)
        let keyPath = NSBezierPath(roundedRect: rect, xRadius: Layout.cornerRadius, yRadius: Layout.cornerRadius)

        keyFillColor(for: highlightStyle).setFill()
        keyPath.fill()

        keyStrokeColor(for: highlightStyle).setStroke()
        keyPath.lineWidth = strokeWidth(for: highlightStyle)
        keyPath.stroke()

        guard key.label.isEmpty == false else {
            return
        }

        let fontSize = fontSize(for: key.label, keyHeight: rect.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: fontWeight(for: highlightStyle)),
            .foregroundColor: labelColor(for: highlightStyle),
        ]
        let attributedString = NSAttributedString(string: key.label, attributes: attributes)
        let labelSize = attributedString.size()
        let labelRect = CGRect(
            x: rect.midX - (labelSize.width / 2),
            y: rect.midY - (labelSize.height / 2),
            width: labelSize.width,
            height: labelSize.height
        )
        attributedString.draw(in: labelRect)
    }

    private func keyFillColor(for highlightStyle: KeyboardPreviewHighlightStyle) -> NSColor {
        switch highlightStyle {
        case .primary:
            return NSColor.controlAccentColor.withAlphaComponent(0.13)
        case .secondary:
            return NSColor.controlAccentColor.withAlphaComponent(0.07)
        case .none:
            break
        }

        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDarkMode
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.035)
    }

    private func keyStrokeColor(for highlightStyle: KeyboardPreviewHighlightStyle) -> NSColor {
        switch highlightStyle {
        case .primary:
            return NSColor.controlAccentColor.withAlphaComponent(0.92)
        case .secondary:
            return NSColor.controlAccentColor.withAlphaComponent(0.45)
        case .none:
            break
        }

        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDarkMode
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.08)
    }

    private func labelColor(for highlightStyle: KeyboardPreviewHighlightStyle) -> NSColor {
        switch highlightStyle {
        case .primary:
            return .controlAccentColor
        case .secondary:
            return .controlAccentColor.withAlphaComponent(0.65)
        case .none:
            return .secondaryLabelColor
        }
    }

    private func fontWeight(for highlightStyle: KeyboardPreviewHighlightStyle) -> NSFont.Weight {
        switch highlightStyle {
        case .primary:
            .semibold
        case .secondary, .none:
            .medium
        }
    }

    private func strokeWidth(for highlightStyle: KeyboardPreviewHighlightStyle) -> CGFloat {
        switch highlightStyle {
        case .primary:
            2
        case .secondary:
            1.5
        case .none:
            1
        }
    }

    private func fontSize(for label: String, keyHeight: CGFloat) -> CGFloat {
        if label.count >= 5 {
            return max(8, keyHeight * 0.28)
        }
        if label.count >= 3 {
            return max(9, keyHeight * 0.32)
        }
        return max(10, keyHeight * 0.38)
    }
}
