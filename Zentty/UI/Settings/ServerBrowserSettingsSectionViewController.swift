import AppKit
import UniformTypeIdentifiers

@MainActor
final class ServerBrowserSettingsSectionViewController: SettingsScrollableSectionViewController {
    private struct VisibleBrowserTarget {
        let stableID: String
        let title: String
        let removeAction: Selector?
        let tooltip: String?
    }

    private let configStore: AppConfigStore
    private let serverOpenService: ServerOpening
    private let customBrowserPicker: () -> ServerBrowserCustomApp?

    private let rootStackView = NSStackView()
    private var subtitleLabel: NSTextField?
    private var detectionCard: SettingsCardView?
    private var defaultBrowserCard: SettingsCardView?
    private var availableCard: SettingsCardView?
    private var availableHeaderRow: NSStackView?
    private let passiveDetectionSwitch = NSSwitch()
    private let primaryBrowserPopup = NSPopUpButton()
    private let availableTargetsStackView = NSStackView()
    private let addCustomBrowserButton = NSButton()
    private var targetRowsByID: [String: SettingsCheckmarkTargetRow] = [:]
    private var isApplyingPreferences = false
    private var currentServerDetection = AppConfig.ServerDetection.default
    private var currentVisibleTargets: [VisibleBrowserTarget] = []
    private var ignoredPortsCard: SettingsCardView?
    private let ignoredPortRulesStackView = NSStackView()
    private let ignoredPortInputField = NSTextField()
    private let addIgnoredPortButton = NSButton()
    private var ignoredPortErrorLabel: NSTextField?

    static let defaultCustomBrowserPicker: () -> ServerBrowserCustomApp? = {
        let panel = NSOpenPanel()
        panel.prompt = "Add Browser"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let appURL = panel.url else {
            return nil
        }

        let bundle = Bundle(url: appURL)
        return ServerBrowserCustomApp(
            id: "custom:\(UUID().uuidString.lowercased())",
            name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? appURL.deletingPathExtension().lastPathComponent,
            appPath: appURL.path,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }

    init(
        configStore: AppConfigStore,
        serverOpenService: ServerOpening,
        customBrowserPicker: @escaping () -> ServerBrowserCustomApp? =
            ServerBrowserSettingsSectionViewController.defaultCustomBrowserPicker
    ) {
        self.configStore = configStore
        self.serverOpenService = serverOpenService
        self.customBrowserPicker = customBrowserPicker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func assembleContent(in contentView: NSView) {
        rootStackView.orientation = .vertical
        rootStackView.alignment = .leading
        rootStackView.spacing = 16
        rootStackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStackView)

        let subtitleLabel = makeLabel(
            text: "Choose how Zentty discovers running dev servers, which browsers appear when you open a server URL, and the default browser.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        self.subtitleLabel = subtitleLabel
        rootStackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        let detectionCard = SettingsCardView()
        self.detectionCard = detectionCard
        let detectionRow = NSStackView()
        detectionRow.orientation = .horizontal
        detectionRow.alignment = .centerY
        detectionRow.spacing = 12
        detectionRow.translatesAutoresizingMaskIntoConstraints = false
        let detectionLabel = makeLabel(
            text: "Detect running servers in terminals",
            font: .systemFont(ofSize: 13, weight: .medium)
        )
        detectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detectionRow.addArrangedSubview(detectionLabel)
        passiveDetectionSwitch.target = self
        passiveDetectionSwitch.action = #selector(handlePassiveDetectionChanged(_:))
        detectionRow.addArrangedSubview(passiveDetectionSwitch)
        detectionCard.addSubview(detectionRow)
        NSLayoutConstraint.activate([
            detectionRow.topAnchor.constraint(equalTo: detectionCard.topAnchor, constant: 12),
            detectionRow.leadingAnchor.constraint(equalTo: detectionCard.leadingAnchor, constant: 16),
            detectionRow.trailingAnchor.constraint(equalTo: detectionCard.trailingAnchor, constant: -16),
            detectionRow.bottomAnchor.constraint(equalTo: detectionCard.bottomAnchor, constant: -12),
        ])
        rootStackView.addArrangedSubview(detectionCard)
        detectionCard.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        let defaultBrowserCard = SettingsCardView()
        self.defaultBrowserCard = defaultBrowserCard
        let popupRow = NSStackView()
        popupRow.orientation = .horizontal
        popupRow.alignment = .centerY
        popupRow.spacing = 12
        popupRow.translatesAutoresizingMaskIntoConstraints = false
        let defaultLabel = makeLabel(
            text: "Default browser",
            font: .systemFont(ofSize: 13, weight: .medium)
        )
        defaultLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popupRow.addArrangedSubview(defaultLabel)
        primaryBrowserPopup.target = self
        primaryBrowserPopup.action = #selector(handlePrimaryBrowserChanged(_:))
        primaryBrowserPopup.setContentHuggingPriority(.required, for: .horizontal)
        popupRow.addArrangedSubview(primaryBrowserPopup)
        defaultBrowserCard.addSubview(popupRow)
        NSLayoutConstraint.activate([
            popupRow.topAnchor.constraint(equalTo: defaultBrowserCard.topAnchor, constant: 12),
            popupRow.leadingAnchor.constraint(equalTo: defaultBrowserCard.leadingAnchor, constant: 16),
            popupRow.trailingAnchor.constraint(equalTo: defaultBrowserCard.trailingAnchor, constant: -16),
            popupRow.bottomAnchor.constraint(equalTo: defaultBrowserCard.bottomAnchor, constant: -12),
        ])
        rootStackView.addArrangedSubview(defaultBrowserCard)
        defaultBrowserCard.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        let availableCard = SettingsCardView()
        self.availableCard = availableCard
        let availableStack = NSStackView()
        availableStack.orientation = .vertical
        availableStack.alignment = .leading
        availableStack.spacing = 12
        availableStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        self.availableHeaderRow = headerRow
        let availableLabel = makeLabel(
            text: "Available browsers",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        availableLabel.textColor = .secondaryLabelColor
        availableLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(availableLabel)
        addCustomBrowserButton.title = "Add App\u{2026}"
        addCustomBrowserButton.target = self
        addCustomBrowserButton.action = #selector(handleAddCustomBrowser(_:))
        addCustomBrowserButton.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(addCustomBrowserButton)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        availableStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: availableStack.widthAnchor).isActive = true

        availableTargetsStackView.orientation = .vertical
        availableTargetsStackView.alignment = .leading
        availableTargetsStackView.spacing = 10
        availableStack.addArrangedSubview(availableTargetsStackView)
        availableTargetsStackView.widthAnchor.constraint(equalTo: availableStack.widthAnchor).isActive = true

        availableCard.addSubview(availableStack)
        NSLayoutConstraint.activate([
            availableStack.topAnchor.constraint(equalTo: availableCard.topAnchor, constant: 16),
            availableStack.leadingAnchor.constraint(equalTo: availableCard.leadingAnchor, constant: 16),
            availableStack.trailingAnchor.constraint(equalTo: availableCard.trailingAnchor, constant: -16),
            availableStack.bottomAnchor.constraint(equalTo: availableCard.bottomAnchor, constant: -16),
        ])
        rootStackView.addArrangedSubview(availableCard)
        availableCard.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        let ignoredPortsCard = makeIgnoredPortsCard()
        self.ignoredPortsCard = ignoredPortsCard
        rootStackView.addArrangedSubview(ignoredPortsCard)
        ignoredPortsCard.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            rootStackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // Top-anchor the content (≤, not ==) so it keeps its natural height
            // instead of stretching — and spreading rows — when the pane is
            // taller than the content.
            rootStackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func measuredContentHeight() -> CGFloat {
        let subtitleHeight = subtitleLabel?.fittingSize.height ?? 0
        let detectionHeight = detectionCard?.fittingSize.height ?? 0
        let defaultHeight = defaultBrowserCard?.fittingSize.height ?? 0
        let headerHeight = availableHeaderRow?.fittingSize.height ?? 0
        let arrangedRows = availableTargetsStackView.arrangedSubviews
        var rowHeights: CGFloat = 0
        for row in arrangedRows {
            rowHeights += row.fittingSize.height
        }
        let rowCount = arrangedRows.count
        let rowSpacing = rowCount > 1 ? availableTargetsStackView.spacing * CGFloat(rowCount - 1) : 0
        let availableInnerHeight = 16 + headerHeight + 12 + rowHeights + rowSpacing + 16
        let availableCardHeight = availableCard != nil ? availableInnerHeight : 0
        let ignoredPortsHeight = ignoredPortsCard?.fittingSize.height ?? 0

        return subtitleHeight + 16 + detectionHeight + 16 + defaultHeight + 16 + availableCardHeight + 16 + ignoredPortsHeight
    }

    func apply(serverDetection: AppConfig.ServerDetection) {
        currentServerDetection = serverDetection
        if isViewLoaded {
            renderCurrentState()
        }
    }

    override func prepareInitialContent() {
        renderCurrentState()
    }

    override func prepareForPresentation() {
        let sanitized = sanitizedServerDetectionForPresentation(currentServerDetection)
        if sanitized != configStore.current.serverDetection {
            try? configStore.update { config in
                config.serverDetection = sanitized
            }
            apply(serverDetection: configStore.current.serverDetection)
        } else {
            apply(serverDetection: currentServerDetection)
        }
        super.prepareForPresentation()
    }

    private func renderCurrentState() {
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }

        passiveDetectionSwitch.state = currentServerDetection.passiveDetectionEnabled ? .on : .off

        rebuildVisibleTargetRows()
        rebuildIgnoredPortRows()
        hideIgnoredPortError()

        primaryBrowserPopup.removeAllItems()
        let items = availablePrimaryBrowserItems(for: currentServerDetection)
        if items.isEmpty {
            primaryBrowserPopup.addItem(withTitle: "No browsers available")
            primaryBrowserPopup.isEnabled = false
            refreshScrollableContentLayout()
            return
        }

        primaryBrowserPopup.isEnabled = true
        for item in items {
            primaryBrowserPopup.addItem(withTitle: item.title)
            primaryBrowserPopup.lastItem?.representedObject = item.stableID
        }

        let preferredID = currentServerDetection.preferredBrowserID
        let browsersForMatch = serverOpenService.availableBrowsers(config: currentServerDetection)
        let selectedIndex = items.firstIndex(where: { item in
            guard let match = browsersForMatch.first(where: { $0.stableID == item.stableID }) else {
                return false
            }
            return ServerBrowserCatalog.preferenceMatchesTarget(preferredID, target: match)
        }) ?? 0
        primaryBrowserPopup.selectItem(at: selectedIndex)
        reconcilePreferredBrowserIfNeeded(selectedStableID: items[selectedIndex].stableID)
        refreshScrollableContentLayout()
    }

    private func installedBrowsersByStableID(_ config: AppConfig.ServerDetection) -> [String: ServerBrowserTarget] {
        var probe = config
        probe.enabledBrowserTargetIDs = ServerBrowserCatalog.orderedBrowserTargetIDs(
            customBrowserIDs: config.customBrowsers.map(\.id)
        )
        let list = serverOpenService.availableBrowsers(config: probe)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.stableID, $0) })
    }

    private func visibleBrowserTargets(for config: AppConfig.ServerDetection) -> [VisibleBrowserTarget] {
        let installed = installedBrowsersByStableID(config)
        let builtIns = ServerBrowserCatalog.macOSBuiltInBrowsers.compactMap { definition -> VisibleBrowserTarget? in
            guard installed[definition.id.rawValue] != nil else {
                return nil
            }

            return VisibleBrowserTarget(
                stableID: definition.id.rawValue,
                title: definition.displayName,
                removeAction: nil,
                tooltip: nil
            )
        }
        let customApps = config.customBrowsers.compactMap { app -> VisibleBrowserTarget? in
            guard installed[app.id]?.isAvailable == true else {
                return nil
            }

            return VisibleBrowserTarget(
                stableID: app.id,
                title: app.name,
                removeAction: #selector(handleRemoveCustomBrowser(_:)),
                tooltip: app.appPath
            )
        }

        return builtIns + customApps
    }

    private func rebuildVisibleTargetRows() {
        targetRowsByID.removeAll()
        availableTargetsStackView.arrangedSubviews.forEach { view in
            availableTargetsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        currentVisibleTargets = visibleBrowserTargets(for: currentServerDetection)

        if currentVisibleTargets.isEmpty {
            let label = makeLabel(
                text: "No installed browsers found from the catalog.",
                font: .systemFont(ofSize: 11, weight: .regular)
            )
            label.textColor = .secondaryLabelColor
            availableTargetsStackView.addArrangedSubview(label)
            return
        }

        for target in currentVisibleTargets {
            let row = SettingsCheckmarkTargetRow(
                title: target.title,
                stableID: target.stableID,
                target: self,
                toggleAction: #selector(handleBrowserTargetToggle(_:)),
                removeAction: target.removeAction
            )
            row.checkbox.toolTip = target.tooltip
            row.checkbox.state = currentServerDetection.enabledBrowserTargetIDs.contains(target.stableID) ? .on : .off
            targetRowsByID[target.stableID] = row
            availableTargetsStackView.addArrangedSubview(row)
        }
    }

    private func sanitizedServerDetectionForPresentation(_ detection: AppConfig.ServerDetection) -> AppConfig.ServerDetection {
        let fileManager = FileManager.default
        var sanitized = detection
        sanitized.customBrowsers = detection.customBrowsers.filter { fileManager.isReadableFile(atPath: $0.appPath) }

        let installed = installedBrowsersByStableID(sanitized)
        let installedIDs = Set(installed.keys)
        let enabledIDs = Set(sanitized.enabledBrowserTargetIDs)
        let visibleBuiltInIDs = Set(ServerBrowserCatalog.macOSBuiltInBrowsers.map(\.id.rawValue)).intersection(installedIDs)
        let remainingCustomApps = sanitized.customBrowsers.filter { installedIDs.contains($0.id) }
        let remainingCustomIDs = Set(remainingCustomApps.map(\.id))

        sanitized.customBrowsers = remainingCustomApps
        sanitized.enabledBrowserTargetIDs = orderedBrowserTargetIDs(for: sanitized).filter { stableID in
            enabledIDs.contains(stableID)
                && (visibleBuiltInIDs.contains(stableID) || remainingCustomIDs.contains(stableID))
        }
        sanitized.preferredBrowserID = fallbackPreferredBrowserIDIfNeeded(sanitized)
        return sanitized.normalized()
    }

    private func orderedBrowserTargetIDs(for detection: AppConfig.ServerDetection) -> [String] {
        ServerBrowserCatalog.orderedBrowserTargetIDs(customBrowserIDs: detection.customBrowsers.map(\.id))
    }

    private func availablePrimaryBrowserItems(for detection: AppConfig.ServerDetection) -> [(stableID: String, title: String)] {
        var items: [(String, String)] = [
            (ServerBrowserTarget.systemDefaultID, "System Default"),
        ]
        let enabledIDs = Set(detection.enabledBrowserTargetIDs)
        let browsers = serverOpenService.availableBrowsers(config: detection)
        for browser in browsers where !browser.isSystemDefault && browser.isAvailable {
            guard enabledIDs.contains(browser.stableID) else {
                continue
            }
            items.append((browser.stableID, browser.displayName))
        }
        return items
    }

    private func fallbackPreferredBrowserIDIfNeeded(_ detection: AppConfig.ServerDetection) -> String {
        let browsers = serverOpenService.availableBrowsers(config: detection)
        let pref = detection.preferredBrowserID
        let stillValid = browsers.contains {
            ServerBrowserCatalog.preferenceMatchesTarget(pref, target: $0) && $0.isAvailable
        }
        if stillValid {
            return pref
        }
        if let first = browsers.first(where: { $0.isAvailable && !$0.isSystemDefault }) {
            return first.stableID
        }
        return ServerBrowserTarget.systemDefaultID
    }

    private func reconcilePreferredBrowserIfNeeded(selectedStableID: String) {
        guard
            !selectedStableID.isEmpty,
            currentServerDetection.preferredBrowserID != selectedStableID,
            configStore.current.serverDetection.preferredBrowserID != selectedStableID
        else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.preferredBrowserID = selectedStableID
        }
    }

    @objc
    private func handlePassiveDetectionChanged(_ sender: NSSwitch) {
        guard !isApplyingPreferences else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.passiveDetectionEnabled = sender.state == .on
        }
        apply(serverDetection: configStore.current.serverDetection)
    }

    @objc
    private func handlePrimaryBrowserChanged(_ sender: NSPopUpButton) {
        guard
            !isApplyingPreferences,
            let stableID = sender.selectedItem?.representedObject as? String
        else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.preferredBrowserID = stableID
        }
        apply(serverDetection: configStore.current.serverDetection)
    }

    @objc
    private func handleBrowserTargetToggle(_ sender: NSButton) {
        guard
            !isApplyingPreferences,
            let stableID = sender.identifier?.rawValue
        else {
            return
        }

        try? configStore.update { config in
            var enabledIDs = Set(config.serverDetection.enabledBrowserTargetIDs)
            if sender.state == .on {
                enabledIDs.insert(stableID)
            } else {
                enabledIDs.remove(stableID)
            }

            config.serverDetection.enabledBrowserTargetIDs = orderedBrowserTargetIDs(for: config.serverDetection).filter {
                enabledIDs.contains($0)
            }

            let browsers = serverOpenService.availableBrowsers(config: config.serverDetection)
            let pref = config.serverDetection.preferredBrowserID
            let prefStillValid = browsers.contains {
                ServerBrowserCatalog.preferenceMatchesTarget(pref, target: $0) && $0.isAvailable
            }
            if !prefStillValid {
                config.serverDetection.preferredBrowserID = fallbackPreferredBrowserIDIfNeeded(config.serverDetection)
            }
        }
        apply(serverDetection: configStore.current.serverDetection)
    }

    @objc
    private func handleAddCustomBrowser(_ sender: Any?) {
        _ = sender
        guard let browser = customBrowserPicker() else {
            return
        }

        try? configStore.update { config in
            let resolvedStableID: String
            if let existingApp = config.serverDetection.customBrowsers.first(where: { $0.id == browser.id || $0.appPath == browser.appPath }) {
                resolvedStableID = existingApp.id
            } else {
                config.serverDetection.customBrowsers.append(browser)
                resolvedStableID = browser.id
            }
            if !config.serverDetection.enabledBrowserTargetIDs.contains(resolvedStableID) {
                var enabled = Set(config.serverDetection.enabledBrowserTargetIDs)
                enabled.insert(resolvedStableID)
                config.serverDetection.enabledBrowserTargetIDs = orderedBrowserTargetIDs(for: config.serverDetection).filter {
                    enabled.contains($0)
                }
            }
        }
        apply(serverDetection: configStore.current.serverDetection)
    }

    @objc
    private func handleRemoveCustomBrowser(_ sender: NSButton) {
        guard let stableID = sender.identifier?.rawValue else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.customBrowsers.removeAll { $0.id == stableID }
            config.serverDetection.enabledBrowserTargetIDs.removeAll { $0 == stableID }
            targetRowsByID.removeValue(forKey: stableID)

            if config.serverDetection.preferredBrowserID == stableID {
                config.serverDetection.preferredBrowserID = fallbackPreferredBrowserIDIfNeeded(config.serverDetection)
            }
        }
        apply(serverDetection: configStore.current.serverDetection)
    }

    private func makeIgnoredPortsCard() -> SettingsCardView {
        let card = SettingsCardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(text: "Ignored ports", font: .systemFont(ofSize: 13, weight: .semibold))
        titleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)

        let descriptionLabel = makeLabel(
            text: "Servers on these ports are hidden from the server menu. Enter a port (9229) or a range (24678-24680).",
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        descriptionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(descriptionLabel)
        descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        ignoredPortRulesStackView.orientation = .vertical
        ignoredPortRulesStackView.alignment = .leading
        ignoredPortRulesStackView.spacing = 8
        stack.addArrangedSubview(ignoredPortRulesStackView)
        ignoredPortRulesStackView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 8
        ignoredPortInputField.placeholderString = "e.g. 9229 or 24678-24680"
        ignoredPortInputField.target = self
        ignoredPortInputField.action = #selector(handleAddIgnoredPort(_:))
        ignoredPortInputField.translatesAutoresizingMaskIntoConstraints = false
        ignoredPortInputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        addRow.addArrangedSubview(ignoredPortInputField)
        addIgnoredPortButton.title = "Add"
        addIgnoredPortButton.bezelStyle = .rounded
        addIgnoredPortButton.target = self
        addIgnoredPortButton.action = #selector(handleAddIgnoredPort(_:))
        addIgnoredPortButton.setContentHuggingPriority(.required, for: .horizontal)
        addRow.addArrangedSubview(addIgnoredPortButton)
        stack.addArrangedSubview(addRow)

        let errorLabel = makeLabel(text: "", font: .systemFont(ofSize: 11, weight: .regular))
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        self.ignoredPortErrorLabel = errorLabel
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func rebuildIgnoredPortRows() {
        ignoredPortRulesStackView.arrangedSubviews.forEach { view in
            ignoredPortRulesStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !currentServerDetection.ignoredPortRules.isEmpty else {
            let label = makeLabel(text: "No ignored ports.", font: .systemFont(ofSize: 11, weight: .regular))
            label.textColor = .tertiaryLabelColor
            ignoredPortRulesStackView.addArrangedSubview(label)
            return
        }

        for rule in currentServerDetection.ignoredPortRules {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            let label = makeLabel(text: rule, font: .systemFont(ofSize: 12, weight: .regular))
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)

            let removeButton = NSButton()
            removeButton.title = "Remove"
            removeButton.bezelStyle = .rounded
            removeButton.controlSize = .small
            removeButton.target = self
            removeButton.action = #selector(handleRemoveIgnoredPort(_:))
            removeButton.identifier = NSUserInterfaceItemIdentifier(rule)
            removeButton.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(removeButton)

            ignoredPortRulesStackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: ignoredPortRulesStackView.widthAnchor).isActive = true
        }
    }

    @objc
    private func handleAddIgnoredPort(_ sender: Any?) {
        guard !isApplyingPreferences else {
            return
        }

        let text = ignoredPortInputField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return
        }
        guard ServerPortRule.parse(text) != nil else {
            showIgnoredPortError("Enter a port (e.g. 9229) or a range (e.g. 24678-24680).")
            return
        }

        hideIgnoredPortError()
        try? configStore.update { config in
            config.serverDetection.ignoredPortRules.append(text)
        }
        ignoredPortInputField.stringValue = ""
        apply(serverDetection: configStore.current.serverDetection)
    }

    @objc
    private func handleRemoveIgnoredPort(_ sender: NSButton) {
        guard let rule = sender.identifier?.rawValue else {
            return
        }

        try? configStore.update { config in
            config.serverDetection.ignoredPortRules.removeAll { $0 == rule }
        }
        apply(serverDetection: configStore.current.serverDetection)
    }

    private func showIgnoredPortError(_ message: String) {
        ignoredPortErrorLabel?.stringValue = message
        ignoredPortErrorLabel?.isHidden = false
        refreshScrollableContentLayout()
    }

    private func hideIgnoredPortError() {
        ignoredPortErrorLabel?.isHidden = true
        ignoredPortErrorLabel?.stringValue = ""
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        SettingsFormBuilder.label(text, font: font)
    }

    var isPassiveDetectionSwitchOnForTesting: Bool {
        passiveDetectionSwitch.state == .on
    }

    var primaryBrowserPopupStableIDsForTesting: [String] {
        primaryBrowserPopup.itemArray.compactMap { $0.representedObject as? String }
    }

    var visibleBrowserTargetStableIDsForTesting: [String] {
        currentVisibleTargets.map(\.stableID)
    }

    var checkedBrowserTargetStableIDsForTesting: [String] {
        currentVisibleTargets
            .map(\.stableID)
            .filter { currentServerDetection.enabledBrowserTargetIDs.contains($0) }
    }

    func setPassiveDetectionEnabledForTesting(_ enabled: Bool) {
        passiveDetectionSwitch.state = enabled ? .on : .off
        handlePassiveDetectionChanged(passiveDetectionSwitch)
    }

    var ignoredPortRulesForTesting: [String] {
        currentServerDetection.ignoredPortRules
    }

    var ignoredPortErrorVisibleForTesting: Bool {
        ignoredPortErrorLabel?.isHidden == false
    }

    /// Attempts to add `text` as an ignored-port rule. Returns true when accepted.
    @discardableResult
    func addIgnoredPortRuleForTesting(_ text: String) -> Bool {
        ignoredPortInputField.stringValue = text
        handleAddIgnoredPort(nil)
        return ignoredPortErrorLabel?.isHidden ?? true
    }

    func removeIgnoredPortRuleForTesting(_ rule: String) {
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(rule)
        handleRemoveIgnoredPort(button)
    }
}
