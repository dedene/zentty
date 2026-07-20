import AppKit

/// Settings → Mobile Devices. Enables the companion bridge, lists paired phones
/// (with revoke), shows the live listener status, and hosts the QR pairing sheet.
///
/// The bridge itself (`CompanionBridgeServer.shared`) owns pairing/advertising;
/// this controller is a thin front end. All offer-lifecycle logic lives in the
/// window-free `CompanionPairingSession` / `CompanionPairingOfferModel`.
@MainActor
final class MobileDevicesSettingsSectionViewController: SettingsScrollableSectionViewController {
    private let configStore: AppConfigStore
    /// Injectable so tests / previews can substitute the bridge; production reads
    /// the process-wide shared instance lazily (nil only in hosted test mode).
    private let bridgeProvider: () -> CompanionBridgeServer?

    private var currentCompanion: AppConfig.Companion = .default
    private var isApplyingCompanion = false

    private let enableSwitch = NSSwitch()
    private let statusValueLabel = NSTextField(labelWithString: "")
    private let statusDetailLabel = NSTextField(labelWithString: "")
    private let devicesStack = NSStackView()
    private let pairButton = NSButton(title: "Pair New Device\u{2026}", target: nil, action: nil)

    private var pairingSheetController: MobileDevicesPairingSheetViewController?

    init(
        configStore: AppConfigStore,
        bridgeProvider: @escaping () -> CompanionBridgeServer? = { CompanionBridgeServer.shared }
    ) {
        self.configStore = configStore
        self.currentCompanion = configStore.current.companion
        self.bridgeProvider = bridgeProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Assembly

    override func assembleContent(in contentView: NSView) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        let subtitle = SettingsFormBuilder.label(
            "Pair a phone to watch your agents, respond to prompts, and take over a pane from anywhere on your network.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitle.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let enableCard = makeEnableCard()
        stackView.addArrangedSubview(enableCard)
        enableCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let statusCard = makeStatusCard()
        stackView.addArrangedSubview(statusCard)
        statusCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let devicesCard = makeDevicesCard()
        stackView.addArrangedSubview(devicesCard)
        devicesCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        applyCompanionToControls()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Refresh the paired list when a device pairs while Settings is open.
        bridgeProvider()?.onPairedDevicesChanged = { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadDevicesAndStatus() }
        }
        reloadDevicesAndStatus()
    }

    override func prepareForPresentation() {
        reloadDevicesAndStatus()
        super.prepareForPresentation()
    }

    func apply(companion: AppConfig.Companion) {
        currentCompanion = companion
        applyCompanionToControls()
    }

    // MARK: - Enable card

    private func makeEnableCard() -> NSView {
        let card = SettingsCardView()
        let cardStack = verticalCardStack()
        card.addSubview(cardStack)

        let row = SettingsFormBuilder.switchRow(
            title: "Enable mobile companion",
            subtitle: "Advertise this Mac over the local network so paired phones can connect. Only active while a device is paired.",
            toggle: enableSwitch,
            target: self,
            action: #selector(handleEnableChanged(_:)),
            verticalInset: 16,
            toggleLeadingSpacing: 16,
            subtitleWidth: .matchStack
        )
        cardStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        pinStackToCard(cardStack, card)
        return card
    }

    // MARK: - Status card

    private func makeStatusCard() -> NSView {
        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 4
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let title = SettingsFormBuilder.label("Listener", font: .systemFont(ofSize: 13, weight: .semibold))
        cardStack.addArrangedSubview(title)

        statusValueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        cardStack.addArrangedSubview(statusValueLabel)

        statusDetailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusDetailLabel.textColor = .secondaryLabelColor
        statusDetailLabel.lineBreakMode = .byWordWrapping
        statusDetailLabel.maximumNumberOfLines = 0
        cardStack.addArrangedSubview(statusDetailLabel)
        statusDetailLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    // MARK: - Devices card

    private func makeDevicesCard() -> NSView {
        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = SettingsFormBuilder.label("Paired Devices", font: .systemFont(ofSize: 13, weight: .semibold))
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(headerLabel)

        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(handlePairNewDevice(_:))
        pairButton.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(pairButton)

        cardStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 10
        devicesStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.addArrangedSubview(devicesStack)
        devicesStack.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func rebuildDeviceRows(_ devices: [CompanionPairedDevice]) {
        devicesStack.arrangedSubviews.forEach { view in
            devicesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !devices.isEmpty else {
            let empty = SettingsFormBuilder.label(
                "No devices paired yet. Choose \u{201C}Pair New Device\u{201D} to get started.",
                font: .systemFont(ofSize: 11, weight: .regular)
            )
            empty.textColor = .secondaryLabelColor
            devicesStack.addArrangedSubview(empty)
            return
        }

        let now = Date()
        for device in devices.sorted(by: { $0.pairedAt < $1.pairedAt }) {
            let row = makeDeviceRow(CompanionPairedDeviceRow(device: device, now: now))
            devicesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true
        }
    }

    private func makeDeviceRow(_ model: CompanionPairedDeviceRow) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftStack)

        let nameLabel = SettingsFormBuilder.label(model.name, font: .systemFont(ofSize: 13, weight: .semibold))
        leftStack.addArrangedSubview(nameLabel)

        let metaLabel = SettingsFormBuilder.label(
            "\(model.pairedAtText)  ·  \(model.lastSeenText)",
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        metaLabel.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(metaLabel)

        let revokeButton = NSButton(title: "Revoke", target: self, action: #selector(handleRevoke(_:)))
        revokeButton.bezelStyle = .rounded
        revokeButton.identifier = NSUserInterfaceItemIdentifier(model.deviceId)
        revokeButton.setContentHuggingPriority(.required, for: .horizontal)
        revokeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(revokeButton)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

            revokeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            revokeButton.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            revokeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: - State

    private func applyCompanionToControls() {
        guard isViewLoaded else { return }
        isApplyingCompanion = true
        enableSwitch.state = currentCompanion.enabled ? .on : .off
        isApplyingCompanion = false
    }

    private func reloadDevicesAndStatus() {
        guard isViewLoaded else { return }
        let bridge = bridgeProvider()
        rebuildDeviceRows(bridge?.pairedDevices() ?? [])
        applyStatus(bridge?.currentStatus())
        pairButton.isEnabled = bridge != nil
        refreshScrollableContentLayout()
    }

    private func applyStatus(_ status: CompanionBridgeServer.Status?) {
        guard let status else {
            statusValueLabel.stringValue = "Unavailable"
            statusValueLabel.textColor = .secondaryLabelColor
            statusDetailLabel.stringValue = "The companion bridge is not running in this build."
            return
        }

        if status.isAdvertising, let port = status.port {
            statusValueLabel.stringValue = "Advertising on port \(port)"
            statusValueLabel.textColor = .systemGreen
            statusDetailLabel.stringValue =
                "Bonjour: \(status.bonjourName) (\(status.bonjourServiceType))"
        } else if status.pairedDeviceCount == 0 {
            statusValueLabel.stringValue = "Idle"
            statusValueLabel.textColor = .secondaryLabelColor
            statusDetailLabel.stringValue = "Pair a device to start advertising on the local network."
        } else {
            statusValueLabel.stringValue = currentCompanion.enabled ? "Starting\u{2026}" : "Disabled"
            statusValueLabel.textColor = .secondaryLabelColor
            statusDetailLabel.stringValue = currentCompanion.enabled
                ? "Waiting for the local network listener to come up."
                : "Enable the mobile companion above to advertise this Mac."
        }
    }

    // MARK: - Actions

    @objc
    private func handleEnableChanged(_ sender: NSSwitch) {
        guard !isApplyingCompanion else { return }
        try? configStore.update { config in
            config.companion.enabled = sender.state == .on
        }
        currentCompanion = configStore.current.companion
        reloadDevicesAndStatus()
    }

    @objc
    private func handlePairNewDevice(_ sender: Any?) {
        guard let bridge = bridgeProvider(), let window = view.window else { return }

        let configuredRelayURL = configStore.current.companion.relayUrl
        let session = CompanionPairingSession(mint: {
            // Offer carries the configured relay URL (empty = LAN-only) so the
            // phone can reach this Mac off-network when a relay is set.
            bridge.makePairingOffer(relayURL: configuredRelayURL)
        })
        let sheet = MobileDevicesPairingSheetViewController(
            session: session,
            onClose: { [weak self] in
                bridge.cancelPairingOffers()
                self?.reloadDevicesAndStatus()
            }
        )
        pairingSheetController = sheet
        presentAsSheet(sheet)
        // Refresh so the status row reflects the listener that minting just started.
        reloadDevicesAndStatus()
    }

    @objc
    private func handleRevoke(_ sender: NSButton) {
        guard let deviceId = sender.identifier?.rawValue else { return }
        bridgeProvider()?.revokeDevice(deviceId: deviceId)
        reloadDevicesAndStatus()
    }

    // MARK: - Layout helpers

    private func verticalCardStack() -> NSStackView {
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        return cardStack
    }

    private func pinStackToCard(_ stack: NSStackView, _ card: NSView) {
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    // MARK: - For Testing

    var isEnableSwitchOnForTesting: Bool { enableSwitch.state == .on }
    var statusValueTextForTesting: String { statusValueLabel.stringValue }
    var deviceRowCountForTesting: Int { devicesStack.arrangedSubviews.count }
}
