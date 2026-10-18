import UserNotifications
import XCTest
@testable import Zentty

@MainActor
final class AgentNotificationReplyTests: XCTestCase {
    private let windowID = WindowID("window-main")
    private let worklaneID = WorklaneID("worklane-main")
    private let paneID = PaneID("worklane-main-agent")

    // MARK: - Policy

    func test_typed_reply_is_accepted_for_a_finished_turn_while_the_agent_owns_the_pane() {
        for shell in [PaneShellActivityState.commandRunning, .unknown] {
            XCTAssertTrue(
                AgentNotificationReplyPolicy.acceptsTypedReply(state: .ready, shellActivityState: shell),
                "shell \(shell.rawValue)"
            )
        }
        XCTAssertTrue(AgentNotificationReplyPolicy.acceptsTypedReply(state: .ready, shellActivityState: nil))
    }

    func test_typed_reply_is_refused_once_the_shell_is_back_at_its_prompt() {
        XCTAssertFalse(AgentNotificationReplyPolicy.acceptsTypedReply(state: .ready, shellActivityState: .promptIdle))
    }

    func test_typed_reply_is_refused_for_an_agent_that_stopped_early() {
        // unresolvedStop means the agent process went away mid-turn.
        XCTAssertFalse(AgentNotificationReplyPolicy.acceptsTypedReply(state: .unresolvedStop, shellActivityState: .unknown))
    }

    func test_typed_reply_is_refused_for_every_needs_input_prompt() {
        // Questions included: pickers and approval menus are reported as
        // questions too, and the trailing Return would pick an option.
        XCTAssertFalse(AgentNotificationReplyPolicy.acceptsTypedReply(state: .needsInput, shellActivityState: .commandRunning))
        XCTAssertFalse(AgentNotificationReplyPolicy.acceptsTypedReply(state: .running, shellActivityState: .commandRunning))
        XCTAssertFalse(AgentNotificationReplyPolicy.acceptsTypedReply(state: .checkBack, shellActivityState: .commandRunning))
    }

    func test_reply_is_not_offered_when_setting_is_off() {
        XCTAssertTrue(AgentNotificationReplyPolicy.offersReply(
            state: .ready, shellActivityState: .commandRunning, isInlineReplyEnabled: true
        ))
        XCTAssertFalse(AgentNotificationReplyPolicy.offersReply(
            state: .ready, shellActivityState: .commandRunning, isInlineReplyEnabled: false
        ))
    }

    func test_category_identifier_follows_reply_offer() {
        XCTAssertEqual(
            AgentNotificationReplyPolicy.categoryIdentifier(offersReply: true),
            AgentNotificationIdentifiers.Category.attentionWithReply
        )
        XCTAssertEqual(
            AgentNotificationReplyPolicy.categoryIdentifier(offersReply: false),
            AgentNotificationIdentifiers.Category.attention
        )
    }

    func test_categories_register_plain_and_reply_variants() throws {
        let categories = AgentNotificationReplyPolicy.makeCategories()
        XCTAssertEqual(categories.count, 2)

        let plain = try XCTUnwrap(categories.first { $0.identifier == AgentNotificationIdentifiers.Category.attention })
        XCTAssertEqual(
            plain.actions.map(\.identifier),
            [AgentNotificationIdentifiers.Action.jump, AgentNotificationIdentifiers.Action.dismiss]
        )
        XCTAssertFalse(plain.actions.contains { $0 is UNTextInputNotificationAction })

        let reply = try XCTUnwrap(categories.first { $0.identifier == AgentNotificationIdentifiers.Category.attentionWithReply })
        XCTAssertEqual(
            reply.actions.map(\.identifier),
            [
                AgentNotificationIdentifiers.Action.reply,
                AgentNotificationIdentifiers.Action.jump,
                AgentNotificationIdentifiers.Action.dismiss,
            ]
        )
        let replyAction = try XCTUnwrap(reply.actions.first as? UNTextInputNotificationAction)
        XCTAssertFalse(replyAction.options.contains(.foreground), "replying must not pull Zentty forward")
    }

    // MARK: - Staleness guard

    func test_guard_delivers_when_token_and_state_still_match() {
        XCTAssertEqual(decide(currentState: .ready), .deliver)
        XCTAssertEqual(decide(currentState: .ready, shellActivityState: .unknown), .deliver)
    }

    func test_guard_refuses_missing_pane() {
        XCTAssertEqual(decide(paneExists: false, currentState: .ready), .stale(.paneGone))
    }

    func test_guard_refuses_banners_raised_before_the_setting_was_turned_off() {
        XCTAssertEqual(decide(isInlineReplyEnabled: false, currentState: .ready), .stale(.replyDisabled))
    }

    func test_guard_refuses_notification_without_token() {
        XCTAssertEqual(decide(notificationToken: nil, currentState: .ready), .stale(.missingToken))
        XCTAssertEqual(decide(notificationToken: "", currentState: .ready), .stale(.missingToken))
    }

    func test_guard_refuses_pane_without_agent() {
        XCTAssertEqual(decide(currentState: nil), .stale(.agentGone))
    }

    func test_guard_never_types_into_a_running_agent_even_with_matching_token() {
        XCTAssertEqual(decide(currentState: .running), .stale(.agentRunning))
    }

    func test_guard_never_types_into_the_shell_after_the_agent_exited() {
        XCTAssertEqual(decide(currentState: .ready, shellActivityState: .promptIdle), .stale(.agentExited))
        XCTAssertEqual(decide(currentState: .unresolvedStop, shellActivityState: .promptIdle), .stale(.agentExited))
    }

    func test_guard_refuses_states_that_take_no_typed_reply() {
        XCTAssertEqual(decide(currentState: .unresolvedStop), .stale(.notReplyable))
        XCTAssertEqual(decide(currentState: .needsInput), .stale(.notReplyable))
    }

    func test_guard_refuses_when_attention_changed_since_notification() {
        XCTAssertEqual(
            decide(currentToken: "token-new", currentState: .ready),
            .stale(.attentionChanged)
        )
        XCTAssertEqual(
            decide(currentToken: nil, currentState: .ready),
            .stale(.attentionChanged)
        )
    }

    // MARK: - Delivery decision on live state

    func test_reply_to_a_ready_pane_is_delivered_with_the_coordinators_token() throws {
        let coordinator = makeCoordinator()
        let ready = readyWorklane()
        updateCoordinator(coordinator, worklane: ready)
        let token = try XCTUnwrap(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))

        XCTAssertEqual(decideLive(ready, coordinator: coordinator, token: token), .deliver)
        XCTAssertEqual(
            decideLive(ready, coordinator: coordinator, token: "other-token"),
            .stale(.attentionChanged)
        )
    }

    func test_reply_types_nothing_once_the_agent_started_another_turn() throws {
        let coordinator = makeCoordinator()
        updateCoordinator(coordinator, worklane: readyWorklane())
        let token = try XCTUnwrap(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))

        let running = worklane(status: agentStatus(state: .running, updatedAt: 200))
        updateCoordinator(coordinator, worklane: running)
        XCTAssertEqual(decideLive(running, coordinator: coordinator, token: token), .stale(.agentRunning))

        let readyAgain = readyWorklane(updatedAt: 300)
        updateCoordinator(coordinator, worklane: readyAgain)
        XCTAssertEqual(decideLive(readyAgain, coordinator: coordinator, token: token), .stale(.attentionChanged))
    }

    func test_reply_types_nothing_after_the_agent_exited_to_the_shell() throws {
        let coordinator = makeCoordinator()
        updateCoordinator(coordinator, worklane: readyWorklane())
        let token = try XCTUnwrap(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))

        let exited = readyWorklane(shellActivityState: .promptIdle)
        updateCoordinator(coordinator, worklane: exited)

        XCTAssertEqual(decideLive(exited, coordinator: coordinator, token: token), .stale(.agentExited))
    }

    func test_reply_types_nothing_when_the_worklane_is_gone() {
        XCTAssertEqual(
            AgentNotificationReplyGuard.decide(
                worklane: nil,
                paneID: paneID,
                paneExists: true,
                isInlineReplyEnabled: true,
                notificationToken: "token-1",
                currentToken: "token-1"
            ),
            .stale(.paneGone)
        )
    }

    // MARK: - Reply text

    func test_single_line_reply_is_pasted_verbatim() {
        XCTAssertEqual(AgentNotificationReplyText.terminalPaste(for: "yes, go ahead"), "yes, go ahead")
    }

    func test_multi_line_reply_becomes_one_line_so_it_is_submitted_once() {
        let paste = AgentNotificationReplyText.terminalPaste(for: "first line\r\nsecond line\rthird line\n\n  fourth\n")
        XCTAssertEqual(paste, "first line second line third line fourth")
        XCTAssertEqual(paste?.contains("\n"), false, "without bracketed paste every newline would submit")
        XCTAssertEqual(paste?.contains("\r"), false, "the single Return is sent as a key, not pasted")
    }

    func test_reply_strips_escape_and_other_controls() {
        let paste = AgentNotificationReplyText.terminalPaste(for: "ok\u{1B}[201~rm -rf\u{07}\u{7F}\u{9B}\tdone")
        XCTAssertEqual(paste, "ok[201~rm -rf done")
    }

    func test_whitespace_only_reply_is_dropped() {
        XCTAssertNil(AgentNotificationReplyText.terminalPaste(for: ""))
        XCTAssertNil(AgentNotificationReplyText.terminalPaste(for: "  \n\r\n\t "))
        XCTAssertNil(AgentNotificationReplyText.terminalPaste(for: "\u{1B}\u{03}"))
    }

    func test_reply_keeps_unicode_text() {
        XCTAssertEqual(AgentNotificationReplyText.terminalPaste(for: "  ja, doe maar 👍 "), "ja, doe maar 👍")
    }

    // MARK: - Coordinator

    func test_coordinator_offers_reply_for_finished_turn() {
        let recorder = ReplyRecordingNotificationCenter()
        let coordinator = makeCoordinator(center: recorder)

        updateCoordinator(coordinator, worklane: readyWorklane())

        XCTAssertEqual(recorder.requests.count, 1)
        let token = recorder.requests.last?.replyToken
        XCTAssertNotNil(token)
        XCTAssertEqual(token, coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))
    }

    func test_coordinator_keeps_jump_only_when_the_shell_is_back_at_its_prompt() {
        let recorder = ReplyRecordingNotificationCenter()
        let coordinator = makeCoordinator(center: recorder)

        updateCoordinator(coordinator, worklane: readyWorklane(shellActivityState: .promptIdle))

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests.last?.replyToken)
    }

    func test_coordinator_keeps_jump_only_for_agent_that_stopped_early() {
        let recorder = ReplyRecordingNotificationCenter()
        let coordinator = makeCoordinator(center: recorder)

        updateCoordinator(coordinator, worklane: worklane(status: agentStatus(state: .unresolvedStop)))

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests.last?.replyToken)
    }

    func test_coordinator_keeps_jump_only_for_questions_and_approvals() {
        for (kind, text) in [
            (PaneAgentInteractionKind.question, "Which branch should I use?"),
            (.approval, "Allow Bash: rm build/"),
            (.decision, "Pick one: 1. main 2. dev"),
        ] {
            let recorder = ReplyRecordingNotificationCenter()
            let coordinator = makeCoordinator(center: recorder)

            updateCoordinator(coordinator, worklane: worklane(status: needsInputStatus(kind: kind, text: text)))

            XCTAssertEqual(recorder.requests.count, 1, kind.rawValue)
            XCTAssertNil(recorder.requests.last?.replyToken, kind.rawValue)
        }
    }

    func test_coordinator_omits_reply_when_setting_is_off() throws {
        let recorder = ReplyRecordingNotificationCenter()
        let configStore = AppConfigStore(fileURL: AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.InlineReply"))
        try configStore.update { $0.notifications.inlineReply = false }
        let coordinator = WorklaneAttentionNotificationCoordinator(
            center: recorder,
            notificationStore: NotificationStore(),
            configStore: configStore
        )

        updateCoordinator(coordinator, worklane: readyWorklane())

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests.last?.replyToken)
    }

    func test_coordinator_token_is_stable_until_attention_changes() throws {
        let recorder = ReplyRecordingNotificationCenter()
        let coordinator = makeCoordinator(center: recorder)

        updateCoordinator(coordinator, worklane: readyWorklane())
        let firstToken = try XCTUnwrap(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))
        updateCoordinator(coordinator, worklane: readyWorklane())
        XCTAssertEqual(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID), firstToken)

        updateCoordinator(coordinator, worklane: worklane(status: agentStatus(state: .running, updatedAt: 200)))
        updateCoordinator(coordinator, worklane: readyWorklane(updatedAt: 300))

        let secondToken = try XCTUnwrap(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))
        XCTAssertNotEqual(secondToken, firstToken, "a new turn must invalidate replies to the old banner")
        XCTAssertEqual(recorder.requests.last?.replyToken, secondToken)
    }

    func test_coordinator_drops_token_when_agent_leaves_the_pane() {
        let coordinator = makeCoordinator()
        updateCoordinator(coordinator, worklane: readyWorklane())
        XCTAssertNotNil(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))

        updateCoordinator(coordinator, worklane: worklane(status: nil))

        XCTAssertNil(coordinator.replyToken(worklaneID: worklaneID, paneID: paneID))
    }

    // MARK: - Config

    func test_inline_reply_defaults_on_and_round_trips_through_toml() throws {
        XCTAssertTrue(AppConfig.Notifications.default.inlineReply)

        let fileURL = AppConfigStore.temporaryFileURL(prefix: "ZenttyTests.InlineReplyTOML")
        let store = AppConfigStore(fileURL: fileURL)
        XCTAssertTrue(store.current.notifications.inlineReply)

        try store.update { $0.notifications.inlineReply = false }
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("inline_reply = false"))

        let reloaded = AppConfigStore(fileURL: fileURL)
        XCTAssertFalse(reloaded.current.notifications.inlineReply)
    }

    // MARK: - Helpers

    private func decide(
        paneExists: Bool = true,
        isInlineReplyEnabled: Bool = true,
        notificationToken: String? = "token-1",
        currentToken: String? = "token-1",
        currentState: WorklaneAttentionState?,
        shellActivityState: PaneShellActivityState? = .commandRunning
    ) -> AgentNotificationReplyGuard.Decision {
        AgentNotificationReplyGuard.decide(
            paneExists: paneExists,
            isInlineReplyEnabled: isInlineReplyEnabled,
            notificationToken: notificationToken,
            currentToken: currentToken,
            currentState: currentState,
            shellActivityState: shellActivityState
        )
    }

    private func decideLive(
        _ worklane: WorklaneState,
        coordinator: WorklaneAttentionNotificationCoordinator,
        token: String?
    ) -> AgentNotificationReplyGuard.Decision {
        AgentNotificationReplyGuard.decide(
            worklane: worklane,
            paneID: paneID,
            paneExists: true,
            isInlineReplyEnabled: true,
            notificationToken: token,
            currentToken: coordinator.replyToken(worklaneID: worklaneID, paneID: paneID)
        )
    }

    private func makeCoordinator(
        center: ReplyRecordingNotificationCenter = ReplyRecordingNotificationCenter()
    ) -> WorklaneAttentionNotificationCoordinator {
        WorklaneAttentionNotificationCoordinator(center: center, notificationStore: NotificationStore())
    }

    private func agentStatus(
        state: PaneAgentState,
        updatedAt: TimeInterval = 100,
        interactionKind: PaneAgentInteractionKind? = nil,
        text: String? = nil
    ) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: .claudeCode,
            state: state,
            text: text,
            artifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            interactionKind: interactionKind,
            hasObservedRunning: true
        )
    }

    private func needsInputStatus(kind: PaneAgentInteractionKind, text: String) -> PaneAgentStatus {
        agentStatus(state: .needsInput, interactionKind: kind, text: text)
    }

    /// An agent that finished its turn: idle status shown as "ready", the way
    /// the store marks a completed turn.
    private func readyWorklane(
        updatedAt: TimeInterval = 100,
        shellActivityState: PaneShellActivityState = .commandRunning
    ) -> WorklaneState {
        worklane(
            status: agentStatus(state: .idle, updatedAt: updatedAt),
            showsReadyStatus: true,
            shellActivityState: shellActivityState
        )
    }

    private func worklane(
        status: PaneAgentStatus?,
        showsReadyStatus: Bool = false,
        shellActivityState: PaneShellActivityState = .commandRunning
    ) -> WorklaneState {
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Implement replies",
                currentWorkingDirectory: "/tmp/project",
                processName: status == nil ? "zsh" : "claude",
                gitBranch: "main"
            ),
            agentStatus: status,
            shellActivityState: shellActivityState,
            showsReadyStatus: showsReadyStatus
        )
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: auxiliaryState.raw,
            previous: nil
        )
        return WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )
    }

    private func updateCoordinator(_ coordinator: WorklaneAttentionNotificationCoordinator, worklane: WorklaneState) {
        coordinator.update(
            windowID: windowID,
            worklanes: [worklane],
            activeWorklaneID: worklaneID,
            windowIsKey: false
        )
    }
}

@MainActor
private final class ReplyRecordingNotificationCenter: WorklaneAttentionUserNotificationCenter {
    struct Request: Equatable {
        let identifier: String
        let paneID: String
        let replyToken: String?
    }

    private(set) var requests: [Request] = []

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
        XCTFail("agent attention notifications must go through the reply-aware add")
    }

    func add(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        windowID: String,
        worklaneID: String,
        paneID: String,
        soundName: String?,
        replyToken: String?
    ) {
        requests.append(Request(identifier: identifier, paneID: paneID, replyToken: replyToken))
    }
}
