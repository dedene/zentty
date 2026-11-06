import Foundation

/// What the result list shows when it has no rows for a typed query.
enum AgentHistoryEmptyResults: Equatable {
    /// The metadata tier found nothing and the content tier is still running.
    case searching
    case noMatches(query: String, suggestsAllProjects: Bool)

    var title: String {
        switch self {
        case .searching: "Searching conversations…"
        case .noMatches(let query, _): "No sessions match “\(query)”."
        }
    }

    /// Shown under a project scope only.
    var scopeHint: String? {
        if case .noMatches(_, true) = self {
            return "Press ⇥ to search all projects"
        }
        return nil
    }

    var filterHint: String? {
        if case .noMatches = self {
            return "Filter with agent:, repo:, branch:, before:YYYY-MM-DD or after:YYYY-MM-DD"
        }
        return nil
    }
}

/// The two search tiers: the empty-query view, the synchronous metadata tier and the debounced
/// content tier with its generation guard.
extension AgentHistoryViewModel {
    var emptyResults: AgentHistoryEmptyResults? {
        guard body == .results, !parsedQuery.isEmpty, rows.isEmpty else { return nil }
        if contentPhase == .pending {
            return .searching
        }
        return .noMatches(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestsAllProjects: scope != .all
        )
    }

    /// Rebuilds the sections for the current query and scope. `resetSelection` (query or scope
    /// change) selects the first row; otherwise the selection is kept by key or position.
    /// `keepsStaleContent` false drops the previous conversation rows instead of showing them
    /// until the content tier answers (they may list sessions that are now hidden).
    func runSearch(resetSelection: Bool, keepsStaleContent: Bool = true) {
        searchGeneration &+= 1
        let previousKey = resetSelection ? nil : selectedKey
        let previousIndex = resetSelection ? nil : selectedIndex
        let previousSessionID = selectedRow?.sessionID

        if parsedQuery.isEmpty {
            cancelContentSearch()
            sections = emptyQuerySections()
            setContentPhase(.idle)
            noteEmptyQueryRefresh()
        } else {
            runTypedSearch(keepsStaleContent: keepsStaleContent)
        }

        resolveSelection(previous: previousKey, previousIndex: previousIndex, previousSessionID: previousSessionID)
        checkFolders()
    }

    private var selectedIndex: Int? {
        guard let selectedKey else { return nil }
        return rows.firstIndex { $0.key == selectedKey }
    }

    private func resolveSelection(previous: AgentHistorySessionKey?, previousIndex: Int?, previousSessionID: Int64?) {
        let resolved = AgentHistoryResultMerger.resolveSelection(previous: previous, previousIndex: previousIndex, in: rows)
        let changed = resolved != selectedKey
        selectedKey = resolved
        // A rebuild may keep the key yet change the query the preview's turns depend on, or give
        // a live row its index row.
        if changed || previous == nil || !parsedQuery.isEmpty || selectedRow?.sessionID != previousSessionID {
            selectionDidChange()
        }
    }

    // MARK: - Empty query

    private func emptyQuerySections() -> [AgentHistorySection] {
        let search = services.search
        let locations = liveSnapshot.allPrimaryLocations
        // A session the index hides (removed, agent off, folder excluded) is not listed; one it
        // hasn't read yet is, from its pane. A missing answer counts as hidden.
        let runningNow = zip(locations, search.liveSessions(for: locations)).compactMap {
            location, lookup -> AgentHistoryResultRow? in
            let summary: AgentHistorySessionSummary?
            switch lookup {
            case .hidden: return nil
            case .indexed(let indexed): summary = indexed
            case .notIndexed: summary = nil
            }
            return admitsLive(location, summary: summary) ? AgentHistoryResultRow(live: location, summary: summary) : nil
        }
        let liveKeySet = Set(runningNow.map(\.key))

        let recent = search.recentSessions(scope: scope, limit: Self.recentLimit + liveKeySet.count)
            .filter { !liveKeySet.contains($0.key) }
            .prefix(Self.recentLimit)
            .map { AgentHistoryResultRow(summary: $0) }

        var sections: [AgentHistorySection] = []
        if !runningNow.isEmpty {
            sections.append(AgentHistorySection(kind: .runningNow, rows: runningNow, note: Self.runningNowNote))
        }
        if !recent.isEmpty {
            let count = search.indexedSessionCount(scope: scope)
            sections.append(AgentHistorySection(kind: .recent, rows: Array(recent), note: formatting.sessionCount(count)))
        }
        return sections
    }

    /// A live session belongs to the scope by its pane's folder or its indexed paths.
    private func admitsLive(_ location: LiveAgentSessionLocation, summary: AgentHistorySessionSummary?) -> Bool {
        guard case .project(let project) = scope else { return true }
        if project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: location.workingDirectory) {
            return true
        }
        guard let summary else { return false }
        return project.admits(repoRoot: summary.repoRoot, mainRepoRoot: summary.mainRepoRoot, cwd: summary.cwd)
    }

    // MARK: - Typed query

    private func runTypedSearch(keepsStaleContent: Bool) {
        let context = searchContext
        let response = services.search.metadataHits(
            for: parsedQuery,
            context: context,
            limit: AgentHistoryResultMerger.sessionsLimit
        )
        let sessionRows = AgentHistoryResultMerger.metadataRows(response).map(applyLive)
        let metadataIDs = Set(sessionRows.compactMap(\.sessionID))

        cancelContentSearch()
        let conversationRows: [AgentHistoryResultRow]
        if parsedQuery.terms.isEmpty {
            // Filters only: the metadata tier lists the matching sessions newest first.
            conversationRows = []
            setContentPhase(.complete)
        } else if !parsedQuery.hasContentTerms(tokenizer: services.search.tokenizer()) {
            conversationRows = []
            setContentPhase(.shortTermsOnly)
        } else {
            conversationRows = keepsStaleContent
                ? AgentHistoryResultMerger.staleContent(currentConversationRows, droppingSessionsIn: metadataIDs)
                : []
            setContentPhase(.pending)
            scheduleContentSearch(context: context, metadataIDs: metadataIDs)
        }
        sections = typedSections(sessions: sessionRows, conversations: conversationRows)
    }

    private var currentConversationRows: [AgentHistoryResultRow] {
        sections.first { $0.kind == .inConversations }?.rows ?? []
    }

    private func typedSections(
        sessions: [AgentHistoryResultRow],
        conversations: [AgentHistoryResultRow]
    ) -> [AgentHistorySection] {
        var sections: [AgentHistorySection] = []
        if !sessions.isEmpty {
            sections.append(AgentHistorySection(kind: .sessions, rows: sessions))
        }
        if !conversations.isEmpty {
            sections.append(AgentHistorySection(kind: .inConversations, rows: conversations))
        }
        return sections
    }

    private func scheduleContentSearch(context: HistorySearchContext, metadataIDs: Set<Int64>) {
        let generation = searchGeneration
        let query = parsedQuery
        contentDebounceToken = scheduler.schedule(after: Self.contentDebounce) { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.contentDebounceToken = nil
            self.contentToken = self.services.search.searchContent(
                query,
                context: context,
                excluding: metadataIDs
            ) { [weak self] result in
                self?.contentSearchCompleted(result, generation: generation)
            }
        }
    }

    private func contentSearchCompleted(_ result: Result<HistoryContentResponse, Error>, generation: UInt64) {
        guard searchGeneration == generation else { return }
        contentToken = nil
        let previousKey = selectedKey
        let previousIndex = selectedIndex
        let sessionRows = sections.first { $0.kind == .sessions }?.rows ?? []

        switch result {
        case .success(let response):
            let merge = AgentHistoryResultMerger.applyContent(
                response: response,
                to: sessionRows,
                metadataIDs: Set(sessionRows.compactMap(\.sessionID))
            )
            sections = typedSections(sessions: merge.sessions, conversations: merge.conversations.map(applyLive))
            setContentPhase(.complete)
        case .failure(HistorySearchError.cancelled):
            return
        case .failure(let error):
            AgentHistoryLog.search.error(
                "palette content search failed: \(String(describing: type(of: error)), privacy: .public)"
            )
            sections = typedSections(sessions: sessionRows, conversations: [])
            setContentPhase(.failed)
        }

        let resolved = AgentHistoryResultMerger.resolveSelection(previous: previousKey, previousIndex: previousIndex, in: rows)
        if resolved != selectedKey {
            selectedKey = resolved
            selectionDidChange()
        }
        checkFolders()
    }

    private func cancelContentSearch() {
        contentDebounceToken?.cancel()
        contentToken?.cancel()
        contentDebounceToken = nil
        contentToken = nil
    }

    private func setContentPhase(_ phase: ContentPhase) {
        guard contentPhase != phase else { return }
        contentPhase = phase
        updateFooter()
    }

    // MARK: - Folder gone

    /// Checks unseen session folders and transcript files on a utility queue; live rows never
    /// count as folder gone.
    func checkFolders() {
        let folders = rows.compactMap { $0.live == nil ? $0.summary?.cwd : nil }
        let transcripts = rows.compactMap { row -> String? in
            guard let path = row.summary?.transcriptPath, !path.isEmpty else { return nil }
            return path
        }
        let paths = Set(folders + transcripts)
            .subtracting(pathExists.keys)
            .subtracting(pathChecksInFlight)
        refreshFolderGoneKeys()
        guard !paths.isEmpty else { return }
        pathChecksInFlight.formUnion(paths)
        let fileExists = services.fileExists
        let pending = Array(paths)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = pending.map { ($0, fileExists($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.foldersChecked(results)
                }
            }
        }
    }

    private func foldersChecked(_ results: [(String, Bool)]) {
        for (path, exists) in results {
            pathChecksInFlight.remove(path)
            pathExists[path] = exists
        }
        refreshFolderGoneKeys()
    }

    /// Publishes the folder-gone and transcript-present keys from the cached checks.
    func refreshFolderGoneKeys() {
        let gone = Set(rows.compactMap { row -> AgentHistorySessionKey? in
            guard row.live == nil, let cwd = row.summary?.cwd, pathExists[cwd] == false else { return nil }
            return row.key
        })
        if gone != folderGoneKeys {
            folderGoneKeys = gone
        }
        let transcripts = Set(rows.compactMap { row -> AgentHistorySessionKey? in
            guard let path = row.summary?.transcriptPath, pathExists[path] == true else { return nil }
            return row.key
        })
        if transcripts != transcriptPresentKeys {
            transcriptPresentKeys = transcripts
        }
    }
}
