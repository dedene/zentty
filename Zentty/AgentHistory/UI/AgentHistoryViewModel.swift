import Combine
import Foundation

/// The Agent History palette's state. Main-actor only; every service call returns on main.
///
/// Search runs in two tiers (`+Search`): the metadata tier synchronously on every keystroke and
/// the content tier after a 120 ms debounce. Each query change bumps `searchGeneration`, so a
/// late content response from an older query is dropped even if its cancellation lost the race.
@MainActor
final class AgentHistoryViewModel: ObservableObject {
    enum Body: Equatable {
        case loading
        case consent
        case noAgents(checkedPaths: [String])
        case indexUnavailable(AgentHistoryFailureReason)
        case results
        /// Consented, but switched off in Settings.
        case historyOff

        /// The consent card (D15) and the off screen stand alone, without search row and footer:
        /// nothing can be searched from them.
        var showsSearchChrome: Bool {
            self != .consent && self != .historyOff
        }

        /// Whether this body's checkboxes and buttons join the native key-view loop (Tab,
        /// Shift-Tab, Space with Full Keyboard Access on). Bodies under the search row keep focus
        /// in the field and route ↑↓ ⇥ through `AgentHistoryKeyRouter`; without a search row the
        /// controls take focus themselves, so the consent card's privacy controls are reachable
        /// before anything is indexed.
        var controlsTakeKeyboardFocus: Bool {
            !showsSearchChrome
        }
    }

    /// Where the content tier ("In conversations") stands for the current query.
    enum ContentPhase: Equatable {
        /// Empty query, or a filter-only query: nothing to search in conversations.
        case idle
        /// Waiting on the debounce or the engine; previous rows stay visible (stale).
        case pending
        case complete
        /// Every term is too short for the content tier.
        case shortTermsOnly
        case failed
    }

    enum DetailMode: Equatable {
        case none
        /// The preview shown full-panel in a compact (list-only) layout.
        case preview
        case transcript
    }

    enum LoadFailure: Equatable {
        /// A live session without an index row yet.
        case notIndexed
        /// Removed, hidden or excluded since the row was listed.
        case sessionNotFound
        case failed
    }

    enum Loadable<Value: Equatable>: Equatable {
        case idle
        case loading
        case loaded(Value)
        case failed(LoadFailure)
    }

    struct Footer: Equatable {
        var health: AgentHistoryFooterHealth
        /// Amber link to Settings when a source has problems.
        var problemLink: String?
        /// "Type 3+ characters to search conversations".
        var hint: String?
        /// The initial index is running or paused: a bar, and the health text opens the details.
        var indexProgress: AgentHistoryIndexProgress?
    }

    static let shortTermsHint = "Type 3+ characters to search conversations"
    static let runningNowNote = "↩ jumps to the pane"
    static let recentLimit = 10
    static let contentDebounce: TimeInterval = 0.12
    static let detailCoalesce: TimeInterval = 0.06
    static let statusRefreshInterval: TimeInterval = 1

    @Published private(set) var query = ""
    @Published internal(set) var body: Body = .loading
    @Published internal(set) var scope: AgentHistoryScope
    @Published private(set) var pills: [AgentHistoryFilterPill] = []
    @Published internal(set) var sections: [AgentHistorySection] = []
    @Published internal(set) var selectedKey: AgentHistorySessionKey?
    @Published internal(set) var contentPhase: ContentPhase = .idle
    @Published internal(set) var preview: Loadable<HistoryPreview> = .idle
    @Published internal(set) var transcript: Loadable<HistoryTranscript> = .idle
    @Published internal(set) var detail: DetailMode = .none
    @Published internal(set) var footer: Footer
    /// The initial index's details fill the results area; Esc goes back to search.
    @Published internal(set) var isShowingIndexProgress = false
    @Published internal(set) var liveKeys: Set<AgentHistorySessionKey> = []
    @Published internal(set) var folderGoneKeys: Set<AgentHistorySessionKey> = []
    /// Rows whose transcript file was found; only they offer "Reveal Transcript in Finder".
    @Published internal(set) var transcriptPresentKeys: Set<AgentHistorySessionKey> = []
    /// The first-run consent card (`+Consent`), built from the stat-only probe.
    @Published internal(set) var consent: AgentHistoryConsentModel?
    /// The consent card's measured height; the panel fits itself to it.
    @Published var consentFittingHeight: CGFloat?
    /// Bumped to put the caret back in the search field (after the folder picker).
    @Published private(set) var queryFocusRequest = 0
    /// In-panel feedback ("Copied", "Removed …"); never a launch toast (A-20).
    @Published var transientMessage: String?
    /// Where to resume a session whose folder is gone (`+Actions`); nil while hidden.
    @Published internal(set) var folderSheet: AgentHistoryFolderGoneSheetModel?
    /// Sessions whose resume failed with an offer to copy the session ID instead.
    @Published internal(set) var copySessionIDOfferKeys: Set<AgentHistorySessionKey> = []
    @Published private(set) var theme: AgentHistoryTheme
    /// Set by the panel controller on show and on every parent resize.
    @Published var layout: AgentHistoryPanelLayout? {
        didSet {
            if detail == .preview, layout?.isCompact != true {
                detail = .none
            }
        }
    }

    var onRequestClose: ((_ restoreFocus: Bool) -> Void)?
    var onRequestSettings: (() -> Void)?
    var onRequestFolderPicker: (() -> Void)?

    /// Its projects are filled in by `projectsResolved` (`+Projects`) once resolved off main.
    internal(set) var context: AgentHistoryOpenContext
    let services: AgentHistoryPaletteServices
    let scheduler: AgentHistoryScheduling
    let formatting: AgentHistoryFormatting
    /// The scope ⇥ toggles to: the worklane's project, else the focused pane's.
    @Published internal(set) var projectScope: AgentHistoryProjectScope?

    // Search state, shared with `+Search`.
    var parsedQuery = HistoryQueryParser.parse("")
    var searchGeneration: UInt64 = 0
    var contentDebounceToken: AgentHistoryCancellable?
    var contentToken: AgentHistoryCancellable?
    var liveSnapshot = LiveAgentSessionSnapshot.empty

    // Detail loading.
    private var detailDebounceToken: AgentHistoryCancellable?
    private var previewToken: AgentHistoryCancellable?
    private var transcriptToken: AgentHistoryCancellable?
    var detailGeneration: UInt64 = 0

    // Observers and throttles, shared with `+Status`.
    private var statusObserverID: UUID?
    private var liveObservation: AgentHistoryCancellable?
    var lastStatusRevision: UInt64 = 0
    var lastEmptyQueryRefreshAt: Date?
    var statusRefreshToken: AgentHistoryCancellable?
    /// What the last status allowed the palette to show (`+Status`).
    var access: AgentHistoryAccess?
    var transientMessageToken: AgentHistoryCancellable?
    /// Opened before `state.json` was read: `.loading` until the status says what was saved.
    var isAwaitingSavedState = false
    private(set) var isStarted = false

    // `+Projects`: the panes' projects land off main after the panel opens.
    var isAwaitingProjects = false
    var resultsAwaitProjects = false
    var projectsWaitToken: AgentHistoryCancellable?

    // `+Search`: folder or transcript path → exists, filled off-main so renders never stat.
    var pathExists: [String: Bool] = [:]
    var pathChecksInFlight: Set<String> = []

    init(
        context: AgentHistoryOpenContext,
        services: AgentHistoryPaletteServices,
        theme: AgentHistoryTheme,
        scheduler: AgentHistoryScheduling = AgentHistoryMainQueueScheduler(),
        formatting: AgentHistoryFormatting = AgentHistoryFormatting()
    ) {
        self.context = context
        self.services = services
        self.scheduler = scheduler
        self.formatting = formatting
        self.theme = theme
        self.scope = context.initialScope
        if case .project(let project) = context.initialScope {
            projectScope = project
        } else {
            projectScope = context.currentProject
        }
        footer = Footer(health: formatting.footerHealth(status: services.control.status, now: services.now()))
    }

    // MARK: - Lifecycle

    /// Picks the body and, for results, builds the empty-query view. Call once after the panel shows.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        statusObserverID = services.control.addStatusObserver { [weak self] status in
            self?.statusDidChange(status)
        }
        liveObservation = services.launch.observeLiveSessions { [weak self] in
            self?.liveSessionsDidChange()
        }
        let status = services.control.status
        lastStatusRevision = status.revision
        access = AgentHistoryAccess(status)
        updateFooter(status: status)
        liveSnapshot = services.launch.liveSnapshot()
        liveKeys = liveSnapshot.liveKeys
        resolveBody(status: status)
    }

    /// Consented but off → the off screen; failed index → unavailable; consented → results;
    /// `state.json` not read yet → loading until it is (the launch read waits a few seconds, so
    /// ask for it now); no consent → probe for sources (consent card or "no agents").
    func resolveBody(status: AgentHistoryStatus) {
        isAwaitingSavedState = false
        resultsAwaitProjects = false
        if status.isTurnedOff {
            showHistoryOff()
        } else if case .failed(let reason) = status.state {
            body = .indexUnavailable(reason)
        } else if status.hasConsented {
            showResults()
        } else if !status.isStateLoaded {
            body = .loading
            isAwaitingSavedState = true
            services.control.refreshStatus()
        } else {
            body = .loading
            services.control.detectSources { [weak self] sources in
                // The card shows with its retention row, not a beat before it.
                self?.readClaudeRetention(for: sources) { [weak self] retentions in
                    self?.sourcesDetected(sources, retentions: retentions)
                }
            }
        }
    }

    /// Cancels every pending load and drops the observers. Idempotent.
    func stop() {
        cancelPendingLoads()
        liveObservation?.cancel()
        projectsWaitToken?.cancel()
        projectsWaitToken = nil
        liveObservation = nil
        if let statusObserverID {
            services.control.removeObserver(statusObserverID)
            self.statusObserverID = nil
        }
        isStarted = false
    }

    /// Everything that would put a session on screen later.
    func cancelPendingLoads() {
        contentDebounceToken?.cancel()
        contentToken?.cancel()
        detailDebounceToken?.cancel()
        previewToken?.cancel()
        transcriptToken?.cancel()
        statusRefreshToken?.cancel()
        transientMessageToken?.cancel()
        contentDebounceToken = nil
        contentToken = nil
        detailDebounceToken = nil
        previewToken = nil
        transcriptToken = nil
        statusRefreshToken = nil
        transientMessageToken = nil
    }

    func showResults() {
        guard !isAwaitingProjects else {
            body = .loading
            resultsAwaitProjects = true
            return
        }
        body = .results
        runSearch(resetSelection: true)
    }

    private func sourcesDetected(_ sources: [AgentHistoryDetectedSource], retentions: [ClaudeRetentionStatus]) {
        guard isStarted, body == .loading else { return }
        // Consent may have been recorded while the probe ran: the card would offer choices
        // `enable` ignores.
        let status = services.control.status
        guard status.isStateLoaded, !status.hasConsented else {
            resolveBody(status: status)
            return
        }
        if sources.contains(where: \.isFound) {
            consent = makeConsent(from: sources, retentions: retentions)
            body = .consent
        } else {
            body = .noAgents(checkedPaths: sources.flatMap(\.checkedPaths))
        }
    }

    func updateTheme(_ zenttyTheme: ZenttyTheme) {
        theme = AgentHistoryTheme(zenttyTheme: zenttyTheme)
    }

    func requestQueryFocus() {
        queryFocusRequest &+= 1
    }

    // MARK: - Query and scope

    func updateQuery(_ raw: String) {
        guard raw != query else { return }
        query = raw
        isShowingIndexProgress = false
        parsedQuery = HistoryQueryParser.parse(raw)
        pills = AgentHistoryFilterPill.pills(for: parsedQuery)
        closeDetailForNewResults()
        runSearch(resetSelection: true)
    }

    func clearQuery() {
        updateQuery("")
    }

    /// Forgets the query without searching, for a body that lists nothing.
    func resetQuery() {
        query = ""
        parsedQuery = HistoryQueryParser.parse("")
        pills = []
    }

    var canToggleScope: Bool { projectScope != nil }

    /// ⇥: project ↔ all projects. Reruns both tiers.
    func toggleScope() {
        guard let projectScope else { return }
        scope = scope == .all ? .project(projectScope) : .all
        closeDetailForNewResults()
        runSearch(resetSelection: true)
    }

    var searchContext: HistorySearchContext {
        HistorySearchContext(scope: scope, currentRepositoryKey: context.currentProject?.key, now: services.now())
    }

    // MARK: - Selection

    var rows: [AgentHistoryResultRow] { sections.flatMap(\.rows) }

    var selectedRow: AgentHistoryResultRow? {
        guard let selectedKey else { return nil }
        return rows.first { $0.key == selectedKey }
    }

    func select(_ key: AgentHistorySessionKey) {
        guard key != selectedKey, rows.contains(where: { $0.key == key }) else { return }
        selectedKey = key
        selectionDidChange()
    }

    func moveSelection(by delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let current = selectedKey.flatMap { key in rows.firstIndex { $0.key == key } } ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(current + delta, 0), rows.count - 1)
        guard rows[next].key != selectedKey else { return }
        selectedKey = rows[next].key
        selectionDidChange()
    }

    // MARK: - Detail

    /// → / ⌘Y. Wide: preview ↔ transcript. Compact: list → preview → transcript → preview.
    func toggleTranscript() {
        guard selectedRow != nil else { return }
        switch detail {
        case .transcript:
            detail = isCompact ? .preview : .none
            cancelTranscript()
        case .preview:
            detail = .transcript
            loadTranscript()
        case .none:
            if isCompact {
                detail = .preview
            } else {
                detail = .transcript
                loadTranscript()
            }
        }
    }

    /// ← and the escape ladder: one level back. Returns false when nothing was open.
    @discardableResult
    func closeDetail() -> Bool {
        switch detail {
        case .none:
            return false
        case .preview:
            detail = .none
        case .transcript:
            detail = isCompact ? .preview : .none
            cancelTranscript()
        }
        return true
    }

    private var isCompact: Bool { layout?.isCompact == true }

    func closeDetailForNewResults() {
        detail = .none
        cancelTranscript()
    }

    private func cancelTranscript() {
        transcriptToken?.cancel()
        transcriptToken = nil
        transcript = .idle
    }

    /// Called after every rebuild and selection change: reloads the preview (and the transcript
    /// when shown) 60 ms after the last change. The header renders from the row meanwhile.
    func selectionDidChange() {
        detailDebounceToken?.cancel()
        previewToken?.cancel()
        previewToken = nil
        if detail == .transcript {
            transcriptToken?.cancel()
            transcriptToken = nil
        }
        detailGeneration &+= 1

        guard let row = selectedRow else {
            preview = .idle
            closeDetailForNewResults()
            return
        }
        guard let sessionID = row.sessionID else {
            preview = .failed(.notIndexed)
            if detail == .transcript { transcript = .failed(.notIndexed) }
            return
        }
        if case .loaded(let current) = preview, current.session.id == sessionID {
            // Same session: keep its turns visible while they reload for the new query.
        } else {
            preview = .loading
        }
        if detail == .transcript { transcript = .loading }
        let key = row.key
        detailDebounceToken = scheduler.schedule(after: Self.detailCoalesce) { [weak self] in
            self?.loadDetail(sessionID: sessionID, key: key)
        }
    }

    private func loadDetail(sessionID: Int64, key: AgentHistorySessionKey) {
        detailDebounceToken = nil
        let generation = detailGeneration
        let query = parsedQuery
        previewToken = services.search.loadPreview(sessionID, expecting: key, query: query) { [weak self] result in
            guard let self, self.detailGeneration == generation else { return }
            self.previewToken = nil
            if let value = Self.loadable(result) {
                self.preview = value
            }
        }
        if detail == .transcript {
            loadTranscript(sessionID: sessionID, key: key, generation: generation)
        }
    }

    /// Loads the selected session's transcript now (opening the transcript).
    private func loadTranscript() {
        transcriptToken?.cancel()
        transcriptToken = nil
        guard let row = selectedRow else { return }
        guard let sessionID = row.sessionID else {
            transcript = .failed(.notIndexed)
            return
        }
        transcript = .loading
        loadTranscript(sessionID: sessionID, key: row.key, generation: detailGeneration)
    }

    private func loadTranscript(sessionID: Int64, key: AgentHistorySessionKey, generation: UInt64) {
        transcriptToken?.cancel()
        let query = parsedQuery
        transcriptToken = services.search.loadTranscript(sessionID, expecting: key, query: query) { [weak self] result in
            guard let self, self.detailGeneration == generation, self.detail == .transcript else { return }
            self.transcriptToken = nil
            if let value = Self.loadable(result) {
                self.transcript = value
            }
        }
    }

    /// nil for a cancellation (a newer load is on its way).
    private static func loadable<Value>(_ result: Result<Value, Error>) -> Loadable<Value>? {
        switch result {
        case .success(let value):
            return .loaded(value)
        case .failure(let error as HistorySearchError):
            switch error {
            case .cancelled: return nil
            case .sessionNotFound: return .failed(.sessionNotFound)
            case .indexUnavailable: return .failed(.failed)
            }
        case .failure:
            return .failed(.failed)
        }
    }

    func applyLive(_ row: AgentHistoryResultRow) -> AgentHistoryResultRow {
        var row = row
        row.live = liveSnapshot.primaryLocation(for: row.key)
        return row
    }
}
