import AppKit
import UniformTypeIdentifiers

@MainActor
protocol SettingsPresentingSection: AnyObject {
    func prepareForPresentation()
}

@MainActor
protocol SettingsAppearanceUpdating: AnyObject {
    func handleAppearanceChange()
}

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
class SettingsScrollableSectionViewController: NSViewController, SettingsPaneMeasuring, SettingsPresentingSection {
    fileprivate enum Layout {
        static let topInset: CGFloat = 22
        static let horizontalInset: CGFloat = 28
        static let bottomInset: CGFloat = 28
        static let minimumContentWidth: CGFloat = 280
        static let scrollerAllowance: CGFloat = 18
    }

    let scrollView = NSScrollView()
    let contentView = NSView()
    private let documentView = SettingsDocumentView()
    private var contentWidthConstraint: NSLayoutConstraint?
    private var isScrollerSuppressed = false

    final override func loadView() {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        // Keep translatesAutoresizingMaskIntoConstraints = true (default) so
        // NSTabView can size us when the selected tab changes. With =false and
        // no ancestor constraints pinning the scrollView, a post-switch tab
        // ends up at 0×0 (the blank-pane bug).
        scrollView.autoresizingMask = [.width, .height]

        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsViewController.preferredContentWidth,
            height: 1
        )
        contentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentView)
        contentWidthConstraint = contentView.widthAnchor.constraint(
            equalToConstant: SettingsViewController.preferredContentWidth
                - (Layout.horizontalInset * 2)
                - Layout.scrollerAllowance
        )

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Layout.topInset),
            contentView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Layout.horizontalInset),
            contentView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -Layout.bottomInset),
            contentWidthConstraint!,
        ])

        view = scrollView
        assembleContent(in: contentView)
        prepareInitialContent()
        contentView.layoutSubtreeIfNeeded()
        let initialContentHeight = measuredContentHeight() + Layout.topInset + Layout.bottomInset
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsViewController.preferredContentWidth,
            height: max(initialContentHeight, 1)
        )
        scrollView.documentView = documentView
        updateDocumentLayout(
            viewportWidth: SettingsViewController.preferredContentWidth,
            viewportHeight: 1,
            laysOutContent: false
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateDocumentLayout(
            viewportWidth: view.bounds.width,
            viewportHeight: view.bounds.height,
            laysOutContent: false
        )
    }

    func preferredViewportHeight(for width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        updateDocumentLayout(
            viewportWidth: width,
            viewportHeight: 0,
            laysOutContent: true
        )
        return documentView.frame.height
    }

    func prepareForPresentation() {
        loadViewIfNeeded()
        updateDocumentLayout(
            viewportWidth: max(view.bounds.width, SettingsViewController.preferredContentWidth),
            viewportHeight: max(view.bounds.height, 1),
            laysOutContent: true
        )
        scrollToTop()
    }

    func assembleContent(in contentView: NSView) {
        fatalError("Subclasses must override assembleContent(in:)")
    }

    func prepareInitialContent() {}

    func measuredContentHeight() -> CGFloat {
        contentView.fittingSize.height
    }

    func scrollToTop() {
        let clipView = scrollView.contentView
        clipView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clipView)
    }

    func setScrollerSuppressed(_ suppressed: Bool) {
        isScrollerSuppressed = suppressed
        scrollView.hasVerticalScroller = suppressed == false
    }

    func refreshScrollableContentLayout() {
        loadViewIfNeeded()
        updateDocumentLayout(
            viewportWidth: max(view.bounds.width, SettingsViewController.preferredContentWidth),
            viewportHeight: max(view.bounds.height, 1),
            laysOutContent: true
        )
    }

    var isScrollerSuppressedForTesting: Bool {
        isScrollerSuppressed
    }

    private func updateDocumentLayout(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        laysOutContent: Bool
    ) {
        let contentWidth = max(
            viewportWidth - (Layout.horizontalInset * 2) - Layout.scrollerAllowance,
            Layout.minimumContentWidth
        )
        contentWidthConstraint?.constant = contentWidth
        if laysOutContent {
            contentView.layoutSubtreeIfNeeded()
        }

        let contentHeight = measuredContentHeight() + Layout.topInset + Layout.bottomInset
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewportWidth, contentWidth + (Layout.horizontalInset * 2)),
            height: max(contentHeight, viewportHeight, 1)
        )
    }
}

@MainActor
final class PaneLayoutSettingsSectionViewController: SettingsScrollableSectionViewController {
    private let configStore: AppConfigStore
    private var panes: AppConfig.Panes
    private let showLabelsSwitch = NSSwitch()
    private let inactiveOpacitySlider = NSSlider()
    private let inactiveOpacityValueLabel = NSTextField(labelWithString: "")
    private var isApplyingPanes = false

    init(configStore: AppConfigStore) {
        self.configStore = configStore
        self.panes = configStore.current.panes
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

        let subtitleLabel = makeLabel(
            text: "Fine-tune how pane context and focus cues show up in the canvas.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let displayCard = makeDisplayCard()
        stackView.addArrangedSubview(displayCard)
        displayCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        configureInactiveOpacitySlider()

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        apply(panes: panes)
    }

    var showsPaneLabelsForTesting: Bool {
        showLabelsSwitch.state == .on
    }

    var inactivePaneOpacityPercentageForTesting: Int {
        Int(round(inactiveOpacitySlider.doubleValue * 100))
    }

    func apply(panes: AppConfig.Panes) {
        self.panes = panes
        guard isViewLoaded else { return }
        isApplyingPanes = true
        showLabelsSwitch.state = panes.showLabels ? .on : .off
        inactiveOpacitySlider.doubleValue = Double(panes.inactiveOpacity)
        updateInactiveOpacityLabel(panes.inactiveOpacity)
        isApplyingPanes = false
    }

    private func makeDisplayCard() -> NSView {
        let card = SettingsCardView()
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)

        let labelsRow = makeSwitchRow(
            title: "Show pane labels",
            subtitle: "Show the compact path label at the top left of each pane.",
            toggle: showLabelsSwitch,
            action: #selector(handleShowLabelsChanged(_:))
        )
        contentStack.addArrangedSubview(labelsRow)
        labelsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let inactiveOpacityRow = makeInactiveOpacityRow()
        contentStack.addArrangedSubview(inactiveOpacityRow)
        inactiveOpacityRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
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
        container.addSubview(leftStack)

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
        subtitleLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        toggle.target = self
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggle)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 16),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16),
        ])

        return container
    }

    private func makeInactiveOpacityRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stackView)

        let titleLabel = makeLabel(
            text: "Non-focused pane opacity",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        stackView.addArrangedSubview(titleLabel)

        let subtitleLabel = makeLabel(
            text: "Controls how strongly panes dim when they are not focused.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 12
        sliderRow.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sliderRow)
        sliderRow.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        inactiveOpacitySlider.translatesAutoresizingMaskIntoConstraints = false
        sliderRow.addArrangedSubview(inactiveOpacitySlider)

        inactiveOpacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        inactiveOpacityValueLabel.alignment = .right
        inactiveOpacityValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        inactiveOpacityValueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        sliderRow.addArrangedSubview(inactiveOpacityValueLabel)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        return container
    }

    private func configureInactiveOpacitySlider() {
        inactiveOpacitySlider.minValue = Double(AppConfig.Panes.minimumInactiveOpacity)
        inactiveOpacitySlider.maxValue = Double(AppConfig.Panes.maximumInactiveOpacity)
        inactiveOpacitySlider.isContinuous = true
        inactiveOpacitySlider.target = self
        inactiveOpacitySlider.action = #selector(handleInactiveOpacityChanged(_:))
    }

    private func updateInactiveOpacityLabel(_ opacity: CGFloat) {
        inactiveOpacityValueLabel.stringValue = "\(Int(round(opacity * 100)))%"
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    @objc
    private func handleShowLabelsChanged(_ sender: NSSwitch) {
        guard !isApplyingPanes else { return }
        try? configStore.update {
            $0.panes.showLabels = sender.state == .on
        }
    }

    @objc
    private func handleInactiveOpacityChanged(_ sender: NSSlider) {
        let opacity = CGFloat(sender.doubleValue)
        updateInactiveOpacityLabel(opacity)
        guard !isApplyingPanes else { return }
        try? configStore.update {
            $0.panes.inactiveOpacity = opacity
        }
    }
}

@MainActor
final class OpenWithSettingsSectionViewController: SettingsScrollableSectionViewController {
    private struct VisibleTarget {
        let stableID: String
        let title: String
        let removeAction: Selector?
        let tooltip: String?
    }

    private let configStore: AppConfigStore
    private let openWithService: OpenWithServing
    private let customAppPicker: () -> OpenWithCustomApp?
    private let rootStackView = NSStackView()
    private var subtitleLabel: NSTextField?
    private var defaultAppCard: SettingsCardView?
    private var availableCard: SettingsCardView?
    private var availableHeaderRow: NSStackView?
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
        panel.allowedContentTypes = [.applicationBundle]

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

    override func assembleContent(in contentView: NSView) {
        rootStackView.orientation = .vertical
        rootStackView.alignment = .leading
        rootStackView.spacing = 16
        rootStackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStackView)

        let subtitleLabel = makeLabel(
            text: "Choose which editors and file managers appear in the launcher, and set the default app.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        self.subtitleLabel = subtitleLabel
        rootStackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        // Card 1: Default App
        let defaultAppCard = SettingsCardView()
        self.defaultAppCard = defaultAppCard
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
        rootStackView.addArrangedSubview(defaultAppCard)
        defaultAppCard.widthAnchor.constraint(equalTo: rootStackView.widthAnchor).isActive = true

        // Card 2: Available Apps
        let availableCard = SettingsCardView()
        self.availableCard = availableCard
        let availableStack = NSStackView()
        availableStack.orientation = .vertical
        availableStack.alignment = .leading
        availableStack.spacing = 12
        availableStack.translatesAutoresizingMaskIntoConstraints = false

        let availableHeaderRow = NSStackView()
        availableHeaderRow.orientation = .horizontal
        availableHeaderRow.alignment = .centerY
        availableHeaderRow.spacing = 12
        self.availableHeaderRow = availableHeaderRow
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

        NSLayoutConstraint.activate([
            rootStackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    override func prepareInitialContent() {
        renderCurrentState()
    }

    override func measuredContentHeight() -> CGFloat {
        let subtitleHeight = subtitleLabel?.fittingSize.height ?? 0
        let defaultCardHeight = defaultAppCard?.fittingSize.height ?? 0
        let availableHeaderHeight = availableHeaderRow?.fittingSize.height ?? 0
        let rowHeights = availableTargetsStackView.arrangedSubviews.reduce(CGFloat.zero) { partial, row in
            partial + row.fittingSize.height
        }
        let rowSpacing = availableTargetsStackView.spacing * CGFloat(max(availableTargetsStackView.arrangedSubviews.count - 1, 0))
        let availableRowsHeight = rowHeights + rowSpacing
        let availableCardHeight = availableCard.map { _ in
            16 + availableHeaderHeight + 12 + availableRowsHeight + 16
        } ?? 0

        return subtitleHeight + 16 + defaultCardHeight + 16 + availableCardHeight
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

    override func prepareForPresentation() {
        let sanitizedPreferences = sanitizedPreferencesForPresentation(currentPreferences)
        if sanitizedPreferences != configStore.current.openWith {
            try? configStore.update { config in
                config.openWith = sanitizedPreferences
            }
            apply(preferences: configStore.current.openWith)
        } else {
            apply(preferences: currentPreferences)
        }
        super.prepareForPresentation()
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
        refreshScrollableContentLayout()
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
final class SettingsCardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        updateColors()
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.shadowColor = isDarkMode ? nil : NSColor.black.withAlphaComponent(0.04).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        layer?.shadowRadius = 2
    }

    private var fillColor: NSColor {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            return NSColor.white.withAlphaComponent(0.04)
        }
        return NSColor.white.withAlphaComponent(0.72)
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
