import AppKit
import os

private let floatSettingsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Settings")

/// The General section's floating panes card: `[floats] auto_pop_needs_input`
/// and `pip_size`. Owns its controls and writes straight to the config
/// store; `apply(floats:)` mirrors changes made elsewhere (config file edits,
/// another window).
@MainActor
final class FloatingPanesSettingsCard: NSObject {
    let view = SettingsCardView()
    private let configStore: AppConfigStore
    private let autoPopSwitch = NSSwitch()
    private let pipSizePopup = NSPopUpButton()

    init(configStore: AppConfigStore) {
        self.configStore = configStore
        super.init()
        assemble()
        apply(floats: configStore.current.floats)
    }

    func apply(floats: AppConfig.Floats) {
        autoPopSwitch.state = floats.autoPopNeedsInput ? .on : .off
        if let index = AppConfig.Floats.PipSize.allCases.firstIndex(of: floats.pipSize) {
            pipSizePopup.selectItem(at: index)
        }
    }

    // MARK: - Layout

    private func assemble() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let autoPopRow = SettingsFormBuilder.switchRow(
            title: "Pop up minimized agents that need input",
            subtitle: "Show a minimized pane as picture in picture while its agent waits for you, "
                + "and put it back once the agent moves on.",
            toggle: autoPopSwitch,
            target: self,
            action: #selector(handleAutoPopChanged(_:))
        )
        stack.addArrangedSubview(autoPopRow)
        autoPopRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        SettingsFormBuilder.separator(addedTo: stack)

        let pipSizeRow = makePipSizeRow()
        stack.addArrangedSubview(pipSizeRow)
        pipSizeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makePipSizeRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(
            SettingsFormBuilder.label("Picture in picture size", font: .systemFont(ofSize: 13, weight: .semibold))
        )
        let subtitle = SettingsFormBuilder.label(
            "How wide a pane shown in a corner of the window is drawn.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitle.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(subtitle)

        pipSizePopup.removeAllItems()
        for size in AppConfig.Floats.PipSize.allCases {
            pipSizePopup.addItem(withTitle: size.settingsTitle)
            pipSizePopup.lastItem?.representedObject = size.rawValue
        }
        pipSizePopup.target = self
        pipSizePopup.action = #selector(handlePipSizeChanged(_:))
        pipSizePopup.setAccessibilityLabel("Picture in picture size")
        pipSizePopup.setContentHuggingPriority(.required, for: .horizontal)
        pipSizePopup.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(leftStack)
        container.addSubview(pipSizePopup)
        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            pipSizePopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pipSizePopup.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            pipSizePopup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func handleAutoPopChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        persist("auto-pop") { $0.floats.autoPopNeedsInput = enabled }
    }

    @objc private func handlePipSizeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let size = AppConfig.Floats.PipSize(rawValue: raw) else {
            return
        }
        persist("picture in picture size") { $0.floats.pipSize = size }
    }

    private func persist(_ what: String, _ change: (inout AppConfig) -> Void) {
        do {
            try configStore.update(change)
        } catch {
            floatSettingsLogger.error(
                "Could not save floating panes \(what, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            apply(floats: configStore.current.floats)
        }
    }

    // MARK: - Testing

    var isAutoPopSwitchOnForTesting: Bool {
        autoPopSwitch.state == .on
    }

    var selectedPipSizeForTesting: AppConfig.Floats.PipSize? {
        (pipSizePopup.selectedItem?.representedObject as? String).flatMap(AppConfig.Floats.PipSize.init(rawValue:))
    }

    func setAutoPopForTesting(_ enabled: Bool) {
        autoPopSwitch.state = enabled ? .on : .off
        handleAutoPopChanged(autoPopSwitch)
    }

    func selectPipSizeForTesting(_ size: AppConfig.Floats.PipSize) {
        guard let index = AppConfig.Floats.PipSize.allCases.firstIndex(of: size) else { return }
        pipSizePopup.selectItem(at: index)
        handlePipSizeChanged(pipSizePopup)
    }
}
