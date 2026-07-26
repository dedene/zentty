import AppKit

enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case general
    case appearance
    case shortcuts
    case notifications
    case openWith
    case devServers
    case paneLayout
    case updatesPrivacy
    case agents
    case mobileDevices

    var title: String {
        switch self {
        case .general:
            "General"
        case .appearance:
            "Appearance"
        case .shortcuts:
            "Shortcuts"
        case .notifications:
            "Notifications"
        case .mobileDevices:
            "Mobile Devices"
        case .openWith:
            "Open With"
        case .devServers:
            "Dev Servers"
        case .paneLayout:
            "Worklanes & Panes"
        case .updatesPrivacy:
            "Updates & Privacy"
        case .agents:
            "Agents"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .appearance:
            "paintpalette"
        case .shortcuts:
            "keyboard"
        case .notifications:
            "bell.badge"
        case .mobileDevices:
            "iphone"
        case .openWith:
            "square.and.arrow.up.on.square"
        case .devServers:
            "globe"
        case .paneLayout:
            "rectangle.split.3x1"
        case .updatesPrivacy:
            "arrow.triangle.2.circlepath"
        case .agents:
            "cpu"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            "Confirmations, restore, and clipboard"
        case .appearance:
            "Theme, opacity, and terminal colors"
        case .shortcuts:
            "Keyboard shortcuts and conflicts"
        case .notifications:
            "Desktop alerts and notification sound"
        case .mobileDevices:
            "Pair phones and manage the companion bridge"
        case .openWith:
            "Default apps and custom launchers"
        case .devServers:
            "Dev server detection and browsers"
        case .paneLayout:
            "Worklane placement, labels, icons, opacity, and split behavior"
        case .updatesPrivacy:
            "Update channel and crash reporting"
        case .agents:
            "Agent status, teams, and sleep behavior"
        }
    }

    /// Extra terms (beyond the title) that match this section in sidebar
    /// search, so e.g. "crash" finds Updates & Privacy.
    var searchKeywords: [String] {
        switch self {
        case .general:
            ["confirm", "quit", "close", "restore", "workspace", "clipboard", "copy", "flatten", "markdown", "url"]
        case .appearance:
            ["theme", "opacity", "color", "font", "terminal", "ghostty", "background"]
        case .shortcuts:
            ["keyboard", "keybinding", "hotkey", "binding", "shortcut"]
        case .notifications:
            ["sound", "alert", "notify", "permission", "desktop"]
        case .mobileDevices:
            ["mobile", "phone", "iphone", "android", "companion", "pair", "pairing", "qr", "device", "remote", "bonjour"]
        case .openWith:
            ["app", "editor", "launch", "finder", "vscode", "cursor", "xcode"]
        case .devServers:
            ["server", "localhost", "browser", "port", "detect", "ignored", "hidden"]
        case .paneLayout:
            ["worklane", "workspace", "pane", "split", "layout", "opacity", "label", "icon", "scroll"]
        case .updatesPrivacy:
            ["update", "channel", "beta", "stable", "crash", "error", "report", "privacy", "sentry"]
        case .agents:
            ["agent", "claude", "team", "caffeinate", "sleep", "subagent", "menu", "menu bar", "menubar", "status"]
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .general:
            .systemGray
        case .appearance:
            .systemTeal
        case .shortcuts:
            .systemIndigo
        case .notifications:
            .systemRed
        case .mobileDevices:
            .systemMint
        case .openWith:
            .systemBlue
        case .devServers:
            .systemGreen
        case .paneLayout:
            .systemPurple
        case .updatesPrivacy:
            .systemCyan
        case .agents:
            .systemOrange
        }
    }

    /// Per-section shrink factor for the badge glyph. `square.and.arrow.up.on.square`
    /// is unusually wide and fills the rounded square, so Open With renders it a
    /// touch smaller for consistent padding.
    var badgeSymbolScale: CGFloat {
        switch self {
        case .openWith:
            0.82
        default:
            1
        }
    }
}

/// A labelled group of sections in the settings sidebar. A `nil` title renders
/// the sections without a group header (the pinned items at the top, like
/// macOS System Settings).
struct SettingsSidebarGroup: Equatable {
    let title: String?
    let sections: [SettingsSection]
}

/// Drives the order and grouping of the settings sidebar. Reordering is a
/// data-only change here — the section view controllers are untouched.
enum SettingsSidebarLayout {
    static let groups: [SettingsSidebarGroup] = [
        SettingsSidebarGroup(
            title: nil,
            sections: [.general, .appearance, .shortcuts, .notifications, .mobileDevices, .updatesPrivacy]
        ),
        SettingsSidebarGroup(title: "Workspace", sections: [.paneLayout, .openWith, .devServers, .agents]),
    ]
}

enum AgentTeamsEnableWarningDecision {
    case enable
    case cancel
}

typealias AgentTeamsEnableWarningPresenter = @MainActor (
    NSWindow,
    @escaping (AgentTeamsEnableWarningDecision) -> Void
) -> Void

enum AgentTeamsEnableWarning {
    @MainActor
    static func present(
        from window: NSWindow,
        completion: @escaping (AgentTeamsEnableWarningDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claude Code agent teams only apply to new panes"
        alert.informativeText =
            "After enabling this experimental integration, restart Zentty or close and recreate the pane where you want to use Claude Code team mode."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? .enable : .cancel)
        }
    }
}

@MainActor
enum AgentIntegrationUninstallFailureAlert {
    /// Warn that Zentty recorded the integration as off but couldn't remove its
    /// on-disk hooks, and offer to reveal the config so the user can finish the
    /// job manually. No-ops without a host window (e.g. headless tests); the
    /// failure has already been logged by the caller.
    static func present(window: NSWindow?, tool: AgentBootstrapTool, error: Error) {
        guard let window else { return }
        let name = tool.integrationDisplayName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't fully disable \(name)"
        if let path = tool.integrationConfigPathDisplay {
            alert.informativeText = """
            \(name) is now off in Zentty, but its status hooks couldn't be removed from \
            \(path). Remove them there — or run `zentty uninstall` — if \(name) keeps \
            reporting status.
            """
        } else {
            alert.informativeText = """
            \(name) is now off in Zentty, but its status hooks couldn't be removed. Run \
            `zentty uninstall` if \(name) keeps reporting status.
            """
        }

        let canReveal = tool.integrationConfigURL != nil
        if canReveal {
            alert.addButton(withTitle: "Reveal in Finder")
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { response in
            if canReveal, response == .alertFirstButtonReturn, let url = tool.integrationConfigURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

@MainActor
protocol SettingsPaneMeasuring: AnyObject {
    func preferredViewportHeight(for width: CGFloat) -> CGFloat
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController
    private let navigationToolbar = NSToolbar(identifier: "be.zenjoy.Zentty.SettingsToolbar")
    private weak var navigationSegmentedControl: NSSegmentedControl?

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing = OpenWithService(),
        serverOpening: ServerOpening = ServerOpenService(),
        customAppPicker: @escaping () -> OpenWithCustomApp? = OpenWithSettingsSectionViewController.defaultCustomAppPicker,
        errorReportingBundleConfigurationProvider: @escaping ErrorReportingBundleConfigurationProvider = {
            ErrorReportingBundleConfiguration.load(from: .main)
        },
        errorReportingConfirmationPresenter: @escaping ErrorReportingConfirmationPresenter = ErrorReportingRestartConfirmation.present,
        errorReportingRestartHandler: @escaping ErrorReportingRestartHandler = ErrorReportingApplicationRestart.restart,
        agentTeamsEnableWarningPresenter: @escaping AgentTeamsEnableWarningPresenter = AgentTeamsEnableWarning.present,
        runtimeErrorReportingEnabled: Bool = ErrorReportingRuntimeState.isEnabledForCurrentProcess,
        initialSection: SettingsSection = .general
    ) {
        let settingsViewController = SettingsViewController(
            configStore: configStore,
            openWithService: openWithService,
            serverOpenService: serverOpening,
            customAppPicker: customAppPicker,
            errorReportingBundleConfigurationProvider: errorReportingBundleConfigurationProvider,
            errorReportingConfirmationPresenter: errorReportingConfirmationPresenter,
            errorReportingRestartHandler: errorReportingRestartHandler,
            agentTeamsEnableWarningPresenter: agentTeamsEnableWarningPresenter,
            runtimeErrorReportingEnabled: runtimeErrorReportingEnabled,
            initialSection: initialSection
        )
        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: SettingsViewController.defaultContentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.keyEquivalentHandler = { [weak settingsViewController] event in
            settingsViewController?.handlePerformKeyEquivalent(event) ?? false
        }
        window.title = initialSection.title
        // The detail-pane header carries the section title, so keep the
        // title bar text hidden (System Settings / Raycast style) while still
        // setting `title` for the Window menu and Mission Control.
        window.titleVisibility = .hidden
        // Full-size content + transparent titlebar so the source-list sidebar's
        // vibrancy runs all the way up behind the traffic lights, like macOS
        // System Settings. Each pane insets its content below the bar via the
        // safe-area layout guide.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        // Settings has a fixed-ish layout, so disable the green zoom/maximize
        // button while keeping the window resizable by dragging its edges.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.backgroundColor = NSColor.windowBackgroundColor
        // Settings follows the macOS system light/dark, not the terminal theme,
        // so leave the appearance unset (inherits the system appearance).
        window.appearance = nil
        window.contentViewController = settingsViewController
        window.contentMinSize = SettingsViewController.minimumContentSize
        window.setContentSize(SettingsViewController.defaultContentSize)
        if window.placeOnHostedTestScreenIfNeeded() == nil {
            window.center()
        }
        settingsViewController.attach(to: window)

        self.settingsViewController = settingsViewController
        super.init(window: window)
        configureNavigationToolbar(on: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(section: SettingsSection, sender: Any?) {
        settingsViewController.select(
            section: section,
            animated: window?.isVisible == true && settingsViewController.selectedSection != section
        )
        window?.placeOnHostedTestScreenIfNeeded()
        showWindow(sender)
        window?.placeOnHostedTestScreenIfNeeded()
        window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Navigation toolbar

    private func configureNavigationToolbar(on window: NSWindow) {
        navigationToolbar.delegate = self
        navigationToolbar.allowsUserCustomization = false
        navigationToolbar.displayMode = .iconOnly
        window.toolbar = navigationToolbar
        window.toolbarStyle = .unified
        settingsViewController.onNavigationStateChange = { [weak self] in
            self?.updateNavigationControlEnabledState()
        }
    }

    private func makeBackForwardToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let segmented = NSSegmentedControl()
        segmented.segmentStyle = .separated
        segmented.trackingMode = .momentary
        segmented.segmentCount = 2
        segmented.setImage(
            NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back"),
            forSegment: 0
        )
        segmented.setImage(
            NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward"),
            forSegment: 1
        )
        segmented.target = self
        segmented.action = #selector(navigationSegmentClicked(_:))
        navigationSegmentedControl = segmented

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = segmented
        item.label = "Navigate"
        item.visibilityPriority = .high
        updateNavigationControlEnabledState()
        return item
    }

    @objc private func navigationSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            settingsViewController.goBack()
        case 1:
            settingsViewController.goForward()
        default:
            break
        }
    }

    private func updateNavigationControlEnabledState() {
        guard let control = navigationSegmentedControl else { return }
        control.setEnabled(settingsViewController.canGoBack, forSegment: 0)
        control.setEnabled(settingsViewController.canGoForward, forSegment: 1)
    }

    // MARK: - For Testing

    var navigationToolbarItemIdentifiersForTesting: [NSToolbarItem.Identifier] {
        navigationToolbar.items.map(\.itemIdentifier)
    }

    var navigationSegmentedControlForTesting: NSSegmentedControl? {
        navigationSegmentedControl
    }
}

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settingsSidebarTrackingSeparator, .settingsBackForward]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .settingsSidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: settingsViewController.navigationSplitView,
                dividerIndex: 0
            )
        case .settingsBackForward:
            return makeBackForwardToolbarItem(identifier: itemIdentifier)
        default:
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let settingsBackForward = NSToolbarItem.Identifier("be.zenjoy.Zentty.settings.backForward")
    static let settingsSidebarTrackingSeparator =
        NSToolbarItem.Identifier("be.zenjoy.Zentty.settings.sidebarTrackingSeparator")
}

private extension NSWindow {
    @discardableResult
    func placeOnHostedTestScreenIfNeeded() -> NSWindow? {
        guard
            let screenName = ProcessInfo.processInfo.environment["ZENTTY_TEST_SCREEN_NAME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !screenName.isEmpty,
            let screen = NSScreen.screens.first(where: { $0.localizedName == screenName })
        else {
            return nil
        }

        let visibleFrame = screen.visibleFrame
        if frame.intersects(visibleFrame) {
            return self
        }

        let targetSize = NSSize(
            width: min(max(frame.width, 1), visibleFrame.width),
            height: min(max(frame.height, 1), visibleFrame.height)
        )
        let targetFrame = NSRect(
            x: visibleFrame.midX - targetSize.width / 2,
            y: visibleFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        ).integral
        setFrame(targetFrame, display: false)
        return self
    }
}

@MainActor
final class SettingsViewController: NSSplitViewController, SettingsSidebarViewControllerDelegate {
    /// Seed width used by `SettingsScrollableSectionViewController` to lay out
    /// its document view before the detail pane reports its real bounds.
    static let preferredContentWidth: CGFloat = 760
    // Dimensions mirror the Raycast settings window: 981×786 content with a
    // 227pt sidebar (≈754pt detail). The sidebar scrolls, so the height need
    // not fit every row.
    static let sidebarWidth: CGFloat = 227
    static let detailMinimumWidth: CGFloat = 540
    static let defaultContentSize = NSSize(width: 981, height: 786)
    static let minimumContentSize = NSSize(
        width: sidebarWidth + detailMinimumWidth,
        height: 460
    )

    private let configStore: AppConfigStore
    private var configObserverID: UUID?
    private lazy var generalViewController = GeneralSettingsSectionViewController(configStore: configStore)
    private lazy var notificationsViewController = NotificationsSettingsSectionViewController(
        configStore: configStore
    )
    private lazy var updatesPrivacyViewController = UpdatesPrivacySettingsSectionViewController(
        configStore: configStore,
        errorReportingBundleConfigurationProvider: errorReportingBundleConfigurationProvider,
        errorReportingConfirmationPresenter: errorReportingConfirmationPresenter,
        errorReportingRestartHandler: errorReportingRestartHandler,
        runtimeErrorReportingEnabled: runtimeErrorReportingEnabled
    )
    private lazy var appearanceViewController: AppearanceSettingsSectionViewController = {
        let configEnvironment = GhosttyConfigEnvironment(appConfigProvider: { [weak configStore] in
            configStore?.current ?? .default
        })
        let resolver = GhosttyThemeResolver(configEnvironment: configEnvironment)
        return AppearanceSettingsSectionViewController(
            configCoordinator: GhosttyAppearanceSettingsCoordinator(configStore: configStore),
            currentThemeName: resolver.currentThemeName(for:),
            currentBackgroundOpacity: resolver.currentBackgroundOpacity
        )
    }()
    private lazy var shortcutsViewController = ShortcutsSettingsSectionViewController(configStore: configStore)
    private lazy var mobileDevicesViewController = MobileDevicesSettingsSectionViewController(configStore: configStore)
    private lazy var paneLayoutViewController = PaneLayoutSettingsSectionViewController(configStore: configStore)
    private lazy var agentsViewController = AgentsSettingsSectionViewController(
        configStore: configStore,
        agentTeamsEnableWarningPresenter: agentTeamsEnableWarningPresenter
    )
    private let openWithViewController: OpenWithSettingsSectionViewController
    private let serverBrowserSettingsViewController: ServerBrowserSettingsSectionViewController
    private let errorReportingBundleConfigurationProvider: ErrorReportingBundleConfigurationProvider
    private let errorReportingConfirmationPresenter: ErrorReportingConfirmationPresenter
    private let errorReportingRestartHandler: ErrorReportingRestartHandler
    private let agentTeamsEnableWarningPresenter: AgentTeamsEnableWarningPresenter
    private let runtimeErrorReportingEnabled: Bool

    private lazy var sidebarViewController: SettingsSidebarViewController = {
        let controller = SettingsSidebarViewController()
        controller.delegate = self
        return controller
    }()
    private let detailContainer = SettingsDetailContainerViewController()
    private weak var hostWindow: NSWindow?

    private(set) var selectedSection: SettingsSection
    private var history: SettingsNavigationHistory
    /// Fired whenever back/forward availability may have changed, so the
    /// toolbar control can refresh its enabled state.
    var onNavigationStateChange: (() -> Void)?
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var onPrepareSectionForPresentationForTesting: ((SettingsSection, SettingsSection) -> Void)?

    var currentSectionViewController: NSViewController? {
        sectionViewController(for: selectedSection)
    }

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing,
        serverOpenService: ServerOpening,
        customAppPicker: @escaping () -> OpenWithCustomApp?,
        errorReportingBundleConfigurationProvider: @escaping ErrorReportingBundleConfigurationProvider,
        errorReportingConfirmationPresenter: @escaping ErrorReportingConfirmationPresenter,
        errorReportingRestartHandler: @escaping ErrorReportingRestartHandler,
        agentTeamsEnableWarningPresenter: @escaping AgentTeamsEnableWarningPresenter,
        runtimeErrorReportingEnabled: Bool,
        initialSection: SettingsSection
    ) {
        self.configStore = configStore
        self.selectedSection = initialSection
        self.history = SettingsNavigationHistory(initial: initialSection)
        self.errorReportingBundleConfigurationProvider = errorReportingBundleConfigurationProvider
        self.errorReportingConfirmationPresenter = errorReportingConfirmationPresenter
        self.errorReportingRestartHandler = errorReportingRestartHandler
        self.agentTeamsEnableWarningPresenter = agentTeamsEnableWarningPresenter
        self.runtimeErrorReportingEnabled = runtimeErrorReportingEnabled
        self.openWithViewController = OpenWithSettingsSectionViewController(
            configStore: configStore,
            openWithService: openWithService,
            customAppPicker: customAppPicker
        )
        self.serverBrowserSettingsViewController = ServerBrowserSettingsSectionViewController(
            configStore: configStore,
            serverOpenService: serverOpenService
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let configObserverID {
            configStore.removeObserver(configObserverID)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSplitViewItems()
        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor [weak self] in
                self?.apply(config: config)
            }
        }
        apply(config: configStore.current)
        applySelection(selectedSection)
        onNavigationStateChange?()
    }

    /// Builds the sidebar + detail split items on `self` (the split-view
    /// controller is the window's content view controller, which is what lets
    /// AppKit render the sidebar full-height behind the titlebar instead of as
    /// an inset card). `allowsFullHeightLayout` opts both panes into that.
    private func setupSplitViewItems() {
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(
            rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue + 1
        )

        let detailItem = NSSplitViewItem(viewController: detailContainer)
        detailItem.canCollapse = false
        detailItem.minimumThickness = Self.detailMinimumWidth
        detailItem.allowsFullHeightLayout = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attach(to: view.window)
    }

    var sectionTitles: [String] {
        SettingsSidebarViewController.flatten(SettingsSidebarLayout.groups).compactMap { row in
            if case let .section(section) = row {
                return section.title
            }
            return nil
        }
    }

    var contentSectionTitle: String {
        selectedSection.title
    }

    func attach(to window: NSWindow?) {
        hostWindow = window
    }

    /// The split view backing the sidebar/detail layout, exposed so the host
    /// window can anchor an `NSTrackingSeparatorToolbarItem` to its divider.
    var navigationSplitView: NSSplitView {
        _ = view
        return splitView
    }

    func handleAppearanceChange() {
        _ = view
        view.layoutSubtreeIfNeeded()
        (currentSectionViewController as? SettingsAppearanceUpdating)?.handleAppearanceChange()
        sidebarViewController.handleAppearanceChange()
    }

    func select(section: SettingsSection) {
        select(section: section, animated: false)
    }

    func select(section: SettingsSection, animated _: Bool) {
        _ = view
        navigate(to: section, recordHistory: true)
    }

    /// Replays the previous entry in the navigation history, if any.
    func goBack() {
        guard let section = history.goBack() else { return }
        applySelection(section)
        onNavigationStateChange?()
    }

    /// Replays the next entry in the navigation history, if any.
    func goForward() {
        guard let section = history.goForward() else { return }
        applySelection(section)
        onNavigationStateChange?()
    }

    // MARK: - SettingsSidebarViewControllerDelegate

    func settingsSidebar(_: SettingsSidebarViewController, didSelect section: SettingsSection) {
        navigate(to: section, recordHistory: true)
    }

    /// Forward navigation entry point: optionally records history, shows the
    /// section, and refreshes back/forward availability. Back/forward replays
    /// call `applySelection` directly so they don't mutate the stack.
    private func navigate(to section: SettingsSection, recordHistory: Bool) {
        if recordHistory {
            history.record(section)
        }
        applySelection(section)
        onNavigationStateChange?()
    }

    /// Handles ⌘[ / ⌘] for back/forward, scoped to the settings window via
    /// `SettingsWindow.performKeyEquivalent`. Returns `false` for everything
    /// else (and when the direction is unavailable) so the event keeps propagating.
    func handlePerformKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let unsupportedModifiers = modifiers.subtracting([.command, .capsLock])
        guard modifiers.contains(.command), unsupportedModifiers.isEmpty else {
            return false
        }
        switch event.charactersIgnoringModifiers {
        case "[":
            guard canGoBack else { return false }
            goBack()
            return true
        case "]":
            guard canGoForward else { return false }
            goForward()
            return true
        default:
            return false
        }
    }

    private func applySelection(_ section: SettingsSection) {
        _ = view
        onPrepareSectionForPresentationForTesting?(section, selectedSection)

        let contentViewController = sectionViewController(for: section)
        detailContainer.setContent(contentViewController, section: section)
        (contentViewController as? SettingsPresentingSection)?.prepareForPresentation()

        selectedSection = section
        let title = section.title
        hostWindow?.title = title
        view.window?.title = title
        sidebarViewController.select(section: section)
    }

    private func apply(config: AppConfig) {
        generalViewController.apply(confirmations: config.confirmations)
        generalViewController.apply(restore: config.restore)
        generalViewController.apply(clipboard: config.clipboard)
        notificationsViewController.apply(notifications: config.notifications)
        mobileDevicesViewController.apply(companion: config.companion)
        updatesPrivacyViewController.apply(updates: config.updates)
        updatesPrivacyViewController.apply(errorReporting: config.errorReporting)
        agentsViewController.apply(
            agentTeams: config.agentTeams,
            agentCaffeination: config.agentCaffeination,
            menuBar: config.menuBar
        )
        shortcutsViewController.apply(shortcuts: config.shortcuts)
        paneLayoutViewController.apply(worklanes: config.worklanes, panes: config.panes, paneLayout: config.paneLayout)
        openWithViewController.apply(preferences: config.openWith)
        serverBrowserSettingsViewController.apply(serverDetection: config.serverDetection)
    }

    private func sectionViewController(for section: SettingsSection) -> NSViewController {
        switch section {
        case .general:
            generalViewController
        case .appearance:
            appearanceViewController
        case .shortcuts:
            shortcutsViewController
        case .notifications:
            notificationsViewController
        case .mobileDevices:
            mobileDevicesViewController
        case .openWith:
            openWithViewController
        case .devServers:
            serverBrowserSettingsViewController
        case .paneLayout:
            paneLayoutViewController
        case .updatesPrivacy:
            updatesPrivacyViewController
        case .agents:
            agentsViewController
        }
    }
}

/// Settings window. Intercepts the back/forward key equivalents (⌘[ / ⌘])
/// before the responder chain, so the shortcuts work regardless of which
/// control holds first responder.
private final class SettingsWindow: NSWindow {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
