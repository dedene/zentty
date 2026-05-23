import AppKit

@MainActor
enum MenuBarStatusMenuBuilder {
    private enum Section: CaseIterable {
        case waiting
        case running
        case idle

        var representativeState: MenuBarFleetState {
            switch self {
            case .waiting:
                return .waiting
            case .running:
                return .active
            case .idle:
                return .idle
            }
        }

        func contains(_ fleetState: MenuBarFleetState) -> Bool {
            switch (self, fleetState) {
            case (.waiting, .waiting), (.waiting, .stopped):
                return true
            case (.running, .active), (.running, .compacting):
                return true
            case (.idle, .idle):
                return true
            default:
                return false
            }
        }
    }

    static func itemTitle(for snapshot: MenuBarPaneSnapshot) -> String {
        "\(snapshot.primaryText), \(snapshot.statusLabel)"
    }

    static func rebuild(
        menu: NSMenu,
        snapshots: [MenuBarPaneSnapshot],
        fleetSummary: MenuBarFleetSummary,
        target: AnyObject?,
        rowAction: Selector,
        settingsAction: Selector,
        theme: ZenttyTheme = ZenttyTheme.fallback(for: nil),
        settingsShortcut: KeyboardShortcut? = nil
    ) {
        menu.removeAllItems()

        if snapshots.isEmpty {
            addDisabledItem(to: menu, title: "No agent panes")
            menu.addItem(.separator())
            addSettingsItem(to: menu, target: target, action: settingsAction, shortcut: settingsShortcut)
            addQuitItem(to: menu)
            return
        }

        var didAddSection = false
        for section in Section.allCases {
            let sectionSnapshots = snapshots.filter { section.contains($0.fleetState) }
            guard !sectionSnapshots.isEmpty else { continue }

            if didAddSection {
                menu.addItem(.separator())
            }
            didAddSection = true

            addSectionHeader(
                to: menu,
                title: fleetSummary.sectionTitle(for: section.representativeState)
            )
            addPaneRows(
                to: menu,
                snapshots: sectionSnapshots,
                target: target,
                action: rowAction,
                theme: theme
            )
        }

        menu.addItem(.separator())
        addSettingsItem(to: menu, target: target, action: settingsAction, shortcut: settingsShortcut)
        addQuitItem(to: menu)
    }

    private static func addDisabledItem(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private static func addSectionHeader(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        // Keep the plain `title` (accessibility + tests) and overlay a compact
        // attributed title so the section label renders much smaller than the
        // default menu font.
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(item)
    }

    private static func addSettingsItem(
        to menu: NSMenu,
        target: AnyObject?,
        action: Selector,
        shortcut: KeyboardShortcut?
    ) {
        let item = NSMenuItem(title: "Settings…", action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.menuModifierFlags ?? []
        menu.addItem(item)
    }

    private static func addQuitItem(to menu: NSMenu) {
        // Reuse the standard terminate path so it honors "Confirm before quitting"
        // via AppDelegate.applicationShouldTerminate, exactly like the app menu's Quit.
        // Quit has no entry in the command registry, so mirror AppMenuBuilder's literal ⌘Q.
        let item = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = NSApp
        item.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(item)
    }

    private static func addPaneRows(
        to menu: NSMenu,
        snapshots: [MenuBarPaneSnapshot],
        target: AnyObject?,
        action: Selector,
        theme: ZenttyTheme
    ) {
        for snapshot in snapshots {
            let item = NSMenuItem(
                title: itemTitle(for: snapshot),
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.toolTip = snapshot.contextText
            item.representedObject = MenuBarPaneMenuItemPayload(
                windowID: snapshot.windowID,
                worklaneID: snapshot.worklaneID,
                paneID: snapshot.paneID
            )
            let rowView = MenuBarAgentRowView(
                snapshot: snapshot,
                target: target,
                action: action,
                theme: theme,
                appearance: menu.appearance
            )
            rowView.menuItem = item
            item.view = rowView
            menu.addItem(item)
        }
    }
}

final class MenuBarPaneMenuItemPayload: NSObject {
    let windowID: WindowID
    let worklaneID: WorklaneID
    let paneID: PaneID

    init(windowID: WindowID, worklaneID: WorklaneID, paneID: PaneID) {
        self.windowID = windowID
        self.worklaneID = worklaneID
        self.paneID = paneID
    }
}

@MainActor
private final class MenuBarAgentRowView: NSView {
    private enum Metrics {
        // Row content width. macOS status-item menus add native menu chrome around
        // custom row views, so 250pt yields an overall dropdown near 310pt.
        static let width: CGFloat = 250
        static let height: CGFloat = 44
        static let horizontalPadding: CGFloat = 14
        static let iconSide: CGFloat = MenuBarStatusIconRenderer.agentIconSide
        static let iconTextSpacing: CGFloat = 10
        // Gap between the title/context column and the right-aligned status block.
        static let columnGap: CGFloat = 16
        // Width reserved left of the status text for the task-progress indicator.
        static let progressLeadingWidth: CGFloat = 13
    }

    private let snapshot: MenuBarPaneSnapshot
    private weak var target: AnyObject?
    private let action: Selector
    private let theme: ZenttyTheme
    private let menuAppearance: NSAppearance?
    weak var menuItem: NSMenuItem?

    private let iconView = MenuBarAgentIconView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let progressIndicator = SidebarTaskProgressIndicatorView()
    private let progressRevealView = SidebarTaskProgressRevealView()
    private var trackingAreaValue: NSTrackingArea?
    private var isHovered = false

    init(
        snapshot: MenuBarPaneSnapshot,
        target: AnyObject?,
        action: Selector,
        theme: ZenttyTheme,
        appearance: NSAppearance?
    ) {
        self.snapshot = snapshot
        self.target = target
        self.action = action
        self.theme = theme
        self.menuAppearance = appearance
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height))
        self.appearance = appearance
        setup()
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    // A status-item menu renders wider than its computed content, so the menu
    // stretches each row to its full width. Re-run layout on that resize (it
    // positions everything from `bounds.width`) so the status column and hover
    // highlight reach the right edge instead of leaving a gap.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaValue = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        statusLabel.textColor = MenuBarStatusIconRenderer.statusTextColor(
            for: snapshot.fleetState,
            appearance: menuAppearance ?? effectiveAppearance
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let target else { return }
        NSApp.sendAction(action, to: target, from: menuItem ?? self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    override func layout() {
        super.layout()

        let iconY = floor((bounds.height - Metrics.iconSide) / 2)
        iconView.frame = NSRect(
            x: Metrics.horizontalPadding,
            y: iconY,
            width: Metrics.iconSide,
            height: Metrics.iconSide
        )

        let rightEdge = bounds.width - Metrics.horizontalPadding
        let textX = iconView.frame.maxX + Metrics.iconTextSpacing
        let statusY: CGFloat = ageLabel.stringValue.isEmpty ? 13 : 22

        // Size the status/age block to its actual content and hug the right edge,
        // so short statuses (e.g. "Idle") don't reserve a wide empty column. The
        // title/context then fill the remaining width up to a small gap.
        // Measure the text directly (not via intrinsicContentSize): a truncating
        // label that gets a narrow frame during the menu's sizing passes reports a
        // shrunken intrinsicContentSize, which would clip the status text.
        let statusTextWidth = measuredTextWidth(of: statusLabel)
        let ageTextWidth = measuredTextWidth(of: ageLabel)
        let revealWidth = (progressIndicator.isHidden || isHovered == false) ? 0 : progressRevealView.expandedWidth
        let progressWidth: CGFloat = progressIndicator.isHidden ? 0 : (Metrics.progressLeadingWidth + revealWidth)
        let rightBlockWidth = max(progressWidth + statusTextWidth, ageTextWidth)
        let rightBlockX = rightEdge - rightBlockWidth

        let textWidth = max(0, rightBlockX - textX - Metrics.columnGap)
        let titleHeight: CGFloat = 18
        let contextHeight: CGFloat = 16
        titleLabel.frame = NSRect(x: textX, y: 21, width: textWidth, height: titleHeight)
        contextLabel.frame = NSRect(x: textX, y: 5, width: textWidth, height: contextHeight)

        let statusTextX = rightEdge - statusTextWidth
        statusLabel.frame = NSRect(x: statusTextX, y: statusY, width: statusTextWidth, height: 17)
        if progressIndicator.isHidden == false {
            let revealX = statusTextX - revealWidth
            progressRevealView.frame = NSRect(x: revealX, y: statusY, width: revealWidth, height: 16)
            progressIndicator.frame = NSRect(x: revealX - Metrics.progressLeadingWidth, y: statusY + 2, width: 11, height: 11)
        }
        ageLabel.frame = NSRect(x: rightEdge - ageTextWidth, y: 5, width: ageTextWidth, height: 16)
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        autoresizingMask = [.width]

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        contextLabel.font = .systemFont(ofSize: 11, weight: .regular)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.maximumNumberOfLines = 1

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        ageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        ageLabel.textColor = .secondaryLabelColor
        ageLabel.alignment = .right
        ageLabel.lineBreakMode = .byTruncatingTail
        ageLabel.maximumNumberOfLines = 1

        progressIndicator.onHoverEntered = { [weak self] in
            self?.setHovered(true)
        }

        [iconView, titleLabel, contextLabel, statusLabel, ageLabel, progressIndicator, progressRevealView].forEach {
            addSubview($0)
        }
    }

    private func configure() {
        iconView.configure(
            agentTool: snapshot.agentTool,
            fleetState: snapshot.fleetState,
            appearance: menuAppearance ?? effectiveAppearance
        )
        titleLabel.stringValue = snapshot.primaryText
        contextLabel.stringValue = snapshot.contextText ?? snapshot.agentTool.displayName
        statusLabel.stringValue = snapshot.statusLabel
        statusLabel.textColor = MenuBarStatusIconRenderer.statusTextColor(
            for: snapshot.fleetState,
            appearance: menuAppearance ?? effectiveAppearance
        )
        ageLabel.stringValue = ageText(for: snapshot)

        let progressColor = snapshot.fleetState == .idle ? NSColor.secondaryLabelColor : NSColor.systemGreen
        progressIndicator.configure(
            taskProgress: snapshot.taskProgress,
            color: progressColor,
            animated: false,
            reducedMotion: true
        )
        progressRevealView.configure(
            taskProgress: snapshot.taskProgress,
            color: progressColor,
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        progressRevealView.setRevealed(false, animated: false, reducedMotion: true)

        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(MenuBarStatusMenuBuilder.itemTitle(for: snapshot))
        setAccessibilityValue(snapshot.contextText)
    }

    /// Full rendered width of a label's text, independent of its current frame
    /// (so it never shrinks from a prior truncated layout pass). Returns 0 for empty.
    private func measuredTextWidth(of label: NSTextField) -> CGFloat {
        guard label.stringValue.isEmpty == false else { return 0 }
        return ceil(label.fittingSize.width)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        progressRevealView.setRevealed(hovered, animated: true, reducedMotion: false)
        needsLayout = true
        needsDisplay = true
    }

    private func ageText(for snapshot: MenuBarPaneSnapshot) -> String {
        guard snapshot.fleetState == .waiting || snapshot.fleetState == .stopped || snapshot.fleetState == .idle else {
            return ""
        }
        let elapsed = Date().timeIntervalSince(snapshot.updatedAt)
        guard elapsed >= 0,
              elapsed < 60 * 60 * 24 * 30,
              snapshot.updatedAt.timeIntervalSince1970 > 0 else {
            return ""
        }
        if elapsed < 60 {
            return "just now"
        }
        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = Int(minutes / 60)
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(Int(hours / 24))d ago"
    }
}

@MainActor
private final class MenuBarAgentIconView: NSView {
    private enum Metrics {
        static let imageSide: CGFloat = MenuBarStatusIconRenderer.agentIconSide
    }

    private let imageView = NSImageView()
    private var agentTool: AgentTool?
    private var fleetState: MenuBarFleetState = .idle
    private var menuAppearance: NSAppearance?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(agentTool: AgentTool, fleetState: MenuBarFleetState, appearance: NSAppearance?) {
        self.agentTool = agentTool
        self.fleetState = fleetState
        menuAppearance = appearance
        self.appearance = appearance
        updateImage()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let imageX = floor((bounds.width - Metrics.imageSide) / 2)
        let imageY = floor((bounds.height - Metrics.imageSide) / 2)
        imageView.frame = NSRect(
            x: imageX,
            y: imageY,
            width: Metrics.imageSide,
            height: Metrics.imageSide
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown

        addSubview(imageView)
    }

    private func updateImage() {
        guard let agentTool else { return }
        imageView.image = MenuBarStatusIconRenderer.agentIconImage(
            for: agentTool,
            fleetState: fleetState,
            appearance: menuAppearance ?? effectiveAppearance
        )
    }
}
