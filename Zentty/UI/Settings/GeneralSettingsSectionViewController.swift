import AppKit
import os

/// Logs best-effort config-write failures from the settings UI. These persist
/// paths must log and continue rather than crash (see AGENTS.md error handling).
private let settingsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Settings")

@MainActor
final class GeneralSettingsSectionViewController: SettingsScrollableSectionViewController {
    private let configStore: AppConfigStore
    private var currentConfirmations: AppConfig.Confirmations = .default
    private var currentRestore: AppConfig.Restore = .default
    private var currentClipboard: AppConfig.Clipboard = .default

    private let closePaneSwitch = NSSwitch()
    private let closeWindowSwitch = NSSwitch()
    private let quitSwitch = NSSwitch()
    private let restoreWorkspaceSwitch = NSSwitch()
    private let alwaysCleanCopiesSwitch = NSSwitch()
    private let flattenMultiLineCommandsSwitch = NSSwitch()
    private let commandFlattenAggressivenessPopup = NSPopUpButton()
    private let commandFlattenAggressivenessSubtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.textColor = .secondaryLabelColor
        return label
    }()
    private let preserveBlankLinesWhenFlatteningSwitch = NSSwitch()
    private let removeBoxDrawingSwitch = NSSwitch()
    private let flattenSlashCommandSelectionsSwitch = NSSwitch()
    private let stripURLTrackingParametersSwitch = NSSwitch()
    private let quotePathsWithSpacesSwitch = NSSwitch()
    private let showCopyMarkdownCommandSwitch = NSSwitch()

    init(configStore: AppConfigStore) {
        self.configStore = configStore
        self.currentConfirmations = configStore.current.confirmations
        self.currentRestore = configStore.current.restore
        self.currentClipboard = configStore.current.clipboard
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

        let confirmSeparator3 = NSBox()
        confirmSeparator3.boxType = .separator
        confirmSeparator3.translatesAutoresizingMaskIntoConstraints = false
        confirmStack.addArrangedSubview(confirmSeparator3)
        confirmSeparator3.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        let restoreRow = makeSwitchRow(
            title: "Restore worklanes on next launch",
            subtitle: "Reopen windows, pane layout, and saved working directories after quitting.",
            toggle: restoreWorkspaceSwitch,
            action: #selector(handleRestoreWorkspaceSwitchChanged(_:))
        )
        confirmStack.addArrangedSubview(restoreRow)
        restoreRow.widthAnchor.constraint(equalTo: confirmStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            confirmStack.topAnchor.constraint(equalTo: confirmCard.topAnchor),
            confirmStack.leadingAnchor.constraint(equalTo: confirmCard.leadingAnchor),
            confirmStack.trailingAnchor.constraint(equalTo: confirmCard.trailingAnchor),
            confirmStack.bottomAnchor.constraint(equalTo: confirmCard.bottomAnchor),
        ])

        stackView.addArrangedSubview(confirmCard)
        confirmCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        // Clipboard card
        let clipboardCard = SettingsCardView()
        let clipboardStack = NSStackView()
        clipboardStack.orientation = .vertical
        clipboardStack.alignment = .leading
        clipboardStack.spacing = 0
        clipboardStack.translatesAutoresizingMaskIntoConstraints = false
        clipboardCard.addSubview(clipboardStack)

        let cleanCopyRow = makeSwitchRow(
            title: "Always clean copied content",
            subtitle:
                "When you copy from the terminal, run the clean-copy pipeline automatically (whitespace, prompts, URLs, and more).",
            toggle: alwaysCleanCopiesSwitch,
            action: #selector(handleAlwaysCleanCopiesSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(cleanCopyRow)
        cleanCopyRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let flattenRow = makeSwitchRow(
            title: "Flatten multi-line commands",
            subtitle: "Join wrapped shell commands and continuations into a single line when you clean copy.",
            toggle: flattenMultiLineCommandsSwitch,
            action: #selector(handleFlattenMultiLineCommandsSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(flattenRow)
        flattenRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let aggressivenessRow = makeCommandFlattenAggressivenessRow()
        clipboardStack.addArrangedSubview(aggressivenessRow)
        aggressivenessRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let preserveBlanksRow = makeSwitchRow(
            title: "Preserve blank lines when flattening",
            subtitle: "Keep intentional blank lines inside a flattened command block.",
            toggle: preserveBlankLinesWhenFlatteningSwitch,
            action: #selector(handlePreserveBlankLinesWhenFlatteningSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(preserveBlanksRow)
        preserveBlanksRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let boxDrawingRow = makeSwitchRow(
            title: "Remove box-drawing characters",
            subtitle: "Strip terminal table and box-drawing glyphs during cleaning.",
            toggle: removeBoxDrawingSwitch,
            action: #selector(handleRemoveBoxDrawingSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(boxDrawingRow)
        boxDrawingRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let slashRow = makeSwitchRow(
            title: "Flatten slash-command selections",
            subtitle: "Treat agent slash-command decorations like wrapped commands when cleaning.",
            toggle: flattenSlashCommandSelectionsSwitch,
            action: #selector(handleFlattenSlashCommandSelectionsSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(slashRow)
        slashRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let urlRow = makeSwitchRow(
            title: "Strip URL tracking parameters",
            subtitle: "Remove common tracking query parameters from URLs in copied text.",
            toggle: stripURLTrackingParametersSwitch,
            action: #selector(handleStripURLTrackingParametersSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(urlRow)
        urlRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let quotePathsRow = makeSwitchRow(
            title: "Quote paths with spaces",
            subtitle: "Wrap filesystem paths that contain spaces in quotes when cleaning.",
            toggle: quotePathsWithSpacesSwitch,
            action: #selector(handleQuotePathsWithSpacesSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(quotePathsRow)
        quotePathsRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        let markdownMenuRow = makeSwitchRow(
            title: "Show Copy as Markdown command",
            subtitle: "Include Copy as Markdown in the Edit menu for selection-based Markdown reformatting.",
            toggle: showCopyMarkdownCommandSwitch,
            action: #selector(handleShowCopyMarkdownCommandSwitchChanged(_:))
        )
        clipboardStack.addArrangedSubview(markdownMenuRow)
        markdownMenuRow.widthAnchor.constraint(equalTo: clipboardStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            clipboardStack.topAnchor.constraint(equalTo: clipboardCard.topAnchor),
            clipboardStack.leadingAnchor.constraint(equalTo: clipboardCard.leadingAnchor),
            clipboardStack.trailingAnchor.constraint(equalTo: clipboardCard.trailingAnchor),
            clipboardStack.bottomAnchor.constraint(equalTo: clipboardCard.bottomAnchor),
        ])

        stackView.addArrangedSubview(clipboardCard)
        clipboardCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

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
        restoreWorkspaceSwitch.state = currentRestore.restoreWorkspaceOnLaunch ? .on : .off
        syncClipboardControlsFromConfig(currentClipboard)
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    func apply(confirmations: AppConfig.Confirmations) {
        currentConfirmations = confirmations
        guard isViewLoaded else { return }
        closePaneSwitch.state = confirmations.confirmBeforeClosingPane ? .on : .off
        closeWindowSwitch.state = confirmations.confirmBeforeClosingWindow ? .on : .off
        quitSwitch.state = confirmations.confirmBeforeQuitting ? .on : .off
    }

    func apply(restore: AppConfig.Restore) {
        currentRestore = restore
        guard isViewLoaded else { return }
        restoreWorkspaceSwitch.state = restore.restoreWorkspaceOnLaunch ? .on : .off
    }

    func apply(clipboard: AppConfig.Clipboard) {
        currentClipboard = clipboard
        guard isViewLoaded else { return }
        syncClipboardControlsFromConfig(clipboard)
        applyClipboardAndPipelineSideEffects(clipboard)
    }

    // MARK: - Actions

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
    private func handleRestoreWorkspaceSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.restore.restoreWorkspaceOnLaunch = sender.state == .on
        }
        currentRestore = configStore.current.restore
    }

    @objc
    private func handleAlwaysCleanCopiesSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.alwaysCleanCopies = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleFlattenMultiLineCommandsSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.flattenMultiLineCommands = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleCommandFlattenAggressivenessChanged(_ sender: NSPopUpButton) {
        guard let level = sender.selectedItem?.representedObject as? CommandFlattenAggressiveness else {
            return
        }
        try? configStore.update { config in
            config.clipboard.commandFlattenAggressiveness = level
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handlePreserveBlankLinesWhenFlatteningSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.preserveBlankLinesWhenFlattening = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleRemoveBoxDrawingSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.removeBoxDrawing = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleFlattenSlashCommandSelectionsSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.flattenSlashCommandSelections = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleStripURLTrackingParametersSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.stripURLTrackingParameters = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleQuotePathsWithSpacesSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.quotePathsWithSpaces = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    @objc
    private func handleShowCopyMarkdownCommandSwitchChanged(_ sender: NSSwitch) {
        try? configStore.update { config in
            config.clipboard.showCopyMarkdownCommand = sender.state == .on
        }
        currentClipboard = configStore.current.clipboard
        applyClipboardAndPipelineSideEffects(currentClipboard)
    }

    private func syncClipboardControlsFromConfig(_ clipboard: AppConfig.Clipboard) {
        alwaysCleanCopiesSwitch.state = clipboard.alwaysCleanCopies ? .on : .off
        flattenMultiLineCommandsSwitch.state = clipboard.flattenMultiLineCommands ? .on : .off
        preserveBlankLinesWhenFlatteningSwitch.state = clipboard.preserveBlankLinesWhenFlattening ? .on : .off
        removeBoxDrawingSwitch.state = clipboard.removeBoxDrawing ? .on : .off
        flattenSlashCommandSelectionsSwitch.state = clipboard.flattenSlashCommandSelections ? .on : .off
        stripURLTrackingParametersSwitch.state = clipboard.stripURLTrackingParameters ? .on : .off
        quotePathsWithSpacesSwitch.state = clipboard.quotePathsWithSpaces ? .on : .off
        showCopyMarkdownCommandSwitch.state = clipboard.showCopyMarkdownCommand ? .on : .off
        selectCommandFlattenAggressivenessPopupItem(for: clipboard.commandFlattenAggressiveness)
    }

    private func applyClipboardAndPipelineSideEffects(_ clipboard: AppConfig.Clipboard) {
        CleanCopyPipeline.isAutoCleanEnabled = clipboard.alwaysCleanCopies
        CleanCopyPipeline.options = CleanCopyOptions.from(clipboard)
        AppMenuBuilder.installIfNeeded(on: NSApp, config: configStore.current)
    }

    private func makeCommandFlattenAggressivenessRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: "Command flatten aggressiveness",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        leftStack.addArrangedSubview(titleLabel)

        commandFlattenAggressivenessSubtitleLabel.stringValue =
            currentClipboard.commandFlattenAggressiveness.settingsBlurb
        leftStack.addArrangedSubview(commandFlattenAggressivenessSubtitleLabel)

        commandFlattenAggressivenessPopup.removeAllItems()
        for level in CommandFlattenAggressiveness.allCases {
            commandFlattenAggressivenessPopup.addItem(withTitle: level.settingsTitle)
            commandFlattenAggressivenessPopup.lastItem?.representedObject = level
        }
        commandFlattenAggressivenessPopup.target = self
        commandFlattenAggressivenessPopup.action = #selector(handleCommandFlattenAggressivenessChanged(_:))
        commandFlattenAggressivenessPopup.setContentHuggingPriority(.required, for: .horizontal)

        container.addSubview(leftStack)
        container.addSubview(commandFlattenAggressivenessPopup)
        commandFlattenAggressivenessPopup.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            commandFlattenAggressivenessPopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            commandFlattenAggressivenessPopup.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            commandFlattenAggressivenessPopup.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    private func selectCommandFlattenAggressivenessPopupItem(for level: CommandFlattenAggressiveness) {
        for index in 0 ..< commandFlattenAggressivenessPopup.numberOfItems {
            if commandFlattenAggressivenessPopup.item(at: index)?.representedObject as? CommandFlattenAggressiveness
                == level
            {
                commandFlattenAggressivenessPopup.selectItem(at: index)
                break
            }
        }
        commandFlattenAggressivenessSubtitleLabel.stringValue = level.settingsBlurb
    }
    // MARK: - Helpers

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
            toggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
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

    var isClosePaneSwitchOn: Bool {
        closePaneSwitch.state == .on
    }

    var isQuitSwitchOn: Bool {
        quitSwitch.state == .on
    }

    var isRestoreWorkspaceSwitchOn: Bool {
        restoreWorkspaceSwitch.state == .on
    }

    func setRestoreWorkspaceEnabledForTesting(_ enabled: Bool) {
        restoreWorkspaceSwitch.state = enabled ? .on : .off
        handleRestoreWorkspaceSwitchChanged(restoreWorkspaceSwitch)
    }
}

@MainActor
final class AgentsSettingsSectionViewController: SettingsScrollableSectionViewController {
    private let configStore: AppConfigStore
    private let agentTeamsEnableWarningPresenter: AgentTeamsEnableWarningPresenter
    private var currentAgentTeams: AppConfig.AgentTeams
    private var currentAgentCaffeination: AppConfig.AgentCaffeination
    private var currentMenuBar: AppConfig.MenuBar

    private let menuBarStatusSwitch = NSSwitch()
    private let agentTeamsSwitch = NSSwitch()
    private let agentCaffeinationSwitch = NSSwitch()
    private let experimentalBadgeLabel = NSTextField(labelWithString: "EXPERIMENTAL")
    private weak var agentTeamsTitleLabel: NSTextField?

    /// Live controls for one agent-integration row, so toggles and status can
    /// be refreshed when config changes (or a toggle is reverted).
    private struct IntegrationRow {
        let tool: AgentBootstrapTool
        let toggle: NSSwitch
        let statusGlyph: HoverImageView
        let askLabel: NSTextField
    }

    private var integrationRows: [IntegrationRow] = []
    private var toolForToggle: [NSSwitch: AgentBootstrapTool] = [:]
    /// One reused caret tooltip shown when hovering a status glyph.
    private let statusTooltip = CaretTooltip()
    /// Presents the consent panel; injectable for tests. Mirrors the launch-time
    /// consent panel so enabling here is gated by the same prompt.
    private let consentPresenter: @MainActor (AgentBootstrapTool, @escaping (AgentIntegrationState) -> Void) -> Void
    /// Removes a persistent agent's on-disk hooks; injectable so tests can force a
    /// failure without touching disk. Defaults to the real remover.
    private let performUninstall: (AgentBootstrapTool) throws -> Void
    /// Surfaces an uninstall failure (default: a warning NSAlert); injectable for
    /// tests. Receives the host window (nil in headless tests), the tool, and the error.
    private let uninstallFailurePresenter: @MainActor (NSWindow?, AgentBootstrapTool, Error) -> Void

    init(
        configStore: AppConfigStore,
        agentTeamsEnableWarningPresenter: @escaping AgentTeamsEnableWarningPresenter =
            AgentTeamsEnableWarning.present,
        consentPresenter: @escaping @MainActor (AgentBootstrapTool, @escaping (AgentIntegrationState) -> Void) -> Void =
            AgentIntegrationConsentPanel.present,
        performUninstall: @escaping (AgentBootstrapTool) throws -> Void = AgentIntegrationHooks.uninstall,
        uninstallFailurePresenter: @escaping @MainActor (NSWindow?, AgentBootstrapTool, Error) -> Void =
            AgentIntegrationUninstallFailureAlert.present
    ) {
        self.configStore = configStore
        self.agentTeamsEnableWarningPresenter = agentTeamsEnableWarningPresenter
        self.consentPresenter = consentPresenter
        self.performUninstall = performUninstall
        self.uninstallFailurePresenter = uninstallFailurePresenter
        self.currentAgentTeams = configStore.current.agentTeams
        self.currentAgentCaffeination = configStore.current.agentCaffeination
        self.currentMenuBar = configStore.current.menuBar
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

        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let menuBarStatusRow = makeMenuBarStatusRow()
        cardStack.addArrangedSubview(menuBarStatusRow)
        menuBarStatusRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        addSeparator(to: cardStack)

        let agentTeamsRow = makeAgentTeamsRow()
        cardStack.addArrangedSubview(agentTeamsRow)
        agentTeamsRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        addSeparator(to: cardStack)

        let agentCaffeinationRow = makeAgentCaffeinationRow()
        cardStack.addArrangedSubview(agentCaffeinationRow)
        agentCaffeinationRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        stackView.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let integrationsHeader = makeIntegrationsSectionHeader()
        stackView.addArrangedSubview(integrationsHeader)
        integrationsHeader.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let integrationsCard = makeIntegrationsCard()
        stackView.addArrangedSubview(integrationsCard)
        integrationsCard.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        menuBarStatusSwitch.state = currentMenuBar.showStatusItem ? .on : .off
        agentTeamsSwitch.state = currentAgentTeams.enabled ? .on : .off
        agentCaffeinationSwitch.state = currentAgentCaffeination.enabled ? .on : .off
        refreshIntegrationControls()

        // Re-check on-disk hook status when a pane launch (re)installs hooks while
        // this panel is already open, so a stale "Hooks missing" warning clears
        // live. The post is delivered on the main thread (see AgentIPC), so a plain
        // selector observer is safe; `removeObserver(self)` in deinit cleans it up.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHooksDidChange),
            name: .agentIntegrationHooksDidChange,
            object: nil
        )

        // Dismiss the status tooltip on scroll so it never floats away from its glyph
        // (a trackpad scroll while hovering won't fire mouseExited).
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideStatusTooltip),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        statusTooltip.hide()
    }

    @objc
    private func hideStatusTooltip() {
        statusTooltip.hide()
    }

    @objc
    private func handleHooksDidChange() {
        refreshIntegrationControls()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-check on-disk hook status each time the panel is presented (reopened or
    /// switched back to), so the green/amber glyph reflects hooks installed by an
    /// agent launch since the last time this section was shown.
    override func prepareForPresentation() {
        super.prepareForPresentation()
        refreshIntegrationControls()
    }

    func apply(
        agentTeams: AppConfig.AgentTeams,
        agentCaffeination: AppConfig.AgentCaffeination,
        menuBar: AppConfig.MenuBar
    ) {
        currentAgentTeams = agentTeams
        currentAgentCaffeination = agentCaffeination
        currentMenuBar = menuBar
        guard isViewLoaded else { return }
        menuBarStatusSwitch.state = menuBar.showStatusItem ? .on : .off
        agentTeamsSwitch.state = agentTeams.enabled ? .on : .off
        agentCaffeinationSwitch.state = agentCaffeination.enabled ? .on : .off
        refreshIntegrationControls()
    }

    private func makeMenuBarStatusRow() -> NSView {
        let row = makeAgentSwitchRow(
            title: "Show agent status in menu bar",
            subtitle: "Display a Zentty menu bar icon with live waiting, running, and idle agent panes.",
            toggle: menuBarStatusSwitch,
            action: #selector(handleMenuBarStatusSwitchChanged(_:))
        )
        return row
    }

    private func makeAgentTeamsRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 4
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(
            text: "Claude Code agent teams",
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        agentTeamsTitleLabel = titleLabel
        configureExperimentalBadge()
        experimentalBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        titleRow.addSubview(titleLabel)
        titleRow.addSubview(experimentalBadgeLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),

            experimentalBadgeLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            experimentalBadgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor, constant: 1),
            experimentalBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleRow.trailingAnchor),
        ])
        leftStack.addArrangedSubview(titleRow)

        let subtitleLabel = makeLabel(
            text:
                "Render Claude Code's subagents as native Zentty panes when team mode is enabled.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(subtitleLabel)

        agentTeamsSwitch.target = self
        agentTeamsSwitch.action = #selector(handleAgentTeamsSwitchChanged(_:))

        container.addSubview(leftStack)
        container.addSubview(agentTeamsSwitch)
        agentTeamsSwitch.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            agentTeamsSwitch.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            agentTeamsSwitch.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor,
                constant: 12
            ),
            agentTeamsSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    private func makeAgentCaffeinationRow() -> NSView {
        makeAgentSwitchRow(
            title: "Prevent sleep while agents run",
            subtitle: "Keep the Mac awake while an agent pane is running. The display can still sleep.",
            toggle: agentCaffeinationSwitch,
            action: #selector(handleAgentCaffeinationSwitchChanged(_:))
        )
    }

    private func makeAgentSwitchRow(
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
        leftStack.spacing = 4
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
            toggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor,
                constant: 12
            ),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        return container
    }

    @discardableResult
    private func addSeparator(to stack: NSStackView) -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        // Add to the stack before activating the width constraint: the anchor
        // pair needs a common ancestor at activation time, otherwise AppKit
        // throws and aborts assembleContent (leaving the pane blank).
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return separator
    }

    private func configureExperimentalBadge() {
        experimentalBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        experimentalBadgeLabel.textColor = .secondaryLabelColor
        experimentalBadgeLabel.alignment = .center
        experimentalBadgeLabel.wantsLayer = true
        experimentalBadgeLabel.layer?.cornerRadius = 5
        experimentalBadgeLabel.layer?.cornerCurve = .continuous
        experimentalBadgeLabel.layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.16)
            .cgColor
        experimentalBadgeLabel.layer?.borderColor = NSColor.systemOrange
            .withAlphaComponent(0.35)
            .cgColor
        experimentalBadgeLabel.layer?.borderWidth = 1
        experimentalBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        experimentalBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        experimentalBadgeLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    @objc
    private func handleMenuBarStatusSwitchChanged(_ sender: NSSwitch) {
        do {
            try configStore.update { config in
                config.menuBar.showStatusItem = sender.state == .on
            }
        } catch {
            settingsLogger.error(
                "Failed to persist menu-bar status-item visibility: \(error.localizedDescription, privacy: .public)")
        }
        currentMenuBar = configStore.current.menuBar
        menuBarStatusSwitch.state = currentMenuBar.showStatusItem ? .on : .off
    }

    @objc
    private func handleAgentTeamsSwitchChanged(_ sender: NSSwitch) {
        requestAgentTeamsChange(to: sender.state == .on)
    }

    @objc
    private func handleAgentCaffeinationSwitchChanged(_ sender: NSSwitch) {
        persistAgentCaffeinationEnabled(sender.state == .on)
    }

    private func requestAgentTeamsChange(to requestedValue: Bool) {
        guard requestedValue != currentAgentTeams.enabled else {
            agentTeamsSwitch.state = currentAgentTeams.enabled ? .on : .off
            return
        }

        if requestedValue == false {
            persistAgentTeamsEnabled(false)
            return
        }

        guard let window = view.window else {
            agentTeamsSwitch.state = currentAgentTeams.enabled ? .on : .off
            return
        }

        agentTeamsSwitch.state = .off
        agentTeamsEnableWarningPresenter(window) { [weak self] decision in
            guard let self else { return }
            if decision == .enable {
                self.persistAgentTeamsEnabled(true)
            } else {
                self.agentTeamsSwitch.state = self.currentAgentTeams.enabled ? .on : .off
            }
        }
    }

    private func persistAgentTeamsEnabled(_ enabled: Bool) {
        do {
            try configStore.update { config in
                config.agentTeams.enabled = enabled
            }
        } catch {
            settingsLogger.error(
                "Failed to persist agent-teams enabled state: \(error.localizedDescription, privacy: .public)")
        }
        currentAgentTeams = configStore.current.agentTeams
        agentTeamsSwitch.state = currentAgentTeams.enabled ? .on : .off
    }

    private func persistAgentCaffeinationEnabled(_ enabled: Bool) {
        do {
            try configStore.update { config in
                config.agentCaffeination.enabled = enabled
            }
        } catch {
            settingsLogger.error(
                "Failed to persist agent-caffeination enabled state: \(error.localizedDescription, privacy: .public)")
        }
        currentAgentCaffeination = configStore.current.agentCaffeination
        agentCaffeinationSwitch.state = currentAgentCaffeination.enabled ? .on : .off
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    // MARK: - Agent integrations

    private func makeIntegrationsSectionHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = makeLabel(text: "Agent integrations", font: .systemFont(ofSize: 13, weight: .semibold))
        let subtitle = makeLabel(
            text: "Enable or disable each agent's Zentty integration. Agents that modify your "
                + "configuration ask before installing hooks; turn any integration off if it misbehaves.",
            font: .systemFont(ofSize: 12)
        )
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        return stack
    }

    private func makeIntegrationsCard() -> NSView {
        integrationRows = []
        toolForToggle = [:]

        let card = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        func appendRow(_ view: NSView, separatorBefore: Bool) {
            if separatorBefore {
                addSeparator(to: cardStack)
            }
            cardStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        }

        // Display order is a view concern: sort each group alphabetically by name
        // so the list stays scannable regardless of the registry's array order.
        func sortedByName(_ tools: [AgentBootstrapTool]) -> [AgentBootstrapTool] {
            tools.sorted {
                $0.integrationDisplayName.localizedCaseInsensitiveCompare($1.integrationDisplayName)
                    == .orderedAscending
            }
        }

        appendRow(makeIntegrationGroupHeader("MODIFIES YOUR CONFIG"), separatorBefore: false)
        for tool in sortedByName(AgentIntegrationConsent.persistentTools) {
            appendRow(makeIntegrationRow(tool: tool), separatorBefore: true)
        }

        appendRow(makeIntegrationGroupHeader("AUTOMATIC"), separatorBefore: true)
        for tool in sortedByName(AgentIntegrationConsent.ephemeralTools) {
            appendRow(makeIntegrationRow(tool: tool), separatorBefore: true)
        }

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func makeIntegrationGroupHeader(_ title: String) -> NSView {
        let container = NSView()
        let label = makeLabel(text: title, font: .systemFont(ofSize: 11, weight: .semibold))
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        // Symmetric band so the uppercase label sits vertically centered, not pinned
        // to the top. The fixed height keeps the band's overall footprint stable.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 34),
        ])
        return container
    }

    private func makeIntegrationRow(tool: AgentBootstrapTool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = MenuBarStatusIconRenderer.agentIconTemplateImage(for: tool.agentTool)
        icon.image?.isTemplate = true
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let nameLabel = makeLabel(text: tool.integrationDisplayName, font: .systemFont(ofSize: 13, weight: .semibold))
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Trailing status: a quiet glyph (installed / needs-reinstall) or, for the
        // first-launch consent state, a compact amber label. Detail lives in the
        // glyph's hover tooltip so the row stays a single scannable line. Built-in
        // agents show neither — their toggle says everything.
        let statusGlyph = HoverImageView()
        statusGlyph.translatesAutoresizingMaskIntoConstraints = false
        statusGlyph.imageScaling = .scaleProportionallyUpOrDown
        statusGlyph.setContentHuggingPriority(.required, for: .horizontal)
        statusGlyph.onEnter = { [weak self] glyph in
            guard let self, let window = self.view.window, let text = glyph.tooltipText else { return }
            self.statusTooltip.show(text: text, relativeTo: glyph, in: window)
        }
        statusGlyph.onExit = { [weak self] in
            self?.statusTooltip.hide()
        }
        NSLayoutConstraint.activate([
            statusGlyph.widthAnchor.constraint(equalToConstant: 15),
            statusGlyph.heightAnchor.constraint(equalToConstant: 15),
        ])

        let askLabel = makeLabel(text: "Asks on first launch", font: .systemFont(ofSize: 11, weight: .medium))
        askLabel.maximumNumberOfLines = 1
        askLabel.textColor = .systemOrange
        askLabel.setContentHuggingPriority(.required, for: .horizontal)

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(handleIntegrationToggle(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toolForToggle[toggle] = tool

        let leftStack = NSStackView(views: [icon, nameLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 10
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = NSStackView(views: [askLabel, statusGlyph])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 6
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.setContentHuggingPriority(.required, for: .horizontal)
        statusStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        container.addSubview(leftStack)
        container.addSubview(statusStack)
        container.addSubview(toggle)
        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),

            statusStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),

            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggle.leadingAnchor.constraint(equalTo: statusStack.trailingAnchor, constant: 12),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        integrationRows.append(
            IntegrationRow(tool: tool, toggle: toggle, statusGlyph: statusGlyph, askLabel: askLabel)
        )
        return container
    }

    private func friendlyPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    func refreshIntegrationControls() {
        guard isViewLoaded else { return }
        let integrations = configStore.current.agentIntegrations
        for row in integrationRows {
            let state = integrations.state(for: row.tool)
            row.toggle.state = (state == .on) ? .on : .off
            applyStatusIndicator(statusIndicator(for: state, tool: row.tool), to: row)
        }
    }

    private func applyStatusIndicator(_ indicator: IntegrationStatusIndicator, to row: IntegrationRow) {
        switch indicator {
        case let .glyph(symbol, color, tooltip):
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            row.statusGlyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(config)
            row.statusGlyph.contentTintColor = color
            row.statusGlyph.tooltipText = tooltip
            row.statusGlyph.setAccessibilityLabel(tooltip)
            row.statusGlyph.isHidden = false
            row.askLabel.isHidden = true
        case let .ask(text):
            row.askLabel.stringValue = text
            row.askLabel.isHidden = false
            row.statusGlyph.isHidden = true
            row.statusGlyph.image = nil
            row.statusGlyph.tooltipText = nil
        case .none:
            row.statusGlyph.isHidden = true
            row.statusGlyph.image = nil
            row.statusGlyph.tooltipText = nil
            row.askLabel.isHidden = true
        }
    }

    private enum IntegrationStatusIndicator {
        case glyph(symbol: String, color: NSColor, tooltip: String)
        case ask(text: String)
        case none
    }

    /// Resolves a row's trailing treatment. Persistent agents that wrote hooks to
    /// disk show a green check; an `.on` agent whose hooks vanished (a manual edit
    /// of the agent's config) shows an amber warning so it doesn't read as pristine.
    /// The `.ask` first-launch state keeps a visible amber label. Built-in agents
    /// rely on the toggle alone.
    private func statusIndicator(
        for state: AgentIntegrationState,
        tool: AgentBootstrapTool
    ) -> IntegrationStatusIndicator {
        guard tool.integrationClass == .persistent else { return .none }
        switch state {
        case .ask:
            return .ask(text: "Asks on first launch")
        case .off:
            return .none
        case .on:
            if AgentIntegrationHooks.isInstalled(tool) {
                let location = tool.integrationConfigURL.map { " in \(friendlyPath($0))" } ?? ""
                return .glyph(
                    symbol: "checkmark.circle.fill",
                    color: .systemGreen,
                    tooltip: "Hooks installed\(location). Zentty added these — turn the integration off to remove them."
                )
            }
            return .glyph(
                symbol: "exclamationmark.triangle.fill",
                color: .systemOrange,
                tooltip: "Hooks missing — Zentty reinstalls them on next launch."
            )
        }
    }

    @objc
    private func handleIntegrationToggle(_ sender: NSSwitch) {
        guard let tool = toolForToggle[sender] else { return }
        let wantsOn = sender.state == .on

        if tool.integrationClass == .ephemeral {
            setIntegrationState(tool, wantsOn ? .on : .off)
            return
        }

        if wantsOn {
            // Any disk write is gated by the same consent panel as first launch;
            // only persist On if the user confirms, otherwise revert the switch.
            consentPresenter(tool) { [weak self] decision in
                guard let self else { return }
                if decision == .on {
                    self.setIntegrationState(tool, .on)
                } else {
                    self.refreshIntegrationControls()
                }
            }
        } else {
            // Turning off removes our hooks from disk (parity with `zentty
            // uninstall`), then records the choice. The state is recorded as off
            // regardless of the disk outcome — but if removal fails we log and
            // warn the user, so stale hooks don't keep reporting status silently.
            do {
                try performUninstall(tool)
            } catch {
                settingsLogger.error(
                    "Failed to uninstall \(tool.rawValue, privacy: .public) hooks: \(error.localizedDescription, privacy: .public)")
                uninstallFailurePresenter(view.window, tool, error)
            }
            setIntegrationState(tool, .off)
        }
    }

    private func setIntegrationState(_ tool: AgentBootstrapTool, _ state: AgentIntegrationState) {
        do {
            try configStore.update { config in
                config.agentIntegrations.states[tool.rawValue] = state
            }
        } catch {
            settingsLogger.error(
                "Failed to persist \(tool.rawValue, privacy: .public) integration state: \(error.localizedDescription, privacy: .public)")
        }
        refreshIntegrationControls()
    }

    var isAgentTeamsSwitchOn: Bool {
        agentTeamsSwitch.state == .on
    }

    var isMenuBarStatusSwitchOn: Bool {
        menuBarStatusSwitch.state == .on
    }

    var isAgentCaffeinationSwitchOn: Bool {
        agentCaffeinationSwitch.state == .on
    }

    var experimentalBadgeText: String {
        experimentalBadgeLabel.stringValue
    }

    var experimentalBadgeTitleCenterYOffset: CGFloat? {
        guard let titleLabel = agentTeamsTitleLabel else { return nil }
        return titleLabel.frame.midY - experimentalBadgeLabel.frame.midY
    }

    func setAgentTeamsEnabledForTesting(_ enabled: Bool) {
        agentTeamsSwitch.state = enabled ? .on : .off
        requestAgentTeamsChange(to: enabled)
    }

    func setMenuBarStatusEnabledForTesting(_ enabled: Bool) {
        menuBarStatusSwitch.state = enabled ? .on : .off
        handleMenuBarStatusSwitchChanged(menuBarStatusSwitch)
    }

    func setAgentCaffeinationEnabledForTesting(_ enabled: Bool) {
        agentCaffeinationSwitch.state = enabled ? .on : .off
        persistAgentCaffeinationEnabled(enabled)
    }

    /// Drives an integration row's toggle and runs the same handler the real
    /// switch would, so tests can exercise enable/disable + consent/uninstall.
    func simulateIntegrationToggleForTesting(_ tool: AgentBootstrapTool, on: Bool) {
        guard let row = integrationRows.first(where: { $0.tool == tool }) else { return }
        row.toggle.state = on ? .on : .off
        handleIntegrationToggle(row.toggle)
    }

    /// Snapshot of a row's trailing status treatment, for tests.
    func integrationStatusForTesting(
        _ tool: AgentBootstrapTool
    ) -> (glyphVisible: Bool, askVisible: Bool, tooltipText: String?)? {
        guard let row = integrationRows.first(where: { $0.tool == tool }) else { return nil }
        return (!row.statusGlyph.isHidden, !row.askLabel.isHidden, row.statusGlyph.tooltipText)
    }

    /// Vertical offset of a group header's label from its band centre, for tests.
    /// ~0 means the uppercase title is vertically centered in its band.
    func groupHeaderCenterYOffsetForTesting(title: String) -> CGFloat? {
        guard isViewLoaded,
              let label = firstLabel(in: view, withString: title),
              let container = label.superview
        else { return nil }
        return label.frame.midY - container.bounds.midY
    }

    private func firstLabel(in view: NSView, withString string: String) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.stringValue == string {
                return field
            }
            if let found = firstLabel(in: subview, withString: string) {
                return found
            }
        }
        return nil
    }
}
