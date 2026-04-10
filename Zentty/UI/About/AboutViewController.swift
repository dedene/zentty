import AppKit

@MainActor
final class AboutViewController: NSViewController {
    private enum Layout {
        static let iconSize: CGFloat = 124
        static let horizontalInset: CGFloat = 52
        static let minimumTopInset: CGFloat = 44
        static let minimumBottomInset: CGFloat = 42
        static let verticalOffset: CGFloat = 4
        static let subtitleWidth: CGFloat = 404
    }

    private let metadata: AboutMetadata
    private let urlOpener: (URL) -> Void
    private let onLicensesRequested: () -> Void

    private let versionTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Version")
    private let buildTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Build")
    private let commitTitleLabel = AboutViewController.makeMetadataTitleLabel(title: "Commit")

    private let versionValueLabel = AboutViewController.makeMetadataValueLabel()
    private let buildValueLabel = AboutViewController.makeMetadataValueLabel()
    private let commitValueLabel = AboutViewController.makeMetadataValueLabel()

    private lazy var docsButton = AboutViewController.makeActionButton(title: "Docs", target: self, action: #selector(handleDocs(_:)))
    private lazy var githubButton = AboutViewController.makeActionButton(title: "GitHub", target: self, action: #selector(handleGitHub(_:)))
    private lazy var licensesButton = AboutViewController.makeActionButton(title: "Licenses", target: self, action: #selector(handleLicenses(_:)))

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Zentty")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "Zentty is a Ghostty-based native macOS terminal for agent-native development."
    )

    init(
        metadata: AboutMetadata,
        urlOpener: @escaping (URL) -> Void,
        onLicensesRequested: @escaping () -> Void = {},
        theme: ZenttyTheme
    ) {
        self.metadata = metadata
        self.urlOpener = urlOpener
        self.onLicensesRequested = onLicensesRequested
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

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
        subtitleLabel.textColor = .secondaryLabelColor
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
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        view.appearance = appearance
    }

    func applyTheme(_ theme: ZenttyTheme) {}

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

    private static func makeMetadataTitleLabel(title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func makeMetadataValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        return label
    }

    private static func makeActionButton(title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc
    private func handleDocs(_ sender: Any?) {
        guard let url = URL(string: "https://zentty.org/docs") else {
            return
        }

        urlOpener(url)
    }

    @objc
    private func handleLicenses(_ sender: Any?) {
        onLicensesRequested()
    }

    @objc
    private func handleGitHub(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/dedene/zentty") else {
            return
        }

        urlOpener(url)
    }
}
