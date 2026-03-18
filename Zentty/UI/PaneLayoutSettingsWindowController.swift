import AppKit

@MainActor
final class PaneLayoutSettingsWindowController: NSWindowController {
    private let settingsViewController: PaneLayoutSettingsViewController

    init(
        preferences: PaneLayoutPreferences,
    ) {
        let settingsViewController = PaneLayoutSettingsViewController(
            preferences: preferences
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = settingsViewController

        self.settingsViewController = settingsViewController
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(preferences: PaneLayoutPreferences) {
        settingsViewController.update(preferences: preferences)
    }
}

@MainActor
final class PaneLayoutSettingsViewController: NSViewController {
    private var preferences: PaneLayoutPreferences
    private var summaryLabelsByDisplayClass: [DisplayClass: NSTextField] = [:]

    init(
        preferences: PaneLayoutPreferences,
    ) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 18
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        let titleLabel = makeLabel(
            text: "Pane Layout",
            font: .systemFont(ofSize: 20, weight: .semibold)
        )
        stackView.addArrangedSubview(titleLabel)

        let subtitleLabel = makeLabel(
            text: "Zentty uses explicit screen behavior presets so each split stays calm and predictable.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitleLabel)

        DisplayClass.allCases.forEach { displayClass in
            let sectionView = makeSection(for: displayClass)
            stackView.addArrangedSubview(sectionView)
        }

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])

        update(preferences: preferences)
    }

    func update(preferences: PaneLayoutPreferences) {
        self.preferences = preferences

        for displayClass in DisplayClass.allCases {
            summaryLabelsByDisplayClass[displayClass]?.stringValue = behaviorSummary(for: displayClass)
        }
    }

    var sectionTitlesForTesting: [String] {
        DisplayClass.allCases.map(\.title)
    }

    var presetSummaryForTesting: [String] {
        DisplayClass.allCases.compactMap { summaryLabelsByDisplayClass[$0]?.stringValue }
    }

    private func makeSection(for displayClass: DisplayClass) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let titleLabel = makeLabel(
            text: displayClass.title,
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        container.addArrangedSubview(titleLabel)

        let descriptionText: String
        switch displayClass {
        case .laptop:
            descriptionText = "Laptop behavior\nPreserve the active pane, then scroll horizontally."
        case .largeDisplay:
            descriptionText = "Large Display behavior\nPreserve the active pane with slightly denser columns."
        case .ultrawide:
            descriptionText = "Ultrawide Hybrid behavior\nFirst split is 50/50, then keep horizontal scrolling."
        }

        let descriptionLabel = makeLabel(
            text: descriptionText,
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        descriptionLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(descriptionLabel)

        let presetSummary = makeLabel(
            text: behaviorSummary(for: displayClass),
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        presetSummary.textColor = .secondaryLabelColor
        summaryLabelsByDisplayClass[displayClass] = presetSummary
        container.addArrangedSubview(presetSummary)

        return container
    }

    private func behaviorSummary(for displayClass: DisplayClass) -> String {
        switch displayClass {
        case .laptop:
            return "Laptop behavior: preserve the active pane, then scroll horizontally."
        case .largeDisplay:
            return "Large Display behavior: preserve the active pane with slightly denser columns."
        case .ultrawide:
            return "Ultrawide Hybrid behavior: first split is 50/50, then keep horizontal scrolling."
        }
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}
