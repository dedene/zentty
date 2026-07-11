import AppKit

@MainActor
final class UpdatesPrivacySettingsSectionViewController: SettingsScrollableSectionViewController {
    private let configStore: AppConfigStore
    private let errorReportingBundleConfigurationProvider: ErrorReportingBundleConfigurationProvider
    private let errorReportingConfirmationPresenter: ErrorReportingConfirmationPresenter
    private let errorReportingRestartHandler: ErrorReportingRestartHandler
    private let runtimeErrorReportingEnabled: Bool
    private var currentUpdates: AppConfig.Updates = .default
    private var currentErrorReporting: AppConfig.ErrorReporting = .default

    private let updateChannelPopupButton = NSPopUpButton()
    private let errorReportingSwitch = NSSwitch()
    private let errorReportingStatusLabel = NSTextField(labelWithString: "")
    private let errorReportingSubtitleLabel = NSTextField(labelWithString: "")
    private let errorReportingRestartLabel = NSTextField(labelWithString: "")

    init(
        configStore: AppConfigStore,
        errorReportingBundleConfigurationProvider:
            @escaping ErrorReportingBundleConfigurationProvider = {
                ErrorReportingBundleConfiguration.load(from: .main)
            },
        errorReportingConfirmationPresenter: @escaping ErrorReportingConfirmationPresenter =
            ErrorReportingRestartConfirmation.present,
        errorReportingRestartHandler: @escaping ErrorReportingRestartHandler =
            ErrorReportingApplicationRestart.restart,
        runtimeErrorReportingEnabled: Bool = ErrorReportingRuntimeState.isEnabledForCurrentProcess
    ) {
        self.configStore = configStore
        self.errorReportingBundleConfigurationProvider = errorReportingBundleConfigurationProvider
        self.errorReportingConfirmationPresenter = errorReportingConfirmationPresenter
        self.errorReportingRestartHandler = errorReportingRestartHandler
        self.runtimeErrorReportingEnabled = runtimeErrorReportingEnabled
        self.currentUpdates = configStore.current.updates
        self.currentErrorReporting = configStore.current.errorReporting
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

        let updatesCard = SettingsCardView()
        let updatesRow = makeUpdateChannelRow()
        updatesCard.addSubview(updatesRow)
        updatesRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updatesRow.topAnchor.constraint(equalTo: updatesCard.topAnchor),
            updatesRow.leadingAnchor.constraint(equalTo: updatesCard.leadingAnchor),
            updatesRow.trailingAnchor.constraint(equalTo: updatesCard.trailingAnchor),
            updatesRow.bottomAnchor.constraint(equalTo: updatesCard.bottomAnchor),
        ])

        stackView.addArrangedSubview(updatesCard)
        updatesCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let errorReportingCard = SettingsCardView()
        let errorReportingStack = NSStackView()
        errorReportingStack.orientation = .vertical
        errorReportingStack.alignment = .leading
        errorReportingStack.spacing = 0
        errorReportingStack.translatesAutoresizingMaskIntoConstraints = false
        errorReportingCard.addSubview(errorReportingStack)

        let errorReportingRow = makeErrorReportingRow()
        errorReportingStack.addArrangedSubview(errorReportingRow)
        errorReportingRow.widthAnchor.constraint(equalTo: errorReportingStack.widthAnchor)
            .isActive = true

        NSLayoutConstraint.activate([
            errorReportingStack.topAnchor.constraint(equalTo: errorReportingCard.topAnchor),
            errorReportingStack.leadingAnchor.constraint(equalTo: errorReportingCard.leadingAnchor),
            errorReportingStack.trailingAnchor.constraint(
                equalTo: errorReportingCard.trailingAnchor),
            errorReportingStack.bottomAnchor.constraint(equalTo: errorReportingCard.bottomAnchor),
        ])

        stackView.addArrangedSubview(errorReportingCard)
        errorReportingCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        selectUpdateChannelPopupItem(for: currentUpdates.channel)
        errorReportingSwitch.state = currentErrorReporting.enabled ? .on : .off
        updateErrorReportingAvailability()
        updateErrorReportingRestartMessage()
    }

    func apply(updates: AppConfig.Updates) {
        currentUpdates = updates
        selectUpdateChannelPopupItem(for: updates.channel)
    }

    func apply(errorReporting: AppConfig.ErrorReporting) {
        currentErrorReporting = errorReporting
        guard isViewLoaded else { return }
        errorReportingSwitch.state = errorReporting.enabled ? .on : .off
        updateErrorReportingAvailability()
        updateErrorReportingRestartMessage()
    }

    // MARK: - Rows

    private func makeUpdateChannelRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: "Update Channel",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        leftStack.addArrangedSubview(titleLabel)

        let updatesSubtitle = makeLabel(
            text: "Stable gets regular releases. Beta includes prerelease updates.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        updatesSubtitle.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(updatesSubtitle)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        updateChannelPopupButton.removeAllItems()
        for channel in AppUpdateChannel.allCases {
            updateChannelPopupButton.addItem(withTitle: channel.displayName)
            updateChannelPopupButton.lastItem?.representedObject = channel
        }
        updateChannelPopupButton.target = self
        updateChannelPopupButton.action = #selector(handleUpdateChannelChanged(_:))
        updateChannelPopupButton.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.addArrangedSubview(updateChannelPopupButton)

        container.addSubview(leftStack)
        container.addSubview(rightStack)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            rightStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rightStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    private func makeErrorReportingRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: "Error Reporting",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        leftStack.addArrangedSubview(titleLabel)

        errorReportingSubtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        errorReportingSubtitleLabel.textColor = .secondaryLabelColor
        errorReportingSubtitleLabel.lineBreakMode = .byWordWrapping
        errorReportingSubtitleLabel.maximumNumberOfLines = 0
        leftStack.addArrangedSubview(errorReportingSubtitleLabel)

        errorReportingRestartLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorReportingRestartLabel.textColor = .secondaryLabelColor
        errorReportingRestartLabel.lineBreakMode = .byWordWrapping
        errorReportingRestartLabel.maximumNumberOfLines = 0
        leftStack.addArrangedSubview(errorReportingRestartLabel)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        errorReportingStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        errorReportingStatusLabel.textColor = .secondaryLabelColor
        rightStack.addArrangedSubview(errorReportingStatusLabel)

        errorReportingSwitch.target = self
        errorReportingSwitch.action = #selector(handleErrorReportingSwitchChanged(_:))
        rightStack.addArrangedSubview(errorReportingSwitch)

        container.addSubview(leftStack)
        container.addSubview(rightStack)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            rightStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rightStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    // MARK: - Actions

    @objc
    private func handleUpdateChannelChanged(_ sender: NSPopUpButton) {
        guard let channel = sender.selectedItem?.representedObject as? AppUpdateChannel else {
            return
        }
        try? configStore.update { config in
            config.updates.channel = channel
        }
        currentUpdates = configStore.current.updates
        selectUpdateChannelPopupItem(for: currentUpdates.channel)
    }

    @objc
    private func handleErrorReportingSwitchChanged(_ sender: NSSwitch) {
        requestErrorReportingChange(to: sender.state == .on)
    }

    private func requestErrorReportingChange(to requestedValue: Bool) {
        guard requestedValue != currentErrorReporting.enabled else {
            return
        }

        guard errorReportingBundleConfigurationProvider() != nil else {
            errorReportingSwitch.state = currentErrorReporting.enabled ? .on : .off
            updateErrorReportingAvailability()
            return
        }

        guard let window = view.window else {
            errorReportingSwitch.state = currentErrorReporting.enabled ? .on : .off
            return
        }

        errorReportingConfirmationPresenter(window, requestedValue) { [weak self] decision in
            guard let self else { return }

            if decision != .cancel {
                try? self.configStore.update { config in
                    config.errorReporting.enabled = requestedValue
                }
                self.currentErrorReporting = self.configStore.current.errorReporting
            }

            self.errorReportingSwitch.state = self.currentErrorReporting.enabled ? .on : .off
            self.updateErrorReportingAvailability()
            self.updateErrorReportingRestartMessage()

            if decision == .restartNow {
                self.errorReportingRestartHandler()
            }
        }
    }

    // MARK: - Status

    private func updateErrorReportingAvailability() {
        let isAvailable = errorReportingBundleConfigurationProvider() != nil
        errorReportingSwitch.isEnabled = isAvailable

        if isAvailable {
            errorReportingStatusLabel.stringValue = ""
            errorReportingStatusLabel.textColor = .secondaryLabelColor
            errorReportingStatusLabel.isHidden = true
            errorReportingSubtitleLabel.stringValue =
                "Send anonymous crash reports to help improve Zentty. Privacy-first by design."
        } else {
            errorReportingStatusLabel.stringValue = "Unavailable"
            errorReportingStatusLabel.textColor = .secondaryLabelColor
            errorReportingStatusLabel.isHidden = false
            errorReportingSubtitleLabel.stringValue =
                "Error reporting is unavailable in this build."
        }
    }

    private func updateErrorReportingRestartMessage() {
        let needsRestart = currentErrorReporting.enabled != runtimeErrorReportingEnabled
        errorReportingRestartLabel.stringValue =
            needsRestart ? "Restart Zentty to apply this change." : ""
        errorReportingRestartLabel.isHidden = !needsRestart
    }

    // MARK: - Helpers

    private func selectUpdateChannelPopupItem(for channel: AppUpdateChannel) {
        guard isViewLoaded else { return }
        let index =
            updateChannelPopupButton.itemArray.firstIndex {
                ($0.representedObject as? AppUpdateChannel) == channel
            } ?? 0
        updateChannelPopupButton.selectItem(at: index)
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        SettingsFormBuilder.label(text, font: font)
    }

    // MARK: - For Testing

    var selectedUpdateChannel: AppUpdateChannel {
        (updateChannelPopupButton.selectedItem?.representedObject as? AppUpdateChannel) ?? .stable
    }

    var availableUpdateChannels: [AppUpdateChannel] {
        updateChannelPopupButton.itemArray.compactMap { $0.representedObject as? AppUpdateChannel }
    }

    var isErrorReportingSwitchOn: Bool {
        errorReportingSwitch.state == .on
    }

    var isErrorReportingControlEnabled: Bool {
        errorReportingSwitch.isEnabled
    }

    var isErrorReportingAvailabilityHidden: Bool {
        errorReportingStatusLabel.isHidden
    }

    var errorReportingAvailabilityText: String {
        errorReportingStatusLabel.stringValue
    }

    var errorReportingStatusMessage: String {
        errorReportingSubtitleLabel.stringValue
    }

    var errorReportingRestartMessage: String? {
        errorReportingRestartLabel.stringValue.isEmpty
            ? nil : errorReportingRestartLabel.stringValue
    }

    func setErrorReportingEnabledForTesting(_ enabled: Bool) {
        requestErrorReportingChange(to: enabled)
    }

    func setUpdateChannelForTesting(_ channel: AppUpdateChannel) {
        let index =
            updateChannelPopupButton.itemArray.firstIndex {
                ($0.representedObject as? AppUpdateChannel) == channel
            } ?? 0
        updateChannelPopupButton.selectItem(at: index)
        handleUpdateChannelChanged(updateChannelPopupButton)
    }
}
