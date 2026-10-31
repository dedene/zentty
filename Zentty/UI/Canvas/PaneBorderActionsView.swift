import AppKit

/// Which chrome a `PaneContainerView` wears: a strip tile, a float, or a PiP.
enum PaneChromeKind: Equatable, Sendable {
    case tile
    case float
    case pip
}

/// The icon buttons of a pane's right legend (on the top border line).
enum PaneBorderAction: String, Equatable, Sendable, CaseIterable {
    case float
    case pip
    case minimize
    case dock
    case restore
    case close

    var symbolName: String {
        switch self {
        case .float, .restore: "rectangle.on.rectangle"
        case .pip: "pip.enter"
        case .minimize: "minus"
        case .dock: "rectangle.split.3x1"
        case .close: "xmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .float: "Float pane"
        case .pip: "Picture in picture"
        case .minimize: "Minimize"
        case .dock: "Dock into layout"
        case .restore: "Restore float"
        case .close: "Close pane"
        }
    }

    /// Command whose shortcut the tooltip shows.
    var commandID: AppCommandID? {
        switch self {
        case .float, .dock: .toggleFloat
        case .close: .closeFocusedPane
        case .pip: .pipFloat
        case .minimize: .minimizeFloat
        case .restore: nil
        }
    }
}

/// Pure geometry and visibility rules for the right legend.
enum PaneBorderActionsLayout {
    static let buttonSize = CGSize(width: 20, height: 16)
    static let spacing: CGFloat = 2
    /// Distance from the pane's trailing edge to the last button (mirrors the
    /// left legend's leading inset).
    static let trailingInset: CGFloat = 24
    /// Border cut on each side of the buttons.
    static let gapPadding: CGFloat = 2
    /// Room kept between the left legend and the buttons.
    static let legendSpacing: CGFloat = 8
    /// Narrowest left legend worth keeping next to the buttons. A tile too
    /// narrow for both keeps its legend and drops the buttons.
    static let minimumLegendWidth: CGFloat = 80

    static func actions(for kind: PaneChromeKind) -> [PaneBorderAction] {
        switch kind {
        case .tile: [.float, .close]
        case .float: [.pip, .minimize, .dock, .close]
        case .pip: [.restore, .minimize, .close]
        }
    }

    static func isVisible(kind: PaneChromeKind, isHovered: Bool, isFocused: Bool) -> Bool {
        switch kind {
        case .tile: isHovered || isFocused
        case .float: true
        case .pip: isHovered
        }
    }

    static func size(for actions: [PaneBorderAction]) -> CGSize {
        guard !actions.isEmpty else { return .zero }
        let count = CGFloat(actions.count)
        return CGSize(
            width: count * buttonSize.width + (count - 1) * spacing,
            height: buttonSize.height
        )
    }

    /// Right-aligned on the border, vertically centred on its top line
    /// (`borderFrame` is the inset border layer's frame, y-up).
    static func frame(size: CGSize, borderFrame: CGRect, borderInset: CGFloat, strokeWidth: CGFloat) -> CGRect {
        let borderLineY = borderFrame.maxY - (strokeWidth / 2)
        let maxX = borderFrame.maxX - (trailingInset - borderInset)
        return CGRect(
            x: maxX - size.width,
            y: borderLineY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    /// Width a pane needs to show `actions` without starving the left legend.
    static func minimumPaneWidth(for actions: [PaneBorderAction]) -> CGFloat {
        PaneBorderContextInsetView.Layout.paneContextLeadingInset
            + minimumLegendWidth
            + legendSpacing
            + size(for: actions).width
            + trailingInset
    }
}

/// The right legend: a row of borderless symbol buttons, muted until hover.
@MainActor
final class PaneBorderActionsView: NSView {
    var onAction: ((PaneBorderAction) -> Void)?

    private var buttons: [PaneBorderAction: PaneBorderActionButton] = [:]
    private var renderedActions: [PaneBorderAction] = []
    private var shortcutManager = ShortcutManager(shortcuts: .default)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane actions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// Clicks between buttons stop here instead of reaching the terminal.
    override func mouseDown(with event: NSEvent) {}

    func render(actions: [PaneBorderAction], isFocused: Bool, theme: ZenttyTheme) {
        if actions != renderedActions {
            rebuild(actions)
        }
        let idleTint = (isFocused ? theme.paneBorderFocused : theme.paneBorderUnfocused).brightenedForLabel
        for (index, action) in actions.enumerated() {
            guard let button = buttons[action] else { continue }
            button.frame = CGRect(
                x: CGFloat(index) * (PaneBorderActionsLayout.buttonSize.width + PaneBorderActionsLayout.spacing),
                y: 0,
                width: PaneBorderActionsLayout.buttonSize.width,
                height: PaneBorderActionsLayout.buttonSize.height
            )
            button.idleTint = idleTint
            button.hoverTint = theme.primaryText
        }
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        buttons.forEach { action, button in
            button.toolTip = tooltip(for: action)
        }
    }

    func buttonForTesting(_ action: PaneBorderAction) -> NSButton? {
        buttons[action]
    }

    private func rebuild(_ actions: [PaneBorderAction]) {
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons = [:]
        renderedActions = actions
        for action in actions {
            let button = PaneBorderActionButton(action: action)
            button.target = self
            button.action = #selector(handleButton(_:))
            button.toolTip = tooltip(for: action)
            addSubview(button)
            buttons[action] = button
        }
    }

    private func tooltip(for action: PaneBorderAction) -> String {
        guard let commandID = action.commandID else {
            return action.accessibilityLabel
        }
        return CommandTooltipFormatter.title(
            action.accessibilityLabel,
            commandID: commandID,
            shortcutManager: shortcutManager
        )
    }

    @objc private func handleButton(_ sender: NSButton) {
        guard let button = sender as? PaneBorderActionButton else { return }
        onAction?(button.borderAction)
    }
}

/// Borderless symbol button that brightens while the pointer is over it.
@MainActor
private final class PaneBorderActionButton: NSButton {
    let borderAction: PaneBorderAction
    var idleTint: NSColor = .secondaryLabelColor {
        didSet { applyTint() }
    }
    var hoverTint: NSColor = .labelColor {
        didSet { applyTint() }
    }
    private var isPointerInside = false
    private var hoverArea: NSTrackingArea?

    init(action: PaneBorderAction) {
        self.borderAction = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        focusRingType = .none
        title = ""
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        image = (NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.accessibilityLabel)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: action.accessibilityLabel))?
            .withSymbolConfiguration(configuration)
        setAccessibilityLabel(action.accessibilityLabel)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerInside = true
        applyTint()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        applyTint()
    }

    private func applyTint() {
        contentTintColor = isPointerInside ? hoverTint : idleTint
    }
}
