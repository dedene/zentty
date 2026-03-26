import AppKit

@MainActor
final class PaneLayoutSettingsSectionViewController: NSViewController {
    private var preferences: PaneLayoutPreferences = .default
    private var summaryLabelsByDisplayClass: [DisplayClass: NSTextField] = [:]

    override func loadView() {
        view = NSView()

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        let subtitleLabel = makeLabel(
            text: "Zentty uses explicit screen behavior presets so each split stays calm and predictable.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitleLabel)

        DisplayClass.allCases.forEach { displayClass in
            let card = makeCardSection(for: displayClass)
            stackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])

        apply(preferences: preferences)
    }

    var sectionTitles: [String] {
        DisplayClass.allCases.map(\.title)
    }

    var presetSummary: [String] {
        DisplayClass.allCases.compactMap { summaryLabelsByDisplayClass[$0]?.stringValue }
    }

    func apply(preferences: PaneLayoutPreferences) {
        self.preferences = preferences

        for displayClass in DisplayClass.allCases {
            summaryLabelsByDisplayClass[displayClass]?.stringValue = behaviorSummary(for: displayClass)
        }
    }

    private func makeCardSection(for displayClass: DisplayClass) -> NSView {
        let card = SettingsCardView()

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(makeLabel(
            text: displayClass.title,
            font: .systemFont(ofSize: 13, weight: .semibold)
        ))

        let descriptionLabel = makeLabel(
            text: descriptionText(for: displayClass),
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        descriptionLabel.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(descriptionLabel)

        let presetSummary = makeLabel(
            text: behaviorSummary(for: displayClass),
            font: .systemFont(ofSize: 11, weight: .regular)
        )
        presetSummary.textColor = .secondaryLabelColor
        summaryLabelsByDisplayClass[displayClass] = presetSummary
        contentStack.addArrangedSubview(presetSummary)

        card.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        return card
    }

    private func descriptionText(for displayClass: DisplayClass) -> String {
        switch displayClass {
        case .laptop:
            "Laptop behavior\nPreserve the active pane, then scroll horizontally."
        case .largeDisplay:
            "Large Display behavior\nPreserve the active pane with slightly denser columns."
        case .ultrawide:
            "Ultrawide Hybrid behavior\nFirst split is 50/50, then keep horizontal scrolling."
        }
    }

    private func behaviorSummary(for displayClass: DisplayClass) -> String {
        switch displayClass {
        case .laptop:
            "Laptop behavior: preserve the active pane, then scroll horizontally."
        case .largeDisplay:
            "Large Display behavior: preserve the active pane with slightly denser columns."
        case .ultrawide:
            "Ultrawide Hybrid behavior: first split is 50/50, then keep horizontal scrolling."
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

@MainActor
final class OpenWithSettingsSectionViewController: NSViewController {
    private struct VisibleTarget {
        let stableID: String
        let title: String
        let removeAction: Selector?
        let tooltip: String?
    }

    private let configStore: AppConfigStore
    private let openWithService: OpenWithServing
    private let customAppPicker: () -> OpenWithCustomApp?
    private let primaryTargetPopupButton = NSPopUpButton()
    private let availableTargetsStackView = NSStackView()
    private let addCustomAppButton = NSButton()
    private var targetRowsByID: [String: OpenWithTargetRowView] = [:]
    private var isApplyingPreferences = false
    private var currentPreferences: AppConfig.OpenWith = .default
    private var currentVisibleTargets: [VisibleTarget] = []
    private var currentDetectedTargetsByID: [String: OpenWithDetectedTarget] = [:]

    private(set) var selectedPrimaryTargetStableID = ""
    private(set) var enabledTargetStableIDs: [String] = []
    private(set) var customAppNames: [String] = []

    static let defaultCustomAppPicker: () -> OpenWithCustomApp? = {
        let panel = NSOpenPanel()
        panel.prompt = "Add App"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["app"]

        guard panel.runModal() == .OK, let appURL = panel.url else {
            return nil
        }

        return OpenWithCustomApp(
            id: "custom:\(UUID().uuidString.lowercased())",
            name: appURL.deletingPathExtension().lastPathComponent,
            appPath: appURL.path
        )
    }

    init(
        configStore: AppConfigStore,
        openWithService: OpenWithServing = OpenWithService(),
        customAppPicker: @escaping () -> OpenWithCustomApp? = OpenWithSettingsSectionViewController.defaultCustomAppPicker
    ) {
        self.configStore = configStore
        self.openWithService = openWithService
        self.customAppPicker = customAppPicker
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
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        let subtitleLabel = makeLabel(
            text: "Choose which editors and file managers appear in the launcher, and set the default app.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitleLabel)

        // Card 1: Default App
        let defaultAppCard = SettingsCardView()
        let popupRow = NSStackView()
        popupRow.orientation = .horizontal
        popupRow.alignment = .centerY
        popupRow.spacing = 12
        popupRow.translatesAutoresizingMaskIntoConstraints = false
        let defaultAppLabel = makeLabel(
            text: "Default app",
            font: .systemFont(ofSize: 13, weight: .medium)
        )
        defaultAppLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popupRow.addArrangedSubview(defaultAppLabel)
        primaryTargetPopupButton.target = self
        primaryTargetPopupButton.action = #selector(handlePrimaryTargetChanged(_:))
        primaryTargetPopupButton.setContentHuggingPriority(.required, for: .horizontal)
        popupRow.addArrangedSubview(primaryTargetPopupButton)
        defaultAppCard.addSubview(popupRow)
        NSLayoutConstraint.activate([
            popupRow.topAnchor.constraint(equalTo: defaultAppCard.topAnchor, constant: 12),
            popupRow.leadingAnchor.constraint(equalTo: defaultAppCard.leadingAnchor, constant: 16),
            popupRow.trailingAnchor.constraint(equalTo: defaultAppCard.trailingAnchor, constant: -16),
            popupRow.bottomAnchor.constraint(equalTo: defaultAppCard.bottomAnchor, constant: -12),
        ])
        stackView.addArrangedSubview(defaultAppCard)
        defaultAppCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Card 2: Available Apps
        let availableCard = SettingsCardView()
        let availableStack = NSStackView()
        availableStack.orientation = .vertical
        availableStack.alignment = .leading
        availableStack.spacing = 12
        availableStack.translatesAutoresizingMaskIntoConstraints = false

        let availableHeaderRow = NSStackView()
        availableHeaderRow.orientation = .horizontal
        availableHeaderRow.alignment = .centerY
        availableHeaderRow.spacing = 12
        let availableLabel = makeLabel(
            text: "Available Apps",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        availableLabel.textColor = .secondaryLabelColor
        availableLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        availableHeaderRow.addArrangedSubview(availableLabel)
        addCustomAppButton.title = "Add App\u{2026}"
        addCustomAppButton.target = self
        addCustomAppButton.action = #selector(handleAddCustomApp(_:))
        addCustomAppButton.setContentHuggingPriority(.required, for: .horizontal)
        availableHeaderRow.addArrangedSubview(addCustomAppButton)
        availableHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        availableStack.addArrangedSubview(availableHeaderRow)
        availableHeaderRow.widthAnchor.constraint(equalTo: availableStack.widthAnchor).isActive = true

        availableTargetsStackView.orientation = .vertical
        availableTargetsStackView.alignment = .leading
        availableTargetsStackView.spacing = 10
        availableStack.addArrangedSubview(availableTargetsStackView)

        availableCard.addSubview(availableStack)
        NSLayoutConstraint.activate([
            availableStack.topAnchor.constraint(equalTo: availableCard.topAnchor, constant: 16),
            availableStack.leadingAnchor.constraint(equalTo: availableCard.leadingAnchor, constant: 16),
            availableStack.trailingAnchor.constraint(equalTo: availableCard.trailingAnchor, constant: -16),
            availableStack.bottomAnchor.constraint(equalTo: availableCard.bottomAnchor, constant: -16),
        ])
        stackView.addArrangedSubview(availableCard)
        availableCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderCurrentState()
    }

    func apply(preferences: AppConfig.OpenWith) {
        currentPreferences = preferences
        currentDetectedTargetsByID = openWithService.detectedTargets(preferences: preferences).reduce(into: [String: OpenWithDetectedTarget]()) {
            $0[$1.target.stableID] = $1
        }
        enabledTargetStableIDs = preferences.enabledTargetIDs
        customAppNames = preferences.customApps.map(\.name)
        currentVisibleTargets = visibleTargets(
            for: preferences,
            detectedTargetsByID: currentDetectedTargetsByID
        )
        if isViewLoaded {
            renderCurrentState()
        }
    }

    func prepareForPresentation() {
        let sanitizedPreferences = sanitizedPreferencesForPresentation(currentPreferences)
        if sanitizedPreferences != configStore.current.openWith {
            try? configStore.update { config in
                config.openWith = sanitizedPreferences
            }
            apply(preferences: configStore.current.openWith)
        } else {
            apply(preferences: currentPreferences)
        }
    }

    private func renderCurrentState() {
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }

        rebuildVisibleTargetRows()

        primaryTargetPopupButton.removeAllItems()
        let items = availablePrimaryTargetItems(
            for: currentPreferences,
            detectedTargetsByID: currentDetectedTargetsByID
        )
        if items.isEmpty {
            primaryTargetPopupButton.addItem(withTitle: "No available apps")
            primaryTargetPopupButton.isEnabled = false
            selectedPrimaryTargetStableID = currentPreferences.primaryTargetID
            return
        }

        primaryTargetPopupButton.isEnabled = true
        for item in items {
            primaryTargetPopupButton.addItem(withTitle: item.title)
            primaryTargetPopupButton.lastItem?.representedObject = item.stableID
        }
        let selectedIndex = items.firstIndex(where: { $0.stableID == currentPreferences.primaryTargetID }) ?? 0
        primaryTargetPopupButton.selectItem(at: selectedIndex)
        selectedPrimaryTargetStableID = items[selectedIndex].stableID
        reconcilePrimaryTargetIfNeeded(
            selectedStableID: items[selectedIndex].stableID,
            preferences: currentPreferences
        )
    }

    private func rebuildVisibleTargetRows() {
        targetRowsByID.removeAll()
        availableTargetsStackView.arrangedSubviews.forEach { view in
            availableTargetsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if currentVisibleTargets.isEmpty {
            let label = makeLabel(
                text: "No available apps found.",
                font: .systemFont(ofSize: 11, weight: .regular)
            )
            label.textColor = .secondaryLabelColor
            availableTargetsStackView.addArrangedSubview(label)
            return
        }

        for target in currentVisibleTargets {
            let row = OpenWithTargetRowView(
                title: target.title,
                stableID: target.stableID,
                target: self,
                toggleAction: #selector(handleTargetToggle(_:)),
                removeAction: target.removeAction
            )
            row.checkbox.toolTip = target.tooltip
            row.checkbox.state = currentPreferences.enabledTargetIDs.contains(target.stableID) ? .on : .off
            targetRowsByID[target.stableID] = row
            availableTargetsStackView.addArrangedSubview(row)
        }
    }

    private func visibleTargets(
        for preferences: AppConfig.OpenWith,
        detectedTargetsByID: [String: OpenWithDetectedTarget]
    ) -> [VisibleTarget] {
        let builtIns = OpenWithCatalog.macOSBuiltInTargets.compactMap { target -> VisibleTarget? in
            guard detectedTargetsByID[target.id.rawValue]?.isAvailable == true else {
                return nil
            }

            return VisibleTarget(
                stableID: target.id.rawValue,
                title: target.displayName,
                removeAction: nil,
                tooltip: nil
            )
        }
        let customApps = preferences.customApps.compactMap { app -> VisibleTarget? in
            guard detectedTargetsByID[app.id]?.isAvailable == true else {
                return nil
            }

            return VisibleTarget(
                stableID: app.id,
                title: app.name,
                removeAction: #selector(handleRemoveCustomApp(_:)),
                tooltip: app.appPath
            )
        }
        return builtIns + customApps
    }

    private func sanitizedPreferencesForPresentation(_ preferences: AppConfig.OpenWith) -> AppConfig.OpenWith {
        let detectedTargetsByID = openWithService.detectedTargets(preferences: preferences).reduce(into: [String: OpenWithDetectedTarget]()) {
            $0[$1.target.stableID] = $1
        }
        let availableIDs = Set(detectedTargetsByID.compactMap { $0.value.isAvailable ? $0.key : nil })
        let enabledIDs = Set(preferences.enabledTargetIDs)
        let remainingCustomApps = preferences.customApps.filter { availableIDs.contains($0.id) }
        let remainingCustomIDs = Set(remainingCustomApps.map(\.id))
        let visibleBuiltInIDs = Set(OpenWithCatalog.macOSBuiltInTargets.map(\.id.rawValue)).intersection(availableIDs)

        var sanitized = preferences
        sanitized.customApps = remainingCustomApps
        sanitized.enabledTargetIDs = orderedTargetIDs(for: sanitized).filter { stableID in
            enabledIDs.contains(stableID)
                && (visibleBuiltInIDs.contains(stableID) || remainingCustomIDs.contains(stableID))
        }
        sanitized.primaryTargetID = fallbackPrimaryTargetID(for: sanitized)
        return sanitized
    }

    private func availablePrimaryTargetItems(
        for preferences: AppConfig.OpenWith,
        detectedTargetsByID: [String: OpenWithDetectedTarget]
    ) -> [(stableID: String, title: String)] {
        let enabledIDs = Set(preferences.enabledTargetIDs)
        let builtIns = OpenWithCatalog.macOSBuiltInTargets.compactMap { target -> (String, String)? in
            guard
                enabledIDs.contains(target.id.rawValue),
                detectedTargetsByID[target.id.rawValue]?.isAvailable == true
            else {
                return nil
            }

            return (target.id.rawValue, target.displayName)
        }
        let customApps = preferences.customApps.compactMap { app -> (String, String)? in
            guard
                enabledIDs.contains(app.id),
                detectedTargetsByID[app.id]?.isAvailable == true
            else {
                return nil
            }

            return (app.id, app.name)
        }
        return builtIns + customApps
    }

    @objc
    private func handlePrimaryTargetChanged(_ sender: NSPopUpButton) {
        guard
            !isApplyingPreferences,
            let stableID = sender.selectedItem?.representedObject as? String
        else {
            return
        }

        try? configStore.update { config in
            config.openWith.primaryTargetID = stableID
        }
        apply(preferences: configStore.current.openWith)
    }

    @objc
    private func handleTargetToggle(_ sender: NSButton) {
        guard
            !isApplyingPreferences,
            let stableID = sender.identifier?.rawValue
        else {
            return
        }

        try? configStore.update { config in
            var enabledTargetIDs = Set(config.openWith.enabledTargetIDs)
            if sender.state == .on {
                enabledTargetIDs.insert(stableID)
            } else {
                enabledTargetIDs.remove(stableID)
            }

            config.openWith.enabledTargetIDs = orderedTargetIDs(for: config.openWith).filter {
                enabledTargetIDs.contains($0)
            }

            if !config.openWith.enabledTargetIDs.contains(config.openWith.primaryTargetID) {
                config.openWith.primaryTargetID = fallbackPrimaryTargetID(for: config.openWith)
            }
        }
        apply(preferences: configStore.current.openWith)
    }

    @objc
    private func handleAddCustomApp(_ sender: Any?) {
        _ = sender
        addCustomApp()
    }

    @objc
    private func handleRemoveCustomApp(_ sender: NSButton) {
        guard let stableID = sender.identifier?.rawValue else {
            return
        }

        try? configStore.update { config in
            config.openWith.customApps.removeAll { $0.id == stableID }
            config.openWith.enabledTargetIDs.removeAll { $0 == stableID }
            targetRowsByID.removeValue(forKey: stableID)

            if config.openWith.primaryTargetID == stableID {
                config.openWith.primaryTargetID = fallbackPrimaryTargetID(for: config.openWith)
            }
        }
        apply(preferences: configStore.current.openWith)
    }

    private func addCustomApp() {
        guard let app = customAppPicker() else {
            return
        }

        try? configStore.update { config in
            let resolvedStableID: String
            if let existingApp = config.openWith.customApps.first(where: { $0.id == app.id || $0.appPath == app.appPath }) {
                resolvedStableID = existingApp.id
            } else {
                config.openWith.customApps.append(app)
                resolvedStableID = app.id
            }
            if !config.openWith.enabledTargetIDs.contains(resolvedStableID) {
                config.openWith.enabledTargetIDs.append(resolvedStableID)
            }
        }
        apply(preferences: configStore.current.openWith)
    }

    private func orderedTargetIDs(for preferences: AppConfig.OpenWith) -> [String] {
        OpenWithCatalog.macOSBuiltInTargets.map { $0.id.rawValue } + preferences.customApps.map(\.id)
    }

    private func fallbackPrimaryTargetID(for preferences: AppConfig.OpenWith) -> String {
        openWithService.primaryTarget(preferences: preferences)?.stableID
            ?? preferences.enabledTargetIDs.first
            ?? "finder"
    }

    private func reconcilePrimaryTargetIfNeeded(
        selectedStableID: String,
        preferences: AppConfig.OpenWith
    ) {
        guard
            !selectedStableID.isEmpty,
            preferences.primaryTargetID != selectedStableID,
            configStore.current.openWith.primaryTargetID != selectedStableID
        else {
            return
        }

        try? configStore.update { config in
            config.openWith.primaryTargetID = selectedStableID
        }
    }

    func performAddCustomAppForTesting() {
        addCustomApp()
    }

    var visibleTargetStableIDs: [String] {
        currentVisibleTargets.map(\.stableID)
    }

    var checkedVisibleTargetStableIDs: [String] {
        currentVisibleTargets
            .map(\.stableID)
            .filter { currentPreferences.enabledTargetIDs.contains($0) }
    }

    var primaryTargetPopupStableIDs: [String] {
        primaryTargetPopupButton.itemArray.compactMap { $0.representedObject as? String }
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}

@MainActor
final class SettingsCardView: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        updateBorderColor()
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

@MainActor
private final class OpenWithTargetRowView: NSStackView {
    let checkbox: NSButton
    let removeButton: NSButton?

    init(
        title: String,
        stableID: String,
        target: AnyObject,
        toggleAction: Selector,
        removeAction: Selector?
    ) {
        self.checkbox = NSButton(checkboxWithTitle: title, target: target, action: toggleAction)
        self.checkbox.identifier = NSUserInterfaceItemIdentifier(stableID)

        if let removeAction {
            let button = NSButton(title: "Remove", target: target, action: removeAction)
            button.identifier = NSUserInterfaceItemIdentifier(stableID)
            self.removeButton = button
        } else {
            self.removeButton = nil
        }

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        addArrangedSubview(checkbox)
        if let removeButton {
            addArrangedSubview(removeButton)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
