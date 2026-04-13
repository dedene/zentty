import AppKit

enum SettingsSection: String, CaseIterable, Equatable, Sendable {
    case general
    case appearance
    case shortcuts
    case openWith
    case paneLayout

    var title: String {
        switch self {
        case .general:
            "General"
        case .appearance:
            "Appearance"
        case .shortcuts:
            "Shortcuts"
        case .openWith:
            "Open With"
        case .paneLayout:
            "Panes"
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
        case .openWith:
            "square.and.arrow.up.on.square"
        case .paneLayout:
            "rectangle.split.3x1"
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
        case .openWith:
            .systemBlue
        case .paneLayout:
            .systemPurple
        }
    }
}

enum SettingsNavigationPlacement: Equatable {
    case topBar
}

enum SettingsTransitionProfile {
    static let standardDuration: TimeInterval = 0.30
    static let reducedMotionDuration: TimeInterval = 0.15
    // Spring-like overshoot: controlPoint1.y > 1 creates natural overshoot
    static let controlPoint1 = CGPoint(x: 0.34, y: 1.18)
    static let controlPoint2 = CGPoint(x: 0.64, y: 1)
    static let slideOffset: CGFloat = 16

    static func resolvedDuration(reducedMotion: Bool) -> TimeInterval {
        reducedMotion ? reducedMotionDuration : standardDuration
    }

    static func resolvedTimingFunction(reducedMotion: Bool) -> CAMediaTimingFunction {
        if reducedMotion {
            return CAMediaTimingFunction(name: .easeOut)
        }
        return CAMediaTimingFunction(
            controlPoints: Float(controlPoint1.x),
            Float(controlPoint1.y),
            Float(controlPoint2.x),
            Float(controlPoint2.y)
        )
    }
}

@MainActor
protocol SettingsPaneMeasuring: AnyObject {
    func preferredViewportHeight(for width: CGFloat) -> CGFloat
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing = OpenWithService(),
        customAppPicker: @escaping () -> OpenWithCustomApp? = OpenWithSettingsSectionViewController.defaultCustomAppPicker,
        errorReportingBundleConfigurationProvider: @escaping ErrorReportingBundleConfigurationProvider = {
            ErrorReportingBundleConfiguration.load(from: .main)
        },
        errorReportingConfirmationPresenter: @escaping ErrorReportingConfirmationPresenter = ErrorReportingRestartConfirmation.present,
        errorReportingRestartHandler: @escaping ErrorReportingRestartHandler = ErrorReportingApplicationRestart.restart,
        runtimeErrorReportingEnabled: Bool = ErrorReportingRuntimeState.isEnabledForCurrentProcess,
        appearance: NSAppearance? = nil,
        initialSection: SettingsSection = .shortcuts
    ) {
        let settingsViewController = SettingsViewController(
            configStore: configStore,
            openWithService: openWithService,
            customAppPicker: customAppPicker,
            errorReportingBundleConfigurationProvider: errorReportingBundleConfigurationProvider,
            errorReportingConfirmationPresenter: errorReportingConfirmationPresenter,
            errorReportingRestartHandler: errorReportingRestartHandler,
            runtimeErrorReportingEnabled: runtimeErrorReportingEnabled,
            initialSection: initialSection
        )
        let initialContentSize = NSSize(width: SettingsViewController.preferredContentWidth, height: 440)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = initialSection.title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.center()
        if #available(macOS 13.0, *) {
            window.toolbarStyle = .preference
        }
        window.contentViewController = settingsViewController
        settingsViewController.attach(to: window)
        settingsViewController.loadViewIfNeeded()
        settingsViewController.select(section: initialSection, animated: false)

        self.settingsViewController = settingsViewController
        super.init(window: window)
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
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
        settingsViewController.handleAppearanceChange()
    }
}

@MainActor
final class SettingsViewController: NSTabViewController {
    private enum Layout {
        static let minimumContentHeight: CGFloat = 340
        static let maximumScreenHeightFraction: CGFloat = 2.0 / 3.0
        static let toolbarIconBottomPadding: CGFloat = 4
    }

    static let preferredContentWidth: CGFloat = 760

    private struct SectionEntry {
        let section: SettingsSection
        let contentViewController: NSViewController
        let tabViewItem: NSTabViewItem
    }

    private struct PendingTransition {
        let id: Int
        let section: SettingsSection
        let animated: Bool
    }

    private let configStore: AppConfigStore
    private var configObserverID: UUID?
    private lazy var generalViewController = GeneralSettingsSectionViewController(
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
    private lazy var paneLayoutViewController = PaneLayoutSettingsSectionViewController(configStore: configStore)
    private let openWithViewController: OpenWithSettingsSectionViewController
    private let errorReportingBundleConfigurationProvider: ErrorReportingBundleConfigurationProvider
    private let errorReportingConfirmationPresenter: ErrorReportingConfirmationPresenter
    private let errorReportingRestartHandler: ErrorReportingRestartHandler
    private let runtimeErrorReportingEnabled: Bool
    private var entriesBySection: [SettingsSection: SectionEntry] = [:]
    private weak var hostWindow: NSWindow?
    private var isSynchronizingSelection = false
    private var currentTransitionID = 0
    private var pendingTransition: PendingTransition?

    private(set) var selectedSection: SettingsSection

    var currentSectionViewController: NSViewController? {
        entriesBySection[selectedSection]?.contentViewController
    }

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing,
        customAppPicker: @escaping () -> OpenWithCustomApp?,
        errorReportingBundleConfigurationProvider: @escaping ErrorReportingBundleConfigurationProvider,
        errorReportingConfirmationPresenter: @escaping ErrorReportingConfirmationPresenter,
        errorReportingRestartHandler: @escaping ErrorReportingRestartHandler,
        runtimeErrorReportingEnabled: Bool,
        initialSection: SettingsSection
    ) {
        self.configStore = configStore
        self.selectedSection = initialSection
        self.errorReportingBundleConfigurationProvider = errorReportingBundleConfigurationProvider
        self.errorReportingConfirmationPresenter = errorReportingConfirmationPresenter
        self.errorReportingRestartHandler = errorReportingRestartHandler
        self.runtimeErrorReportingEnabled = runtimeErrorReportingEnabled
        self.openWithViewController = OpenWithSettingsSectionViewController(
            configStore: configStore,
            openWithService: openWithService,
            customAppPicker: customAppPicker
        )
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
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
        tabStyle = .toolbar
        transitionOptions = []
        configureTabsIfNeeded()

        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor [weak self] in
                self?.apply(config: config)
            }
        }
        apply(config: configStore.current)
        select(section: selectedSection, animated: false)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attach(to: view.window)
        synchronizeWindow(animated: false, transitionID: currentTransitionID)
    }

    var navigationPlacement: SettingsNavigationPlacement {
        .topBar
    }

    var sectionTitles: [String] {
        SettingsSection.allCases.map(\.title)
    }

    var contentSectionTitle: String {
        selectedSection.title
    }

    func attach(to window: NSWindow?) {
        hostWindow = window
    }

    func handleAppearanceChange() {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        (currentSectionViewController as? SettingsAppearanceUpdating)?.handleAppearanceChange()
    }

    func select(section: SettingsSection) {
        select(section: section, animated: hostWindow?.isVisible == true && selectedSection != section)
    }

    func select(section: SettingsSection, animated: Bool) {
        loadViewIfNeeded()
        guard let entry = entriesBySection[section] else {
            return
        }

        let isChangingSection = selectedSection != section
        let shouldAnimate = animated && isChangingSection
        if
            shouldAnimate,
            let window = hostWindow ?? view.window,
            let targetFrame = targetWindowFrame(for: section, window: window),
            targetFrame.height > window.frame.height
        {
            window.setFrame(targetFrame, display: false)
        }
        let transitionID = prepareTransition(to: section, animated: shouldAnimate)

        if tabView.selectedTabViewItem !== entry.tabViewItem {
            isSynchronizingSelection = true
            tabView.selectTabViewItem(entry.tabViewItem)
            isSynchronizingSelection = false
        }

        handleSelectionChange(to: section, animated: shouldAnimate, transitionID: transitionID)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard
            isSynchronizingSelection == false,
            let identifier = tabViewItem?.identifier as? String,
            let section = SettingsSection(rawValue: identifier)
        else {
            return
        }

        let transition = (pendingTransition?.section == section ? pendingTransition : nil)
            ?? PendingTransition(
                id: prepareTransition(
                    to: section,
                    animated: hostWindow?.isVisible == true && selectedSection != section
                ),
                section: section,
                animated: hostWindow?.isVisible == true && selectedSection != section
            )
        handleSelectionChange(to: section, animated: transition.animated, transitionID: transition.id)
    }

    override func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        guard
            isSynchronizingSelection == false,
            let identifier = tabViewItem?.identifier as? String,
            let section = SettingsSection(rawValue: identifier)
        else {
            return true
        }

        _ = prepareTransition(
            to: section,
            animated: hostWindow?.isVisible == true && selectedSection != section
        )
        return true
    }

    private func configureTabsIfNeeded() {
        guard entriesBySection.isEmpty else {
            return
        }

        for section in SettingsSection.allCases {
            let contentViewController = sectionViewController(for: section)
            let tabViewItem = NSTabViewItem(viewController: contentViewController)
            tabViewItem.identifier = section.rawValue
            tabViewItem.label = section.title
            let image = NSImage(
                systemSymbolName: section.symbolName,
                accessibilityDescription: section.title
            )
            let baseImage: NSImage?
            if section == .openWith {
                baseImage = image?.withSymbolConfiguration(
                    .init(pointSize: 0, weight: .regular, scale: .medium)
                )
            } else {
                baseImage = image
            }
            if let baseImage {
                let padded = NSImage(
                    size: NSSize(
                        width: baseImage.size.width,
                        height: baseImage.size.height + Layout.toolbarIconBottomPadding
                    ),
                    flipped: false
                ) { _ in
                    baseImage.draw(in: NSRect(
                        x: 0,
                        y: Layout.toolbarIconBottomPadding,
                        width: baseImage.size.width,
                        height: baseImage.size.height
                    ))
                    return true
                }
                padded.isTemplate = true
                tabViewItem.image = padded
            } else {
                tabViewItem.image = nil
            }

            addTabViewItem(tabViewItem)
            entriesBySection[section] = SectionEntry(
                section: section,
                contentViewController: contentViewController,
                tabViewItem: tabViewItem
            )
        }
    }

    private func apply(config: AppConfig) {
        generalViewController.apply(notifications: config.notifications)
        generalViewController.apply(confirmations: config.confirmations)
        generalViewController.apply(restore: config.restore)
        generalViewController.apply(clipboard: config.clipboard)
        generalViewController.apply(restore: config.restore)
        generalViewController.apply(updates: config.updates)
        generalViewController.apply(errorReporting: config.errorReporting)
        shortcutsViewController.apply(shortcuts: config.shortcuts)
        paneLayoutViewController.apply(panes: config.panes)
        openWithViewController.apply(preferences: config.openWith)
        synchronizeWindow(animated: false, transitionID: currentTransitionID)
    }

    private func sectionViewController(for section: SettingsSection) -> NSViewController {
        switch section {
        case .general:
            generalViewController
        case .appearance:
            appearanceViewController
        case .shortcuts:
            shortcutsViewController
        case .openWith:
            openWithViewController
        case .paneLayout:
            paneLayoutViewController
        }
    }

    private func handleSelectionChange(to section: SettingsSection, animated: Bool, transitionID: Int) {
        selectedSection = section
        synchronizeWindow(animated: animated, transitionID: transitionID)
    }

    @discardableResult
    private func prepareTransition(to section: SettingsSection, animated: Bool) -> Int {
        currentTransitionID += 1
        let transitionID = currentTransitionID
        pendingTransition = PendingTransition(id: transitionID, section: section, animated: animated)
        transitionOptions = []
        setScrollerSuppressed(true)

        if let presentingSection = entriesBySection[section]?.contentViewController as? SettingsPresentingSection {
            presentingSection.prepareForPresentation()
        }

        return transitionID
    }

    private func setScrollerSuppressed(_ suppressed: Bool) {
        entriesBySection.values.forEach { entry in
            (entry.contentViewController as? SettingsScrollableSectionViewController)?
                .setScrollerSuppressed(suppressed)
        }
    }

    private func completeTransitionIfCurrent(_ transitionID: Int) {
        guard transitionID == currentTransitionID else {
            return
        }

        if pendingTransition?.id == transitionID {
            pendingTransition = nil
        }
        setScrollerSuppressed(false)
    }

    private func synchronizeWindow(animated: Bool, transitionID: Int) {
        guard let window = hostWindow ?? view.window else {
            return
        }

        hostWindow = window
        window.title = selectedSection.title

        guard let entry = entriesBySection[selectedSection] else {
            return
        }

        let targetHeight = targetContentHeight(
            for: entry.contentViewController,
            window: window,
            screen: window.screen ?? NSScreen.main
        )
        let targetContentSize = NSSize(width: Self.preferredContentWidth, height: targetHeight)
        let targetFrame = targetWindowFrame(for: targetContentSize, window: window)

        if animated {
            let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let duration = SettingsTransitionProfile.resolvedDuration(reducedMotion: reducedMotion)
            let timingFunction = SettingsTransitionProfile.resolvedTimingFunction(reducedMotion: reducedMotion)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = timingFunction
                context.allowsImplicitAnimation = true
                window.animator().setFrame(targetFrame, display: false)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.completeTransitionIfCurrent(transitionID)
                }
            }
        } else {
            window.setFrame(targetFrame, display: false)
            completeTransitionIfCurrent(transitionID)
        }
    }

    private func targetWindowFrame(for contentSize: NSSize, window: NSWindow) -> NSRect {
        let currentFrame = window.frame
        let topEdge = currentFrame.maxY
        let targetFrameSize = window.frameRect(forContentRect: NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: contentSize.height
        )).size

        return NSRect(
            x: currentFrame.minX,
            y: topEdge - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
    }

    private func targetWindowFrame(for section: SettingsSection, window: NSWindow) -> NSRect? {
        guard let entry = entriesBySection[section] else {
            return nil
        }

        let targetHeight = targetContentHeight(
            for: entry.contentViewController,
            window: window,
            screen: window.screen ?? NSScreen.main
        )
        return targetWindowFrame(
            for: NSSize(width: Self.preferredContentWidth, height: targetHeight),
            window: window
        )
    }

    private func targetContentHeight(
        for contentViewController: NSViewController,
        window: NSWindow,
        screen: NSScreen?
    ) -> CGFloat {
        let measuredHeight = (contentViewController as? SettingsPaneMeasuring)?
            .preferredViewportHeight(for: Self.preferredContentWidth)
            ?? Layout.minimumContentHeight
        let maxFrameHeight = max(
            Layout.minimumContentHeight,
            floor((screen?.visibleFrame.height ?? 900) * Layout.maximumScreenHeightFraction)
        )
        let maxContentHeight = max(
            Layout.minimumContentHeight,
            window.contentRect(forFrameRect: NSRect(
                x: 0,
                y: 0,
                width: Self.preferredContentWidth,
                height: maxFrameHeight
            )).height
        )
        return min(max(measuredHeight, Layout.minimumContentHeight), maxContentHeight)
    }
}
