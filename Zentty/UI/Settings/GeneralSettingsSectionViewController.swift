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
    private var currentNotifications: AppConfig.Notifications = .default

    private let statusLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let openSettingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let sendTestButton = NSButton(title: "Send Test", target: nil, action: nil)
    private let soundPopupButton = NSPopUpButton()
    private let playButton = NSButton()

    init(configStore: AppConfigStore) {
        self.configStore = configStore
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
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        // Row 1: Desktop Notifications
        let notificationRow = makeNotificationRow()
        cardStack.addArrangedSubview(notificationRow)
        notificationRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cardStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        // Row 2: Notification Sound
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

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshNotificationStatus()
    }

    override func prepareForPresentation() {
        refreshNotificationStatus()
        super.prepareForPresentation()
    }

    func apply(notifications: AppConfig.Notifications) {
        currentNotifications = notifications
        selectSoundPopupItem(for: notifications.soundName)
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

    // MARK: - Helpers

    private func selectSoundPopupItem(for soundName: String) {
        guard isViewLoaded else { return }
        let index = soundPopupButton.itemArray.firstIndex {
            ($0.representedObject as? String) == soundName
        } ?? 0
        soundPopupButton.selectItem(at: index)
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
}

func resolvedNotificationSound(for soundName: String) -> UNNotificationSound {
    if soundName.isEmpty {
        return .default
    }
    return UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
}
