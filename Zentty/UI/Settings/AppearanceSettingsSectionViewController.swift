import AppKit

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

    private let catalogProvider: any ThemeCatalogProviding
    private let configWriter: any GhosttyConfigWriting
    private let currentThemeNameProvider: (NSAppearance?) -> String?
    private let currentBackgroundOpacityProvider: () -> CGFloat?
    private let runtimeReload: @MainActor () -> Void

    private let searchField = NSSearchField()
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let themeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
    private let previewView = ThemePreviewPanel()
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")

    private var allThemes: [ThemePreview] = []
    private var filteredThemes: [ThemePreview] = []
    private var activeThemeName: String?
    private var searchQuery = ""
    private var selectedPreviewTheme: ThemePreview?

    init(
        catalogProvider: any ThemeCatalogProviding = ThemeCatalogService(),
        configWriter: any GhosttyConfigWriting = GhosttyConfigWriter(),
        currentThemeName: @escaping (NSAppearance?) -> String? = GhosttyThemeResolver().currentThemeName(for:),
        currentBackgroundOpacity: @escaping () -> CGFloat? = {
            GhosttyThemeResolver().currentBackgroundOpacity()
        },
        runtimeReload: @escaping @MainActor () -> Void = { LibghosttyRuntime.shared.reloadConfig() }
    ) {
        self.catalogProvider = catalogProvider
        self.configWriter = configWriter
        self.currentThemeNameProvider = currentThemeName
        self.currentBackgroundOpacityProvider = currentBackgroundOpacity
        self.runtimeReload = runtimeReload
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

        let subtitleLabel = NSTextField(labelWithString: "Choose a terminal theme. Themes are loaded from your Ghostty configuration.")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let card = SettingsCardView()

        let shellView = NSView()
        shellView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(shellView)

        // Left: search + theme list
        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 0
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        shellView.addSubview(leftStack)

        configureSearchField()
        let searchWrapper = NSView()
        searchWrapper.translatesAutoresizingMaskIntoConstraints = false
        searchWrapper.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: searchWrapper.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: searchWrapper.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchWrapper.trailingAnchor, constant: -10),
            searchField.bottomAnchor.constraint(equalTo: searchWrapper.bottomAnchor, constant: -6),
        ])
        leftStack.addArrangedSubview(searchWrapper)
        searchWrapper.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

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
            shellView.topAnchor.constraint(equalTo: card.topAnchor),
            shellView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            shellView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            shellView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
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

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshActiveThemeName()
        refreshOpacitySlider()
        Task {
            allThemes = await catalogProvider.loadThemes()
            applyFilter()
            updatePreviewForCurrentSelection()
        }
    }

    override func prepareForPresentation() {
        refreshActiveThemeName()
        refreshOpacitySlider()
        super.prepareForPresentation()
    }

    func handleAppearanceChange() {
        refreshActiveThemeName()
    }

    // MARK: - Theme State

    private(set) var themes: [ThemePreview] {
        get { filteredThemes }
        set { filteredThemes = newValue }
    }

    var activeThemeNameForTesting: String? {
        activeThemeName
    }

    private func refreshActiveThemeName() {
        let appearance = view.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        activeThemeName = currentThemeNameProvider(appearance)
        if isViewLoaded {
            tableView.reloadData()
            updatePreviewForCurrentSelection()
        }
    }

    private func applyFilter() {
        if searchQuery.isEmpty {
            filteredThemes = allThemes
        } else {
            filteredThemes = allThemes.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        tableView.reloadData()
        updatePreviewForCurrentSelection()
    }

    private func applyTheme(_ name: String) {
        activeThemeName = name
        configWriter.writeTheme(name)
        runtimeReload()
        tableView.reloadData()
        if let theme = filteredThemes.first(where: { $0.name == name }) {
            selectedPreviewTheme = theme
            previewView.configure(with: theme)
        }
    }

    private func updatePreviewForCurrentSelection() {
        let targetName = activeThemeName
        if let theme = filteredThemes.first(where: { $0.name == targetName }) {
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

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        searchQuery = query
        applyFilter()
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

    @objc
    private func handleSearchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
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
        let opacity = currentBackgroundOpacityProvider() ?? 0.8
        opacitySlider.doubleValue = Double(opacity)
        updateOpacityLabel(opacity)
    }

    private func updateOpacityLabel(_ opacity: CGFloat) {
        opacityValueLabel.stringValue = "\(Int(round(opacity * 100)))%"
    }

    @objc
    private func handleOpacityChanged(_ sender: NSSlider) {
        let opacity = CGFloat(sender.doubleValue)
        updateOpacityLabel(opacity)
        configWriter.writeBackgroundOpacity(opacity)
        runtimeReload()
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
        let isActive = theme.name == activeThemeName

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
        nameLabel.stringValue = theme.name
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
        let abString = NSAttributedString(
            string: "Ab",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .medium),
                .foregroundColor: foreground,
            ]
        )
        let abSize = abString.size()
        abString.draw(at: NSPoint(
            x: (abWidth - abSize.width) / 2,
            y: rowHeight + rowGap + (rowHeight - abSize.height) / 2
        ))

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
        let titleString = NSAttributedString(string: theme.name, attributes: [
            .font: titleFont,
            .foregroundColor: theme.foreground,
        ])
        let titleSize = titleString.size()
        y -= titleSize.height
        titleString.draw(at: NSPoint(x: padding, y: y))
        y -= 16

        // Sample terminal content
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let monoBoldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
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
                let lineString = NSAttributedString(string: line.text, attributes: [
                    .font: line.font,
                    .foregroundColor: line.color,
                ])
                y -= lineHeight
                lineString.draw(at: NSPoint(x: padding, y: y))
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
        let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
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
                let indexString = NSAttributedString(string: "\(colorIndex)", attributes: [
                    .font: labelFont,
                    .foregroundColor: labelColor,
                ])
                let indexSize = indexString.size()
                indexString.draw(at: NSPoint(
                    x: x + (swatchSize - indexSize.width) / 2,
                    y: rowY - indexSize.height - 1
                ))
            }
        }
    }
}
