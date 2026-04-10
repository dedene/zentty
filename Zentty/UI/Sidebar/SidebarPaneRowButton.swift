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
    var onPaneClicked: ((PaneID) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCloseWorklane: ((PaneID) -> Void)?
    var onClosePane: ((PaneID) -> Void)?
    var onSplitHorizontal: ((PaneID) -> Void)?
    var onSplitVertical: ((PaneID) -> Void)?

    private let contentStack = NSStackView()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var hoverBackgroundColor: NSColor = .clear

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

    func setContent(_ views: [NSView]) {
        contentStack.setViews(views, in: .top)
    }

    func updateTheme(hoverColor: NSColor) {
        hoverBackgroundColor = hoverColor
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
            color = hoverBackgroundColor.withAlphaComponent(0.7)
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

        let closeWorklaneItem = NSMenuItem(
            title: "Close Worklane",
            action: #selector(handleCloseWorklane),
            keyEquivalent: ""
        )
        closeWorklaneItem.target = self
        menu.addItem(closeWorklaneItem)

        if !isLastPaneInWorklane {
            let closePaneItem = NSMenuItem(
                title: "Close Pane",
                action: #selector(handleClosePane),
                keyEquivalent: ""
            )
            closePaneItem.target = self
            menu.addItem(closePaneItem)
        }

        menu.addItem(NSMenuItem.separator())

        let splitHItem = NSMenuItem(
            title: "Split Horizontal",
            action: #selector(handleSplitHorizontal),
            keyEquivalent: ""
        )
        splitHItem.target = self
        menu.addItem(splitHItem)

        let splitVItem = NSMenuItem(
            title: "Split Vertical",
            action: #selector(handleSplitVertical),
            keyEquivalent: ""
        )
        splitVItem.target = self
        menu.addItem(splitVItem)

        return menu
    }

    @objc private func handleCloseWorklane() {
        onCloseWorklane?(paneID)
    }

    @objc private func handleClosePane() {
        onClosePane?(paneID)
    }

    @objc private func handleSplitHorizontal() {
        onSplitHorizontal?(paneID)
    }

    @objc private func handleSplitVertical() {
        onSplitVertical?(paneID)
    }
}
