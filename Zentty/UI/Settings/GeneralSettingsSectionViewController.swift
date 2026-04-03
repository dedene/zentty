import AppKit
import UserNotifications

@MainActor
final class GeneralSettingsSectionViewController: SettingsScrollableSectionViewController {
    private enum Sound {
        static let systemSounds = [
            "Basso", "Blow", "Bottle", "Frog", "Funk",
            "Glass", "Hero", "Morse", "Ping", "Pop",
            "Purr", "Sosumi", "Submarine", "Tink",
        ]
    }

    private let configStore: AppConfigStore
    private let errorReportingBundleConfigurationProvider: ErrorReportingBundleConfigurationProvider
    private let errorReportingConfirmationPresenter: ErrorReportingConfirmationPresenter
    private let errorReportingRestartHandler: ErrorReportingRestartHandler
    private let runtimeErrorReportingEnabled: Bool
    private var currentNotifications: AppConfig.Notifications = .default
    private var currentConfirmations: AppConfig.Confirmations = .default
    private var currentErrorReporting: AppConfig.ErrorReporting = .default

    private let statusLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let openSettingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let sendTestButton = NSButton(title: "Send Test", target: nil, action: nil)
    private let soundPopupButton = NSPopUpButton()
    private let playButton = NSButton()
    private let closePaneSwitch = NSSwitch()
    private let closeWindowSwitch = NSSwitch()
    private let quitSwitch = NSSwitch()
    private let errorReportingSwitch = NSSwitch()
    private let errorReportingStatusLabel = NSTextField(labelWithString: "")
    private let errorReportingSubtitleLabel = NSTextField(labelWithString: "")
    private let errorReportingRestartLabel = NSTextField(labelWithString: "")

    init(
        configStore: AppConfigStore,
        errorReportingBundleConfigurationProvider: @escaping ErrorReportingBundleConfigurationProvider = {
            ErrorReportingBundleConfiguration.load(from: .main)
        },
        errorReportingConfirmationPresenter: @escaping ErrorReportingConfirmationPresenter = ErrorReportingRestartConfirmation.present,
        errorReportingRestartHandler: @escaping ErrorReportingRestartHandler = ErrorReportingApplicationRestart.restart,
        runtimeErrorReportingEnabled: Bool = ErrorReportingRuntimeState.isEnabledForCurrentProcess
    ) {
        self.configStore = configStore
        self.errorReportingBundleConfigurationProvider = errorReportingBundleConfigurationProvider
        self.errorReportingConfirmationPresenter = errorReportingConfirmationPresenter
        self.errorReportingRestartHandler = errorReportingRestartHandler
        self.runtimeErrorReportingEnabled = runtimeErrorReportingEnabled
        self.currentNotifications = configStore.current.notifications
        self.currentConfirmations = configStore.current.confirmations
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

        // Notifications card
        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let notificationRow = makeNotificationRow()
        cardStack.addArrangedSubview(notificationRow)
        notificationRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cardStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        let soundRow = makeSoundRow()
        cardStack.addArrangedSubview(soundRow)
        soundRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        stackView.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let errorReportingCard = SettingsCardView()
        let errorReportingStack = NSStackView()
        errorReportingStack.orientation = .vertical
        errorReportingStack.alignment = .leading
        errorReportingStack.spacing = 0
        errorReportingStack.translatesAutoresizingMaskIntoConstraints = false
        errorReportingCard.addSubview(errorReportingStack)

        let errorReportingRow = makeErrorReportingRow()
        errorReportingStack.addArrangedSubview(errorReportingRow)
        errorReportingRow.widthAnchor.constraint(equalTo: errorReportingStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            errorReportingStack.topAnchor.constraint(equalTo: errorReportingCard.topAnchor),
            errorReportingStack.leadingAnchor.constraint(equalTo: errorReportingCard.leadingAnchor),
            errorReportingStack.trailingAnchor.constraint(equalTo: errorReportingCard.trailingAnchor),
            errorReportingStack.bottomAnchor.constraint(equalTo: errorReportingCard.bottomAnchor),
        ])

        stackView.addArrangedSubview(errorReportingCard)
        errorReportingCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Confirmations card
        let confirmCard = SettingsCardView()
        let confirmStack = NSStackView()
        confirmStack.orientation = .vertical
        confirmStack.alignment = .leading
        confirmStack.spacing = 0
        confirmStack.translatesAutoresizingMaskIntoConstraints = false
        confirmCard.addSubview(confirmStack)

        let closePaneRow = makeSwitchRow(
            title: "Confirm before closing",
            subtitle: "Show a confirmation dialog when closing a pane.",
            toggle: closePaneSwitch,
            action: #selector(handleClosePaneSwitchChanged(_:))
        )
        confirmStack.addArrangedSubview(closePaneRow)
        closePaneRow.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        let confirmSeparator1 = NSBox()
        confirmSeparator1.boxType = .separator
        confirmSeparator1.translatesAutoresizingMaskIntoConstraints = false
        confirmStack.addArrangedSubview(confirmSeparator1)
        confirmSeparator1.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        let closeWindowRow = makeSwitchRow(
            title: "Confirm before closing window",
            subtitle: "Show a confirmation dialog when closing a window with running processes.",
            toggle: closeWindowSwitch,
            action: #selector(handleCloseWindowSwitchChanged(_:))
        )
        confirmStack.addArrangedSubview(closeWindowRow)
        closeWindowRow.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        let confirmSeparator2 = NSBox()
        confirmSeparator2.boxType = .separator
        confirmSeparator2.translatesAutoresizingMaskIntoConstraints = false
        confirmStack.addArrangedSubview(confirmSeparator2)
        confirmSeparator2.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        let quitRow = makeSwitchRow(
            title: "Confirm before quitting",
            subtitle: "Show a confirmation dialog when quitting Zentty.",
            toggle: quitSwitch,
            action: #selector(handleQuitSwitchChanged(_:))
        )
        confirmStack.addArrangedSubview(quitRow)
        quitRow.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            confirmStack.topAnchor.constraint(equalTo: confirmCard.topAnchor),
            confirmStack.leadingAnchor.constraint(equalTo: confirmCard.leadingAnchor),
            confirmStack.trailingAnchor.constraint(equalTo: confirmCard.trailingAnchor),
            confirmStack.bottomAnchor.constraint(equalTo: confirmCard.bottomAnchor),
        ])

        stackView.addArrangedSubview(confirmCard)
        confirmCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        closePaneSwitch.state = currentConfirmations.confirmBeforeClosingPane ? .on : .off
        closeWindowSwitch.state = currentConfirmations.confirmBeforeClosingWindow ? .on : .off
        quitSwitch.state = currentConfirmations.confirmBeforeQuitting ? .on : .off
        errorReportingSwitch.state = currentErrorReporting.enabled ? .on : .off
        refreshNotificationStatus()
        updateErrorReportingAvailability()
        updateErrorReportingRestartMessage()
    }

    override func prepareForPresentation() {
        refreshNotificationStatus()
        super.prepareForPresentation()
    }

    func apply(notifications: AppConfig.Notifications) {
        currentNotifications = notifications
        selectSoundPopupItem(for: notifications.soundName)
    }

    func apply(confirmations: AppConfig.Confirmations) {
        currentConfirmations = confirmations
        guard isViewLoaded else { return }
        closePaneSwitch.state = confirmations.confirmBeforeClosingPane ? .on : .off
        closeWindowSwitch.state = confirmations.confirmBeforeClosingWindow ? .on : .off
        quitSwitch.state = confirmations.confirmBeforeQuitting ? .on : .off
    }

    func apply(errorReporting: AppConfig.ErrorReporting) {
        currentErrorReporting = errorReporting
        guard isViewLoaded else { return }
        errorReportingSwitch.state = errorReporting.enabled ? .on : .off
        updateErrorReportingAvailability()
        updateErrorReportingRestartMessage()
    }

    // MARK: - Notification Row

    private func makeNotificationRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: "Desktop Notifications",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        leftStack.addArrangedSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.stringValue = "Checking notification status\u{2026}"
        leftStack.addArrangedSubview(subtitleLabel)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        rightStack.addArrangedSubview(statusLabel)

        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .regular
        openSettingsButton.target = self
        openSettingsButton.action = #selector(handleOpenSettings(_:))
        rightStack.addArrangedSubview(openSettingsButton)

        sendTestButton.bezelStyle = .rounded
        sendTestButton.controlSize = .regular
        sendTestButton.target = self
        sendTestButton.action = #selector(handleSendTest(_:))
        rightStack.addArrangedSubview(sendTestButton)

        container.addSubview(leftStack)
        container.addSubview(rightStack)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            rightStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    // MARK: - Sound Row

    private func makeSoundRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: "Notification Sound",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        leftStack.addArrangedSubview(titleLabel)

        let soundSubtitle = makeLabel(
            text: "Sound played when a notification arrives.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        soundSubtitle.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(soundSubtitle)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        soundPopupButton.removeAllItems()
        soundPopupButton.addItem(withTitle: "Default")
        soundPopupButton.lastItem?.representedObject = "" as String
        for sound in Sound.systemSounds {
            soundPopupButton.addItem(withTitle: sound)
            soundPopupButton.lastItem?.representedObject = sound as String
        }
        soundPopupButton.target = self
        soundPopupButton.action = #selector(handleSoundChanged(_:))
        soundPopupButton.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.addArrangedSubview(soundPopupButton)

        playButton.bezelStyle = .rounded
        playButton.image = NSImage(
            systemSymbolName: "play.fill",
            accessibilityDescription: "Preview sound"
        )
        playButton.imagePosition = .imageOnly
        playButton.target = self
        playButton.action = #selector(handlePlaySound(_:))
        playButton.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.addArrangedSubview(playButton)

        container.addSubview(leftStack)
        container.addSubview(rightStack)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            rightStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
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
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    // MARK: - Actions

    @objc
    private func handleOpenSettings(_ sender: Any?) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let urlString = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc
    private func handleSendTest(_ sender: Any?) {
        let content = UNMutableNotificationContent()
        content.title = "Zentty"
        content.body = "This is a test notification."
        content.sound = resolvedNotificationSound(for: currentNotifications.soundName)
        let request = UNNotificationRequest(
            identifier: "test-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc
    private func handleSoundChanged(_ sender: NSPopUpButton) {
        guard let soundName = sender.selectedItem?.representedObject as? String else { return }
        try? configStore.update { config in
            config.notifications.soundName = soundName
        }
        currentNotifications = configStore.current.notifications
    }

    @objc
    private func handleClosePaneSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.confirmations.confirmBeforeClosingPane = sender.state == .on
        }
        currentConfirmations = configStore.current.confirmations
    }

    @objc
    private func handleCloseWindowSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.confirmations.confirmBeforeClosingWindow = sender.state == .on
        }
        currentConfirmations = configStore.current.confirmations
    }

    @objc
    private func handleQuitSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.confirmations.confirmBeforeQuitting = sender.state == .on
        }
        currentConfirmations = configStore.current.confirmations
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

    @objc
    private func handlePlaySound(_ sender: Any?) {
        let soundName = currentNotifications.soundName
        if soundName.isEmpty {
            NSSound(named: "Tink")?.play()
        } else {
            NSSound(named: NSSound.Name(soundName))?.play()
        }
    }

    // MARK: - Status

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.applyNotificationStatus(status)
            }
        }
    }

    private func applyNotificationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized:
            statusLabel.stringValue = "Allowed"
            statusLabel.textColor = .systemGreen
            subtitleLabel.stringValue = "Desktop notifications are enabled."
        case .denied:
            statusLabel.stringValue = "Denied"
            statusLabel.textColor = .systemRed
            subtitleLabel.stringValue = "Desktop notifications are disabled. Enable them in System Settings."
        case .provisional:
            statusLabel.stringValue = "Provisional"
            statusLabel.textColor = .systemOrange
            subtitleLabel.stringValue = "Notifications are delivered quietly."
        case .notDetermined:
            statusLabel.stringValue = "Not Set Up"
            statusLabel.textColor = .secondaryLabelColor
            subtitleLabel.stringValue = "Notification permission has not been requested yet."
        case .ephemeral:
            statusLabel.stringValue = "Ephemeral"
            statusLabel.textColor = .systemOrange
            subtitleLabel.stringValue = "Notifications are available for a limited time."
        @unknown default:
            statusLabel.stringValue = "Unknown"
            statusLabel.textColor = .secondaryLabelColor
            subtitleLabel.stringValue = "Unable to determine notification status."
        }
    }

    private func updateErrorReportingAvailability() {
        let isAvailable = errorReportingBundleConfigurationProvider() != nil
        errorReportingSwitch.isEnabled = isAvailable

        if isAvailable {
            errorReportingStatusLabel.stringValue = currentErrorReporting.enabled ? "On" : "Off"
            errorReportingStatusLabel.textColor = .secondaryLabelColor
            errorReportingSubtitleLabel.stringValue = "Send anonymous crash reports to help improve Zentty. Privacy-first by design."
        } else {
            errorReportingStatusLabel.stringValue = "Unavailable"
            errorReportingStatusLabel.textColor = .secondaryLabelColor
            errorReportingSubtitleLabel.stringValue = "Error reporting is unavailable in this build."
        }
    }

    private func updateErrorReportingRestartMessage() {
        let needsRestart = currentErrorReporting.enabled != runtimeErrorReportingEnabled
        errorReportingRestartLabel.stringValue = needsRestart ? "Restart Zentty to apply this change." : ""
        errorReportingRestartLabel.isHidden = !needsRestart
    }

    // MARK: - Helpers

    private func selectSoundPopupItem(for soundName: String) {
        guard isViewLoaded else { return }
        let index = soundPopupButton.itemArray.firstIndex {
            ($0.representedObject as? String) == soundName
        } ?? 0
        soundPopupButton.selectItem(at: index)
    }

    private func makeSwitchRow(
        title: String,
        subtitle: String,
        toggle: NSSwitch,
        action: Selector
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: title,
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        leftStack.addArrangedSubview(titleLabel)

        let subtitleLabel = makeLabel(
            text: subtitle,
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(subtitleLabel)

        toggle.target = self
        toggle.action = action

        container.addSubview(leftStack)
        container.addSubview(toggle)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    // MARK: - For Testing

    var notificationStatusText: String {
        statusLabel.stringValue
    }

    var notificationSubtitleText: String {
        subtitleLabel.stringValue
    }

    var selectedSoundName: String {
        (soundPopupButton.selectedItem?.representedObject as? String) ?? ""
    }

    var availableSoundNames: [String] {
        soundPopupButton.itemArray.compactMap { $0.representedObject as? String }
    }

    var isClosePaneSwitchOn: Bool {
        closePaneSwitch.state == .on
    }

    var isQuitSwitchOn: Bool {
        quitSwitch.state == .on
    }

    var isErrorReportingSwitchOn: Bool {
        errorReportingSwitch.state == .on
    }

    var isErrorReportingControlEnabled: Bool {
        errorReportingSwitch.isEnabled
    }

    var errorReportingStatusMessage: String {
        errorReportingSubtitleLabel.stringValue
    }

    var errorReportingRestartMessage: String? {
        errorReportingRestartLabel.stringValue.isEmpty ? nil : errorReportingRestartLabel.stringValue
    }

    func setErrorReportingEnabledForTesting(_ enabled: Bool) {
        requestErrorReportingChange(to: enabled)
    }
}

func resolvedNotificationSound(for soundName: String) -> UNNotificationSound {
    if soundName.isEmpty {
        return .default
    }
    return UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
}
