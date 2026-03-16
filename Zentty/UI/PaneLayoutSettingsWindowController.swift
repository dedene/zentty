import AppKit

@MainActor
final class PaneLayoutSettingsWindowController: NSWindowController {
    private let settingsViewController: PaneLayoutSettingsViewController

    init(
        preferences: PaneLayoutPreferences,
        onUpdate: @escaping (DisplayClass, PaneLayoutPreset) -> Void
    ) {
        let settingsViewController = PaneLayoutSettingsViewController(
            preferences: preferences,
            onUpdate: onUpdate
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
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
    private let onUpdate: (DisplayClass, PaneLayoutPreset) -> Void
    private var preferences: PaneLayoutPreferences
    private var popUpButtonsByDisplayClass: [DisplayClass: NSPopUpButton] = [:]
    private var summaryLabelsByDisplayClass: [DisplayClass: NSTextField] = [:]

    init(
        preferences: PaneLayoutPreferences,
        onUpdate: @escaping (DisplayClass, PaneLayoutPreset) -> Void
    ) {
        self.preferences = preferences
        self.onUpdate = onUpdate
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
            text: "Choose how new panes should size themselves on laptops and larger displays.",
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
            let preset = preferences.preset(for: displayClass)
            popUpButtonsByDisplayClass[displayClass]?.selectItem(withTitle: preset.title)
            summaryLabelsByDisplayClass[displayClass]?.stringValue = preset.summary
        }
    }

    var sectionTitlesForTesting: [String] {
        DisplayClass.allCases.map(\.title)
    }

    var selectedPresetTitlesForTesting: [String] {
        DisplayClass.allCases.compactMap { popUpButtonsByDisplayClass[$0]?.selectedItem?.title }
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

        let descriptionLabel = makeLabel(
            text: displayClass == .laptop
                ? "Defaults for built-in or compact screens."
                : "Defaults for wider external monitors and ultrawides.",
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        descriptionLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(descriptionLabel)

        let popUpButton = NSPopUpButton()
        PaneLayoutPreset.allCases.forEach { preset in
            popUpButton.addItem(withTitle: preset.title)
        }
        popUpButton.target = self
        popUpButton.action = #selector(handlePresetChange(_:))
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        popUpButton.tag = DisplayClass.allCases.firstIndex(of: displayClass) ?? 0
        popUpButtonsByDisplayClass[displayClass] = popUpButton
        container.addArrangedSubview(popUpButton)

        let presetSummary = makeLabel(
            text: preferences.preset(for: displayClass).summary,
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        presetSummary.textColor = .secondaryLabelColor
        summaryLabelsByDisplayClass[displayClass] = presetSummary
        container.addArrangedSubview(presetSummary)

        return container
    }

    @objc
    private func handlePresetChange(_ sender: NSPopUpButton) {
        let displayClass = DisplayClass.allCases[sender.tag]
        guard let selectedTitle = sender.selectedItem?.title,
              let preset = PaneLayoutPreset.allCases.first(where: { $0.title == selectedTitle }) else {
            return
        }

        updateSummary(for: displayClass, preset: preset)
        onUpdate(displayClass, preset)
    }

    private func updateSummary(for displayClass: DisplayClass, preset: PaneLayoutPreset) {
        summaryLabelsByDisplayClass[displayClass]?.stringValue = preset.summary
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}
