import AppKit

@MainActor
final class WorklaneColorMenuItemView: NSView {
    private enum Metric {
        static let swatchDiameter: CGFloat = 18
        static let swatchSpacing: CGFloat = 10
        static let gridHorizontalInset: CGFloat = 14
        static let gridVerticalInset: CGFloat = 12
        static let columns = 6
        static let rows = 2
        static let separatorHeight: CGFloat = 1
        static let resetRowHeight: CGFloat = 28
        static let resetHorizontalInset: CGFloat = 12
        static let resetIconSize: CGFloat = 14
        static let resetIconTextSpacing: CGFloat = 8
    }

    private let onPick: (WorklaneColor?) -> Void
    private var currentColor: WorklaneColor?
    private var swatches: [WorklaneColorSwatchView] = []
    private let separator = NSBox()
    private let resetRow = WorklaneColorResetRowView()
    private var focusedIndex: Int = 0
    private var hasFocusedOnReset: Bool = false
    private var userHasNavigated: Bool = false

    init(current: WorklaneColor?, onPick: @escaping (WorklaneColor?) -> Void) {
        self.currentColor = current
        self.onPick = onPick

        let gridWidth = Metric.gridHorizontalInset * 2
            + CGFloat(Metric.columns) * Metric.swatchDiameter
            + CGFloat(Metric.columns - 1) * Metric.swatchSpacing
        let gridHeight = Metric.gridVerticalInset * 2
            + CGFloat(Metric.rows) * Metric.swatchDiameter
            + CGFloat(Metric.rows - 1) * Metric.swatchSpacing
        let totalHeight = gridHeight + Metric.separatorHeight + Metric.resetRowHeight

        super.init(frame: NSRect(x: 0, y: 0, width: gridWidth, height: totalHeight))
        autoresizingMask = [.width]

        configureSwatches(in: CGRect(x: 0, y: Metric.separatorHeight + Metric.resetRowHeight, width: gridWidth, height: gridHeight))
        configureSeparator(gridWidth: gridWidth)
        configureResetRow(gridWidth: gridWidth)

        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(NSLocalizedString("Worklane color", comment: "Accessibility label for color picker"))

        focusedIndex = swatches.firstIndex { $0.color == current } ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasFocusedOnReset = false
        userHasNavigated = false
        for swatch in swatches {
            swatch.isFocused = false
        }
        resetRow.isFocused = false
        refreshFocusIndicator()
        window?.makeFirstResponder(self)
    }

    // MARK: - Layout

    private func configureSwatches(in rect: CGRect) {
        let startX = rect.minX + Metric.gridHorizontalInset
        let startY = rect.maxY - Metric.gridVerticalInset - Metric.swatchDiameter

        for (index, color) in WorklaneColor.allCases.enumerated() {
            let row = index / Metric.columns
            let column = index % Metric.columns
            let x = startX + CGFloat(column) * (Metric.swatchDiameter + Metric.swatchSpacing)
            let y = startY - CGFloat(row) * (Metric.swatchDiameter + Metric.swatchSpacing)
            let swatch = WorklaneColorSwatchView(
                color: color,
                frame: NSRect(x: x, y: y, width: Metric.swatchDiameter, height: Metric.swatchDiameter)
            )
            swatch.isCurrent = (color == currentColor)
            swatch.onClick = { [weak self] pickedColor in
                self?.commit(color: pickedColor)
            }
            addSubview(swatch)
            swatches.append(swatch)
        }
    }

    private func configureSeparator(gridWidth: CGFloat) {
        separator.boxType = .separator
        separator.frame = NSRect(
            x: 0,
            y: Metric.resetRowHeight,
            width: gridWidth,
            height: Metric.separatorHeight
        )
        separator.autoresizingMask = [.width]
        addSubview(separator)
    }

    private func configureResetRow(gridWidth: CGFloat) {
        resetRow.frame = NSRect(x: 0, y: 0, width: gridWidth, height: Metric.resetRowHeight)
        resetRow.autoresizingMask = [.width]
        resetRow.onClick = { [weak self] in
            self?.commit(color: nil)
        }
        addSubview(resetRow)
    }

    // MARK: - Actions

    private func commit(color: WorklaneColor?) {
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(color)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // left arrow
            userHasNavigated = true
            moveFocus(deltaColumn: -1, deltaRow: 0)
        case 124: // right arrow
            userHasNavigated = true
            moveFocus(deltaColumn: 1, deltaRow: 0)
        case 126: // up arrow
            userHasNavigated = true
            moveFocus(deltaColumn: 0, deltaRow: -1)
        case 125: // down arrow
            userHasNavigated = true
            moveFocus(deltaColumn: 0, deltaRow: 1)
        case 48: // tab and backTab
            userHasNavigated = true
            hasFocusedOnReset.toggle()
            refreshFocusIndicator()
        case 36, 76: // return and enter
            commitFocused()
        default:
            if event.charactersIgnoringModifiers == " " {
                commitFocused()
                return
            }
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        enclosingMenuItem?.menu?.cancelTracking()
    }

    private func moveFocus(deltaColumn: Int, deltaRow: Int) {
        if hasFocusedOnReset {
            if deltaRow == -1 {
                hasFocusedOnReset = false
                focusedIndex = max(0, min(swatches.count - 1, focusedIndex))
                refreshFocusIndicator()
            }
            return
        }

        let currentRow = focusedIndex / Metric.columns
        let currentColumn = focusedIndex % Metric.columns
        let newRow = currentRow + deltaRow
        let newColumn = currentColumn + deltaColumn

        if newRow >= Metric.rows {
            hasFocusedOnReset = true
            refreshFocusIndicator()
            return
        }

        guard newRow >= 0, newColumn >= 0, newColumn < Metric.columns else { return }
        let candidate = newRow * Metric.columns + newColumn
        guard candidate >= 0, candidate < swatches.count else { return }
        focusedIndex = candidate
        refreshFocusIndicator()
    }

    private func commitFocused() {
        if hasFocusedOnReset {
            commit(color: nil)
        } else if focusedIndex < swatches.count {
            commit(color: swatches[focusedIndex].color)
        }
    }

    private func refreshFocusIndicator() {
        for (index, swatch) in swatches.enumerated() {
            swatch.isFocused = userHasNavigated && !hasFocusedOnReset && index == focusedIndex
        }
        resetRow.isFocused = userHasNavigated && hasFocusedOnReset
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = swatches
        children.append(resetRow)
        return children
    }
}

@MainActor
final class WorklaneColorSwatchView: NSView {
    let color: WorklaneColor
    var isCurrent: Bool = false {
        didSet { needsDisplay = true }
    }
    var isFocused: Bool = false {
        didSet { needsDisplay = true }
    }
    var isHovered: Bool = false {
        didSet { needsDisplay = true }
    }
    var onClick: ((WorklaneColor) -> Void)?

    private var trackingArea: NSTrackingArea?

    init(color: WorklaneColor, frame: NSRect) {
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
        toolTip = color.localizedName
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(color.localizedName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityValue() -> Any? {
        isCurrent ? NSNumber(value: 1) : NSNumber(value: 0)
    }

    override var wantsUpdateLayer: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(color)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fillColor = color.tint(alpha: 1.0)
        let highlighted = isHovered || isFocused
        let scale: CGFloat = highlighted ? 1.08 : 1.0
        let radius = (bounds.width / 2) * scale
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))

        fillColor.setFill()
        path.fill()

        if isCurrent {
            let halo = NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2))
            NSColor.keyboardFocusIndicatorColor.setStroke()
            halo.lineWidth = 1.5
            halo.stroke()
        } else if isHovered || isFocused {
            let glow = NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5))
            fillColor.withAlphaComponent(0.35).setStroke()
            glow.lineWidth = 1.5
            glow.stroke()
        }
    }
}

@MainActor
final class WorklaneColorResetRowView: NSView {
    var onClick: (() -> Void)?
    var isFocused: Bool = false {
        didSet { needsDisplay = true }
    }
    var isHovered: Bool = false {
        didSet { needsDisplay = true }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: NSLocalizedString("Reset to Default", comment: "Worklane color reset"))
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label.stringValue)

        let symbol = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        iconView.image = symbol
        iconView.contentTintColor = NSColor.labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = NSColor.labelColor
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isFocused || isHovered {
            NSColor.selectedMenuItemColor.withAlphaComponent(isFocused ? 0.35 : 0.18).setFill()
            dirtyRect.fill()
        }
    }
}
