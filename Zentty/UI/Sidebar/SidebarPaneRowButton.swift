import AppKit

// MARK: - View Helpers

extension NSView {
    func containsDescendant(_ candidate: NSView) -> Bool {
        if self === candidate {
            return true
        }

        return subviews.contains { $0.containsDescendant(candidate) }
    }
}

// MARK: - Sidebar Context Menus

enum SidebarWorklaneMoveDirection: Equatable {
    case up
    case down

    var delta: Int {
        switch self {
        case .up:
            return -1
        case .down:
            return 1
        }
    }

    var title: String {
        switch self {
        case .up:
            return "Move Worklane Up"
        case .down:
            return "Move Worklane Down"
        }
    }

    var symbolName: String {
        switch self {
        case .up:
            return "arrow.up"
        case .down:
            return "arrow.down"
        }
    }
}

struct SidebarWorklaneMoveAvailability: Equatable {
    var canMoveUp: Bool
    var canMoveDown: Bool

    static let none = SidebarWorklaneMoveAvailability(canMoveUp: false, canMoveDown: false)
}

@MainActor
enum SidebarContextMenu {
    static func item(
        title: String,
        action: Selector?,
        target: AnyObject?,
        symbolName: String,
        fallbackSymbolName: String? = nil,
        accessibilityDescription: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = symbolImage(
            named: symbolName,
            fallbackName: fallbackSymbolName,
            accessibilityDescription: accessibilityDescription ?? title
        )
        return item
    }

    static func addMoveItems(
        to menu: NSMenu,
        availability: SidebarWorklaneMoveAvailability,
        target: AnyObject,
        moveUpAction: Selector,
        moveDownAction: Selector
    ) {
        if availability.canMoveUp {
            menu.addItem(
                item(
                    title: SidebarWorklaneMoveDirection.up.title,
                    action: moveUpAction,
                    target: target,
                    symbolName: SidebarWorklaneMoveDirection.up.symbolName
                )
            )
        }

        if availability.canMoveDown {
            menu.addItem(
                item(
                    title: SidebarWorklaneMoveDirection.down.title,
                    action: moveDownAction,
                    target: target,
                    symbolName: SidebarWorklaneMoveDirection.down.symbolName
                )
            )
        }
    }

    static func addSeparatorIfNeeded(to menu: NSMenu) {
        guard let lastItem = menu.items.last, !lastItem.isSeparatorItem else {
            return
        }

        menu.addItem(NSMenuItem.separator())
    }

    private static func symbolImage(
        named symbolName: String,
        fallbackName: String?,
        accessibilityDescription: String
    ) -> NSImage? {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            ?? fallbackName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: accessibilityDescription)
            }

        return image?.withSymbolConfiguration(symbolConfiguration) ?? image
    }
}

// MARK: - SidebarInsetContainerView

final class SidebarInsetContainerView: NSView {
    private weak var referenceWidthView: NSView?
    private var widthConstraint: NSLayoutConstraint?

    init(contentView: NSView, horizontalInset: CGFloat, referenceWidthView: NSView) {
        self.referenceWidthView = referenceWidthView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        widthConstraint?.isActive = false
        widthConstraint = nil

        guard superview != nil, let referenceWidthView else {
            return
        }

        let widthConstraint = widthAnchor.constraint(equalTo: referenceWidthView.widthAnchor)
        widthConstraint.isActive = true
        self.widthConstraint = widthConstraint
    }

    var hasActiveWidthConstraintForTesting: Bool {
        widthConstraint?.isActive == true
    }
}

// MARK: - SidebarPaneRowButton

@MainActor
final class SidebarPaneRowButton: NSButton {
    var paneID = PaneID("")
    var isLastPaneInWorklane = false
    var currentWorklaneColor: WorklaneColor?
    var onPaneClicked: ((PaneID) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCloseWorklane: ((PaneID) -> Void)?
    var onClosePane: ((PaneID) -> Void)?
    var onSplitHorizontal: ((PaneID) -> Void)?
    var onSplitVertical: ((PaneID) -> Void)?
    var onPickWorklaneColor: ((PaneID, WorklaneColor?) -> Void)?
    var onWorklaneDragRequested: ((NSEvent) -> Bool)?
    var onMoveWorklane: ((SidebarWorklaneMoveDirection) -> Void)?
    var worklaneMoveAvailability: SidebarWorklaneMoveAvailability = .none

    private var activeContextPicker: WorklaneColorMenuItemView?

    private let contentStack = NSStackView()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var hoverBackgroundColor: NSColor = .clear
    private var pressedBackgroundColor: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        wantsLayer = true
        layer?.cornerRadius = ShellMetrics.sidebarPaneButtonCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        contentStack.orientation = .vertical
        contentStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: topAnchor, constant: ShellMetrics.sidebarPaneButtonVerticalInset),
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: ShellMetrics.sidebarPaneButtonHorizontalInset),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -ShellMetrics.sidebarPaneButtonHorizontalInset),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -ShellMetrics.sidebarPaneButtonVerticalInset),
        ])

        target = self
        action = #selector(handleClick)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let pointInSelf = convert(point, from: superview)
        return bounds.contains(pointInSelf) ? self : nil
    }

    @objc private func handleClick() {
        onPaneClicked?(paneID)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, onWorklaneDragRequested != nil else {
            super.mouseDown(with: event)
            return
        }

        SidebarWorklaneDragGestureTracker.track(
            from: self,
            event: event,
            beginDrag: { [weak self] dragEvent in
                self?.onWorklaneDragRequested?(dragEvent) ?? false
            },
            click: { [weak self] in
                guard let self else { return }
                self.onPaneClicked?(self.paneID)
            }
        )
    }

    func setContent(_ views: [NSView]) {
        contentStack.setViews(views, in: .top)
    }

    func updateTheme(hoverColor: NSColor, pressedColor: NSColor) {
        hoverBackgroundColor = hoverColor
        pressedBackgroundColor = pressedColor
        updateHoverAppearance()
    }

    var contentMinXForTesting: CGFloat {
        contentStack.frame.minX
    }

    var contentMaxTrailingInsetForTesting: CGFloat {
        bounds.maxX - contentStack.frame.maxX
    }

    var contentMinYForTesting: CGFloat {
        contentStack.frame.minY
    }

    var contentMaxTopInsetForTesting: CGFloat {
        bounds.maxY - contentStack.frame.maxY
    }

    var cornerRadiusForTesting: CGFloat {
        layer?.cornerRadius ?? 0
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverAppearance()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverAppearance()
        onHoverChanged?(false)
    }

    override var isHighlighted: Bool {
        didSet {
            updateHoverAppearance()
        }
    }

    private func updateHoverAppearance() {
        let color: NSColor
        if isHighlighted {
            color = pressedBackgroundColor
        } else if isHovered {
            color = hoverBackgroundColor
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let closeWorklaneItem = SidebarContextMenu.item(
            title: "Close Worklane",
            action: #selector(handleCloseWorklane),
            target: self,
            symbolName: "rectangle.stack.badge.minus",
            fallbackSymbolName: "xmark.circle"
        )
        menu.addItem(closeWorklaneItem)

        if !isLastPaneInWorklane {
            let closePaneItem = SidebarContextMenu.item(
                title: "Close Pane",
                action: #selector(handleClosePane),
                target: self,
                symbolName: "rectangle.badge.minus",
                fallbackSymbolName: "xmark.square"
            )
            menu.addItem(closePaneItem)
        }

        SidebarContextMenu.addSeparatorIfNeeded(to: menu)
        SidebarContextMenu.addMoveItems(
            to: menu,
            availability: worklaneMoveAvailability,
            target: self,
            moveUpAction: #selector(handleMoveWorklaneUp),
            moveDownAction: #selector(handleMoveWorklaneDown)
        )

        let worklaneColorItem = SidebarContextMenu.item(
            title: "Worklane Color",
            action: nil,
            target: nil,
            symbolName: "paintpalette"
        )
        let worklaneColorSubmenu = NSMenu()
        let pickerItem = NSMenuItem()
        let picker = WorklaneColorMenuItemView(current: currentWorklaneColor) { [weak self] color in
            guard let self else { return }
            self.onPickWorklaneColor?(self.paneID, color)
        }
        pickerItem.view = picker
        worklaneColorSubmenu.addItem(pickerItem)
        worklaneColorItem.submenu = worklaneColorSubmenu
        menu.addItem(worklaneColorItem)
        activeContextPicker = picker

        SidebarContextMenu.addSeparatorIfNeeded(to: menu)

        let splitHItem = SidebarContextMenu.item(
            title: "Split Horizontal",
            action: #selector(handleSplitHorizontal),
            target: self,
            symbolName: "rectangle.split.2x1"
        )
        menu.addItem(splitHItem)

        let splitVItem = SidebarContextMenu.item(
            title: "Split Vertical",
            action: #selector(handleSplitVertical),
            target: self,
            symbolName: "rectangle.split.1x2"
        )
        menu.addItem(splitVItem)

        return menu
    }

    @objc private func handleCloseWorklane() {
        onCloseWorklane?(paneID)
    }

    @objc private func handleClosePane() {
        onClosePane?(paneID)
    }

    @objc private func handleMoveWorklaneUp() {
        onMoveWorklane?(.up)
    }

    @objc private func handleMoveWorklaneDown() {
        onMoveWorklane?(.down)
    }

    @objc private func handleSplitHorizontal() {
        onSplitHorizontal?(paneID)
    }

    @objc private func handleSplitVertical() {
        onSplitVertical?(paneID)
    }
}
