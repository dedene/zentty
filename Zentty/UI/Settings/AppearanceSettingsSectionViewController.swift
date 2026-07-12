import AppKit

typealias ThemePreviewPreferredFontProvider = (CGFloat, NSFont.Weight) -> NSFont?

enum ThemePreviewTextAttributes {
    static func make(
        foreground: NSColor,
        background: NSColor,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        preferredFontProvider: ThemePreviewPreferredFontProvider = { size, weight in
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    ) -> [NSAttributedString.Key: Any]? {
        guard let font = resolveFont(
            pointSize: pointSize,
            weight: weight,
            preferredFontProvider: preferredFontProvider
        ) else {
            return nil
        }

        return make(font: font, foreground: foreground, background: background)
    }

    static func make(font: NSFont?, foreground: NSColor, background: NSColor) -> [NSAttributedString.Key: Any]? {
        guard let font else {
            return nil
        }

        return [
            .font: font,
            .foregroundColor: resolvedTextColor(foreground: foreground, background: background),
        ]
    }

    private static func resolveFont(
        pointSize: CGFloat,
        weight: NSFont.Weight,
        preferredFontProvider: ThemePreviewPreferredFontProvider
    ) -> NSFont? {
        if let preferred = preferredFontProvider(pointSize, weight) {
            return preferred
        }

        if let fixedPitch = NSFont.userFixedPitchFont(ofSize: pointSize) {
            return fixedPitch
        }

        return NSFont.systemFont(ofSize: pointSize, weight: weight)
    }

    private static func resolvedTextColor(foreground: NSColor, background: NSColor) -> NSColor {
        let resolvedForeground = foreground.srgbClamped
        guard resolvedForeground.alphaComponent > 0 else {
            return background.isDarkThemeColor
                ? NSColor(calibratedWhite: 0.96, alpha: 1)
                : NSColor(calibratedWhite: 0.08, alpha: 1)
        }
        return resolvedForeground
    }
}

@MainActor
final class AppearanceSettingsSectionViewController: SettingsScrollableSectionViewController,
    SettingsAppearanceUpdating {

    private enum Layout {
        static let rowHeight: CGFloat = 56
        static let listWidth: CGFloat = 240
        static let shellHeight: CGFloat = 420
        static let previewPadding: CGFloat = 20
        static let paletteSwatchSize: CGFloat = 24
        static let paletteSpacing: CGFloat = 4
    }

    private enum ThemeCatalogFilterMode: Int {
        case dark
        case light
        case all

        var title: String {
            switch self {
            case .dark:
                "Dark Themes"
            case .light:
                "Light Themes"
            case .all:
                "All"
            }
        }
    }

    private let catalogProvider: any ThemeCatalogProviding
    private let configCoordinator: any AppearanceSettingsConfigCoordinating
    private let currentThemeNameProvider: (NSAppearance?) -> String?
    private let currentBackgroundOpacityProvider: () -> CGFloat?

    private var modeOptionViews: [ThemeModeOptionView] = []
    private let darkSlotView = ThemeSlotTabControl(slot: .dark)
    private let lightSlotView = ThemeSlotTabControl(slot: .light)
    private let currentThemeSummaryLabel = NSTextField(labelWithString: "")
    private let resetThemeButton = NSButton(title: "Reset", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let catalogFilterButton = NSButton()
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let themeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
    private let previewView = ThemePreviewPanel()
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let openCodeThemeSyncSwitch = NSSwitch()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let createSharedConfigButton = NSButton(title: "Create Ghostty Config...", target: nil, action: nil)

    private var allThemes: [ThemePreview] = []
    private var filteredThemes: [ThemePreview] = []
    private var activeThemeName: String?
    private var themePreferences = AppearanceThemePreferences(mode: .alwaysDark, darkThemeName: nil, lightThemeName: nil)
    private var editingThemeSlot = AppearanceThemeSlot.dark
    private var hasUserSelectedThemeSlot = false
    private var catalogFilterMode = ThemeCatalogFilterMode.dark
    private var hasUserSelectedCatalogFilter = false
    private var searchQuery = ""
    private var selectedPreviewTheme: ThemePreview?

    init(
        catalogProvider: any ThemeCatalogProviding = ThemeCatalogService(),
        configCoordinator: any AppearanceSettingsConfigCoordinating = GhosttyAppearanceSettingsCoordinator(
            configStore: AppConfigStore()
        ),
        currentThemeName: @escaping (NSAppearance?) -> String? = GhosttyThemeResolver().currentThemeName(for:),
        currentBackgroundOpacity: @escaping () -> CGFloat? = {
            GhosttyThemeResolver().currentBackgroundOpacity()
        }
    ) {
        self.catalogProvider = catalogProvider
        self.configCoordinator = configCoordinator
        self.currentThemeNameProvider = currentThemeName
        self.currentBackgroundOpacityProvider = currentBackgroundOpacity
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func assembleContent(in contentView: NSView) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        createSharedConfigButton.bezelStyle = .rounded
        createSharedConfigButton.controlSize = .small
        createSharedConfigButton.target = self
        createSharedConfigButton.action = #selector(handleCreateSharedConfig)
        stackView.addArrangedSubview(createSharedConfigButton)

        let modeCard = SettingsCardView()
        let modeStack = NSStackView()
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 12
        modeStack.translatesAutoresizingMaskIntoConstraints = false
        modeCard.addSubview(modeStack)

        let modeHeaderRow = NSStackView()
        modeHeaderRow.orientation = .horizontal
        modeHeaderRow.alignment = .centerY
        modeHeaderRow.spacing = 12
        modeHeaderRow.translatesAutoresizingMaskIntoConstraints = false

        let modeTitleStack = NSStackView()
        modeTitleStack.orientation = .vertical
        modeTitleStack.alignment = .leading
        modeTitleStack.spacing = 2

        let modeTitleLabel = NSTextField(labelWithString: "Theme Behavior")
        modeTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        modeTitleStack.addArrangedSubview(modeTitleLabel)

        currentThemeSummaryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        currentThemeSummaryLabel.textColor = .secondaryLabelColor
        currentThemeSummaryLabel.lineBreakMode = .byTruncatingTail
        modeTitleStack.addArrangedSubview(currentThemeSummaryLabel)

        modeHeaderRow.addArrangedSubview(modeTitleStack)
        modeTitleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let modeHeaderSpacer = NSView()
        modeHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        modeHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modeHeaderRow.addArrangedSubview(modeHeaderSpacer)

        resetThemeButton.bezelStyle = .rounded
        resetThemeButton.controlSize = .small
        resetThemeButton.target = self
        resetThemeButton.action = #selector(handleResetThemePreferences)
        resetThemeButton.setContentHuggingPriority(.required, for: .horizontal)
        modeHeaderRow.addArrangedSubview(resetThemeButton)

        modeStack.addArrangedSubview(modeHeaderRow)
        modeHeaderRow.widthAnchor.constraint(equalTo: modeStack.widthAnchor).isActive = true

        let modeOptionsRow = NSStackView()
        modeOptionsRow.orientation = .horizontal
        modeOptionsRow.alignment = .top
        modeOptionsRow.distribution = .fillEqually
        modeOptionsRow.spacing = 10
        modeOptionsRow.translatesAutoresizingMaskIntoConstraints = false

        modeOptionViews = [
            ThemeModeOptionView(mode: .alwaysDark, title: "Always Dark", subtitle: "Keep Zentty on the selected dark theme."),
            ThemeModeOptionView(mode: .followMacOS, title: "Follow macOS", subtitle: "Use your dark and light picks automatically."),
            ThemeModeOptionView(mode: .alwaysLight, title: "Always Light", subtitle: "Keep Zentty on the selected light theme."),
        ]
        for optionView in modeOptionViews {
            optionView.target = self
            optionView.action = #selector(handleThemeModeSelected(_:))
            modeOptionsRow.addArrangedSubview(optionView)
        }
        modeStack.addArrangedSubview(modeOptionsRow)
        modeOptionsRow.widthAnchor.constraint(equalTo: modeStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            modeStack.topAnchor.constraint(equalTo: modeCard.topAnchor, constant: 16),
            modeStack.leadingAnchor.constraint(equalTo: modeCard.leadingAnchor, constant: 16),
            modeStack.trailingAnchor.constraint(equalTo: modeCard.trailingAnchor, constant: -16),
            modeStack.bottomAnchor.constraint(equalTo: modeCard.bottomAnchor, constant: -16),
        ])
        stackView.addArrangedSubview(modeCard)
        modeCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let card = SettingsCardView()
        let themePickerStack = NSStackView()
        themePickerStack.orientation = .vertical
        themePickerStack.alignment = .leading
        themePickerStack.spacing = 12
        themePickerStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(themePickerStack)

        let themePickerTitleLabel = NSTextField(labelWithString: "Themes")
        themePickerTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        themePickerStack.addArrangedSubview(themePickerTitleLabel)

        let themePickerSubtitleLabel = NSTextField(
            labelWithString: "Choose the dark and light themes used by the behavior above."
        )
        themePickerSubtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        themePickerSubtitleLabel.textColor = .secondaryLabelColor
        themePickerSubtitleLabel.lineBreakMode = .byWordWrapping
        themePickerSubtitleLabel.maximumNumberOfLines = 0
        themePickerStack.addArrangedSubview(themePickerSubtitleLabel)
        themePickerSubtitleLabel.widthAnchor.constraint(equalTo: themePickerStack.widthAnchor).isActive = true

        let slotsRow = NSStackView()
        slotsRow.orientation = .horizontal
        slotsRow.alignment = .top
        slotsRow.distribution = .fillEqually
        slotsRow.spacing = 10
        slotsRow.translatesAutoresizingMaskIntoConstraints = false
        for slotView in [darkSlotView, lightSlotView] {
            slotView.target = self
            slotView.action = #selector(handleThemeSlotSelected(_:))
            slotsRow.addArrangedSubview(slotView)
        }
        themePickerStack.addArrangedSubview(slotsRow)
        slotsRow.widthAnchor.constraint(equalTo: themePickerStack.widthAnchor).isActive = true

        let shellView = NSView()
        shellView.translatesAutoresizingMaskIntoConstraints = false
        themePickerStack.addArrangedSubview(shellView)
        shellView.widthAnchor.constraint(equalTo: themePickerStack.widthAnchor).isActive = true

        // Left: search + theme list
        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 0
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(leftStack)

        configureSearchField()
        configureCatalogFilterControl()
        let searchWrapper = NSView()
        searchWrapper.translatesAutoresizingMaskIntoConstraints = false
        searchWrapper.addSubview(searchField)
        searchWrapper.addSubview(catalogFilterButton)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: searchWrapper.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: searchWrapper.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: catalogFilterButton.leadingAnchor, constant: -8),
            searchField.bottomAnchor.constraint(equalTo: searchWrapper.bottomAnchor, constant: -6),

            catalogFilterButton.trailingAnchor.constraint(equalTo: searchWrapper.trailingAnchor, constant: -10),
            catalogFilterButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            catalogFilterButton.widthAnchor.constraint(equalToConstant: 32),
            catalogFilterButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        leftStack.addArrangedSubview(searchWrapper)
        searchWrapper.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        SettingsFormBuilder.separator(addedTo: leftStack)

        configureTableView()
        leftStack.addArrangedSubview(tableScrollView)
        tableScrollView.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        // Vertical divider between list and preview
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(divider)

        // Right: preview panel
        previewView.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(previewView)

        NSLayoutConstraint.activate([
            themePickerStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            themePickerStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            themePickerStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            themePickerStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            shellView.heightAnchor.constraint(equalToConstant: Layout.shellHeight),

            leftStack.topAnchor.constraint(equalTo: shellView.topAnchor),
            leftStack.leadingAnchor.constraint(equalTo: shellView.leadingAnchor),
            leftStack.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
            leftStack.widthAnchor.constraint(equalToConstant: Layout.listWidth),

            divider.topAnchor.constraint(equalTo: shellView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            previewView.topAnchor.constraint(equalTo: shellView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            previewView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
        ])

        stackView.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Opacity card
        let opacityCard = SettingsCardView()
        let opacityStack = NSStackView()
        opacityStack.orientation = .vertical
        opacityStack.alignment = .leading
        opacityStack.spacing = 10
        opacityStack.translatesAutoresizingMaskIntoConstraints = false
        opacityCard.addSubview(opacityStack)

        let opacityTitleLabel = NSTextField(labelWithString: "Window Opacity")
        opacityTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        opacityStack.addArrangedSubview(opacityTitleLabel)

        let opacityDescLabel = NSTextField(labelWithString: "Controls sidebar and chrome translucency. Lower values reveal more of the content behind.")
        opacityDescLabel.font = .systemFont(ofSize: 11, weight: .regular)
        opacityDescLabel.textColor = .secondaryLabelColor
        opacityDescLabel.lineBreakMode = .byWordWrapping
        opacityDescLabel.maximumNumberOfLines = 0
        opacityStack.addArrangedSubview(opacityDescLabel)
        opacityDescLabel.widthAnchor.constraint(equalTo: opacityStack.widthAnchor).isActive = true

        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 10
        sliderRow.translatesAutoresizingMaskIntoConstraints = false

        configureOpacitySlider()
        sliderRow.addArrangedSubview(opacitySlider)

        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        opacityValueLabel.alignment = .right
        opacityValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        sliderRow.addArrangedSubview(opacityValueLabel)

        opacityStack.addArrangedSubview(sliderRow)
        sliderRow.widthAnchor.constraint(equalTo: opacityStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            opacityStack.topAnchor.constraint(equalTo: opacityCard.topAnchor, constant: 16),
            opacityStack.leadingAnchor.constraint(equalTo: opacityCard.leadingAnchor, constant: 16),
            opacityStack.trailingAnchor.constraint(equalTo: opacityCard.trailingAnchor, constant: -16),
            opacityStack.bottomAnchor.constraint(equalTo: opacityCard.bottomAnchor, constant: -16),
        ])
        stackView.addArrangedSubview(opacityCard)
        opacityCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let openCodeThemeCard = SettingsCardView()
        let openCodeThemeRow = makeSwitchRow(
            title: "Sync OpenCode Theme",
            subtitle: "Override OpenCode's launch theme to match your current terminal theme.",
            toggle: openCodeThemeSyncSwitch,
            action: #selector(handleOpenCodeThemeSyncChanged(_:))
        )
        openCodeThemeCard.addSubview(openCodeThemeRow)
        openCodeThemeRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            openCodeThemeRow.topAnchor.constraint(equalTo: openCodeThemeCard.topAnchor),
            openCodeThemeRow.leadingAnchor.constraint(equalTo: openCodeThemeCard.leadingAnchor),
            openCodeThemeRow.trailingAnchor.constraint(equalTo: openCodeThemeCard.trailingAnchor),
            openCodeThemeRow.bottomAnchor.constraint(equalTo: openCodeThemeCard.bottomAnchor),
        ])
        stackView.addArrangedSubview(openCodeThemeCard)
        openCodeThemeCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshSourceState()
        refreshThemePreferences()
        refreshActiveThemeName()
        refreshOpacitySlider()
        refreshOpenCodeThemeSyncSwitch()
        Task {
            await reloadThemes()
        }
    }

    override func prepareForPresentation() {
        refreshSourceState()
        refreshThemePreferences()
        refreshActiveThemeName()
        refreshOpacitySlider()
        refreshOpenCodeThemeSyncSwitch()
        super.prepareForPresentation()
    }

    func handleAppearanceChange() {
        refreshSourceState()
        refreshThemePreferences()
        refreshActiveThemeName()
        refreshOpacitySlider()
        refreshOpenCodeThemeSyncSwitch()
    }

    // MARK: - Theme State

    private(set) var themes: [ThemePreview] {
        get { filteredThemes }
        set { filteredThemes = newValue }
    }

    var activeThemeNameForTesting: String? {
        activeThemeName
    }

    var themeModeForTesting: AppConfig.Appearance.ThemeMode {
        themePreferences.mode
    }

    var editingThemeSlotForTesting: AppearanceThemeSlot {
        editingThemeSlot
    }

    var currentThemeSummaryForTesting: String {
        currentThemeSummaryLabel.stringValue
    }

    var selectedPreviewThemeNameForTesting: String? {
        selectedPreviewTheme?.name
    }

    var isCreateSharedConfigButtonHiddenForTesting: Bool {
        createSharedConfigButton.isHidden
    }

    var isOpenCodeThemeSyncEnabledForTesting: Bool {
        openCodeThemeSyncSwitch.state == .on
    }

    private func refreshActiveThemeName() {
        let appearance = view.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        activeThemeName = currentThemeNameProvider(appearance) ?? GhosttyThemeLibrary.fallbackThemeName
        currentThemeSummaryLabel.stringValue = "Current: \(displayName(forThemeNamed: activeThemeName))"
        if isViewLoaded {
            tableView.reloadData()
            updatePreviewForCurrentSelection()
        }
    }

    private func refreshThemePreferences() {
        themePreferences = configCoordinator.themePreferences
        if hasUserSelectedThemeSlot {
            // Keep editing the user's chosen slot even when that slot is not the active runtime theme.
        } else if themePreferences.mode == .alwaysLight {
            editingThemeSlot = .light
        } else if themePreferences.mode == .alwaysDark {
            editingThemeSlot = .dark
        }
        updateDefaultCatalogFilterIfNeeded()

        if isViewLoaded {
            updateThemeModeViews()
            updateThemeSlotViews()
            updateCatalogFilterButton()
            applyFilter()
        }
    }

    private func refreshSourceState() {
        let sourceState = configCoordinator.sourceState
        subtitleLabel.stringValue = sourceState.subtitle
        createSharedConfigButton.isHidden = !sourceState.showsCreateSharedConfigAction
    }

    private func applyFilter() {
        filteredThemes = allThemes.filter { theme in
            let matchesSearch = searchQuery.isEmpty
                || theme.displayName.localizedCaseInsensitiveContains(searchQuery)
                || theme.name.localizedCaseInsensitiveContains(searchQuery)
            guard matchesSearch else {
                return false
            }

            guard catalogFilterMode != .all else {
                return true
            }

            return catalogFilterMode == .dark
                ? theme.background.isDarkThemeColor
                : !theme.background.isDarkThemeColor
        }
        tableView.reloadData()
        updatePreviewForCurrentSelection()
    }

    private func applyTheme(_ name: String) {
        setThemeName(name, for: editingThemeSlot)
        tableView.reloadData()
        if let theme = themePreview(named: name, in: filteredThemes) {
            selectedPreviewTheme = theme
            previewView.configure(with: theme)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await applyThemeForTesting(name, slot: editingThemeSlot)
        }
    }

    private func updatePreviewForCurrentSelection() {
        let targetName = themePreferences.themeName(for: editingThemeSlot)
        if let theme = themePreview(named: targetName, in: filteredThemes) {
            selectedPreviewTheme = theme
            previewView.configure(with: theme)
        } else if let first = filteredThemes.first {
            selectedPreviewTheme = first
            previewView.configure(with: first)
        }
    }

    func selectThemeForTesting(_ name: String) {
        applyTheme(name)
    }

    func selectThemeForTesting(_ name: String) async {
        setThemeName(name, for: editingThemeSlot)
        tableView.reloadData()
        if let theme = themePreview(named: name, in: filteredThemes) {
            selectedPreviewTheme = theme
            previewView.configure(with: theme)
        }
        await applyThemeForTesting(name, slot: editingThemeSlot)
    }

    func selectThemeSlotForTesting(_ slot: AppearanceThemeSlot) {
        editingThemeSlot = slot
        hasUserSelectedThemeSlot = true
        updateDefaultCatalogFilterIfNeeded()
        updateThemeSlotViews()
        updateCatalogFilterButton()
        applyFilter()
    }

    func selectThemeModeForTesting(_ mode: AppConfig.Appearance.ThemeMode) async {
        hasUserSelectedThemeSlot = false
        await configCoordinator.applyThemeMode(mode, presentingWindow: view.window)
        refreshThemePreferences()
        refreshActiveThemeName()
    }

    func resetThemePreferencesForTesting() async {
        hasUserSelectedThemeSlot = false
        hasUserSelectedCatalogFilter = false
        await configCoordinator.resetThemePreferences(presentingWindow: view.window)
        refreshThemePreferences()
        refreshActiveThemeName()
    }

    func setThemeCatalogFilterForTesting(_ mode: Int) {
        catalogFilterMode = ThemeCatalogFilterMode(rawValue: mode) ?? .dark
        hasUserSelectedCatalogFilter = true
        updateCatalogFilterButton()
        applyFilter()
    }

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        searchQuery = query
        applyFilter()
    }

    func setOpacityForTesting(_ opacity: CGFloat) {
        opacitySlider.doubleValue = Double(opacity)
        handleOpacityChanged(opacitySlider)
    }

    func setOpacityForTesting(_ opacity: CGFloat) async {
        opacitySlider.doubleValue = Double(opacity)
        updateOpacityLabel(opacity)
        await configCoordinator.applyBackgroundOpacity(opacity, presentingWindow: view.window)
        refreshSourceState()
        refreshActiveThemeName()
        refreshOpacitySlider()
    }

    func setOpenCodeThemeSyncEnabledForTesting(_ enabled: Bool) {
        openCodeThemeSyncSwitch.state = enabled ? .on : .off
        handleOpenCodeThemeSyncChanged(openCodeThemeSyncSwitch)
    }

    func createSharedConfigForTesting() {
        handleCreateSharedConfig()
    }

    func createSharedConfigForTesting() async {
        await configCoordinator.createSharedConfig(presentingWindow: view.window)
        refreshSourceState()
        refreshActiveThemeName()
        refreshOpacitySlider()
    }

    func loadThemesForTesting() async {
        _ = view
        await reloadThemes()
    }

    // MARK: - Search

    private func configureSearchField() {
        searchField.placeholderString = "Search themes"
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(handleSearchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureCatalogFilterControl() {
        catalogFilterButton.bezelStyle = .rounded
        catalogFilterButton.controlSize = .small
        catalogFilterButton.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease",
            accessibilityDescription: "Filter themes"
        )
        catalogFilterButton.imagePosition = .imageOnly
        catalogFilterButton.target = self
        catalogFilterButton.action = #selector(handleCatalogFilterButton)
        catalogFilterButton.translatesAutoresizingMaskIntoConstraints = false
        updateCatalogFilterButton()
    }

    @objc
    private func handleSearchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        applyFilter()
    }

    private func updateDefaultCatalogFilterIfNeeded() {
        guard !hasUserSelectedCatalogFilter else {
            return
        }

        catalogFilterMode = editingThemeSlot == .dark ? .dark : .light
    }

    private func updateCatalogFilterButton() {
        catalogFilterButton.toolTip = "Theme filter: \(catalogFilterMode.title)"
    }

    private func makeCatalogFilterMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in [ThemeCatalogFilterMode.dark, .light, .all] {
            let item = NSMenuItem(title: mode.title, action: #selector(handleCatalogFilterMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == catalogFilterMode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc
    private func handleCatalogFilterButton() {
        makeCatalogFilterMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: catalogFilterButton.bounds.maxY + 4),
            in: catalogFilterButton
        )
    }

    @objc
    private func handleCatalogFilterMenuItem(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let mode = ThemeCatalogFilterMode(rawValue: rawValue) else {
            return
        }

        catalogFilterMode = mode
        hasUserSelectedCatalogFilter = true
        updateCatalogFilterButton()
        applyFilter()
    }

    // MARK: - Opacity

    private func configureOpacitySlider() {
        opacitySlider.minValue = 0.3
        opacitySlider.maxValue = 1.0
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(handleOpacityChanged(_:))
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
    }

    private func refreshOpacitySlider() {
        let opacity = currentBackgroundOpacityProvider() ?? 0.95
        opacitySlider.doubleValue = Double(opacity)
        updateOpacityLabel(opacity)
    }

    @MainActor
    private func reloadThemes() async {
        allThemes = await catalogProvider.loadThemes()
        applyFilter()
        updatePreviewForCurrentSelection()
        updateThemeSlotViews()
        refreshActiveThemeName()
        refreshScrollableContentLayout()
    }

    @MainActor
    private func applyThemeForTesting(_ name: String, slot: AppearanceThemeSlot) async {
        await configCoordinator.applyTheme(name, slot: slot, presentingWindow: view.window)
        refreshSourceState()
        refreshThemePreferences()
        refreshActiveThemeName()
        refreshOpacitySlider()
    }

    private func setThemeName(_ name: String, for slot: AppearanceThemeSlot) {
        switch slot {
        case .dark:
            themePreferences.darkThemeName = name
        case .light:
            themePreferences.lightThemeName = name
        }
        updateThemeSlotViews()
    }

    private func displayName(forThemeNamed name: String?) -> String {
        guard let name else {
            return GhosttyThemeLibrary.fallbackDisplayName
        }
        if let theme = themePreview(named: name, in: allThemes) {
            return theme.displayName
        }
        return GhosttyThemeLibrary.displayName(for: name)
    }

    private func themePreview(named name: String, in themes: [ThemePreview]) -> ThemePreview? {
        let canonicalName = GhosttyThemeLibrary.canonicalThemeName(for: name)
        return themes.first { theme in
            theme.name == name || theme.name == canonicalName
        }
    }

    private func updateThemeModeViews() {
        modeOptionViews.forEach { $0.isSelected = $0.mode == themePreferences.mode }
    }

    private func updateThemeSlotViews() {
        let darkThemeName = themePreferences.themeName(for: .dark)
        let lightThemeName = themePreferences.themeName(for: .light)
        darkSlotView.configure(
            title: "Dark Theme",
            themeName: displayName(forThemeNamed: darkThemeName),
            preview: themePreview(named: darkThemeName, in: allThemes),
            isEditing: editingThemeSlot == .dark
        )
        lightSlotView.configure(
            title: "Light Theme",
            themeName: displayName(forThemeNamed: lightThemeName),
            preview: themePreview(named: lightThemeName, in: allThemes),
            isEditing: editingThemeSlot == .light
        )
    }

    private func refreshOpenCodeThemeSyncSwitch() {
        openCodeThemeSyncSwitch.state = configCoordinator.syncOpenCodeThemeWithTerminal ? .on : .off
    }

    private func updateOpacityLabel(_ opacity: CGFloat) {
        opacityValueLabel.stringValue = "\(Int(round(opacity * 100)))%"
    }

    @objc
    private func handleOpacityChanged(_ sender: NSSlider) {
        let opacity = CGFloat(sender.doubleValue)
        updateOpacityLabel(opacity)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await configCoordinator.applyBackgroundOpacity(opacity, presentingWindow: view.window)
            refreshSourceState()
            refreshActiveThemeName()
            refreshOpacitySlider()
        }
    }

    @objc
    private func handleCreateSharedConfig() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await configCoordinator.createSharedConfig(presentingWindow: view.window)
            refreshSourceState()
            refreshActiveThemeName()
            refreshOpacitySlider()
            refreshOpenCodeThemeSyncSwitch()
        }
    }

    @objc
    private func handleThemeModeSelected(_ sender: ThemeModeOptionView) {
        themePreferences.mode = sender.mode
        hasUserSelectedThemeSlot = false
        editingThemeSlot = sender.mode == .alwaysLight ? .light : .dark
        updateDefaultCatalogFilterIfNeeded()
        updateThemeModeViews()
        updateThemeSlotViews()
        updateCatalogFilterButton()
        applyFilter()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await configCoordinator.applyThemeMode(sender.mode, presentingWindow: view.window)
            refreshThemePreferences()
            refreshActiveThemeName()
        }
    }

    @objc
    private func handleThemeSlotSelected(_ sender: ThemeSlotTabControl) {
        editingThemeSlot = sender.slot
        hasUserSelectedThemeSlot = true
        updateDefaultCatalogFilterIfNeeded()
        updateThemeSlotViews()
        updateCatalogFilterButton()
        applyFilter()
    }

    @objc
    private func handleResetThemePreferences() {
        hasUserSelectedThemeSlot = false
        hasUserSelectedCatalogFilter = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            await configCoordinator.resetThemePreferences(presentingWindow: view.window)
            refreshThemePreferences()
            refreshActiveThemeName()
        }
    }

    @objc
    private func handleOpenCodeThemeSyncChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        Task { @MainActor [weak self] in
            guard let self else { return }
            await configCoordinator.applyOpenCodeThemeSync(enabled)
            refreshOpenCodeThemeSyncSwitch()
        }
    }

    private func makeSwitchRow(
        title: String,
        subtitle: String,
        toggle: NSSwitch,
        action: Selector
    ) -> NSView {
        SettingsFormBuilder.switchRow(
            title: title, subtitle: subtitle, toggle: toggle, target: self, action: action,
            verticalInset: 16, toggleLeadingSpacing: 16, subtitleFontSize: 11,
            subtitleWidth: .maxWidth(420))
    }

    // MARK: - Table

    private func configureTableView() {
        themeColumn.title = ""
        themeColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(themeColumn)
        tableView.headerView = nil
        tableView.rowHeight = Layout.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
    }
}

// MARK: - NSTableViewDataSource

extension AppearanceSettingsSectionViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredThemes.count
    }
}

// MARK: - NSTableViewDelegate

extension AppearanceSettingsSectionViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredThemes.count else {
            return nil
        }

        let theme = filteredThemes[row]
        let selectedSlotThemeName = GhosttyThemeLibrary.canonicalThemeName(
            for: themePreferences.themeName(for: editingThemeSlot)
        )
        let isActive = GhosttyThemeLibrary.canonicalThemeName(for: theme.name) == selectedSlotThemeName

        let cellID = NSUserInterfaceItemIdentifier("ThemeCell")
        let cell: ThemeRowCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? ThemeRowCellView {
            cell = existing
        } else {
            cell = ThemeRowCellView()
            cell.identifier = cellID
        }

        cell.onSelect = { [weak self] name in
            self?.applyTheme(name)
        }
        cell.onHover = { [weak self] theme in
            guard let self else { return }
            self.selectedPreviewTheme = theme
            self.previewView.configure(with: theme)
        }
        cell.onHoverEnd = { [weak self] in
            self?.updatePreviewForCurrentSelection()
        }
        cell.configure(with: theme, isActive: isActive)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Layout.rowHeight
    }
}

private func previewSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    if let font = NSFont.systemFont(ofSize: size, weight: weight) as NSFont? {
        return font
    }
    return NSFont.systemFont(ofSize: size)
}

private func previewMonospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    if let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight) as NSFont? {
        return font
    }
    if let font = NSFont.userFixedPitchFont(ofSize: size) {
        return font
    }
    return previewSystemFont(ofSize: size, weight: weight)
}

private func previewTextAttributes(font: NSFont?, color: NSColor?) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let font {
        attributes[.font] = font
    }
    if let color {
        attributes[.foregroundColor] = color
    }
    return attributes
}

// MARK: - ThemeModeOptionView

@MainActor
private final class ThemeModeOptionView: NSControl {
    let mode: AppConfig.Appearance.ThemeMode

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateAppearance()
        }
    }

    private let previewView: ThemeModePreviewView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField

    init(mode: AppConfig.Appearance.ThemeMode, title: String, subtitle: String) {
        self.mode = mode
        self.previewView = ThemeModePreviewView(mode: mode)
        self.titleLabel = NSTextField(labelWithString: title)
        self.subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(previewView)
        previewView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: 58).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        stackView.addArrangedSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 136),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isDarkMode ? 0.18 : 0.11).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isHighlighted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(isDarkMode ? 0.18 : 0.55).cgColor
            layer?.borderColor = (isDarkMode
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.12)).cgColor
        }
        previewView.isSelected = isSelected
    }
}

@MainActor
private final class ThemeModePreviewView: NSView {
    let mode: AppConfig.Appearance.ThemeMode

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(mode: AppConfig.Appearance.ThemeMode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let accent = NSColor.controlAccentColor
        let stroke = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        let darkBackground = NSColor(hexString: "#0A0C10") ?? .black
        let lightBackground = NSColor(hexString: "#F7FBFF") ?? .white
        let darkText = NSColor(hexString: "#F0F3F6") ?? .white
        let lightText = NSColor(hexString: "#102030") ?? .black
        let rect = bounds.insetBy(dx: 2, dy: 4)

        switch mode {
        case .followMacOS:
            let gap: CGFloat = 8
            let width = floor((rect.width - gap) / 2)
            drawMiniTerminal(
                frame: NSRect(x: rect.minX, y: rect.minY + 3, width: width, height: rect.height - 6),
                background: darkBackground,
                foreground: darkText,
                stroke: stroke,
                accent: accent
            )
            drawMiniTerminal(
                frame: NSRect(x: rect.minX + width + gap, y: rect.minY + 3, width: width, height: rect.height - 6),
                background: lightBackground,
                foreground: lightText,
                stroke: stroke,
                accent: accent
            )
        case .alwaysDark:
            drawMiniTerminal(
                frame: rect.insetBy(dx: max(0, rect.width * 0.18), dy: 3),
                background: darkBackground,
                foreground: darkText,
                stroke: stroke,
                accent: accent
            )
        case .alwaysLight:
            drawMiniTerminal(
                frame: rect.insetBy(dx: max(0, rect.width * 0.18), dy: 3),
                background: lightBackground,
                foreground: lightText,
                stroke: stroke,
                accent: accent
            )
        }
    }

    private func drawMiniTerminal(
        frame: NSRect,
        background: NSColor,
        foreground: NSColor,
        stroke: NSColor,
        accent: NSColor
    ) {
        let shellPath = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        stroke.setStroke()
        shellPath.lineWidth = isSelected ? 1.5 : 1
        shellPath.stroke()

        let inner = frame.insetBy(dx: 6, dy: 7)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4)
        background.setFill()
        innerPath.fill()

        let lineHeight: CGFloat = 4
        for index in 0..<3 {
            let width = inner.width * [0.72, 0.46, 0.58][index]
            let lineRect = NSRect(
                x: inner.minX + 7,
                y: inner.minY + 8 + CGFloat(index) * 9,
                width: width,
                height: lineHeight
            )
            (index == 0 ? accent : foreground.withAlphaComponent(0.68)).setFill()
            NSBezierPath(roundedRect: lineRect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

// MARK: - ThemeSlotTabControl

@MainActor
private final class ThemeSlotTabControl: NSControl {
    let slot: AppearanceThemeSlot

    private let previewView = ThemeSlotPreviewView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let themeLabel = NSTextField(labelWithString: "")

    private var isEditing = false {
        didSet { updateAppearance() }
    }

    init(slot: AppearanceThemeSlot) {
        self.slot = slot
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(previewView)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(labelStack)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        labelStack.addArrangedSubview(titleLabel)

        themeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        themeLabel.lineBreakMode = .byTruncatingTail
        labelStack.addArrangedSubview(themeLabel)
        themeLabel.widthAnchor.constraint(equalTo: labelStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            previewView.widthAnchor.constraint(equalToConstant: 96),
            previewView.heightAnchor.constraint(equalToConstant: 46),

            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, themeName: String, preview: ThemePreview?, isEditing: Bool) {
        titleLabel.stringValue = title
        themeLabel.stringValue = themeName
        previewView.configure(with: preview)
        self.isEditing = isEditing
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isEditing {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isDarkMode ? 0.16 : 0.10).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isHighlighted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(isDarkMode ? 0.12 : 0.45).cgColor
            layer?.borderColor = (isDarkMode
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.10)).cgColor
        }
    }
}

@MainActor
private final class ThemeSlotPreviewView: NSView {
    private var theme: ThemePreview?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with theme: ThemePreview?) {
        self.theme = theme
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let background = theme?.background ?? (NSColor(hexString: "#0A0C10") ?? .black)
        let foreground = theme?.foreground ?? (NSColor(hexString: "#F0F3F6") ?? .white)
        let palette = theme?.palette ?? []
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 6

        let shellPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shellPath.addClip()

        background.setFill()
        rect.fill()

        let swatchHeight: CGFloat = 7
        let swatchWidth: CGFloat = 9
        for index in 0..<6 {
            let color = index < palette.count
                ? palette[index]
                : foreground.withAlphaComponent(index == 0 ? 0.65 : 0.22)
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: rect.minX + 8 + CGFloat(index) * (swatchWidth + 4),
                    y: rect.minY + 8,
                    width: swatchWidth,
                    height: swatchHeight
                ),
                xRadius: 2,
                yRadius: 2
            ).fill()
        }

        if let attributes = ThemePreviewTextAttributes.make(
            foreground: foreground,
            background: background,
            pointSize: 9,
            weight: .semibold
        ) {
            NSAttributedString(string: "Aa", attributes: attributes).draw(at: NSPoint(x: rect.minX + 8, y: rect.maxY - 19))
        }

        NSGraphicsContext.restoreGraphicsState()

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.14)).setStroke()
        let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        borderPath.lineWidth = 0.5
        borderPath.stroke()
    }
}

// MARK: - ThemeRowCellView

@MainActor
private final class ThemeRowCellView: NSView {
    var onSelect: ((String) -> Void)?
    var onHover: ((ThemePreview) -> Void)?
    var onHoverEnd: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let checkmarkImageView = NSImageView()
    private let paletteView = TwoRowPaletteView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var themeName = ""
    private var currentTheme: ThemePreview?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with theme: ThemePreview, isActive: Bool) {
        themeName = theme.name
        currentTheme = theme
        nameLabel.stringValue = theme.displayName
        checkmarkImageView.isHidden = !isActive
        paletteView.configure(
            background: theme.background,
            foreground: theme.foreground,
            palette: theme.palette
        )
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(themeName)
    }

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
        updateBackgroundColor()
        if let currentTheme {
            onHover?(currentTheme)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackgroundColor()
        onHoverEnd?()
    }

    private func setupViews() {
        wantsLayer = true

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let checkmarkImage = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Active theme"
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        checkmarkImageView.image = checkmarkImage
        checkmarkImageView.contentTintColor = .controlAccentColor
        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkImageView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(checkmarkImageView)

        paletteView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paletteView)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkImageView.leadingAnchor, constant: -4),

            checkmarkImageView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            checkmarkImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            paletteView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            paletteView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            paletteView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            paletteView.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func updateBackgroundColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isHovered {
            layer?.backgroundColor = isDark
                ? NSColor.white.withAlphaComponent(0.06).cgColor
                : NSColor.black.withAlphaComponent(0.04).cgColor
        } else {
            layer?.backgroundColor = nil
        }
    }
}

// MARK: - TwoRowPaletteView (compact, for list rows)

@MainActor
private final class TwoRowPaletteView: NSView {
    private var background: NSColor = .black
    private var foreground: NSColor = .white
    private var palette: [NSColor] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(background: NSColor, foreground: NSColor, palette: [NSColor]) {
        self.background = background
        self.foreground = foreground
        self.palette = palette
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let cornerRadius: CGFloat = 3
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()

        // Fill background
        background.setFill()
        bounds.fill()

        let rowGap: CGFloat = 2
        let rowHeight = (height - rowGap) / 2
        let colorsPerRow = 8

        // Draw "Ab" label in the top-left corner
        let abWidth: CGFloat = 20
        if let abAttributes = ThemePreviewTextAttributes.make(
            foreground: foreground,
            background: background,
            pointSize: 7,
            weight: .medium
        ) {
            let abString = NSAttributedString(string: "Ab", attributes: abAttributes)
            let abSize = abString.size()
            abString.draw(at: NSPoint(
                x: (abWidth - abSize.width) / 2,
                y: rowHeight + rowGap + (rowHeight - abSize.height) / 2
            ))
        }

        // Top row: palette 0-7
        let paletteStartX = abWidth
        let swatchWidth = (width - paletteStartX) / CGFloat(colorsPerRow)
        for i in 0..<colorsPerRow {
            let color = i < palette.count ? palette[i] : NSColor.gray.withAlphaComponent(0.2)
            color.setFill()
            NSRect(
                x: paletteStartX + CGFloat(i) * swatchWidth,
                y: rowHeight + rowGap,
                width: ceil(swatchWidth),
                height: rowHeight
            ).fill()
        }

        // Bottom row: palette 8-15
        for i in 0..<colorsPerRow {
            let paletteIndex = i + colorsPerRow
            let color = paletteIndex < palette.count ? palette[paletteIndex] : NSColor.gray.withAlphaComponent(0.2)
            color.setFill()
            NSRect(
                x: paletteStartX + CGFloat(i) * swatchWidth,
                y: 0,
                width: ceil(swatchWidth),
                height: rowHeight
            ).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        // Border
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let borderColor = isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.12)
        borderColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: cornerRadius, yRadius: cornerRadius)
        borderPath.lineWidth = 0.5
        borderPath.stroke()
    }
}

// MARK: - ThemePreviewPanel (right-side detail view)

@MainActor
private final class ThemePreviewPanel: NSView {
    private var theme: ThemePreview?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with theme: ThemePreview) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let padding: CGFloat = 20
        let contentWidth = width - padding * 2

        // Background
        theme.background.setFill()
        bounds.fill()

        var y = height - padding

        // Theme name
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        if let titleAttributes = ThemePreviewTextAttributes.make(
            font: titleFont,
            foreground: theme.foreground,
            background: theme.background
        ) {
            let titleString = NSAttributedString(string: theme.displayName, attributes: titleAttributes)
            let titleSize = titleString.size()
            y -= titleSize.height
            titleString.draw(at: NSPoint(x: padding, y: y))
            y -= 16
        }

        // Sample terminal content
        let monoFont = previewMonospacedFont(ofSize: 11, weight: .regular)
        let monoBoldFont = previewMonospacedFont(ofSize: 11, weight: .bold)
        let lineHeight: CGFloat = 17

        func paletteColor(_ index: Int) -> NSColor {
            index < theme.palette.count ? theme.palette[index] : theme.foreground
        }

        let sampleLines: [(text: String, color: NSColor, font: NSFont)] = [
            ("$ ls -la", theme.foreground, monoBoldFont),
            ("total 42", theme.foreground, monoFont),
            ("drwxr-xr-x  12 user staff   384 Apr  6 14:22 .", paletteColor(4), monoFont),
            ("drwxr-xr-x   8 user staff   256 Apr  1 09:15 ..", paletteColor(4), monoFont),
            ("-rw-r--r--   1 user staff  2048 Apr  6 14:22 README.md", paletteColor(2), monoFont),
            ("-rwxr-xr-x   1 user staff 15360 Apr  5 11:30 build.sh", paletteColor(10), monoFont),
            ("drwxr-xr-x   5 user staff   160 Apr  4 16:45 src/", paletteColor(12), monoFont),
            ("", theme.foreground, monoFont),
            ("$ git status", theme.foreground, monoBoldFont),
            ("On branch main", theme.foreground, monoFont),
            ("Changes not staged for commit:", paletteColor(3), monoFont),
            ("  modified:   src/main.swift", paletteColor(1), monoFont),
            ("  modified:   src/config.swift", paletteColor(1), monoFont),
            ("", theme.foreground, monoFont),
            ("Untracked files:", paletteColor(3), monoFont),
            ("  src/theme.swift", paletteColor(1), monoFont),
        ]

        for line in sampleLines {
            guard y - lineHeight > padding + 80 else { break }
            if !line.text.isEmpty {
                y -= lineHeight
                if let lineAttributes = ThemePreviewTextAttributes.make(
                    font: line.font,
                    foreground: line.color,
                    background: theme.background
                ) {
                    let lineString = NSAttributedString(string: line.text, attributes: lineAttributes)
                    lineString.draw(at: NSPoint(x: padding, y: y))
                }
            } else {
                y -= lineHeight * 0.5
            }
        }

        // Palette grid at the bottom
        let paletteY = padding
        let colorsPerRow = 8
        let swatchSpacing: CGFloat = 3
        let swatchSize = min(
            (contentWidth - CGFloat(colorsPerRow - 1) * swatchSpacing) / CGFloat(colorsPerRow),
            22
        )
        let gridWidth = CGFloat(colorsPerRow) * swatchSize + CGFloat(colorsPerRow - 1) * swatchSpacing
        let gridX = padding + (contentWidth - gridWidth) / 2
        let rowHeight = swatchSize + swatchSpacing

        // Row labels
        let labelFont = previewMonospacedFont(ofSize: 8, weight: .regular)
        let labelColor = theme.foreground.withAlphaComponent(0.5)

        for row in 0..<2 {
            let rowY = paletteY + CGFloat(1 - row) * rowHeight
            for col in 0..<colorsPerRow {
                let colorIndex = row * colorsPerRow + col
                let color = colorIndex < theme.palette.count
                    ? theme.palette[colorIndex]
                    : NSColor.gray.withAlphaComponent(0.2)
                let x = gridX + CGFloat(col) * (swatchSize + swatchSpacing)

                color.setFill()
                let swatchRect = NSRect(x: x, y: rowY, width: swatchSize, height: swatchSize)
                let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
                swatchPath.fill()

                // Swatch border
                let isDark = theme.background.isDarkThemeColor
                let borderAlpha: CGFloat = isDark ? 0.2 : 0.15
                (isDark ? NSColor.white : NSColor.black).withAlphaComponent(borderAlpha).setStroke()
                let borderRect = swatchRect.insetBy(dx: 0.25, dy: 0.25)
                let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 3, yRadius: 3)
                borderPath.lineWidth = 0.5
                borderPath.stroke()

                // Index label below
                if let indexAttributes = ThemePreviewTextAttributes.make(
                    font: labelFont,
                    foreground: labelColor,
                    background: theme.background
                ) {
                    let indexString = NSAttributedString(string: "\(colorIndex)", attributes: indexAttributes)
                    let indexSize = indexString.size()
                    indexString.draw(at: NSPoint(
                        x: x + (swatchSize - indexSize.width) / 2,
                        y: rowY - indexSize.height - 1
                    ))
                }
            }
        }
    }
}
