import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyAdapterTests: XCTestCase {
    func test_make_terminal_view_returns_reusable_scroll_host_view() throws {
        let adapter = LibghosttyAdapter(runtime: LibghosttyRuntimeProviderSpy())

        let firstView = adapter.makeTerminalView()
        let secondView = adapter.makeTerminalView()

        XCTAssertTrue(firstView === secondView)
        let scrollHost = try XCTUnwrap(firstView as? LibghosttySurfaceScrollHostView)
        XCTAssertTrue(scrollHost.surfaceViewForTesting is LibghosttyView)
    }

    func test_start_session_creates_surface_and_forwards_metadata() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        let terminalView = adapter.makeTerminalView()
        let request = TerminalSessionRequest(workingDirectory: "/tmp/project")
        let metadata = TerminalMetadata(
            title: "editor",
            currentWorkingDirectory: "/Users/peter/Development/Personal/zentty",
            processName: "zsh",
            gitBranch: "main"
        )
        var receivedMetadata: TerminalMetadata?

        adapter.metadataDidChange = { receivedMetadata = $0 }

        try adapter.startSession(using: request)

        XCTAssertEqual(runtime.makeSurfaceCallCount, 1)
        XCTAssertFalse(runtime.lastHostView === terminalView)
        XCTAssertTrue((terminalView as? LibghosttySurfaceScrollHostView)?.surfaceViewForTesting === runtime.lastHostView)
        XCTAssertEqual(runtime.lastRequest, request)

        runtime.lastMetadataHandler?(metadata)

        XCTAssertEqual(receivedMetadata, metadata)
    }

    func test_start_session_delivers_codex_title_phase_transition_immediately() async throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var delivered: [TerminalMetadata] = []
        let unexpectedThirdDelivery = expectation(description: "no delayed third delivery")
        unexpectedThirdDelivery.isInverted = true

        adapter.metadataDidChange = { metadata in
            delivered.append(metadata)
            if delivered.count > 2 {
                unexpectedThirdDelivery.fulfill()
            }
        }

        try adapter.startSession(using: TerminalSessionRequest())

        runtime.lastMetadataHandler?(
            TerminalMetadata(
                title: "Working ⠋ my-project",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        runtime.lastMetadataHandler?(
            TerminalMetadata(
                title: "Ready my-project",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(
            delivered,
            [
                TerminalMetadata(
                    title: "Working ⠋ my-project",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                ),
                TerminalMetadata(
                    title: "Ready my-project",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                ),
            ]
        )

        await fulfillment(of: [unexpectedThirdDelivery], timeout: 0.08)
        XCTAssertEqual(delivered.count, 2)
    }

    func test_start_session_delivers_title_implied_working_directory_change_immediately() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var delivered: [TerminalMetadata] = []

        adapter.metadataDidChange = { delivered.append($0) }

        try adapter.startSession(using: TerminalSessionRequest())

        runtime.lastMetadataHandler?(
            TerminalMetadata(
                title: "peter@host:~/Development/project-a",
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )
        runtime.lastMetadataHandler?(
            TerminalMetadata(
                title: "peter@host:~/Development/project-b",
                currentWorkingDirectory: nil,
                processName: "zsh",
                gitBranch: nil
            )
        )

        XCTAssertEqual(
            delivered,
            [
                TerminalMetadata(
                    title: "peter@host:~/Development/project-a",
                    currentWorkingDirectory: nil,
                    processName: "zsh",
                    gitBranch: nil
                ),
                TerminalMetadata(
                    title: "peter@host:~/Development/project-b",
                    currentWorkingDirectory: nil,
                    processName: "zsh",
                    gitBranch: nil
                ),
            ]
        )
    }

    func test_start_session_delivers_meaningful_title_identity_change_immediately() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var delivered: [TerminalMetadata] = []

        adapter.metadataDidChange = { delivered.append($0) }

        try adapter.startSession(using: TerminalSessionRequest())

        runtime.lastMetadataHandler?(
            TerminalMetadata(
                title: "Review PR #128",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        runtime.lastMetadataHandler?(
            TerminalMetadata(
                title: "Review PR #129",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(
            delivered,
            [
                TerminalMetadata(
                    title: "Review PR #128",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                ),
                TerminalMetadata(
                    title: "Review PR #129",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                ),
            ]
        )
    }

    func test_starting_visible_surface_refreshes_after_first_visibility_update() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        XCTAssertEqual(surfaceController.refreshCallCount, 0)

        adapter.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        XCTAssertEqual(surfaceController.refreshCallCount, 1)
        XCTAssertEqual(surfaceController.focusValues.last, true)
    }

    func test_hidden_live_surface_does_not_refresh_until_it_becomes_visible() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        adapter.setSurfaceActivity(
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )
        XCTAssertEqual(surfaceController.refreshCallCount, 0)
        XCTAssertEqual(surfaceController.focusValues.last, false)

        adapter.setSurfaceActivity(
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: true,
                isFocused: false
            )
        )

        XCTAssertEqual(surfaceController.refreshCallCount, 1)
        XCTAssertEqual(surfaceController.focusValues.last, false)
    }

    func test_find_next_uses_navigate_search_binding_action() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        adapter.findNext()

        XCTAssertEqual(surfaceController.bindingActions, ["navigate_search:next"])
    }

    func test_find_previous_uses_navigate_search_binding_action() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        adapter.findPrevious()

        XCTAssertEqual(surfaceController.bindingActions, ["navigate_search:previous"])
    }

    func test_hidden_live_surface_still_forwards_progress_events() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var receivedEvent: TerminalEvent?

        adapter.eventDidOccur = { receivedEvent = $0 }

        try adapter.startSession(using: TerminalSessionRequest())
        adapter.setSurfaceActivity(
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )

        let report = TerminalProgressReport(state: .indeterminate, progress: nil)
        runtime.lastEventHandler?(.progressReport(report))

        XCTAssertEqual(receivedEvent, .progressReport(report))
    }

    func test_repeated_surface_activity_does_not_resend_focus_or_refresh() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        adapter.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))
        let focusValuesAfterFirstUpdate = surfaceController.focusValues
        let refreshCallCountAfterFirstUpdate = surfaceController.refreshCallCount

        adapter.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        XCTAssertEqual(surfaceController.focusValues, focusValuesAfterFirstUpdate)
        XCTAssertEqual(surfaceController.refreshCallCount, refreshCallCountAfterFirstUpdate)
    }

    func test_return_key_emits_user_submitted_input_event() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var receivedEvents: [TerminalEvent] = []

        adapter.eventDidOccur = { receivedEvents.append($0) }

        _ = adapter.makeTerminalView()
        try adapter.startSession(using: TerminalSessionRequest())

        let hostView = try XCTUnwrap(runtime.lastHostView)
        hostView.keyDown(with: try makeKeyEvent(characters: "\r", keyCode: 36))

        XCTAssertTrue(receivedEvents.contains(.userSubmittedInput))
    }

    func test_navigation_key_does_not_emit_user_submitted_input_event() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var receivedEvents: [TerminalEvent] = []

        adapter.eventDidOccur = { receivedEvents.append($0) }

        _ = adapter.makeTerminalView()
        try adapter.startSession(using: TerminalSessionRequest())

        let hostView = try XCTUnwrap(runtime.lastHostView)
        hostView.keyDown(with: try makeKeyEvent(characters: "\u{F700}", keyCode: 126))

        XCTAssertFalse(receivedEvents.contains(.userSubmittedInput))
    }

    func test_prepare_session_start_uses_inherited_config_from_source_surface() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let sourceAdapter = LibghosttyAdapter(runtime: runtime)
        let splitAdapter = LibghosttyAdapter(runtime: runtime)
        let inheritedConfig = ghostty_surface_config_new()

        try sourceAdapter.startSession(using: TerminalSessionRequest())
        runtime.lastSurfaceController?.inheritedConfigContext = inheritedConfig.context

        splitAdapter.prepareSessionStart(from: sourceAdapter, context: .split)
        try splitAdapter.startSession(using: TerminalSessionRequest(configInheritanceSourcePaneID: PaneID("source")))

        XCTAssertEqual(runtime.makeSurfaceCallCount, 2)
        XCTAssertEqual(runtime.receivedConfigTemplates.count, 2)
        XCTAssertNil(runtime.receivedConfigTemplates[0])
        XCTAssertEqual(runtime.receivedConfigTemplates[1]?.context, inheritedConfig.context)
    }

    func test_prepare_session_start_requests_inherited_config_for_requested_context() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let sourceAdapter = LibghosttyAdapter(runtime: runtime)
        let tabAdapter = LibghosttyAdapter(runtime: runtime)

        try sourceAdapter.startSession(using: TerminalSessionRequest())

        tabAdapter.prepareSessionStart(from: sourceAdapter, context: .tab)

        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)
        XCTAssertEqual(surfaceController.inheritedConfigRequests, [GHOSTTY_SURFACE_CONTEXT_TAB])
    }

    func test_copy_action_payload_copies_pwd_string_before_async_boundary() {
        let duplicated = strdup("/tmp/project")
        defer { free(duplicated) }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_PWD,
            action: ghostty_action_u(pwd: ghostty_action_pwd_s(pwd: duplicated))
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .pwd("/tmp/project"))
    }

    func test_copy_action_payload_copies_title_string_before_async_boundary() {
        let duplicated = strdup("shell")
        defer { free(duplicated) }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_SET_TITLE,
            action: ghostty_action_u(set_title: ghostty_action_set_title_s(title: duplicated))
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .setTitle("shell"))
    }

    func test_copy_action_payload_copies_command_finished_values() {
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_COMMAND_FINISHED,
            action: ghostty_action_u(
                command_finished: ghostty_action_command_finished_s(
                    exit_code: 1,
                    duration: 250_000_000
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .commandFinished(exitCode: 1, durationNanoseconds: 250_000_000))
    }

    func test_copy_action_payload_copies_progress_report_values() {
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_PROGRESS_REPORT,
            action: ghostty_action_u(
                progress_report: ghostty_action_progress_report_s(
                    state: GHOSTTY_PROGRESS_STATE_INDETERMINATE,
                    progress: -1
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(
            payload,
            .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )
    }

    func test_copy_action_payload_copies_scrollbar_offset_values() {
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_SCROLLBAR,
            action: ghostty_action_u(
                scrollbar: ghostty_action_scrollbar_s(
                    total: 120,
                    offset: 35,
                    len: 18
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .scrollbar(total: 120, offset: 35, len: 18))
    }

    func test_copy_action_payload_copies_desktop_notification_values() {
        let duplicatedTitle = strdup("Codex")
        let duplicatedBody = strdup("Needs your input")
        defer {
            free(duplicatedTitle)
            free(duplicatedBody)
        }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
            action: ghostty_action_u(
                desktop_notification: ghostty_action_desktop_notification_s(
                    title: duplicatedTitle,
                    body: duplicatedBody
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(
            payload,
            .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Needs your input")
            )
        )
    }

}

final class TerminalDiagnosticsTests: XCTestCase {
    func test_terminal_diagnostics_emits_burst_summary_after_quiet_period() async {
        let diagnostics = TerminalDiagnostics(quietPeriod: 0.02)
        let emitted = expectation(description: "burst emitted")
        var summary: TerminalDiagnostics.BurstSummary?
        diagnostics.onEmit = { emittedSummary in
            summary = emittedSummary
            emitted.fulfill()
        }
        diagnostics.setEnabled(true)

        let paneID = PaneID("pane-1")
        let previous = TerminalMetadata(
            title: "Thinking ✳ drag-drop-pane-reorder",
            currentWorkingDirectory: "/tmp/project",
            processName: "claude",
            gitBranch: "main"
        )
        let next = TerminalMetadata(
            title: "Thinking ● drag-drop-pane-reorder",
            currentWorkingDirectory: "/tmp/project",
            processName: "claude",
            gitBranch: "main"
        )

        diagnostics.recordMetadataObservation(
            paneID: paneID,
            previous: previous,
            next: next,
            changeKind: .meaningful,
            delivery: .immediate
        )
        diagnostics.recordMetadataDelivery(paneID: paneID, outcome: .immediate)
        diagnostics.recordStoreMetadataUpdate(paneID: paneID)
        diagnostics.recordStoreFastPath(paneID: paneID)
        diagnostics.recordInvalidation(paneID: paneID, impacts: [.sidebar, .header, .reviewRefresh])
        diagnostics.recordActionCallback(
            paneID: paneID,
            payload: .setTitle("Thinking about drag-drop-pane-reorder")
        )
        diagnostics.recordRender(.canvas, activePaneID: paneID)

        await fulfillment(of: [emitted], timeout: 1.0)

        XCTAssertEqual(summary?.scope, .pane(paneID))
        XCTAssertEqual(summary?.metadataDeliveryCount, 1)
        XCTAssertEqual(summary?.metadataChangeKindCounts["meaningful"], 1)
        XCTAssertEqual(summary?.metadataToolCounts["claude"], 1)
        XCTAssertEqual(summary?.storeUpdateCount, 1)
        XCTAssertEqual(summary?.storeFastPathCount, 1)
        XCTAssertEqual(summary?.auxiliaryInvalidationCounts["sidebar"], 1)
        XCTAssertEqual(summary?.auxiliaryInvalidationCounts["header"], 1)
        XCTAssertEqual(summary?.auxiliaryInvalidationCounts["reviewRefresh"], 1)
        XCTAssertEqual(summary?.actionPayloadCounts["title"], 1)
        XCTAssertEqual(summary?.renderCounts["canvas"], 1)
        XCTAssertEqual(summary?.wouldHaveBeenVolatileClaudeCount, 1)
    }

    func test_terminal_diagnostics_emits_tick_and_drain_timings_in_payload() async throws {
        let diagnostics = TerminalDiagnostics(quietPeriod: 0.02)
        let runtimeEmitted = expectation(description: "runtime burst emitted")
        let paneEmitted = expectation(description: "pane burst emitted")
        var summariesByScope: [TerminalDiagnostics.Scope: TerminalDiagnostics.BurstSummary] = [:]
        diagnostics.onEmit = { emittedSummary in
            summariesByScope[emittedSummary.scope] = emittedSummary
            switch emittedSummary.scope {
            case .runtime:
                runtimeEmitted.fulfill()
            case .pane(PaneID("pane-2")):
                paneEmitted.fulfill()
            default:
                break
            }
        }
        diagnostics.setEnabled(true)

        let paneID = PaneID("pane-2")
        diagnostics.recordWakeupReceived()
        diagnostics.recordWakeupEnqueued()
        diagnostics.recordTick(durationNanoseconds: 2_500_000, queueDelayNanoseconds: 750_000)
        diagnostics.recordActionCallback(paneID: paneID, payload: .scrollbar(total: 100, offset: 0, len: 10))
        diagnostics.recordActionDrain(paneID: paneID, queueDelayNanoseconds: 4_250_000)

        await fulfillment(of: [runtimeEmitted, paneEmitted], timeout: 1.0)

        let runtimeSummary = try XCTUnwrap(summariesByScope[.runtime])
        XCTAssertEqual(runtimeSummary.wakeupCount, 1)
        XCTAssertEqual(runtimeSummary.tickCount, 1)
        XCTAssertEqual(runtimeSummary.tickTotalMilliseconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(runtimeSummary.tickMaxMilliseconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(runtimeSummary.mainQueueDelayTotalMilliseconds, 0.75, accuracy: 0.001)
        XCTAssertEqual(runtimeSummary.mainQueueDelayMaxMilliseconds, 0.75, accuracy: 0.001)

        let runtimePayload = TerminalDiagnostics.logPayloadForTesting(runtimeSummary)
        XCTAssertTrue(runtimePayload.contains("tickTotalMilliseconds=2.5"))
        XCTAssertTrue(runtimePayload.contains("tickMaxMilliseconds=2.5"))
        XCTAssertTrue(runtimePayload.contains("mainQueueDelayTotalMilliseconds=0.75"))
        XCTAssertTrue(runtimePayload.contains("mainQueueDelayMaxMilliseconds=0.75"))

        let paneSummary = try XCTUnwrap(summariesByScope[.pane(paneID)])
        XCTAssertEqual(paneSummary.actionCallbackCount, 1)
        XCTAssertEqual(paneSummary.actionDrainCount, 1)
        XCTAssertEqual(paneSummary.actionDrainQueueDelayTotalMilliseconds, 4.25, accuracy: 0.001)
        XCTAssertEqual(paneSummary.actionDrainQueueDelayMaxMilliseconds, 4.25, accuracy: 0.001)
        XCTAssertEqual(paneSummary.actionPayloadCounts["scrollbar"], 1)

        let panePayload = TerminalDiagnostics.logPayloadForTesting(paneSummary)
        XCTAssertTrue(panePayload.contains("actionCallbackCount=1"))
        XCTAssertTrue(panePayload.contains("actionDrainCount=1"))
        XCTAssertTrue(panePayload.contains("actionDrainQueueDelayTotalMilliseconds=4.25"))
        XCTAssertTrue(panePayload.contains("actionDrainQueueDelayMaxMilliseconds=4.25"))
    }

    func test_terminal_diagnostics_emits_scroll_host_metrics_in_payload() async throws {
        let diagnostics = TerminalDiagnostics(quietPeriod: 0.02)
        let emitted = expectation(description: "pane burst emitted")
        var summary: TerminalDiagnostics.BurstSummary?
        let paneID = PaneID("pane-scroll-host")
        diagnostics.onEmit = { emittedSummary in
            guard emittedSummary.scope == .pane(paneID) else {
                return
            }
            summary = emittedSummary
            emitted.fulfill()
        }
        diagnostics.setEnabled(true)

        diagnostics.recordScrollbarApply(paneID: paneID, durationNanoseconds: 3_500_000)
        diagnostics.recordScrollHostSync(
            paneID: paneID,
            durationNanoseconds: 6_250_000,
            geometryApplied: true,
            documentHeightChanged: true,
            documentHeightPoints: 12_000,
            documentHeightDeltaPoints: 11_500,
            reflected: true,
            scrollbarTotalRows: 1_024,
            scrollbarOffsetRows: 960,
            scrollbarVisibleRows: 64,
            wasAtBottom: true,
            shouldAutoScroll: true,
            autoScrollApplied: true,
            userScrolledAwayFromBottom: false,
            explicitScrollbarSyncAllowed: false
        )
        diagnostics.recordScrollToRowAction(paneID: paneID)
        diagnostics.recordViewportSync(paneID: paneID, durationNanoseconds: 1_250_000)

        await fulfillment(of: [emitted], timeout: 1.0)

        let emittedSummary = try XCTUnwrap(summary)
        XCTAssertEqual(emittedSummary.scrollbarApplyCount, 1)
        XCTAssertEqual(emittedSummary.scrollbarApplyTotalMilliseconds, 3.5, accuracy: 0.001)
        XCTAssertEqual(emittedSummary.scrollHostSyncCount, 1)
        XCTAssertEqual(emittedSummary.scrollHostSyncTotalMilliseconds, 6.25, accuracy: 0.001)
        XCTAssertEqual(emittedSummary.scrollbarGeometryApplyCount, 1)
        XCTAssertEqual(emittedSummary.documentHeightChangeCount, 1)
        XCTAssertEqual(emittedSummary.documentHeightMaxPoints, 12_000, accuracy: 0.001)
        XCTAssertEqual(emittedSummary.documentHeightMaxDeltaPoints, 11_500, accuracy: 0.001)
        XCTAssertEqual(emittedSummary.scrollbarBottomAlignedCount, 1)
        XCTAssertEqual(emittedSummary.scrollbarOffBottomCount, 0)
        XCTAssertEqual(emittedSummary.scrollbarWasAtBottomCount, 1)
        XCTAssertEqual(emittedSummary.scrollbarAutoFollowEligibleCount, 1)
        XCTAssertEqual(emittedSummary.scrollbarAutoFollowSuppressedCount, 0)
        XCTAssertEqual(emittedSummary.scrollbarAutoFollowAppliedCount, 1)
        XCTAssertEqual(emittedSummary.scrollbarUserScrolledAwayCount, 0)
        XCTAssertEqual(emittedSummary.scrollbarExplicitSyncAllowedCount, 0)
        XCTAssertEqual(emittedSummary.scrollbarMaxTotalRows, 1_024)
        XCTAssertEqual(emittedSummary.scrollbarMinOffsetRows, 960)
        XCTAssertEqual(emittedSummary.scrollbarMaxOffsetRows, 960)
        XCTAssertEqual(emittedSummary.scrollbarMinVisibleRows, 64)
        XCTAssertEqual(emittedSummary.scrollbarMaxVisibleRows, 64)
        XCTAssertEqual(emittedSummary.firstScrollbarPosition, "total:1024,offset:960,len:64")
        XCTAssertEqual(emittedSummary.lastScrollbarPosition, "total:1024,offset:960,len:64")
        XCTAssertEqual(emittedSummary.reflectScrolledClipViewCount, 1)
        XCTAssertEqual(emittedSummary.scrollToRowActionCount, 1)
        XCTAssertEqual(emittedSummary.viewportSyncCount, 1)
        XCTAssertEqual(emittedSummary.viewportSyncTotalMilliseconds, 1.25, accuracy: 0.001)

        let payload = TerminalDiagnostics.logPayloadForTesting(emittedSummary)
        XCTAssertTrue(payload.contains("scrollbarApplyCount=1"))
        XCTAssertTrue(payload.contains("scrollHostSyncCount=1"))
        XCTAssertTrue(payload.contains("documentHeightMaxDeltaPoints=11500.0"))
        XCTAssertTrue(payload.contains("scrollbarBottomAlignedCount=1"))
        XCTAssertTrue(payload.contains("scrollbarAutoFollowAppliedCount=1"))
        XCTAssertTrue(payload.contains("scrollbarMaxTotalRows=1024"))
        XCTAssertTrue(payload.contains("firstScrollbarPosition=total:1024,offset:960,len:64"))
        XCTAssertTrue(payload.contains("reflectScrolledClipViewCount=1"))
        XCTAssertTrue(payload.contains("scrollToRowActionCount=1"))
        XCTAssertTrue(payload.contains("viewportSyncCount=1"))
    }

    func test_terminal_diagnostics_tolerates_inconsistent_scrollbar_ranges() async throws {
        let diagnostics = TerminalDiagnostics(quietPeriod: 0.02)
        let emitted = expectation(description: "pane burst emitted")
        let paneID = PaneID("pane-scroll-overflow")
        var summary: TerminalDiagnostics.BurstSummary?
        diagnostics.onEmit = { emittedSummary in
            guard emittedSummary.scope == .pane(paneID) else {
                return
            }
            summary = emittedSummary
            emitted.fulfill()
        }
        diagnostics.setEnabled(true)

        diagnostics.recordScrollHostSync(
            paneID: paneID,
            durationNanoseconds: 1_000,
            geometryApplied: false,
            documentHeightChanged: false,
            documentHeightPoints: 100,
            documentHeightDeltaPoints: 0,
            reflected: false,
            scrollbarTotalRows: 10,
            scrollbarOffsetRows: UInt64.max,
            scrollbarVisibleRows: UInt64.max,
            wasAtBottom: nil,
            shouldAutoScroll: nil,
            autoScrollApplied: nil,
            userScrolledAwayFromBottom: nil,
            explicitScrollbarSyncAllowed: nil
        )

        await fulfillment(of: [emitted], timeout: 1.0)

        let emittedSummary = try XCTUnwrap(summary)
        XCTAssertEqual(emittedSummary.scrollbarBottomAlignedCount, 1)
        XCTAssertEqual(emittedSummary.scrollbarOffBottomCount, 0)
        XCTAssertEqual(emittedSummary.scrollbarMaxTotalRows, 10)
        XCTAssertEqual(emittedSummary.scrollbarMaxOffsetRows, UInt64.max)
        XCTAssertEqual(emittedSummary.scrollbarMaxVisibleRows, UInt64.max)
    }

    func test_terminal_diagnostics_drops_events_when_disabled() async {
        let diagnostics = TerminalDiagnostics(quietPeriod: 0.02)
        let emitted = expectation(description: "no burst emitted")
        emitted.isInverted = true
        diagnostics.onEmit = { _ in
            emitted.fulfill()
        }

        diagnostics.recordStoreMetadataUpdate(paneID: PaneID("pane-1"))

        await fulfillment(of: [emitted], timeout: 0.1)
    }
}

final class LibghosttyWakeupCoordinatorTests: XCTestCase {
    func test_request_tick_coalesces_repeated_wakeups_while_a_tick_is_pending() {
        final class State: @unchecked Sendable {
            var scheduled: [@Sendable () -> Void] = []
            var tickCount = 0
        }

        let state = State()

        let coordinator = LibghosttyWakeupCoordinator(
            diagnostics: .shared,
            schedule: { state.scheduled.append($0) },
            tick: { state.tickCount += 1 }
        )

        coordinator.requestTick()
        coordinator.requestTick()
        coordinator.requestTick()

        XCTAssertEqual(state.scheduled.count, 1)
        XCTAssertEqual(state.tickCount, 0)

        let first = state.scheduled.removeFirst()
        first()

        XCTAssertEqual(state.tickCount, 1)
        XCTAssertEqual(state.scheduled.count, 1)

        let second = state.scheduled.removeFirst()
        second()

        XCTAssertEqual(state.tickCount, 2)
        XCTAssertEqual(state.scheduled.count, 0)
    }
}

@MainActor
private final class LibghosttyRuntimeProviderSpy: LibghosttyRuntimeProviding {
    private(set) var makeSurfaceCallCount = 0
    private(set) weak var lastHostView: LibghosttyView?
    private(set) var lastMetadataHandler: ((TerminalMetadata) -> Void)?
    private(set) var lastEventHandler: ((TerminalEvent) -> Void)?
    private(set) var lastRequest: TerminalSessionRequest?
    private(set) var lastSurfaceController: LibghosttySurfaceControllerSpy?
    private(set) var receivedConfigTemplates: [ghostty_surface_config_s?] = []

    private(set) var reloadConfigCallCount = 0

    func makeSurface(
        for hostView: LibghosttyView,
        paneID _: PaneID,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        makeSurfaceCallCount += 1
        lastHostView = hostView
        lastRequest = request
        lastMetadataHandler = metadataDidChange
        lastEventHandler = eventDidOccur
        receivedConfigTemplates.append(configTemplate)
        let surfaceController = LibghosttySurfaceControllerSpy()
        lastSurfaceController = surfaceController
        return surfaceController
    }

    func reloadConfig() {
        reloadConfigCallCount += 1
    }

    func applyBackgroundBlur(to window: NSWindow) {}
}

private final class LibghosttySurfaceControllerSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var refreshCallCount = 0
    private(set) var focusValues: [Bool] = []
    private(set) var bindingActions: [String] = []
    private(set) var inheritedConfigRequests: [ghostty_surface_context_e] = []
    var selectionPresent = false
    var inheritedConfigContext: ghostty_surface_context_e?
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) { focusValues.append(isFocused) }
    func refresh() { refreshCallCount += 1 }
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) {}
    func sendText(_ text: String) {}
    func performBindingAction(_ action: String) -> Bool {
        bindingActions.append(action)
        return true
    }
    func hasSelection() -> Bool { selectionPresent }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        inheritedConfigRequests.append(context)
        guard let inheritedConfigContext else {
            return nil
        }

        var config = ghostty_surface_config_new()
        config.context = inheritedConfigContext
        return config
    }
}

private func makeKeyEvent(
    characters: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try XCTUnwrap(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}
