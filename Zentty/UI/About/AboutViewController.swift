import AppKit

private struct AboutButtonPalette {
    let background: NSColor
    let border: NSColor
    let text: NSColor
    let hoverBackground: NSColor
    let pressedBackground: NSColor
}

private struct AboutPalette {
    let border: NSColor
    let title: NSColor
    let subtitle: NSColor
    let metadataTitle: NSColor
    let metadataValue: NSColor
    let accent: NSColor
    let button: AboutButtonPalette

    init(theme: ZenttyTheme) {
        border = theme.topChromeBorder
        title = theme.primaryText.withAlphaComponent(0.98)
        subtitle = theme.secondaryText.withAlphaComponent(0.90)
        metadataTitle = theme.secondaryText.withAlphaComponent(0.92)
        metadataValue = theme.primaryText.withAlphaComponent(0.88)
        accent = theme.statusRunning.withAlphaComponent(0.96)
        button = AboutButtonPalette(
            background: theme.openWithChromeBackground,
            border: theme.openWithChromeBorder,
            text: theme.openWithChromePrimaryTint,
            hoverBackground: theme.openWithChromeHoverBackground,
            pressedBackground: theme.openWithChromePressedBackground
        )
    }
}

@MainActor
final class AboutViewController: NSViewController {
    private enum Layout {
        static let iconSize: CGFloat = 124
        static let horizontalInset: CGFloat = 52
        static let minimumTopInset: CGFloat = 78
        static let minimumBottomInset: CGFloat = 42
        static let verticalOffset: CGFloat = 16
        static let subtitleWidth: CGFloat = 404
    }

    private let metadata: AboutMetadata
    private let urlOpener: (URL) -> Void
    private var currentTheme: ZenttyTheme

    private let versionTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Version")
    private let buildTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Build")
    private let commitTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Commit")

    private let versionValueLabel = AboutViewController.makeMetadataValueLabel()
    private let buildValueLabel = AboutViewController.makeMetadataValueLabel()
    private let commitValueLabel = AboutViewController.makeMetadataValueLabel()

    private lazy var docsButton = AboutActionButton(title: "Docs", target: self, action: #selector(handleDocs(_:)))
    private lazy var githubButton = AboutActionButton(title: "GitHub", target: self, action: #selector(handleGitHub(_:)))
    private lazy var licensesButton = AboutActionButton(title: "Licenses", target: self, action: #selector(handleLicenses(_:)))

    private lazy var rootSurfaceView: AboutSurfaceView = {
        let view = AboutSurfaceView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Zentty")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "Zentty is a Ghostty-based native macOS terminal for agent-native development."
    )

    init(
        metadata: AboutMetadata,
        urlOpener: @escaping (URL) -> Void,
        theme: ZenttyTheme
    ) {
        self.metadata = metadata
        self.urlOpener = urlOpener
        self.currentTheme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = rootSurfaceView

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 18
        view.addSubview(rootStack)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSApp.applicationIconImage
        rootStack.addArrangedSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 27, weight: .bold)
        rootStack.addArrangedSubview(titleLabel)

        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.preferredMaxLayoutWidth = Layout.subtitleWidth
        rootStack.addArrangedSubview(subtitleLabel)

        let metadataStack = NSStackView()
        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        metadataStack.orientation = .vertical
        metadataStack.alignment = .centerX
        metadataStack.spacing = 7
        metadataStack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        rootStack.addArrangedSubview(metadataStack)

        configureMetadataRows(in: metadataStack)

        let buttonsStack = NSStackView(views: [docsButton, githubButton, licensesButton])
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        buttonsStack.orientation = .horizontal
        buttonsStack.alignment = .centerY
        buttonsStack.spacing = 10
        rootStack.addArrangedSubview(buttonsStack)

        NSLayoutConstraint.activate([
            rootStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rootStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: Layout.verticalOffset),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Layout.horizontalInset),
            view.trailingAnchor.constraint(greaterThanOrEqualTo: rootStack.trailingAnchor, constant: Layout.horizontalInset),
            rootStack.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: Layout.minimumTopInset),
            view.bottomAnchor.constraint(greaterThanOrEqualTo: rootStack.bottomAnchor, constant: Layout.minimumBottomInset),

            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.subtitleWidth),
        ])

        updateTheme(animated: false)
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        view.appearance = appearance
    }

    func applyTheme(_ theme: ZenttyTheme) {
        currentTheme = theme
        guard isViewLoaded else {
            return
        }

        updateTheme(animated: true)
    }

    var versionValueForTesting: String { versionValueLabel.stringValue }
    var buildValueForTesting: String { buildValueLabel.stringValue }
    var commitValueForTesting: String { commitValueLabel.stringValue }
    var appearanceMatchForTesting: NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    }
    var surfaceBackgroundTokenForTesting: String {
        rootSurfaceView.backgroundColorForTesting.themeToken
    }
    var commitColorTokenForTesting: String {
        commitValueLabel.textColor?.themeToken ?? ""
    }
    var docsButtonBackgroundTokenForTesting: String {
        docsButton.backgroundColorForTesting.themeToken
    }
    var docsButtonTextColorTokenForTesting: String {
        docsButton.titleColorForTesting.themeToken
    }

    private func configureMetadataRows(in stackView: NSStackView) {
        versionValueLabel.stringValue = metadata.version
        buildValueLabel.stringValue = metadata.build
        commitValueLabel.stringValue = metadata.commit

        stackView.addArrangedSubview(
            makeMetadataRow(titleLabel: versionTitleLabel, valueLabel: versionValueLabel)
        )
        stackView.addArrangedSubview(
            makeMetadataRow(titleLabel: buildTitleLabel, valueLabel: buildValueLabel)
        )
        stackView.addArrangedSubview(
            makeMetadataRow(titleLabel: commitTitleLabel, valueLabel: commitValueLabel)
        )
    }

    private func makeMetadataRow(titleLabel: NSTextField, valueLabel: NSTextField) -> NSView {
        let row = NSStackView(views: [titleLabel, valueLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func updateTheme(animated: Bool) {
        let palette = AboutPalette(theme: currentTheme)

        rootSurfaceView.apply(theme: currentTheme, borderColor: palette.border, animated: animated)
        titleLabel.textColor = palette.title
        subtitleLabel.textColor = palette.subtitle

        [versionTitleLabel, buildTitleLabel, commitTitleLabel].forEach {
            $0.textColor = palette.metadataTitle
        }

        versionValueLabel.textColor = palette.metadataValue
        buildValueLabel.textColor = palette.metadataValue
        commitValueLabel.textColor = palette.accent
        [docsButton, githubButton, licensesButton].forEach {
            $0.apply(palette: palette.button, animated: animated)
        }
    }

    private static func makeMetadataTitleLabel(title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private static func makeMetadataValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        return label
    }

    @objc
    private func handleDocs(_ sender: Any?) {}

    @objc
    private func handleLicenses(_ sender: Any?) {}

    @objc
    private func handleGitHub(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/dedene/zentty") else {
            return
        }

        urlOpener(url)
    }
}

private final class AboutSurfaceView: NSView {
    var backgroundColorForTesting: NSColor {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.outerWindowRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(theme: ZenttyTheme, borderColor: NSColor, animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.windowBackground.cgColor
            self.layer?.borderColor = borderColor.cgColor
        }
    }
}

private final class AboutActionButton: NSButton {
    private enum Layout {
        static let horizontalInset: CGFloat = 12
        static let verticalInset: CGFloat = 7
    }

    private var displayTitle = ""
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingAreaValue: NSTrackingArea?
    private var currentPalette = AboutButtonPalette(
        background: .clear,
        border: .clear,
        text: .clear,
        hoverBackground: .clear,
        pressedBackground: .clear
    )

    private(set) var isHovered = false
    private(set) var backgroundColorForTesting = NSColor.clear
    private(set) var titleColorForTesting = NSColor.clear

    override var mouseDownCanMoveWindow: Bool { false }
    override var title: String {
        get { displayTitle }
        set {
            displayTitle = newValue
            super.title = ""
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let titleSize = titleLabel.fittingSize
        return NSSize(
            width: ceil(titleSize.width + (Layout.horizontalInset * 2)),
            height: ceil(titleSize.height + (Layout.verticalInset * 2))
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }

        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else {
            return
        }

        isHovered = true
        applyCurrentAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        applyCurrentAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        applyCurrentAppearance(animated: true, isPressed: true)
        super.mouseDown(with: event)
        applyCurrentAppearance(animated: true)
    }

    func apply(palette: AboutButtonPalette, animated: Bool) {
        currentPalette = palette
        applyCurrentAppearance(animated: animated)
    }

    private func commonInit() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalInset),
            trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Layout.horizontalInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Layout.verticalInset),
            bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Layout.verticalInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func applyCurrentAppearance(animated: Bool, isPressed: Bool = false) {
        let backgroundColor: NSColor
        if isPressed {
            backgroundColor = currentPalette.pressedBackground
        } else if isHovered {
            backgroundColor = currentPalette.hoverBackground
        } else {
            backgroundColor = currentPalette.background
        }

        titleColorForTesting = currentPalette.text
        backgroundColorForTesting = backgroundColor
        titleLabel.textColor = currentPalette.text

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = self.currentPalette.border.cgColor
        }
    }
}
