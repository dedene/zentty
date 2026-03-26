import AppKit

enum SettingsSection: String, CaseIterable, Equatable, Sendable {
    case openWith
    case paneLayout

    var title: String {
        switch self {
        case .openWith:
            "Open With"
        case .paneLayout:
            "Pane Layout"
        }
    }

    var symbolName: String {
        switch self {
        case .openWith:
            "square.and.arrow.up.on.square"
        case .paneLayout:
            "rectangle.split.3x1"
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .openWith:
            .systemBlue
        case .paneLayout:
            .systemPurple
        }
    }
}

// MARK: - Window Controller

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing = OpenWithService(),
        customAppPicker: @escaping () -> OpenWithCustomApp? = OpenWithSettingsSectionViewController.defaultCustomAppPicker,
        initialSection: SettingsSection = .paneLayout
    ) {
        let settingsViewController = SettingsViewController(
            configStore: configStore,
            openWithService: openWithService,
            customAppPicker: customAppPicker,
            initialSection: initialSection
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        window.contentViewController = settingsViewController

        self.settingsViewController = settingsViewController
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(section: SettingsSection, sender: Any?) {
        settingsViewController.select(section: section)
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}

// MARK: - Settings View Controller

@MainActor
final class SettingsViewController: NSViewController {
    private enum Layout {
        static let sidebarWidth: CGFloat = 200
        static let sidebarInset: CGFloat = 12
        static let sidebarItemSpacing: CGFloat = 2
        static let contentInset: CGFloat = 24
        static let separatorWidth: CGFloat = 1
    }

    private let configStore: AppConfigStore
    private var configObserverID: UUID?
    private let sidebarStackView = NSStackView()
    private let separatorView = NSBox()
    private let contentTitleLabel = NSTextField(labelWithString: "")
    private let contentContainerView = NSView()
    private var itemsBySection: [SettingsSection: SettingsSidebarItemView] = [:]
    private lazy var paneLayoutViewController = PaneLayoutSettingsSectionViewController()
    private let openWithViewController: OpenWithSettingsSectionViewController

    private(set) var selectedSection: SettingsSection
    private(set) var currentSectionViewController: NSViewController?

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing,
        customAppPicker: @escaping () -> OpenWithCustomApp?,
        initialSection: SettingsSection
    ) {
        self.configStore = configStore
        self.selectedSection = initialSection
        self.openWithViewController = OpenWithSettingsSectionViewController(
            configStore: configStore,
            openWithService: openWithService,
            customAppPicker: customAppPicker
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

    override func loadView() {
        let rootView = NSView()

        let windowBackgroundView = NSVisualEffectView()
        windowBackgroundView.material = .underWindowBackground
        windowBackgroundView.blendingMode = .behindWindow
        windowBackgroundView.state = .active
        windowBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(windowBackgroundView)

        let sidebarBackgroundView = NSVisualEffectView()
        sidebarBackgroundView.material = .sidebar
        sidebarBackgroundView.blendingMode = .behindWindow
        sidebarBackgroundView.state = .active
        sidebarBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(sidebarBackgroundView)

        sidebarStackView.orientation = .vertical
        sidebarStackView.alignment = .leading
        sidebarStackView.spacing = Layout.sidebarItemSpacing
        sidebarStackView.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackgroundView.addSubview(sidebarStackView)

        SettingsSection.allCases.forEach { section in
            let itemView = SettingsSidebarItemView(section: section) { [weak self] selected in
                self?.select(section: selected)
            }
            itemsBySection[section] = itemView
            sidebarStackView.addArrangedSubview(itemView)
            itemView.widthAnchor.constraint(
                equalToConstant: Layout.sidebarWidth - (Layout.sidebarInset * 2)
            ).isActive = true
        }

        separatorView.boxType = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(separatorView)

        contentTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        contentTitleLabel.textColor = .labelColor
        contentTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentTitleLabel)

        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(contentContainerView)

        NSLayoutConstraint.activate([
            windowBackgroundView.topAnchor.constraint(equalTo: rootView.topAnchor),
            windowBackgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            windowBackgroundView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            windowBackgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarBackgroundView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarBackgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarBackgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarBackgroundView.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),

            sidebarStackView.topAnchor.constraint(
                equalTo: sidebarBackgroundView.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            sidebarStackView.leadingAnchor.constraint(
                equalTo: sidebarBackgroundView.leadingAnchor,
                constant: Layout.sidebarInset
            ),
            sidebarStackView.trailingAnchor.constraint(
                equalTo: sidebarBackgroundView.trailingAnchor,
                constant: -Layout.sidebarInset
            ),

            separatorView.topAnchor.constraint(equalTo: rootView.topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            separatorView.leadingAnchor.constraint(equalTo: sidebarBackgroundView.trailingAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: Layout.separatorWidth),

            contentTitleLabel.topAnchor.constraint(
                equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 12
            ),
            contentTitleLabel.leadingAnchor.constraint(
                equalTo: separatorView.trailingAnchor, constant: Layout.contentInset
            ),

            contentContainerView.topAnchor.constraint(
                equalTo: contentTitleLabel.bottomAnchor, constant: 16
            ),
            contentContainerView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configObserverID = configStore.addObserver { [weak self] config in
            Task { @MainActor [weak self] in
                self?.apply(config: config)
            }
        }
        apply(config: configStore.current)
        select(section: selectedSection)
    }

    var sectionTitles: [String] {
        SettingsSection.allCases.map(\.title)
    }

    var contentSectionTitle: String {
        selectedSection.title
    }

    func select(section: SettingsSection) {
        loadViewIfNeeded()
        selectedSection = section
        contentTitleLabel.stringValue = section.title
        updateSidebarSelection()
        swapContentViewController(to: sectionViewController(for: section))
        if section == .openWith {
            openWithViewController.prepareForPresentation()
        }
    }

    private func apply(config: AppConfig) {
        paneLayoutViewController.apply(preferences: config.paneLayout)
        openWithViewController.apply(preferences: config.openWith)
    }

    private func sectionViewController(for section: SettingsSection) -> NSViewController {
        switch section {
        case .openWith:
            openWithViewController
        case .paneLayout:
            paneLayoutViewController
        }
    }

    private func swapContentViewController(to nextViewController: NSViewController) {
        guard currentSectionViewController !== nextViewController else {
            return
        }

        currentSectionViewController?.view.removeFromSuperview()
        currentSectionViewController?.removeFromParent()

        addChild(nextViewController)
        nextViewController.loadViewIfNeeded()
        let nextView = nextViewController.view
        nextView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(nextView)
        NSLayoutConstraint.activate([
            nextView.topAnchor.constraint(equalTo: contentContainerView.topAnchor, constant: Layout.contentInset),
            nextView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: Layout.contentInset),
            nextView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor, constant: -Layout.contentInset),
            nextView.bottomAnchor.constraint(lessThanOrEqualTo: contentContainerView.bottomAnchor, constant: -Layout.contentInset),
        ])
        currentSectionViewController = nextViewController
    }

    private func updateSidebarSelection() {
        for (section, itemView) in itemsBySection {
            itemView.isSelected = section == selectedSection
        }
    }
}

// MARK: - Sidebar Item View

@MainActor
private final class SettingsSidebarItemView: NSView {
    private enum Layout {
        static let height: CGFloat = 36
        static let iconSize: CGFloat = 28
        static let iconCornerRadius: CGFloat = 7
        static let symbolPointSize: CGFloat = 14
        static let horizontalPadding: CGFloat = 6
        static let iconLabelSpacing: CGFloat = 8
        static let cornerRadius: CGFloat = 8
    }

    let section: SettingsSection
    private let onClick: (SettingsSection) -> Void
    private let iconContainerView = NSView()
    private let iconGradientLayer = CAGradientLayer()
    private let iconImageView = NSImageView()
    private let titleLabel: NSTextField
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    init(section: SettingsSection, onClick: @escaping (SettingsSection) -> Void) {
        self.section = section
        self.onClick = onClick
        self.titleLabel = NSTextField(labelWithString: section.title)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Layout.cornerRadius
        layer?.cornerCurve = .continuous

        setupIconBadge()
        setupLabel()
        setupConstraints()
        setupAccessibility()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupIconBadge() {
        iconContainerView.wantsLayer = true
        iconContainerView.layer?.cornerRadius = Layout.iconCornerRadius
        iconContainerView.layer?.cornerCurve = .continuous
        iconContainerView.layer?.masksToBounds = false

        let color = section.badgeColor
        iconGradientLayer.cornerRadius = Layout.iconCornerRadius
        iconGradientLayer.cornerCurve = .continuous
        iconGradientLayer.startPoint = CGPoint(x: 0, y: 0)
        iconGradientLayer.endPoint = CGPoint(x: 1, y: 1)
        iconGradientLayer.colors = [
            (color.blended(withFraction: 0.15, of: .white) ?? color).cgColor,
            (color.blended(withFraction: 0.1, of: .black) ?? color).cgColor,
        ]
        iconContainerView.layer?.addSublayer(iconGradientLayer)

        iconContainerView.layer?.shadowColor = NSColor.black.cgColor
        iconContainerView.layer?.shadowOpacity = 0.25
        iconContainerView.layer?.shadowRadius = 0.5
        iconContainerView.layer?.shadowOffset = CGSize(width: 0, height: -0.5)

        iconContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconContainerView)

        let config = NSImage.SymbolConfiguration(pointSize: Layout.symbolPointSize, weight: .medium)
        iconImageView.image = NSImage(
            systemSymbolName: section.symbolName,
            accessibilityDescription: section.title
        )?.withSymbolConfiguration(config)
        iconImageView.contentTintColor = .white
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconContainerView.addSubview(iconImageView)
    }

    private func setupLabel() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
    }

    private func setupConstraints() {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Layout.height),

            iconContainerView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Layout.horizontalPadding
            ),
            iconContainerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainerView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconContainerView.heightAnchor.constraint(equalToConstant: Layout.iconSize),

            iconImageView.centerXAnchor.constraint(equalTo: iconContainerView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainerView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: iconContainerView.trailingAnchor, constant: Layout.iconLabelSpacing
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Layout.horizontalPadding
            ),
        ])
    }

    private func setupAccessibility() {
        setAccessibilityRole(.button)
        setAccessibilityLabel(section.title)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        iconGradientLayer.frame = iconContainerView.bounds
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        onClick(section)
    }

    // MARK: - Appearance

    private func updateAppearance() {
        let bgColor: NSColor
        if isSelected {
            bgColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
        } else if isHovered {
            bgColor = NSColor.labelColor.withAlphaComponent(0.04)
        } else {
            bgColor = .clear
        }
        layer?.backgroundColor = bgColor.cgColor

        titleLabel.textColor = isSelected ? .controlAccentColor : .labelColor
    }
}
