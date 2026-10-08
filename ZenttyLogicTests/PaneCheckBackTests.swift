import XCTest
@testable import Zentty

@MainActor
final class PaneCheckBackTests: XCTestCase {
    // MARK: - Marking and visiting

    func test_mark_unread_on_unfocused_idle_agent_pane_shows_check_back_until_visited() throws {
        let (store, agentPaneID, _) = try makeStoreWithVisitedIdleAgentPane()

        XCTAssertEqual(store.unreadToggle(for: agentPaneID), .markUnread)
        XCTAssertTrue(store.toggleUnread(paneID: agentPaneID))

        let presentation = try XCTUnwrap(presentation(in: store, agentPaneID))
        XCTAssertTrue(presentation.isCheckBack)
        XCTAssertEqual(presentation.statusText, "Check back")
        XCTAssertEqual(presentation.statusSymbolName, "checkmark.circle.fill")
        XCTAssertEqual(store.unreadToggle(for: agentPaneID), .markRead)

        let worklane = try XCTUnwrap(store.activeWorklane)
        let paneRow = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
            .paneRows.first { $0.paneID == agentPaneID }
        XCTAssertEqual(paneRow?.attentionState, .checkBack)
        XCTAssertEqual(paneRow?.statusText, "Check back")
        XCTAssertEqual(WorklaneAttentionSummaryBuilder.summary(for: worklane)?.state, .checkBack)

        store.focusPane(id: agentPaneID)

        XCTAssertNil(reminder(in: store, agentPaneID))
        XCTAssertEqual(statusText(in: store, agentPaneID), "Idle")
    }

    func test_mark_unread_on_focused_pane_survives_until_focus_leaves_and_returns() throws {
        let (store, agentPaneID, otherPaneID) = try makeStoreWithVisitedIdleAgentPane()
        store.focusPane(id: agentPaneID)

        store.toggleUnread(paneID: agentPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Check back")

        store.focusPane(id: agentPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Check back", "Re-clicking the focused pane is not a new visit")

        store.focusPane(id: otherPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Check back", "Leaving the pane only arms the mark")

        store.focusPane(id: agentPaneID)
        XCTAssertNil(reminder(in: store, agentPaneID))
        XCTAssertEqual(statusText(in: store, agentPaneID), "Idle")
    }

    func test_marking_from_another_worklane_clears_when_that_worklane_is_selected() throws {
        let (store, agentPaneID, _) = try makeStoreWithVisitedIdleAgentPane()
        let agentWorklaneID = store.activeWorklaneID
        _ = store.createWorklane()
        XCTAssertNotEqual(store.activeWorklaneID, agentWorklaneID)

        store.toggleUnread(paneID: agentPaneID)
        XCTAssertEqual(reminder(in: store, agentPaneID)?.hasLeftPane, true)

        store.selectWorklaneAndFocusPane(worklaneID: agentWorklaneID, paneID: agentPaneID)

        XCTAssertNil(reminder(in: store, agentPaneID))
    }

    // MARK: - Clearing without a visit

    func test_check_back_clears_when_agent_starts_working_again() throws {
        let (store, agentPaneID, _) = try makeStoreWithVisitedIdleAgentPane()
        store.toggleUnread(paneID: agentPaneID)

        applyAgentState(.running, in: store, paneID: agentPaneID)
        XCTAssertNil(reminder(in: store, agentPaneID))
        XCTAssertNotEqual(statusText(in: store, agentPaneID), "Check back")

        applyAgentState(.idle, in: store, paneID: agentPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Agent ready", "A finished turn is a real ready, not the old mark")
    }

    func test_mark_read_clears_check_back_without_visiting() throws {
        let (store, agentPaneID, otherPaneID) = try makeStoreWithVisitedIdleAgentPane()
        store.toggleUnread(paneID: agentPaneID)

        store.toggleUnread(paneID: agentPaneID)

        XCTAssertNil(reminder(in: store, agentPaneID))
        XCTAssertEqual(statusText(in: store, agentPaneID), "Idle")
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, otherPaneID)
        XCTAssertEqual(store.unreadToggle(for: agentPaneID), .markUnread)
    }

    func test_mark_read_clears_agent_ready_without_visiting() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let agentPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.send(.splitHorizontally)
        let otherPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        finishAgentTurn(in: store, paneID: agentPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Agent ready")
        XCTAssertEqual(store.unreadToggle(for: agentPaneID), .markRead)

        store.toggleUnread(paneID: agentPaneID)

        XCTAssertEqual(statusText(in: store, agentPaneID), "Idle")
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPaneID, otherPaneID)
    }

    func test_check_back_shows_when_ready_flag_is_hidden_by_incomplete_tasks() {
        var raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "claude",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true,
                taskProgress: PaneAgentTaskProgress(doneCount: 1, totalCount: 3)
            ),
            showsReadyStatus: true
        )
        let unmarked = PanePresentationNormalizer.normalize(paneTitle: "claude", raw: raw, previous: nil)
        XCTAssertFalse(unmarked.isReady, "Incomplete tasks hide Agent ready")
        XCTAssertEqual(PaneUnreadToggle.resolve(for: unmarked), .markUnread)

        raw.checkBackReminder = PaneCheckBackReminder(hasLeftPane: true)
        let marked = PanePresentationNormalizer.normalize(paneTitle: "claude", raw: raw, previous: unmarked)

        XCTAssertTrue(marked.isCheckBack)
        XCTAssertFalse(marked.isReady)
        XCTAssertEqual(marked.statusText, "Check back")
        XCTAssertEqual(PaneUnreadToggle.resolve(for: marked), .markRead)
    }

    // MARK: - Availability

    func test_unread_toggle_is_unavailable_for_shell_and_busy_agent_panes() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertNil(store.unreadToggle(for: paneID), "Plain shell panes cannot be marked")
        XCTAssertFalse(store.toggleUnread(paneID: paneID))

        applyAgentState(.running, in: store, paneID: paneID)
        XCTAssertNil(store.unreadToggle(for: paneID), "A working agent cannot be marked")
    }

    func test_command_availability_and_palette_title_follow_focused_pane_toggle() {
        func context(_ toggle: PaneUnreadToggle?) -> CommandAvailabilityContext {
            CommandAvailabilityContext(
                worklaneCount: 1,
                activePaneCount: 1,
                totalPaneCount: 1,
                activeColumnCount: 1,
                focusedColumnPaneCount: 1,
                focusedPaneHasRememberedSearch: false,
                globalSearchHasRememberedSearch: false,
                activeWorklaneHasBranchURL: false,
                focusedPaneUnreadToggle: toggle
            )
        }
        XCTAssertFalse(CommandAvailabilityResolver.isCommandAvailable(.toggleFocusedPaneUnread, for: context(nil)))
        XCTAssertTrue(CommandAvailabilityResolver.isCommandAvailable(.toggleFocusedPaneUnread, for: context(.markUnread)))

        func paletteItem(_ toggle: PaneUnreadToggle) -> CommandPaletteItem? {
            CommandPaletteItemBuilder.buildItems(
                availableCommandIDs: [.toggleFocusedPaneUnread],
                shortcutManager: ShortcutManager(shortcuts: .default),
                focusedPaneUnreadToggle: toggle
            ).first
        }
        XCTAssertEqual(paletteItem(.markUnread)?.title, "Mark as Unread")
        XCTAssertEqual(paletteItem(.markUnread)?.shortcutDisplay, "⌘U")
        XCTAssertEqual(paletteItem(.markRead)?.title, "Mark as Read")
        XCTAssertEqual(paletteItem(.markRead)?.iconSystemName, "envelope.open")
    }

    // MARK: - Notifications

    func test_check_back_adds_bell_entry_without_system_notification_and_visit_resolves_it() throws {
        let (store, agentPaneID, _) = try makeStoreWithVisitedIdleAgentPane()
        let center = RecordingNotificationCenter()
        let notificationStore = NotificationStore()
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: center,
            notificationStore: notificationStore
        )
        let windowID = WindowID("window-main")
        let update = {
            coordinator.update(
                windowID: windowID,
                worklanes: store.worklanes,
                activeWorklaneID: store.activeWorklaneID,
                windowIsKey: true
            )
        }
        update()

        store.toggleUnread(paneID: agentPaneID)
        update()

        XCTAssertEqual(center.requestCount, 0, "Marking must not post a banner or play a sound")
        let entry = try XCTUnwrap(notificationStore.mostUrgentUnresolved())
        XCTAssertEqual(entry.paneID, agentPaneID)
        XCTAssertEqual(entry.state, .checkBack)
        XCTAssertEqual(entry.statusText, "Check back")

        store.focusPane(id: agentPaneID)
        update()

        XCTAssertNil(notificationStore.mostUrgentUnresolved())
        XCTAssertEqual(center.requestCount, 0)
    }

    // MARK: - Helpers

    /// Two panes, an agent on the first one that finished a turn while
    /// unfocused, then got visited (so "Agent ready" is gone). Focus ends on
    /// the second pane.
    private func makeStoreWithVisitedIdleAgentPane() throws -> (WorklaneStore, PaneID, PaneID) {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let agentPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        store.send(.splitHorizontally)
        let otherPaneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertNotEqual(agentPaneID, otherPaneID)

        finishAgentTurn(in: store, paneID: agentPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Agent ready")
        store.focusPane(id: agentPaneID)
        store.focusPane(id: otherPaneID)
        XCTAssertEqual(statusText(in: store, agentPaneID), "Idle")
        return (store, agentPaneID, otherPaneID)
    }

    private func finishAgentTurn(in store: WorklaneStore, paneID: PaneID) {
        applyAgentState(.running, in: store, paneID: paneID)
        applyAgentState(.idle, in: store, paneID: paneID)
    }

    private func applyAgentState(_ state: PaneAgentState, in store: WorklaneStore, paneID: PaneID) {
        let worklaneID = store.worklanes.first { $0.paneStripState.panes.contains { $0.id == paneID } }?.id
            ?? store.activeWorklaneID
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                state: state,
                origin: state == .running ? .explicitHook : .explicitAPI,
                toolName: "Codex",
                text: nil,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
    }

    private func presentation(in store: WorklaneStore, _ paneID: PaneID) -> PanePresentationState? {
        store.worklanes.lazy.compactMap { $0.auxiliaryStateByPaneID[paneID]?.presentation }.first
    }

    private func statusText(in store: WorklaneStore, _ paneID: PaneID) -> String? {
        presentation(in: store, paneID)?.statusText
    }

    private func reminder(in store: WorklaneStore, _ paneID: PaneID) -> PaneCheckBackReminder? {
        store.worklanes.lazy.compactMap { $0.auxiliaryStateByPaneID[paneID]?.raw.checkBackReminder }.first
    }
}

@MainActor
private final class RecordingNotificationCenter: WorklaneAttentionUserNotificationCenter {
    private(set) var requestCount = 0

    func requestAuthorizationIfNeeded() {}

    func add(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String?
    ) {
        requestCount += 1
    }
}
