import AppKit

/// One entry in a row's context menu, in display order.
enum AgentHistoryRowMenuItem: Equatable, CaseIterable {
    case resumeInNewWorklane
    case openInSplit
    case jumpToPane
    case forkIntoSplit
    case copyResumeCommand
    case copySessionID
    case revealTranscript
    case removeFromHistory

    var title: String {
        switch self {
        case .resumeInNewWorklane: "Resume in New Worklane"
        case .openInSplit: "Open in Split"
        case .jumpToPane: "Jump to Pane"
        case .forkIntoSplit: "Fork into Split"
        case .copyResumeCommand: "Copy Resume Command"
        case .copySessionID: "Copy Session ID"
        case .revealTranscript: "Reveal Transcript in Finder"
        case .removeFromHistory: "Remove from Agent History"
        }
    }

    var isDestructive: Bool { self == .removeFromHistory }

    /// Items of one group sit together; the menu puts a separator between groups.
    var group: Int {
        switch self {
        case .resumeInNewWorklane, .openInSplit, .jumpToPane, .forkIntoSplit: 0
        case .copyResumeCommand, .copySessionID: 1
        case .revealTranscript: 2
        case .removeFromHistory: 3
        }
    }

    var systemImage: String {
        switch self {
        case .resumeInNewWorklane: "arrow.uturn.forward"
        case .openInSplit: "rectangle.split.2x1"
        case .jumpToPane: "arrow.right.circle"
        case .forkIntoSplit: "arrow.triangle.branch"
        case .copyResumeCommand: "terminal"
        case .copySessionID: "doc.on.doc"
        case .revealTranscript: "folder"
        case .removeFromHistory: "trash"
        }
    }

    /// Indexes in `items` that get a separator before them.
    static func separatorIndexes(in items: [AgentHistoryRowMenuItem]) -> Set<Int> {
        Set(items.indices.dropFirst().filter { items[$0].group != items[$0 - 1].group })
    }
}

/// What the preview's primary button does for a session.
enum AgentHistoryPreviewPrimaryAction: Equatable {
    /// Resume (ended) or jump to the pane (live).
    case launch
    /// The last resume failed and offered the session ID instead.
    case copySessionID
}

/// Launching, copying, removing and the escape ladder. The launcher records opens and toasts
/// launch outcomes (A-20); the palette only closes or shows an in-panel transient message.
extension AgentHistoryViewModel {
    static let transientMessageDuration: TimeInterval = 2.4
    static let copiedResumeCommandMessage = "Copied resume command"
    static let copiedSessionIDMessage = "Copied session ID"
    static let removedMessage = "Removed from Agent History. Restore in Settings."
    static let removeFailedMessage = "Couldn't remove this session from Agent History right now."

    // MARK: - Keyboard

    /// Runs a key command from the panel's key monitor.
    func handle(_ command: AgentHistoryKeyCommand) {
        switch command {
        case .moveSelection(let delta):
            moveSelection(by: delta)
        case .primary:
            performSelected(.primary)
        case .secondary:
            performSelected(.secondary)
        case .toggleTranscript:
            toggleTranscript()
        case .closeTranscript:
            closeDetail()
        case .toggleScope:
            toggleScope()
        case .escape:
            escape()
        case .copyResumeCommand:
            if let selectedKey {
                copyResumeCommand(for: selectedKey)
            }
        case .closePalette:
            onRequestClose?(true)
        case .sheetMove(let delta):
            folderSheet?.move(delta)
        case .sheetConfirm:
            confirmFolderSheet()
        case .sheetCancel:
            cancelFolderSheet()
        case .consentConfirm:
            confirmConsent()
        }
    }

    /// esc: close the sheet, then the transcript (or compact preview), then clear the query,
    /// then close the palette.
    func escape() {
        if folderSheet != nil {
            folderSheet = nil
        } else if isShowingIndexProgress {
            isShowingIndexProgress = false
        } else if closeDetail() {
            return
        } else if !query.isEmpty {
            clearQuery()
        } else {
            onRequestClose?(true)
        }
    }

    // MARK: - Launching

    func performSelected(_ intent: AgentHistoryLaunchIntent) {
        // The selected row is hidden behind the details: ↩ goes back rather than resume it.
        guard !isShowingIndexProgress else {
            isShowingIndexProgress = false
            return
        }
        guard let selectedKey else { return }
        perform(intent, on: selectedKey)
    }

    func perform(_ intent: AgentHistoryLaunchIntent, on key: AgentHistorySessionKey) {
        guard let source = resumeSource(for: key) else { return }
        perform(intent, source: source, folderChoice: nil)
    }

    private func perform(
        _ intent: AgentHistoryLaunchIntent,
        source: AgentHistoryResumeSource,
        folderChoice: AgentHistoryFolderChoice?
    ) {
        let outcome = services.launch.launch(source, intent: intent, folderChoice: folderChoice)
        if outcome.closesPalette {
            folderSheet = nil
            onRequestClose?(false)
            return
        }
        switch outcome {
        case .needsFolderChoice(let options, let defaultChoice):
            folderSheet = AgentHistoryFolderGoneSheetModel.make(
                source: source,
                intent: intent,
                options: options,
                defaultChoice: defaultChoice
            )
        case .failed(let message, let offerCopySessionID):
            folderSheet = nil
            if offerCopySessionID {
                copySessionIDOfferKeys.insert(source.key)
            }
            showTransientMessage(Self.launchFailedMessage(message))
        case .jumped, .forked, .resumed, .recreatingWorktree:
            break
        }
    }

    /// ↩ on the folder-gone sheet: copy the command, or resume where the user picked.
    func confirmFolderSheet() {
        guard let sheet = folderSheet else { return }
        folderSheet = nil
        if sheet.selectedChoice == .copyResumeCommand {
            // The folder is gone, so the copied command carries no `cd`.
            copyResumeCommand(source: sheet.source, workingDirectory: nil)
        } else {
            perform(sheet.intent, source: sheet.source, folderChoice: sheet.selectedChoice)
        }
    }

    /// A click on a sheet option; a double click also confirms it.
    func selectFolderSheetOption(_ index: Int, confirm: Bool = false) {
        folderSheet?.select(index)
        if confirm, folderSheet?.selectedIndex == index {
            confirmFolderSheet()
        }
    }

    /// esc or Cancel on the sheet: nothing launches, the palette stays.
    func cancelFolderSheet() {
        folderSheet = nil
    }

    static func launchFailedMessage(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("…") ? trimmed : trimmed + "."
        return "Can't resume this session: \(sentence)"
    }

    /// The indexed session when there is one, else the live pane's session (A-12).
    func resumeSource(for key: AgentHistorySessionKey) -> AgentHistoryResumeSource? {
        guard let row = rows.first(where: { $0.key == key }) else { return nil }
        if let summary = row.summary {
            return AgentHistoryResumeSource(summary: summary)
        }
        return row.live.map(AgentHistoryResumeSource.init(live:))
    }

    func resumeAvailability(for key: AgentHistorySessionKey) -> AgentHistoryResumeAvailability? {
        resumeSource(for: key).map { services.launch.resumePlan(for: $0) }
    }

    func previewPrimaryAction(for key: AgentHistorySessionKey) -> AgentHistoryPreviewPrimaryAction {
        copySessionIDOfferKeys.contains(key) ? .copySessionID : .launch
    }

    // MARK: - Copying

    /// ⌘C and "Copy Resume Command". Does nothing when no command can be built. A row whose
    /// folder is gone copies no `cd`, like the folder sheet: a failing `cd` would stop the `&&`.
    func copyResumeCommand(for key: AgentHistorySessionKey) {
        guard let source = resumeSource(for: key) else { return }
        let workingDirectory = folderGoneKeys.contains(key) ? nil : source.workingDirectory
        copyResumeCommand(source: source, workingDirectory: workingDirectory)
    }

    private func copyResumeCommand(source: AgentHistoryResumeSource, workingDirectory: String?) {
        guard case .available(let plan) = services.launch.resumePlan(for: source) else { return }
        writeToPasteboard(plan.copyText(workingDirectory: workingDirectory))
        showTransientMessage(Self.copiedResumeCommandMessage)
    }

    func copySessionID(for key: AgentHistorySessionKey) {
        guard let source = resumeSource(for: key) else { return }
        writeToPasteboard(source.nativeSessionID)
        showTransientMessage(Self.copiedSessionIDMessage)
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = services.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Row menu

    func rowMenuItems(for key: AgentHistorySessionKey) -> [AgentHistoryRowMenuItem] {
        guard let row = rows.first(where: { $0.key == key }) else { return [] }
        var items: [AgentHistoryRowMenuItem] = row.live != nil
            ? [.jumpToPane, .forkIntoSplit]
            : [.resumeInNewWorklane, .openInSplit]
        if case .available = resumeAvailability(for: key) {
            items.append(.copyResumeCommand)
        }
        items.append(.copySessionID)
        if transcriptPresentKeys.contains(key) {
            items.append(.revealTranscript)
        }
        if row.summary != nil {
            items.append(.removeFromHistory)
        }
        return items
    }

    func perform(_ item: AgentHistoryRowMenuItem, on key: AgentHistorySessionKey) {
        switch item {
        case .resumeInNewWorklane, .jumpToPane:
            perform(.primary, on: key)
        case .openInSplit, .forkIntoSplit:
            perform(.secondary, on: key)
        case .copyResumeCommand:
            copyResumeCommand(for: key)
        case .copySessionID:
            copySessionID(for: key)
        case .revealTranscript:
            if let row = rows.first(where: { $0.key == key }), let url = transcriptURL(for: row) {
                services.revealInFinder(url)
            }
        case .removeFromHistory:
            removeFromHistory(key)
        }
    }

    /// Only sources with a transcript file that still exists; re-checked at click time.
    private func transcriptURL(for row: AgentHistoryResultRow) -> URL? {
        guard let path = row.summary?.transcriptPath, !path.isEmpty, services.fileExists(path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Drops the row at once and tombstones the session; it can be restored in Settings. The
    /// index can refuse (standing by, disk full): the row then comes back and the message says so.
    func removeFromHistory(_ key: AgentHistorySessionKey) {
        let currentRows = rows
        guard let index = currentRows.firstIndex(where: { $0.key == key }), currentRows[index].summary != nil else {
            return
        }
        sections = sections.compactMap { section in
            var section = section
            section.rows.removeAll { $0.key == key }
            return section.rows.isEmpty ? nil : section
        }
        copySessionIDOfferKeys.remove(key)
        if folderSheet?.key == key {
            folderSheet = nil
        }
        if selectedKey == key {
            selectedKey = AgentHistoryResultMerger.resolveSelection(previous: nil, previousIndex: index, in: rows)
            selectionDidChange()
        }
        refreshFolderGoneKeys()
        // Last: the answer can come back synchronously and rebuild the rows.
        services.control.removeSession(key) { [weak self] removed in
            self?.removalCompleted(removed: removed)
        }
    }

    /// The palette may have closed (`stop` keeps the body) or lost access since the drop.
    private func removalCompleted(removed: Bool) {
        guard isStarted, body == .results else { return }
        guard removed else {
            showTransientMessage(Self.removeFailedMessage)
            // Nothing was published, so this finds the row where it was.
            runSearch(resetSelection: false)
            return
        }
        showTransientMessage(Self.removedMessage)
    }

    // MARK: - Footer and messages

    /// The amber footer link: Settings › Agent History.
    func openProblemLink() {
        onRequestSettings?()
    }

    func showTransientMessage(_ message: String) {
        transientMessageToken?.cancel()
        transientMessage = message
        transientMessageToken = scheduler.schedule(after: Self.transientMessageDuration) { [weak self] in
            self?.transientMessage = nil
            self?.transientMessageToken = nil
        }
    }
}
