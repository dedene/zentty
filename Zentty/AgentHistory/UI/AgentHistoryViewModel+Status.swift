import Foundation

/// What a status lets the palette show. Turning Agent History off or deleting its index revokes
/// it; turning an agent off or changing the excluded folders narrows (or widens) the results.
struct AgentHistoryAccess: Equatable {
    var isEnabled: Bool
    var hasConsented: Bool
    var enabledAgents: Set<AgentHistoryAgent>
    var excludedFolders: [String]
    var removedKeys: Set<AgentHistorySessionKey>

    init(_ status: AgentHistoryStatus) {
        isEnabled = status.isEnabled
        hasConsented = status.hasConsented
        enabledAgents = status.enabledAgents
        excludedFolders = status.excludedFolders
        removedKeys = status.removedKeys
    }

    /// Turned off, or consent gone ("Delete Index and Turn Off").
    func isRevoked(by next: AgentHistoryAccess) -> Bool {
        (isEnabled && !next.isEnabled) || (hasConsented && !next.hasConsented)
    }

    /// The agents or excluded folders changed: which sessions may be listed changed with them.
    func changesVisibleSessions(to other: AgentHistoryAccess) -> Bool {
        enabledAgents != other.enabledAgents || excludedFolders != other.excludedFolders
    }
}

/// Status and live-session updates, including the privacy invalidation: nothing the status no
/// longer allows stays on screen, typed query or not.
extension AgentHistoryViewModel {
    func statusDidChange(_ status: AgentHistoryStatus) {
        let next = AgentHistoryAccess(status)
        let previous = access
        access = next
        if let previous, previous.isRevoked(by: next) {
            revokeAccess(status: status)
            return
        }
        updateFooter(status: status)
        if consentStatusDidChange(status) {
            return
        }
        if body == .historyOff {
            lastStatusRevision = status.revision
            if !status.isTurnedOff {
                resolveBody(status: status)
            }
            return
        }
        switch (body, status.state) {
        case (_, .failed(let reason)) where body != .consent:
            body = .indexUnavailable(reason)
            return
        case (.indexUnavailable, _):
            resolveBody(status: status)
            return
        default:
            break
        }
        // Waiting on `state.json`, or consent recorded while the source probe runs.
        if body == .loading, (isAwaitingSavedState && status.isStateLoaded) || status.hasConsented {
            lastStatusRevision = status.revision
            resolveBody(status: status)
            return
        }
        // Another Zentty instance recorded consent while this one saw no agents.
        if case .noAgents = body, status.hasConsented {
            lastStatusRevision = status.revision
            resolveBody(status: status)
            return
        }
        if body == .results, let previous, previous.changesVisibleSessions(to: next) {
            lastStatusRevision = status.revision
            refreshForAccessChange()
            return
        }
        // Removed here (`removalCompleted` got there too) or by another instance, or in another
        // window: no row stays, and nothing typed runs again for a session that wasn't listed.
        if body == .results, let previous {
            let removed = next.removedKeys.subtracting(previous.removedKeys)
            if !removed.isEmpty {
                dropRemovedSessions(removed)
            }
        }
        guard status.revision != lastStatusRevision else { return }
        lastStatusRevision = status.revision
        // Typed results never re-run; the empty-query view refreshes at most once a second.
        guard body == .results, parsedQuery.isEmpty, statusRefreshToken == nil else { return }
        let elapsed = lastEmptyQueryRefreshAt.map { services.now().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, Self.statusRefreshInterval - elapsed)
        statusRefreshToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.statusRefreshToken = nil
            guard self.body == .results, self.parsedQuery.isEmpty else { return }
            self.runSearch(resetSelection: false)
        }
    }

    /// Turned off, the palette stays on the off screen to hear History coming back. Index
    /// deleted, consent is gone with it, so the palette closes and the next open starts over
    /// from the status. Focus stays where the change was made (Settings).
    private func revokeAccess(status: AgentHistoryStatus) {
        if status.isTurnedOff {
            lastStatusRevision = status.revision
            resolveBody(status: status)
            updateFooter(status: status)
            return
        }
        stop()
        body = .loading
        clearShownSessions()
        onRequestClose?(false)
    }

    /// The only way onto the off screen: nothing listed before stays behind it.
    func showHistoryOff() {
        body = .historyOff
        resetQuery()
        clearShownSessions()
    }

    /// Drops every pending load (a late one is ignored by the bumped generations) and clears
    /// what was shown.
    private func clearShownSessions() {
        cancelPendingLoads()
        searchGeneration &+= 1
        detailGeneration &+= 1
        sections = []
        selectedKey = nil
        contentPhase = .idle
        preview = .idle
        transcript = .idle
        detail = .none
        folderSheet = nil
        copySessionIDOfferKeys = []
        folderGoneKeys = []
        transcriptPresentKeys = []
        consent = nil
        transientMessage = nil
        isShowingIndexProgress = false
    }

    /// An agent was turned off or the excluded folders changed. The search services already
    /// hide those sessions (Running now included), so the current query runs again, typed or not, without keeping the
    /// previous conversation rows; a detail or sheet for a session that is gone closes.
    private func refreshForAccessChange() {
        statusRefreshToken?.cancel()
        statusRefreshToken = nil
        let previousKey = selectedKey
        runSearch(resetSelection: false, keepsStaleContent: false)
        let visible = Set(rows.map(\.key))
        if let previousKey, !visible.contains(previousKey) {
            closeDetailForNewResults()
        }
        copySessionIDOfferKeys.formIntersection(visible)
        if let sheet = folderSheet, !visible.contains(sheet.key) {
            folderSheet = nil
        }
    }

    func updateFooter(status: AgentHistoryStatus? = nil) {
        let status = status ?? services.control.status
        let indexProgress = AgentHistoryIndexProgress(status: status)
        footer = Footer(
            health: formatting.footerHealth(status: status, now: services.now()),
            problemLink: formatting.problemLink(status: status),
            hint: contentPhase == .shortTermsOnly ? Self.shortTermsHint : nil,
            indexProgress: indexProgress
        )
        if indexProgress == nil {
            isShowingIndexProgress = false
        }
    }

    func toggleIndexProgress() {
        guard footer.indexProgress != nil else { return }
        isShowingIndexProgress.toggle()
    }

    func closeIndexProgress() {
        isShowingIndexProgress = false
    }

    /// Marks when the empty-query view was last built (for the status refresh throttle).
    func noteEmptyQueryRefresh() {
        lastEmptyQueryRefreshAt = services.now()
    }

    func liveSessionsDidChange() {
        liveSnapshot = services.launch.liveSnapshot()
        liveKeys = liveSnapshot.liveKeys
        guard body == .results else { return }
        if parsedQuery.isEmpty {
            runSearch(resetSelection: false)
        } else {
            sections = sections.map { section in
                var section = section
                section.rows = section.rows.map(applyLive)
                return section
            }
            refreshFolderGoneKeys()
        }
    }
}
