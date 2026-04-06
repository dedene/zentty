import AppKit

private struct AboutPalette {
    let title: NSColor
    let subtitle: NSColor
    let metadataTitle: NSColor
    let metadataValue: NSColor
    let accent: NSColor
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

    private let versionTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Version")
    private let buildTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Build")
    private let commitTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Commit")

    private let versionValueLabel = AboutViewController.makeMetadataValueLabel()
    private let buildValueLabel = AboutViewController.makeMetadataValueLabel()
    private let commitValueLabel = AboutViewController.makeMetadataValueLabel()

    private lazy var docsButton = makeButton(title: "Docs", action: #selector(handleDocs(_:)))
    private lazy var githubButton = makeButton(title: "GitHub", action: #selector(handleGitHub(_:)))
    private lazy var licensesButton = makeButton(title: "Licenses", action: #selector(handleLicenses(_:)))

    private lazy var rootSurfaceView: AboutSurfaceView = {
        let view = AboutSurfaceView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onEffectiveAppearanceChanged = { [weak self] in
            self?.applyTheme()
        }
        return view
    }()

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Zentty")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "Zentty is a Ghostty-based native macOS terminal for agent-native development."
    )

    init(
        metadata: AboutMetadata,
        urlOpener: @escaping (URL) -> Void
    ) {
        self.metadata = metadata
        self.urlOpener = urlOpener
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

        applyTheme()
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        view.appearance = appearance
        applyTheme()
    }

    var versionValueForTesting: String { versionValueLabel.stringValue }
    var buildValueForTesting: String { buildValueLabel.stringValue }
    var commitValueForTesting: String { commitValueLabel.stringValue }
    var appearanceMatchForTesting: NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
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

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func applyTheme() {
        let palette = resolvedPalette()

        rootSurfaceView.applyMaterial(for: appearanceMatchForTesting)
        titleLabel.textColor = palette.title
        subtitleLabel.textColor = palette.subtitle

        [versionTitleLabel, buildTitleLabel, commitTitleLabel].forEach {
            $0.textColor = palette.metadataTitle
        }

        versionValueLabel.textColor = palette.metadataValue
        buildValueLabel.textColor = palette.metadataValue
        commitValueLabel.textColor = palette.accent
    }

    private func resolvedPalette() -> AboutPalette {
        let match = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let isDark = match != .aqua

        if isDark {
            return AboutPalette(
                title: NSColor(white: 0.97, alpha: 1),
                subtitle: NSColor(white: 0.86, alpha: 0.84),
                metadataTitle: NSColor(white: 0.96, alpha: 0.9),
                metadataValue: NSColor(white: 0.92, alpha: 0.82),
                accent: NSColor(red: 0.29, green: 0.57, blue: 0.93, alpha: 1)
            )
        }

        return AboutPalette(
            title: NSColor(calibratedWhite: 0.18, alpha: 1),
            subtitle: NSColor(calibratedWhite: 0.30, alpha: 0.8),
            metadataTitle: NSColor(calibratedWhite: 0.18, alpha: 0.9),
            metadataValue: NSColor(calibratedWhite: 0.28, alpha: 0.7),
            accent: NSColor(red: 0.12, green: 0.42, blue: 0.83, alpha: 1)
        )
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

private final class AboutSurfaceView: NSVisualEffectView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyMaterial(for appearance: NSAppearance.Name?) {
        let isDark = appearance != .aqua
        material = isDark ? .hudWindow : .underWindowBackground
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }
}
