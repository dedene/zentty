import AppKit
import OSLog

@MainActor
struct MenuBarWorklaneSource {
    let windowID: WindowID
    let windowTitle: String
    let worklaneStore: WorklaneStore
}

@MainActor
final class MenuBarStatusController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "MenuBarStatus")

    private let configStore: AppConfigStore
    private let focusPaneHandler: (WindowID, WorklaneID, PaneID) -> Void
    private let openSettingsHandler: () -> Void
    private var currentTheme: ZenttyTheme
    private let statusBadgeView = MenuBarStatusDotView(frame: .zero)
    private var statusItem: NSStatusItem?
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.appearance = Self.systemMenuAppearance()
        return menu
    }()
    private var sources: [MenuBarWorklaneSource] = []
    private var subscriptions: [WindowID: (store: WorklaneStore, subscription: WorklaneChangeSubscription)] = [:]
    private var isStarted = false
    private var latestSnapshots: [MenuBarPaneSnapshot] = []
    private var latestFleetSummary = MenuBarFleetSummary.from(snapshots: [])
    private var latestPresentation: MenuBarStatusPresentation?
    private var isMenuOpen = false

    init(
        configStore: AppConfigStore,
        focusPaneHandler: @escaping (WindowID, WorklaneID, PaneID) -> Void,
        openSettingsHandler: @escaping () -> Void,
        theme: ZenttyTheme = ZenttyTheme.fallback(for: nil)
    ) {
        self.configStore = configStore
        self.focusPaneHandler = focusPaneHandler
        self.openSettingsHandler = openSettingsHandler
        self.currentTheme = theme
        super.init()
    }

    func start() {
        guard configStore.current.menuBar.showStatusItem else { return }
        guard !isStarted else {
            refresh()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard item.button != nil else {
            Self.logger.error("Failed to create menu bar status item button")
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        item.menu = menu
        statusItem = item
        isStarted = true
        refresh()
    }

    func stop() {
        for entry in subscriptions.values {
            entry.store.unsubscribe(entry.subscription)
        }
        subscriptions.removeAll()

        if let statusItem {
            statusItem.menu = nil
            statusBadgeView.removeFromSuperview()
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        latestSnapshots = []
        latestFleetSummary = MenuBarFleetSummary.from(snapshots: [])
        latestPresentation = nil
        isMenuOpen = false
        isStarted = false
    }

    func syncSources(_ sources: [MenuBarWorklaneSource]) {
        self.sources = sources
        reconcileSubscriptions()
        refresh()
    }

    func refreshPresentation() {
        latestPresentation = nil
        refresh()
    }

    func applyTheme(_ theme: ZenttyTheme) {
        guard theme != currentTheme else { return }
        currentTheme = theme
        refreshPresentation()
    }

    @discardableResult
    func focusNextWaitingPane() -> Bool {
        guard let snapshot = latestSnapshots.first(where: { $0.fleetState == .waiting }) else {
            return false
        }
        focusPaneHandler(snapshot.windowID, snapshot.worklaneID, snapshot.paneID)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.appearance = Self.systemMenuAppearance()
        refresh()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc
    private func handleMenuSelection(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuBarPaneMenuItemPayload else {
            return
        }
        focusPaneHandler(payload.windowID, payload.worklaneID, payload.paneID)
        closeMenuAfterSelection()
    }

    @objc
    private func handleSettingsSelection(_ sender: Any?) {
        openSettingsHandler()
    }

    private func rebuildMenu() {
        let settingsShortcut = ShortcutManager(shortcuts: configStore.current.shortcuts)
            .shortcut(for: .openSettings)
        MenuBarStatusMenuBuilder.rebuild(
            menu: menu,
            snapshots: latestSnapshots,
            fleetSummary: latestFleetSummary,
            target: self,
            rowAction: #selector(handleMenuSelection(_:)),
            settingsAction: #selector(handleSettingsSelection(_:)),
            theme: currentTheme,
            settingsShortcut: settingsShortcut
        )
    }

    private func closeMenuAfterSelection() {
#if DEBUG
        menuCloseRequestCountForTesting += 1
#endif
        menu.cancelTracking()
    }

    private func reconcileSubscriptions() {
        guard isStarted else { return }

        let sourceWindowIDs = Set(sources.map(\.windowID))
        for windowID in subscriptions.keys where !sourceWindowIDs.contains(windowID) {
            if let entry = subscriptions.removeValue(forKey: windowID) {
                entry.store.unsubscribe(entry.subscription)
            }
        }

        for source in sources {
            if let existing = subscriptions[source.windowID] {
                if existing.store !== source.worklaneStore {
                    existing.store.unsubscribe(existing.subscription)
                    subscriptions[source.windowID] = subscribe(to: source)
                }
            } else {
                subscriptions[source.windowID] = subscribe(to: source)
            }
        }
    }

    private func subscribe(
        to source: MenuBarWorklaneSource
    ) -> (store: WorklaneStore, subscription: WorklaneChangeSubscription) {
        let subscription = source.worklaneStore.subscribe { [weak self] change in
            guard let self, Self.isMenuRelevant(change) else { return }
            self.refresh()
        }
        return (store: source.worklaneStore, subscription: subscription)
    }

    private static func isMenuRelevant(_ change: WorklaneChange) -> Bool {
        switch change {
        case .paneStructure, .activeWorklaneChanged, .worklaneListChanged:
            return true
        case .auxiliaryStateUpdated:
            return true
        case .volatileAgentTitleUpdated, .layoutResized, .focusChanged, .historyChanged, .teamAnchorsChanged:
            return false
        }
    }

    private static func systemMenuAppearance() -> NSAppearance? {
        let globalStyle = (
            UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        )
        let appStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        let isDark = (globalStyle ?? appStyle) == "Dark"
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private func refresh() {
        guard isStarted else { return }

        let snapshots = currentSnapshots()
        let fleetSummary = MenuBarFleetSummary.from(snapshots: snapshots)
        let fleetState = MenuBarFleetState.aggregate(snapshots.map(\.fleetState))
        let presentation = MenuBarStatusPresentation.resolve(
            fleetState: fleetState,
            fleetSummary: fleetSummary
        )

        guard snapshots != latestSnapshots || presentation != latestPresentation else {
            return
        }

        latestSnapshots = snapshots
        latestFleetSummary = fleetSummary
        latestPresentation = presentation
        apply(presentation)

        if isMenuOpen {
            rebuildMenu()
        }
    }

    private func currentSnapshots() -> [MenuBarPaneSnapshot] {
#if DEBUG
        if iconInspectorEnabled {
            return MenuBarAgentIconInspector.syntheticSnapshots()
        }
#endif
        return MenuBarPaneSnapshotBuilder.snapshots(from: sources)
    }

    private func apply(_ presentation: MenuBarStatusPresentation) {
        guard let button = statusItem?.button else { return }
        let hasAgentPanes = presentation.fleetSummary.totalCount > 0

        button.image = MenuBarStatusIconRenderer.statusImage(
            fleetState: presentation.fleetState,
            hasAgentPanes: hasAgentPanes,
            appearance: button.effectiveAppearance
        )
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = presentation.accessibilityLabel
        button.contentTintColor = nil

        statusBadgeView.fleetState = presentation.fleetState
        let showsDot = MenuBarStatusIconRenderer.showsStatusDot(
            fleetState: presentation.fleetState,
            hasAgentPanes: hasAgentPanes
        )
        if showsDot {
            if statusBadgeView.superview !== button {
                button.addSubview(statusBadgeView)
            }
            layoutStatusBadge(in: button)
        } else {
            statusBadgeView.removeFromSuperview()
        }
    }

    private func layoutStatusBadge(in button: NSStatusBarButton) {
        statusBadgeView.frame = Self.statusBadgeFrame(in: button.bounds)
    }

#if DEBUG
    private var iconInspectorEnabled = false

    var isIconInspectorEnabled: Bool { iconInspectorEnabled }

    /// Fills the dropdown with one synthetic row per agent (or restores the real
    /// snapshots) so the icons can be inspected, then pops the menu open.
    func toggleIconInspector() {
        iconInspectorEnabled.toggle()
        refresh()
        if iconInspectorEnabled {
            statusItem?.button?.performClick(nil)
        }
    }

    private(set) var menuCloseRequestCountForTesting = 0

    static func isMenuRelevantForTesting(_ change: WorklaneChange) -> Bool {
        isMenuRelevant(change)
    }

    nonisolated static func statusBadgeFrameForTesting(in buttonBounds: NSRect) -> NSRect {
        statusBadgeFrame(in: buttonBounds)
    }

    var usesNativeMenuForTesting: Bool {
        statusItem?.menu === menu
    }

    func forceNativeMenuUpdateForTesting() {
        menuNeedsUpdate(menu)
    }

    func menuItemTitlesForTesting() -> [String] {
        rebuildMenu()
        return menu.items.map(\.title)
    }

    func performMenuSelectionForTesting(windowID: WindowID, worklaneID: WorklaneID, paneID: PaneID) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = MenuBarPaneMenuItemPayload(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID
        )
        handleMenuSelection(item)
    }
#endif

    private nonisolated static func statusBadgeFrame(in buttonBounds: NSRect) -> NSRect {
        let canvasSide = MenuBarStatusIconRenderer.statusItemCanvasSide
        let dotSide = MenuBarStatusIconRenderer.insetDotSide
        let dotOrigin = MenuBarStatusIconRenderer.statusItemDotOrigin
        let imageOrigin = NSPoint(
            x: floor((buttonBounds.width - canvasSide) / 2),
            y: floor((buttonBounds.height - canvasSide) / 2)
        )
        let flippedDotY = canvasSide - dotOrigin.y - dotSide
        return NSRect(
            x: imageOrigin.x + dotOrigin.x,
            y: imageOrigin.y + flippedDotY,
            width: dotSide,
            height: dotSide
        )
    }
}

private final class MenuBarStatusDotView: NSView {
    var fleetState: MenuBarFleetState = .idle {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        MenuBarStatusIconRenderer.dotColor(for: fleetState).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
