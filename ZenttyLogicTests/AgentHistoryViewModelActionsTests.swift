import AppKit
import Combine
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryViewModelActionsTests: XCTestCase {
    private let nowMs: Int64 = 1_800_000_000_000
    private let cwd = "/tmp/agent-history-tests/zentty"
    private var control: FakeAgentHistoryControl!
    private var search: FakeAgentHistorySearch!
    private var launch: FakeAgentHistoryLaunch!
    private var scheduler: ManualAgentHistoryScheduler!
    private var pasteboard: NSPasteboard!
    private var existingPaths: Set<String> = []
    private var revealedURLs: [URL] = []
    private var closeRequests: [Bool] = []
    private var settingsRequests = 0

    override func setUp() {
        super.setUp()
        control = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = .watching
        status.indexedSessions = 3
        status.tokenizer = .trigram
        status.revision = 1
        control.status = status
        search = FakeAgentHistorySearch()
        launch = FakeAgentHistoryLaunch()
        launch.availability = { .available(Self.plan(for: $0)) }
        scheduler = ManualAgentHistoryScheduler()
        existingPaths = []
        revealedURLs = []
        closeRequests = []
        settingsRequests = 0
    }


    // MARK: - Fixtures

    private func summary(_ id: Int64, transcriptPath: String? = nil) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "/tmp/agent-history-tests/root", agent: .codex,
            nativeID: "native-\(id)", title: "Session \(id)", titleKind: .generated,
            cwd: cwd, transcriptPath: transcriptPath,
            createdAtMs: nowMs - 100_000, updatedAtMs: nowMs - id * 1000, turnCount: 4
        )
    }

    private nonisolated static func plan(for source: AgentHistoryResumeSource) -> AgentHistoryResumePlan {
        AgentHistoryResumePlan(
            agent: source.agent,
            sessionID: source.nativeSessionID,
            command: "codex resume \(source.nativeSessionID)",
            environment: [:]
        )
    }

    private func liveLocation(_ key: AgentHistorySessionKey) -> LiveAgentSessionLocation {
        LiveAgentSessionLocation(
            key: key, windowID: WindowID("window"), worklaneID: WorklaneID("worklane"), paneID: PaneID("pane"),
            tool: .codex, rawSessionID: key.nativeID, pid: 42, paneDisplayName: "Fix sidebar",
            worklaneDisplayName: "zentty", windowTitle: "Zentty", workingDirectory: cwd,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), matchSource: .status
        )
    }

    private func makeModel() -> AgentHistoryViewModel {
        let pasteboard = AgentHistoryTestPasteboard.make()
        self.pasteboard = pasteboard
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: launch,
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { completion in
                completion(ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                ))
            },
            raiseClaudeRetention: { $0(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: pasteboard,
            revealInFinder: { [weak self] in self?.revealedURLs.append($0) },
            fileExists: { [existingPaths] in existingPaths.contains($0) },
            now: { [nowMs] in Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }
        )
        let context = AgentHistoryOpenContext(
            entryPoint: .shortcutOrMenu,
            currentProject: nil,
            initialScope: .all,
            hostWindowID: WindowID("window")
        )
        let model = AgentHistoryViewModel(
            context: context,
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: scheduler,
            formatting: AgentHistoryFormatting(locale: Locale(identifier: "en_US"))
        )
        model.onRequestClose = { [weak self] restoreFocus in self?.closeRequests.append(restoreFocus) }
        model.onRequestSettings = { [weak self] in self?.settingsRequests += 1 }
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// A started model showing "Recent" with sessions 1–3, session 1 selected.
    private func startedModel(recent: [AgentHistorySessionSummary]? = nil) -> AgentHistoryViewModel {
        search.recent = recent ?? [summary(1), summary(2), summary(3)]
        search.sessionCount = search.recent.count
        let model = makeModel()
        model.start()
        return model
    }

    // MARK: - Escape and launching

    func test_escape_ladder_sheet_then_transcript_then_query_then_close() {
        search.metadataResults = { _ in
            [HistoryMetadataResult(session: self.summary(1), score: 1, isWordLevel: true, titleHighlights: [], note: nil)]
        }
        let model = startedModel()
        model.updateQuery("session")
        model.handle(.toggleTranscript)
        XCTAssertEqual(model.detail, .transcript)
        launch.outcome = .needsFolderChoice(options: [.homeFolder("/tmp/agent-history-tests/home"), .copyResumeCommand],
                                            defaultChoice: .homeFolder("/tmp/agent-history-tests/home"))
        model.handle(.primary)
        XCTAssertNotNil(model.folderSheet)

        model.handle(.escape)
        XCTAssertNil(model.folderSheet, "the sheet closes first")
        XCTAssertEqual(model.detail, .transcript)
        model.handle(.escape)
        XCTAssertEqual(model.detail, .none, "then the transcript")
        XCTAssertEqual(model.query, "session")
        model.handle(.escape)
        XCTAssertEqual(model.query, "", "then the query")
        XCTAssertTrue(closeRequests.isEmpty)
        model.handle(.escape)
        XCTAssertEqual(closeRequests, [true], "then the palette, restoring focus")
    }

    func test_primary_and_secondary_pass_intent_to_launcher() {
        launch.outcome = .failed(message: "No.", offerCopySessionID: false)
        let model = startedModel()

        model.handle(.primary)
        model.handle(.moveSelection(1))
        model.handle(.secondary)

        XCTAssertEqual(launch.launches.map(\.intent), [.primary, .secondary])
        XCTAssertEqual(launch.launches.map(\.source), [
            AgentHistoryResumeSource(summary: summary(1)),
            AgentHistoryResumeSource(summary: summary(2)),
        ])
        XCTAssertEqual(launch.launches.map(\.folderChoice), [nil, nil])
    }

    func test_successful_launch_requests_close_without_focus_restore_and_never_records_open() {
        let model = startedModel()
        launch.outcome = .recreatingWorktree
        model.handle(.primary)
        XCTAssertEqual(closeRequests, [false])

        let live = liveLocation(summary(1).key)
        launch.outcome = .jumped(live)
        model.handle(.primary)
        XCTAssertEqual(closeRequests, [false, false])
        XCTAssertNil(model.transientMessage, "launch outcomes are toasted by the launcher, not the palette")
        XCTAssertTrue(control.removedKeys.isEmpty)
        XCTAssertEqual(control.refreshCount, 0)
    }

    func test_folder_missing_presents_sheet_with_repository_root_default() {
        let root = "/tmp/agent-history-tests/repo"
        launch.outcome = .needsFolderChoice(
            options: [.repositoryRoot(root), .copyResumeCommand],
            defaultChoice: .repositoryRoot(root)
        )
        let model = startedModel()

        model.handle(.secondary)

        let sheet = model.folderSheet
        XCTAssertEqual(sheet?.key, summary(1).key)
        XCTAssertEqual(sheet?.intent, .secondary)
        XCTAssertEqual(sheet?.selectedChoice, .repositoryRoot(root))
        XCTAssertEqual(sheet?.missingPath, cwd)
        XCTAssertEqual(sheet?.agentName, AgentHistoryAgent.codex.displayName)
        XCTAssertTrue(closeRequests.isEmpty)

        model.handle(.sheetMove(1))
        XCTAssertEqual(model.folderSheet?.selectedChoice, .copyResumeCommand)
        model.handle(.sheetMove(-1))
        launch.outcome = .recreatingWorktree
        model.handle(.sheetConfirm)
        XCTAssertNil(model.folderSheet)
        XCTAssertEqual(launch.launches.last?.folderChoice, .repositoryRoot(root))
        XCTAssertEqual(launch.launches.last?.intent, .secondary)
        XCTAssertEqual(closeRequests, [false])
    }

    func test_failed_with_copy_offer_swaps_preview_action() {
        launch.outcome = .failed(message: "This session's ID can't be resumed safely.", offerCopySessionID: true)
        let model = startedModel()
        let key = summary(1).key
        XCTAssertEqual(model.previewPrimaryAction(for: key), .launch)

        model.handle(.primary)

        XCTAssertEqual(model.transientMessage, "Can't resume this session: This session's ID can't be resumed safely.")
        XCTAssertEqual(model.previewPrimaryAction(for: key), .copySessionID)
        XCTAssertTrue(closeRequests.isEmpty)

        model.copySessionID(for: key)
        XCTAssertEqual(pasteboard.string(forType: .string), "native-1")
    }

    // MARK: - Copy, remove, reveal, settings

    func test_copy_resume_command_writes_injected_pasteboard_and_shows_transient_message() {
        existingPaths = [cwd]
        let model = startedModel()

        model.handle(.copyResumeCommand)

        XCTAssertEqual(pasteboard.string(forType: .string), "cd \(cwd) && codex resume native-1")
        XCTAssertEqual(model.transientMessage, "Copied resume command")
        scheduler.advance(by: 2.3)
        XCTAssertNotNil(model.transientMessage)
        scheduler.advance(by: 0.1)
        XCTAssertNil(model.transientMessage, "the message hides after 2.4 s")
    }

    func test_copy_resume_command_for_folder_gone_row_drops_cd() {
        let model = startedModel()
        let gone = expectation(description: "folder-gone keys published")
        let observation = model.$folderGoneKeys
            .first { $0.contains(self.summary(1).key) }
            .sink { _ in gone.fulfill() }
        wait(for: [gone], timeout: 5)
        observation.cancel()

        model.handle(.copyResumeCommand)
        XCTAssertEqual(pasteboard.string(forType: .string), "codex resume native-1", "no `cd` into a folder that's gone")

        pasteboard.clearContents()
        model.perform(.copyResumeCommand, on: summary(2).key)
        XCTAssertEqual(pasteboard.string(forType: .string), "codex resume native-2")
    }

    func test_copy_resume_command_noop_when_unavailable() {
        launch.availability = { _ in .unavailable(reason: "This session's ID can't be resumed safely.") }
        let model = startedModel()
        pasteboard.clearContents()

        model.handle(.copyResumeCommand)

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(model.transientMessage)
        XCTAssertFalse(model.rowMenuItems(for: summary(1).key).contains(.copyResumeCommand))
    }

    func test_remove_from_history_removes_row_and_calls_control() {
        let model = startedModel()
        let removed = summary(1).key

        model.removeFromHistory(removed)

        XCTAssertFalse(model.rows.contains { $0.key == removed })
        XCTAssertEqual(model.rows.map(\.key), [summary(2).key, summary(3).key])
        XCTAssertEqual(control.removedKeys, [removed])
        XCTAssertEqual(model.selectedKey, summary(2).key, "selection moves to the row now at that position")
        XCTAssertEqual(model.transientMessage, "Removed from Agent History. Restore in Settings.")
    }

    func test_reveal_transcript_only_offered_when_path_exists() {
        let present = "/tmp/agent-history-tests/root/present.jsonl"
        existingPaths = [present]
        let model = startedModel(recent: [
            summary(1, transcriptPath: present),
            summary(2, transcriptPath: "/tmp/agent-history-tests/root/missing.jsonl"),
            summary(3),
        ])
        XCTAssertFalse(
            model.rowMenuItems(for: summary(1).key).contains(.revealTranscript),
            "rendering a menu never stats the disk; the check runs on a utility queue"
        )
        let checked = expectation(description: "transcript checks published")
        let observation = model.$transcriptPresentKeys
            .first { !$0.isEmpty }
            .sink { _ in checked.fulfill() }
        wait(for: [checked], timeout: 5)
        observation.cancel()

        XCTAssertTrue(model.rowMenuItems(for: summary(1).key).contains(.revealTranscript))
        XCTAssertFalse(model.rowMenuItems(for: summary(2).key).contains(.revealTranscript))
        XCTAssertFalse(model.rowMenuItems(for: summary(3).key).contains(.revealTranscript))

        model.perform(.revealTranscript, on: summary(1).key)
        model.perform(.revealTranscript, on: summary(2).key)
        XCTAssertEqual(revealedURLs, [URL(fileURLWithPath: present)])
    }

    func test_row_menu_separates_launch_copy_finder_and_remove_groups() {
        let model = startedModel()
        let items = model.rowMenuItems(for: summary(1).key)

        XCTAssertEqual(items, [.resumeInNewWorklane, .openInSplit, .copyResumeCommand, .copySessionID, .removeFromHistory])
        XCTAssertEqual(AgentHistoryRowMenuItem.separatorIndexes(in: items), [2, 4])
        XCTAssertEqual(AgentHistoryRowMenuItem.separatorIndexes(in: AgentHistoryRowMenuItem.allCases), [4, 6, 7])
    }

    func test_live_rows_offer_jump_and_fork_and_launch_from_the_live_pane() throws {
        let liveOnlyKey = AgentHistorySessionKey(agent: .codex, nativeID: "live-only")
        let indexed = summary(1)
        search.summariesByKey = [indexed.key: indexed]
        launch.snapshot = LiveAgentSessionSnapshot(locationsByKey: [
            liveOnlyKey: [liveLocation(liveOnlyKey)],
            indexed.key: [liveLocation(indexed.key)],
        ])
        launch.outcome = .failed(message: "No such pane", offerCopySessionID: false)
        let model = startedModel(recent: [indexed, summary(2)])
        XCTAssertEqual(Set(model.liveKeys), [liveOnlyKey, indexed.key])

        XCTAssertEqual(
            model.rowMenuItems(for: liveOnlyKey),
            [.jumpToPane, .forkIntoSplit, .copyResumeCommand, .copySessionID],
            "a live-only row has nothing to remove or reveal"
        )
        XCTAssertEqual(
            model.rowMenuItems(for: indexed.key),
            [.jumpToPane, .forkIntoSplit, .copyResumeCommand, .copySessionID, .removeFromHistory]
        )

        model.select(liveOnlyKey)
        model.handle(.primary)
        model.handle(.secondary)
        model.perform(.jumpToPane, on: liveOnlyKey)
        model.perform(.forkIntoSplit, on: liveOnlyKey)
        let liveSource = AgentHistoryResumeSource(live: liveLocation(liveOnlyKey))
        XCTAssertEqual(launch.launches.map(\.intent), [.primary, .secondary, .primary, .secondary])
        XCTAssertEqual(launch.launches.map(\.source), Array(repeating: liveSource, count: 4))
        XCTAssertEqual(liveSource.key, liveOnlyKey)
        XCTAssertNil(liveSource.sessionRowID)
        XCTAssertEqual(liveSource.workingDirectory, cwd)

        model.perform(.primary, on: indexed.key)
        XCTAssertEqual(launch.launches.last?.source, AgentHistoryResumeSource(summary: indexed),
                       "an indexed live row launches from its index row")

        let rowsBefore = model.rows.map(\.key)
        model.removeFromHistory(liveOnlyKey)
        model.perform(.removeFromHistory, on: liveOnlyKey)
        XCTAssertEqual(model.rows.map(\.key), rowsBefore, "a live-only row can't be removed")
        XCTAssertTrue(control.removedKeys.isEmpty)
        XCTAssertNotEqual(model.transientMessage, AgentHistoryViewModel.removedMessage)
    }

    func test_problem_link_requests_settings() {
        let model = startedModel()

        model.openProblemLink()

        XCTAssertEqual(settingsRequests, 1)
    }
}
