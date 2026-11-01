import Foundation

/// The first-run consent card and the index state bodies. Nothing is persisted before
/// "Index ‹N› Sessions" except an explicit "Keep 1 Year" click (it writes Claude Code's file).
extension AgentHistoryViewModel {
    static let retentionFallbackError = "Zentty couldn't change Claude Code's settings; nothing was changed."

    /// Builds the card from the stat-only probe (D11). Claude's retention is read only when
    /// Claude Code was found.
    func makeConsent(from sources: [AgentHistoryDetectedSource]) -> AgentHistoryConsentModel {
        let claudeFound = sources.contains { $0.agent == .claude && $0.isFound }
        return AgentHistoryConsentModel.make(
            detected: sources,
            excluded: services.excludedFolders(),
            retention: claudeFound ? services.claudeRetention() : nil
        )
    }

    // MARK: - Editing

    func setConsentSource(_ agent: AgentHistoryAgent, enabled: Bool) {
        consent?.setEnabled(agent, enabled)
    }

    /// "Keep 1 Year": raises Claude Code's `cleanupPeriodDays` on this explicit click only. A
    /// failure keeps the current retention and says why; nothing was written.
    func keepClaudeConversationsOneYear() {
        guard var consent, consent.showsRetentionNudge else { return }
        do {
            _ = try services.raiseClaudeRetention()
            consent.retention = services.claudeRetention()
            consent.retentionError = nil
            consent.didRaiseRetention = true
        } catch {
            consent.retentionError = (error as? LocalizedError)?.errorDescription ?? Self.retentionFallbackError
        }
        self.consent = consent
    }

    /// "Add Folder…": the panel shows the folder picker and calls `addExcludedFolders`.
    func requestAddExcludedFolder() {
        guard consent?.isIndexing == false else { return }
        onRequestFolderPicker?()
    }

    /// Kept in the card until confirm, so "Not Now" persists nothing.
    func addExcludedFolders(_ urls: [URL]) {
        guard consent?.isIndexing == false, !urls.isEmpty else { return }
        consent?.addExcludedFolders(urls.map(\.path))
    }

    func removeExcludedFolder(_ folder: String) {
        guard consent?.isIndexing == false else { return }
        consent?.removeExcludedFolder(folder)
    }

    // MARK: - Confirm and decline

    /// "Index ‹N› Sessions" (↩): saves the excluded folders first, so the indexer never reads
    /// them, then records consent for the checked agents and shows progress. When the folders
    /// can't be saved, or config.toml can't be read (the card's folder list may be missing the
    /// user's exclusions), nothing is enabled: the card stays editable and says why.
    ///
    /// The card is only shown on a loaded, unconsented status, because `enable` keeps the saved
    /// agent choices once consent exists. If consent was saved elsewhere before its status
    /// arrived, nothing from the card is submitted and the results show instead.
    func confirmConsent() {
        guard body == .consent, var consent, consent.canConfirm else { return }
        let status = services.control.status
        guard status.isStateLoaded, !status.hasConsented else {
            leaveConsentCard(status: status)
            return
        }
        if consent.excludedFolders != services.excludedFolders() {
            do {
                try services.setExcludedFolders(consent.excludedFolders)
            } catch {
                consent.saveError = AgentHistoryConsentModel.excludedFoldersSaveError
                self.consent = consent
                return
            }
        }
        consent.saveError = nil
        consent.isIndexing = true
        self.consent = consent
        services.control.enable(agents: consent.enabledAgents) { [weak self] outcome in
            self?.consentEnableDidFinish(outcome)
        }
        _ = consentStatusDidChange(services.control.status)
    }

    private func consentEnableDidFinish(_ outcome: AgentHistoryStateChangeOutcome) {
        guard outcome == .refusedConfigUnreadable, body == .consent, var consent, consent.isIndexing else { return }
        consent.isIndexing = false
        consent.overallProgress = nil
        consent.saveError = AgentHistoryConsentModel.configUnreadableError
        self.consent = consent
    }

    /// "Not Now": closes; the card shows again next time.
    func declineConsent() {
        onRequestClose?(true)
    }

    /// Status while the card is shown. Returns true when the card handled it. After confirm:
    /// progress, then results once 50 sessions are searchable; a failure shows the unavailable body.
    func consentStatusDidChange(_ status: AgentHistoryStatus) -> Bool {
        guard body == .consent else { return false }
        guard var consent, consent.isIndexing else {
            // Consent recorded elsewhere (Settings): the card's choices would be ignored.
            if status.hasConsented {
                leaveConsentCard(status: status)
            }
            return true
        }
        if case .failed(let reason) = status.state {
            body = .indexUnavailable(reason)
            return true
        }
        consent.applyProgress(status)
        self.consent = consent
        if AgentHistoryConsentModel.isReadyForResults(status) {
            showResults()
        }
        return true
    }

    private func leaveConsentCard(status: AgentHistoryStatus) {
        consent = nil
        lastStatusRevision = status.revision
        resolveBody(status: status)
    }

    // MARK: - Index unavailable

    /// "Rebuild Index" in the unavailable body. The body follows the next status change.
    func rebuildIndex() {
        services.control.rebuildIndex()
    }
}
