import AppKit
import os

private let agentHistorySettingsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Settings")

/// Settings › Agent History (spec §4.7): Status, Sources, Privacy, Agent access, Maintenance.
/// The index lives behind `backend` (the history controller); excluded folders and agent
/// access live in `config.toml`; Claude Code's retention is read and raised off main through
/// `retention`. Every sheet goes through an injected presenter, so tests drive it all.
@MainActor
final class AgentHistorySettingsSectionViewController: SettingsScrollableSectionViewController {
    static let unavailableText = "Agent History isn't available in this window."

    private let configStore: AppConfigStore
    private let backend: (any AgentHistorySettingsBackend)?
    private let confirmationPresenter: AgentHistoryConfirmationPresenter
    private let folderPicker: AgentHistoryFolderPicker
    private let errorPresenter: AgentHistoryErrorPresenter
    private let retention: AgentHistoryClaudeRetentionLoader
    private let formatter: AgentHistorySettingsFormatter
    private let formatting: AgentHistoryFormatting

    private(set) var status: AgentHistoryStatus
    private var config: AppConfig.AgentHistory
    private var detected: [AgentHistoryDetectedSource] = []
    private var retentionRoots: [String] = []
    private var statusObserverID: UUID?
    private var relativeTimeTimer: Timer?

    let statusSwitch = NSSwitch()
    private let summaryLabel = AgentHistorySettingsRows.secondaryLabel("")
    let progressIndicator = NSProgressIndicator()
    private let activityLabel = AgentHistorySettingsRows.label("")
    private let calloutLabel = AgentHistorySettingsRows.label("", color: AgentHistorySettingsRows.amber)
    private(set) var sourceRows: [AgentHistorySettingsSourceRowView] = []
    private let retentionStack = AgentHistorySettingsRows.verticalStack(spacing: 0)
    private(set) var retentionRows: [AgentHistorySettingsRetentionRow] = []
    private let foldersStack = AgentHistorySettingsRows.verticalStack(spacing: 6)
    private(set) var addFolderButton = NSButton()
    private let removedLabel = AgentHistorySettingsRows.label("")
    private(set) var restoreAllButton = NSButton()
    let agentAccessSwitch = NSSwitch()
    private(set) var rebuildButton = NSButton()
    private(set) var deleteButton = NSButton()
    private let rebuildBlockedLabel = AgentHistorySettingsRows.label("", color: AgentHistorySettingsRows.amber)

    init(
        configStore: AppConfigStore,
        backend: (any AgentHistorySettingsBackend)?,
        confirmationPresenter: @escaping AgentHistoryConfirmationPresenter = AgentHistorySettingsAlerts.presentConfirmation,
        folderPicker: @escaping AgentHistoryFolderPicker = AgentHistorySettingsAlerts.pickFolders,
        errorPresenter: @escaping AgentHistoryErrorPresenter = AgentHistorySettingsAlerts.presentError,
        retentionStatusProvider: @escaping @Sendable (URL) -> ClaudeRetentionStatus = { ClaudeRetentionSettings.status(configDirectory: $0) },
        retentionWriter: @escaping @Sendable (URL) throws -> ClaudeRetentionWriteOutcome = { try ClaudeRetentionSettings.raiseRetention(configDirectory: $0) },
        retentionRunner: AgentHistoryOffMainRunner = .userInitiated,
        locale: Locale = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.configStore = configStore
        self.backend = backend
        self.confirmationPresenter = confirmationPresenter
        self.folderPicker = folderPicker
        self.errorPresenter = errorPresenter
        self.retention = .init(statusProvider: retentionStatusProvider, writer: retentionWriter, runner: retentionRunner)
        self.formatter = AgentHistorySettingsFormatter(locale: locale, now: now)
        self.formatting = AgentHistoryFormatting(locale: locale)
        self.status = backend?.status ?? .off
        self.config = configStore.current.agentHistory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Assembly

    override func assembleContent(in contentView: NSView) {
        AgentHistorySettingsRows.stack([
            makeStatusCard(),
            AgentHistorySettingsRows.sectionHeader(title: "Sources", subtitle: "Turning a source off removes its sessions from the index."),
            makeSourcesCard(),
            AgentHistorySettingsRows.sectionHeader(title: "Privacy", subtitle: nil),
            makePrivacyCard(),
            AgentHistorySettingsRows.sectionHeader(title: "Agent access", subtitle: nil),
            AgentHistorySettingsRows.card(rows: [SettingsFormBuilder.switchRow(
                title: "Allow agents to search all projects",
                subtitle: "Agents can always search sessions from their own project with zentty history search.",
                toggle: agentAccessSwitch, target: self, action: #selector(handleAgentAccessChanged(_:)),
                subtitleWidth: .matchStack
            )]),
            AgentHistorySettingsRows.sectionHeader(title: "Maintenance", subtitle: nil),
            makeMaintenanceCard(),
        ], in: contentView)
    }

    override func prepareInitialContent() {
        renderConfig()
        render()
    }

    private func makeStatusCard() -> NSView {
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        let accessory = AgentHistorySettingsRows.verticalStack(spacing: 6)
        for view in [summaryLabel, progressIndicator, activityLabel, calloutLabel] {
            accessory.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: accessory.widthAnchor).isActive = true
        }
        accessory.setCustomSpacing(4, after: summaryLabel)
        return AgentHistorySettingsRows.card(rows: [SettingsFormBuilder.switchRow(
            title: "Agent History",
            subtitle: "Search your past agent conversations on this Mac.",
            toggle: statusSwitch, target: self, action: #selector(handleStatusSwitchChanged(_:)),
            subtitleWidth: .matchStack, accessory: accessory
        )])
    }

    private func makeSourcesCard() -> NSView {
        sourceRows = AgentHistoryAgent.allCases.map {
            AgentHistorySettingsSourceRowView(agent: $0, target: self, action: #selector(handleSourceSwitchChanged(_:)))
        }
        return AgentHistorySettingsRows.card(rows: sourceRows, trailing: retentionStack)
    }

    private func makePrivacyCard() -> NSView {
        let intro = AgentHistorySettingsRows.secondaryLabel(
            "Zentty removes common API keys and tokens before storing text. This is best effort, so exclude folders that hold secrets."
        )
        let folders = AgentHistorySettingsRows.verticalStack(spacing: 8)
        addFolderButton = AgentHistorySettingsRows.button(AgentHistoryConsentModel.addFolderTitle, target: self, action: #selector(handleAddFolder(_:)))
        for view in [intro, AgentHistorySettingsRows.label("Excluded folders", size: 12, weight: .semibold), foldersStack, addFolderButton] {
            folders.addArrangedSubview(view)
        }
        intro.widthAnchor.constraint(equalTo: folders.widthAnchor).isActive = true
        foldersStack.widthAnchor.constraint(equalTo: folders.widthAnchor).isActive = true
        restoreAllButton = AgentHistorySettingsRows.button("Restore All", target: self, action: #selector(handleRestoreAll(_:)))
        return AgentHistorySettingsRows.card(rows: [
            AgentHistorySettingsRows.paddedRow(folders),
            AgentHistorySettingsRows.paddedRow(AgentHistorySettingsRows.actionRow(text: removedLabel, button: restoreAllButton)),
        ])
    }

    private func makeMaintenanceCard() -> NSView {
        rebuildButton = AgentHistorySettingsRows.button("Rebuild Index", target: self, action: #selector(handleRebuild(_:)))
        deleteButton = AgentHistorySettingsRows.button("Delete Index and Turn Off", target: self, action: #selector(handleDelete(_:)))
        deleteButton.hasDestructiveAction = true
        deleteButton.contentTintColor = .systemRed
        let rebuildText = AgentHistorySettingsRows.verticalStack(spacing: 4)
        let rebuildDescription = AgentHistorySettingsRows.secondaryLabel("Reads every conversation again. Search keeps working while it runs.")
        for label in [rebuildDescription, rebuildBlockedLabel] {
            rebuildText.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: rebuildText.widthAnchor).isActive = true
        }
        let deleteText = AgentHistorySettingsRows.secondaryLabel(
            "Removes the index, the removed-sessions list and usage data from this Mac. Your agents' own transcripts aren't touched."
        )
        return AgentHistorySettingsRows.card(rows: [
            AgentHistorySettingsRows.paddedRow(AgentHistorySettingsRows.actionRow(text: rebuildText, button: rebuildButton)),
            AgentHistorySettingsRows.paddedRow(AgentHistorySettingsRows.actionRow(text: deleteText, button: deleteButton)),
        ])
    }

    // MARK: - Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()
        if statusObserverID == nil, let backend {
            statusObserverID = backend.addStatusObserver { [weak self] status in
                self?.apply(status: status)
            }
        }
        relativeTimeTimer?.invalidate()
        relativeTimeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderStatus()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let statusObserverID {
            backend?.removeObserver(statusObserverID)
        }
        statusObserverID = nil
        relativeTimeTimer?.invalidate()
        relativeTimeTimer = nil
    }

    /// Pulls the current status, asks for a recount, probes the sources (stat-only) and
    /// re-reads Claude Code's retention.
    override func prepareForPresentation() {
        guard let backend else {
            super.prepareForPresentation()
            return
        }
        apply(status: backend.status)
        backend.refreshStatus()
        backend.detectSources { [weak self] sources in
            guard let self else { return }
            self.detected = sources
            self.render()
        }
        reloadRetention()
        super.prepareForPresentation()
    }

    // MARK: - Applying state

    func apply(agentHistory: AppConfig.AgentHistory) {
        config = agentHistory
        guard isViewLoaded else { return }
        renderConfig()
        relayout()
    }

    func apply(status: AgentHistoryStatus) {
        self.status = status
        guard isViewLoaded else { return }
        render()
    }

    private var hasBackend: Bool { backend != nil }

    /// First-time consent covers the agents the probe found, so it waits for the probe (it
    /// answers later, off-main) and needs one agent found, like the consent card.
    private var canTurnOn: Bool {
        status.isEnabled || status.hasConsented || detected.contains(where: \.isFound)
    }

    private func render() {
        renderStatus()
        let rows = formatter.sourceRows(for: status, detected: detected)
        for (view, row) in zip(sourceRows, rows) {
            view.update(row, canToggle: hasBackend && status.hasConsented)
        }
        if claudeRoots() != retentionRoots {
            reloadRetention()
        }
        removedLabel.stringValue = AgentHistorySettingsRows.removedSessionsText(status.removedSessionCount, formatting: formatting)
        // Restoring needs an index that takes writes; until then the count is shown, not acted on.
        restoreAllButton.isEnabled = hasBackend && status.removedSessionCount > 0 && status.acceptsIndexWrites
        let rebuildBlockReason = rebuildBlockReason
        rebuildButton.isEnabled = hasBackend && status.isEnabled && status.canRebuild && rebuildBlockReason == nil
        rebuildBlockedLabel.stringValue = rebuildBlockReason ?? ""
        rebuildBlockedLabel.isHidden = rebuildBlockReason == nil
        // Deleting works without a running index; an off index or a kept consent is still there to delete.
        deleteButton.isEnabled = hasBackend && (status.indexExists || status.isEnabled || status.hasConsented)
        relayout()
    }

    /// Why Rebuild is off, for the states the user can do something about.
    private var rebuildBlockReason: String? {
        switch status.state {
        case .failed(.removalsUnreadable): AgentHistorySettingsRows.rebuildBlockedText
        case .paused(.anotherInstance, _): AgentHistorySettingsRows.rebuildOwnedElsewhereText
        default: nil
        }
    }

    private func renderStatus() {
        // Until state.json is read, consent is unknown: turning on could ask a consented user
        // again and overwrite their per-agent choices.
        statusSwitch.isEnabled = hasBackend && status.isStateLoaded && canTurnOn
        statusSwitch.state = status.isEnabled ? .on : .off
        guard hasBackend else {
            summaryLabel.stringValue = Self.unavailableText
            progressIndicator.isHidden = true
            activityLabel.isHidden = true
            calloutLabel.isHidden = true
            return
        }
        summaryLabel.stringValue = formatter.summary(for: status)
        if case .backfilling = status.state, let fraction = formatter.progressFraction(for: status) {
            progressIndicator.doubleValue = fraction
            progressIndicator.isHidden = false
        } else {
            progressIndicator.isHidden = true
        }
        let activity = formatter.activity(for: status)
        // An unusable index gets the callout; the activity line covers everything else.
        if case .failed = status.state, let activity {
            calloutLabel.stringValue = activity.text
            calloutLabel.isHidden = false
            activityLabel.isHidden = true
        } else {
            calloutLabel.isHidden = true
            activityLabel.stringValue = activity?.text ?? ""
            activityLabel.textColor = activity?.isWarning == true ? AgentHistorySettingsRows.amber : .secondaryLabelColor
            activityLabel.isHidden = activity == nil
        }
    }

    private func renderConfig() {
        agentAccessSwitch.state = config.allowAgentsAllProjects ? .on : .off
        agentAccessSwitch.isEnabled = hasBackend
        addFolderButton.isEnabled = hasBackend
        AgentHistorySettingsRows.clear(foldersStack)
        guard !config.excludedFolders.isEmpty else {
            foldersStack.addArrangedSubview(AgentHistorySettingsRows.label("No excluded folders.", size: 11, color: .tertiaryLabelColor))
            return
        }
        for folder in config.excludedFolders {
            let remove = AgentHistorySettingsRows.button("Remove", target: self, action: #selector(handleRemoveFolder(_:)), small: true)
            remove.identifier = NSUserInterfaceItemIdentifier(folder)
            remove.isEnabled = hasBackend
            let row = AgentHistorySettingsRows.actionRow(text: AgentHistorySettingsRows.label(folder), button: remove)
            foldersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: foldersStack.widthAnchor).isActive = true
        }
    }

    /// Known Claude Code config folders: indexed roots first, then roots the probe found.
    private func claudeRoots() -> [String] {
        let roots = status.sources.filter { $0.agent == .claude }.map(\.root)
            + detected.filter { $0.agent == .claude && $0.isFound }.compactMap(\.rootPath)
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    /// Reads each root's settings.json off main; the rows follow when the newest read lands.
    private func reloadRetention() {
        retentionRoots = claudeRoots()
        retention.load(roots: retentionRoots) { [weak self] statuses in
            self?.showRetention(statuses)
        }
    }

    private func showRetention(_ retentionStatuses: [ClaudeRetentionStatus]) {
        let showsPaths = retentionStatuses.count > 1
        retentionRows = retentionStatuses.compactMap { status in
            AgentHistorySettingsRetentionRow.make(
                status: status,
                didRaise: retention.raisedDirectories.contains(status.configDirectory.path),
                showsPath: showsPaths ? (status.configDirectory.path as NSString).abbreviatingWithTildeInPath : nil
            )
        }
        AgentHistorySettingsRetentionRow.fill(
            retentionStack, with: retentionRows, isEnabled: hasBackend,
            target: self, action: #selector(handleKeepOneYear(_:))
        )
        relayout()
    }

    /// Re-measures after rows appear or disappear; skipped while `loadView` still assembles.
    private func relayout() {
        guard isViewLoaded, scrollView.documentView != nil else { return }
        refreshScrollableContentLayout()
    }

    // MARK: - Actions

    @objc func handleStatusSwitchChanged(_ sender: NSSwitch) {
        guard let backend else {
            sender.state = .off
            return
        }
        let wantsOn = sender.state == .on
        guard status.isStateLoaded else {
            sender.state = status.isEnabled ? .on : .off
            return
        }
        guard wantsOn != status.isEnabled else { return }
        // Off, or on again after consent: no sheet.
        guard wantsOn, !status.hasConsented else {
            backend.setEnabled(wantsOn) { [weak self] in self?.reportStateChange($0, .history(on: wantsOn)) }
            return
        }
        let found = detected.filter(\.isFound)
        guard !found.isEmpty else {
            sender.state = .off
            return
        }
        confirmationPresenter(view.window, .enable(detected: detected)) { [weak self] confirmed in
            guard let self else { return }
            guard confirmed, let backend = self.backend else {
                self.statusSwitch.state = self.status.isEnabled ? .on : .off
                return
            }
            // Like the consent card: every agent found on this Mac starts on, and only those.
            backend.enable(agents: Set(found.map(\.agent))) { [weak self] in
                self?.reportStateChange($0, .history(on: true))
            }
        }
    }

    @objc func handleSourceSwitchChanged(_ sender: NSSwitch) {
        guard let backend, let row = sourceRows.first(where: { $0.toggle === sender }) else { return }
        let on = sender.state == .on
        backend.setAgentEnabled(row.agent, on) { [weak self] in self?.reportStateChange($0, .source(row.agent, on: on)) }
    }

    /// Off holds even when it couldn't be saved, but may come back after a restart; on that
    /// couldn't be saved changed nothing. Either way the user hears it, and the switches show
    /// what is in effect.
    private func reportStateChange(_ outcome: AgentHistoryStateChangeOutcome, _ change: AgentHistorySettingsStateChange) {
        if let failure = AgentHistorySettingsAlerts.stateChangeFailure(outcome, change) {
            agentHistorySettingsLogger.error("Agent History couldn't save a state change")
            errorPresenter(view.window, failure.title, failure.message)
        }
        render()
    }

    @objc func handleAddFolder(_: Any?) {
        folderPicker(view.window) { [weak self] urls in
            self?.addExcludedFolders(urls)
        }
    }

    private func addExcludedFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        saveExcludedFolders(AgentHistoryConsentModel.normalizedFolders(config.excludedFolders + urls.map(\.path)))
    }

    @objc func handleRemoveFolder(_ sender: NSButton) {
        guard let folder = sender.identifier?.rawValue else { return }
        saveExcludedFolders(config.excludedFolders.filter { $0 != folder })
    }

    /// Same rule as the consent card: a folder list that didn't reach config.toml is an error
    /// the user sees, never a silent in-memory change.
    private func saveExcludedFolders(_ folders: [String]) {
        do {
            try AgentHistoryPaletteServicesAdapter.saveExcludedFolders(folders, to: configStore)
        } catch {
            errorPresenter(
                view.window,
                "Couldn't save the excluded folders",
                "Zentty couldn't write its config file, so this change isn't saved. Fix config.toml and try again."
            )
        }
        apply(agentHistory: configStore.current.agentHistory)
    }

    @objc func handleRestoreAll(_: Any?) {
        backend?.restoreAllRemovedSessions()
    }

    /// Like the folders: a change that didn't reach config.toml is an error the user sees.
    @objc func handleAgentAccessChanged(_ sender: NSSwitch) {
        do {
            try AgentHistoryPaletteServicesAdapter.saveAgentAccess(sender.state == .on, to: configStore)
        } catch {
            let failure = AgentHistorySettingsAlerts.agentAccessSaveFailure(error)
            errorPresenter(view.window, failure.title, failure.message)
        }
        apply(agentHistory: configStore.current.agentHistory)
    }

    @objc func handleRebuild(_: Any?) {
        guard rebuildButton.isEnabled else { return }
        backend?.rebuildIndex()
    }

    @objc func handleDelete(_: Any?) {
        guard backend != nil else { return }
        confirmationPresenter(view.window, .deleteIndex) { [weak self] confirmed in
            guard confirmed, let self, let backend = self.backend else { return }
            backend.disable(deleteIndex: true) { [weak self] outcome in
                self?.handleDeleteOutcome(outcome)
            }
        }
    }

    private func handleDeleteOutcome(_ outcome: AgentHistoryDisableOutcome) {
        if let message = AgentHistorySettingsAlerts.deleteFailureMessage(outcome) {
            agentHistorySettingsLogger.error("Agent History index delete didn't complete")
            errorPresenter(view.window, "Couldn't delete the index", message)
        }
        backend?.refreshStatus()
    }

    /// Backs up and rewrites Claude Code's settings.json off main, then re-reads it.
    @objc func handleKeepOneYear(_ sender: NSButton) {
        guard let directory = sender.identifier?.rawValue else { return }
        retention.raise(directory: directory) { [weak self] error in
            guard let self else { return }
            if let error {
                let message = (error as? LocalizedError)?.errorDescription ?? AgentHistoryViewModel.retentionFallbackError
                self.errorPresenter(self.view.window, "Couldn't change Claude Code's settings", message)
            }
            self.reloadRetention()
        }
    }

    // MARK: - Testing

    var summaryTextForTesting: String { summaryLabel.stringValue }
    var activityTextForTesting: String? { activityLabel.isHidden ? nil : activityLabel.stringValue }
    var calloutTextForTesting: String? { calloutLabel.isHidden ? nil : calloutLabel.stringValue }
    var removedSessionsTextForTesting: String { removedLabel.stringValue }
    var rebuildBlockedTextForTesting: String? { rebuildBlockedLabel.isHidden ? nil : rebuildBlockedLabel.stringValue }

    var excludedFolderRowsForTesting: [String] {
        foldersStack.arrangedSubviews.compactMap { $0.agentHistoryDescendant(ofType: NSButton.self)?.identifier?.rawValue }
    }

    func sourceRowForTesting(_ agent: AgentHistoryAgent) -> AgentHistorySettingsSourceRowView? {
        sourceRows.first { $0.agent == agent }
    }

    func keepOneYearButtonForTesting(directory: String) -> NSButton? {
        retentionStack.agentHistoryDescendants(ofType: NSButton.self).first { $0.identifier?.rawValue == directory }
    }
}
