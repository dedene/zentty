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

enum SidebarWorklaneContextMenuOrigin: Equatable {
    case worklane
    case paneRow(isLastPaneInWorklane: Bool)
}

struct SidebarWorklaneContextMenuContext {
    var origin: SidebarWorklaneContextMenuOrigin
    var moveAvailability: SidebarWorklaneMoveAvailability
    var worklaneColor: WorklaneColor?
    var bookmarkOriginID: UUID?
    var bookmarkName: String?
    var isOnlyWorklane: Bool
    var rightPaneCommandPresentation: PaneRightCommandPresentation = .addsToWorklane
    var moveToWorklaneCatalog: WorklaneDestinationCatalog?
    var paneID: PaneID?
}

struct SidebarWorklaneContextMenuActions {
    var target: AnyObject
    var closeWorklaneAction: Selector
    var closePaneAction: Selector?
    var moveUpAction: Selector
    var moveDownAction: Selector
    var splitHorizontalAction: Selector?
    var splitVerticalAction: Selector?
    var forceSplitRightAction: Selector?
    var forceAddPaneRightAction: Selector?
    var movePaneToNewWindowAction: Selector?
    var bookmarkAction: Selector
    var colorChanged: (WorklaneColor?) -> Void
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

@MainActor
enum SidebarWorklaneContextMenu {
    struct Result {
        var menu: NSMenu
        var activePicker: WorklaneColorMenuItemView?
    }

    static func makeMenu(
        context: SidebarWorklaneContextMenuContext,
        actions: SidebarWorklaneContextMenuActions
    ) -> Result {
        let menu = NSMenu()

        menu.addItem(
            SidebarContextMenu.item(
                title: "Close Worklane",
                action: actions.closeWorklaneAction,
                target: actions.target,
                symbolName: "rectangle.stack.badge.minus",
                fallbackSymbolName: "xmark.circle"
            )
        )

        if case .paneRow(let isLastPaneInWorklane) = context.origin,
           !isLastPaneInWorklane,
           let closePaneAction = actions.closePaneAction
        {
            menu.addItem(
                SidebarContextMenu.item(
                    title: "Close Pane",
                    action: closePaneAction,
                    target: actions.target,
                    symbolName: "rectangle.badge.minus",
                    fallbackSymbolName: "xmark.square"
                )
            )
        }

        SidebarContextMenu.addSeparatorIfNeeded(to: menu)
        SidebarContextMenu.addMoveItems(
            to: menu,
            availability: context.moveAvailability,
            target: actions.target,
            moveUpAction: actions.moveUpAction,
            moveDownAction: actions.moveDownAction
        )

        let picker = addColorItem(
            to: menu,
            currentColor: context.worklaneColor,
            colorChanged: actions.colorChanged
        )

        addBookmarkItems(
            to: menu,
            originID: context.bookmarkOriginID,
            bookmarkName: context.bookmarkName,
            target: actions.target,
            bookmarkAction: actions.bookmarkAction
        )

        if case let .paneRow(isLastPaneInWorklane) = context.origin,
           let splitHorizontalAction = actions.splitHorizontalAction,
           let splitVerticalAction = actions.splitVerticalAction
        {
            SidebarContextMenu.addSeparatorIfNeeded(to: menu)
            let rightPaneCommandPresentation = context.rightPaneCommandPresentation
            menu.addItem(
                SidebarContextMenu.item(
                    title: rightPaneCommandPresentation.primaryTitle,
                    action: splitHorizontalAction,
                    target: actions.target,
                    symbolName: "rectangle.split.2x1"
                )
            )
            menu.addItem(
                SidebarContextMenu.item(
                    title: "New Pane Below",
                    action: splitVerticalAction,
                    target: actions.target,
                    symbolName: "rectangle.split.1x2"
                )
            )
            if let forceRightAction = rightPaneCommandPresentation.sidebarForceAction(from: actions) {
                menu.addItem(
                    SidebarContextMenu.item(
                        title: rightPaneCommandPresentation.forceOppositeTitle,
                        action: forceRightAction,
                        target: actions.target,
                        symbolName: "arrow.right.square",
                        fallbackSymbolName: "rectangle.split.2x1"
                    )
                )
            }

            if let movePaneToNewWindowAction = actions.movePaneToNewWindowAction {
                SidebarContextMenu.addSeparatorIfNeeded(to: menu)
                let moveToWindowItem = SidebarContextMenu.item(
                    title: "Move Pane to New Window",
                    action: movePaneToNewWindowAction,
                    target: actions.target,
                    symbolName: "macwindow.badge.plus",
                    fallbackSymbolName: "macwindow"
                )
                moveToWindowItem.isEnabled = !(context.isOnlyWorklane && isLastPaneInWorklane)
                menu.addItem(moveToWindowItem)

                if let catalog = context.moveToWorklaneCatalog,
                   catalog.hasAnyDestination,
                   let paneID = context.paneID {
                    let parentItem = NSMenuItem(
                        title: "Move Pane to Worklane",
                        action: nil,
                        keyEquivalent: ""
                    )
                    parentItem.image = NSImage(systemSymbolName: "rectangle.stack",
                                               accessibilityDescription: "Move Pane to Worklane")?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
                    parentItem.submenu = MoveToWorklaneMenuBuilder.makeSubmenu(
                        catalog: catalog,
                        paneID: paneID
                    )
                    menu.addItem(parentItem)
                }
            }
        }

        return Result(menu: menu, activePicker: picker)
    }

    private static func addColorItem(
        to menu: NSMenu,
        currentColor: WorklaneColor?,
        colorChanged: @escaping (WorklaneColor?) -> Void
    ) -> WorklaneColorMenuItemView {
        let parent = SidebarContextMenu.item(
            title: "Worklane Color",
            action: nil,
            target: nil,
            symbolName: "paintpalette"
        )
        let submenu = NSMenu()
        let pickerItem = NSMenuItem()
        let picker = WorklaneColorMenuItemView(current: currentColor) { picked in
            colorChanged(picked)
        }
        pickerItem.view = picker
        submenu.addItem(pickerItem)
        parent.submenu = submenu
        menu.addItem(parent)
        return picker
    }

    private static func addBookmarkItems(
        to menu: NSMenu,
        originID: UUID?,
        bookmarkName: String?,
        target: AnyObject,
        bookmarkAction: Selector
    ) {
        SidebarContextMenu.addSeparatorIfNeeded(to: menu)
        let displayName = bookmarkName.map { "\u{201C}\($0)\u{201D}" }

        if let originID, let displayName {
            menu.addItem(
                bookmarkMenuItem(
                    title: "Update Bookmark \(displayName)",
                    symbolName: "arrow.clockwise",
                    action: .updateBookmark(originID),
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
            menu.addItem(
                bookmarkMenuItem(
                    title: "Edit Bookmark \(displayName)\u{2026}",
                    symbolName: "pencil",
                    action: .editBookmark(originID),
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
            menu.addItem(
                bookmarkMenuItem(
                    title: "Save as New Bookmark\u{2026}",
                    symbolName: "bookmark.circle",
                    action: .saveAsNewBookmark,
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
            menu.addItem(
                bookmarkMenuItem(
                    title: "Save as Preset\u{2026}",
                    symbolName: "rectangle.stack.badge.plus",
                    action: .saveAsPreset,
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
            menu.addItem(.separator())
            menu.addItem(
                bookmarkMenuItem(
                    title: "Unlink from Bookmark",
                    symbolName: "link.badge.plus",
                    action: .unlink,
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
        } else {
            menu.addItem(
                bookmarkMenuItem(
                    title: "Bookmark Worklane\u{2026}",
                    symbolName: "bookmark",
                    action: .bookmark,
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
            menu.addItem(
                bookmarkMenuItem(
                    title: "Save as Preset\u{2026}",
                    symbolName: "rectangle.stack.badge.plus",
                    action: .saveAsPreset,
                    target: target,
                    bookmarkAction: bookmarkAction
                )
            )
        }
    }

    private static func bookmarkMenuItem(
        title: String,
        symbolName: String,
        action: SidebarBookmarkRowAction,
        target: AnyObject,
        bookmarkAction: Selector
    ) -> NSMenuItem {
        let item = SidebarContextMenu.item(
            title: title,
            action: bookmarkAction,
            target: target,
            symbolName: symbolName
        )
        item.representedObject = SidebarBookmarkRowActionBox(action: action)
        return item
    }
}

private extension PaneRightCommandPresentation {
    func sidebarForceAction(from actions: SidebarWorklaneContextMenuActions) -> Selector? {
        switch forceOppositeCommand {
        case .splitRightVisibly:
            actions.forceSplitRightAction
        case .addPaneRightWithoutResizing:
            actions.forceAddPaneRightAction
        default:
            nil
        }
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
    var isLastPaneInOnlyWorklane = false
    var currentWorklaneColor: WorklaneColor?
    var onPaneClicked: ((PaneID) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCloseWorklane: (() -> Void)?
    var onClosePane: ((PaneID) -> Void)?
    var onSplitHorizontal: ((PaneID) -> Void)?
    var onSplitVertical: ((PaneID) -> Void)?
    var onForceSplitRight: ((PaneID) -> Void)?
    var onForceAddPaneRight: ((PaneID) -> Void)?
    var onMovePaneToNewWindow: ((PaneID) -> Void)?
    var onPickWorklaneColor: ((PaneID, WorklaneColor?) -> Void)?
    var onBookmarkAction: ((SidebarBookmarkRowAction) -> Void)?
    var bookmarkOriginID: UUID?
    var bookmarkNameLookup: ((UUID) -> String?)?
    var onWorklaneDragRequested: ((NSEvent) -> Bool)?
    var onMoveWorklane: ((SidebarWorklaneMoveDirection) -> Void)?
    var worklaneMoveAvailability: SidebarWorklaneMoveAvailability = .none
    var rightPaneCommandPresentationProvider: (() -> PaneRightCommandPresentation)?
    var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?

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
        let originID = bookmarkOriginID
        let result = SidebarWorklaneContextMenu.makeMenu(
            context: SidebarWorklaneContextMenuContext(
                origin: .paneRow(isLastPaneInWorklane: isLastPaneInWorklane),
                moveAvailability: worklaneMoveAvailability,
                worklaneColor: currentWorklaneColor,
                bookmarkOriginID: originID,
                bookmarkName: originID.flatMap { bookmarkNameLookup?($0) },
                isOnlyWorklane: isLastPaneInOnlyWorklane && isLastPaneInWorklane,
                rightPaneCommandPresentation: rightPaneCommandPresentationProvider?() ?? .addsToWorklane,
                moveToWorklaneCatalog: moveToWorklaneCatalogProvider?(paneID),
                paneID: paneID
            ),
            actions: SidebarWorklaneContextMenuActions(
                target: self,
                closeWorklaneAction: #selector(handleCloseWorklane),
                closePaneAction: #selector(handleClosePane),
                moveUpAction: #selector(handleMoveWorklaneUp),
                moveDownAction: #selector(handleMoveWorklaneDown),
                splitHorizontalAction: #selector(handleSplitHorizontal),
                splitVerticalAction: #selector(handleSplitVertical),
                forceSplitRightAction: #selector(handleForceSplitRight),
                forceAddPaneRightAction: #selector(handleForceAddPaneRight),
                movePaneToNewWindowAction: #selector(handleMovePaneToNewWindow),
                bookmarkAction: #selector(handleBookmarkMenuItem(_:)),
                colorChanged: { [weak self] color in
                    guard let self else { return }
                    self.onPickWorklaneColor?(self.paneID, color)
                }
            )
        )
        activeContextPicker = result.activePicker
        return result.menu
    }

    @objc private func handleCloseWorklane() {
        onCloseWorklane?()
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

    @objc private func handleBookmarkMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarBookmarkRowActionBox else {
            return
        }
        onBookmarkAction?(box.action)
    }

    @objc private func handleSplitHorizontal() {
        onSplitHorizontal?(paneID)
    }

    @objc private func handleSplitVertical() {
        onSplitVertical?(paneID)
    }

    @objc private func handleForceSplitRight() {
        onForceSplitRight?(paneID)
    }

    @objc private func handleForceAddPaneRight() {
        onForceAddPaneRight?(paneID)
    }

    @objc private func handleMovePaneToNewWindow() {
        onMovePaneToNewWindow?(paneID)
    }
}
