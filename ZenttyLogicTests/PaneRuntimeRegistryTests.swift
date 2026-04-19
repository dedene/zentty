import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneRuntimeRegistryTests: AppKitTestCase {
    func test_registry_creates_runtime_once_and_reuses_existing_session_across_worklane_switches() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let webShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [mainShell],
                    focusedPaneID: mainShell.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: "WS 2",
                paneStripState: PaneStripState(
                    panes: [webShell],
                    focusedPaneID: webShell.id
                )
            ),
        ]

        registry.synchronize(with: worklanes)
        let initialMainRuntime = try XCTUnwrap(registry.runtime(for: mainShell.id))
        let initialWebRuntime = try XCTUnwrap(registry.runtime(for: webShell.id))
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [0, 0])

        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-2"),
            windowIsVisible: true,
            windowIsKey: true
        )
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )
        registry.synchronize(with: worklanes)

        let finalMainRuntime = try XCTUnwrap(registry.runtime(for: mainShell.id))
        let finalWebRuntime = try XCTUnwrap(registry.runtime(for: webShell.id))

        XCTAssertTrue(initialMainRuntime === finalMainRuntime)
        XCTAssertTrue(initialWebRuntime === finalWebRuntime)
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])
    }

    func test_registry_keeps_inactive_worklane_panes_live_while_only_active_worklane_is_visible() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let mainEditor = PaneState(id: PaneID("worklane-main-editor"), title: "editor")
        let hiddenShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [mainShell, mainEditor],
                    focusedPaneID: mainEditor.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: "WS 2",
                paneStripState: PaneStripState(
                    panes: [hiddenShell],
                    focusedPaneID: hiddenShell.id
                )
            ),
        ]

        registry.synchronize(with: worklanes)
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        XCTAssertEqual(
            adapterFactory.activity(for: mainShell.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: false)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: mainEditor.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: true)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: hiddenShell.id),
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )
        XCTAssertEqual(adapterFactory.adaptersByPaneID[hiddenShell.id]?.startSessionCallCount, 1)
    }

    func test_registry_keeps_panes_live_even_when_window_is_not_visible() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let backgroundShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [mainShell],
                    focusedPaneID: mainShell.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: "WS 2",
                paneStripState: PaneStripState(
                    panes: [backgroundShell],
                    focusedPaneID: backgroundShell.id
                )
            ),
        ]

        registry.synchronize(with: worklanes)
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: false,
            windowIsKey: false
        )

        XCTAssertEqual(
            adapterFactory.activity(for: mainShell.id),
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )
        XCTAssertEqual(
            adapterFactory.activity(for: backgroundShell.id),
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )
        XCTAssertEqual(adapterFactory.adaptersByPaneID[mainShell.id]?.startSessionCallCount, 1)
        XCTAssertEqual(adapterFactory.adaptersByPaneID[backgroundShell.id]?.startSessionCallCount, 1)
    }

    func test_registry_removes_runtime_for_closed_pane() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let editor = PaneState(id: PaneID("worklane-main-editor"), title: "editor")

        registry.synchronize(with: [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell, editor],
                    focusedPaneID: editor.id
                )
            )
        ])
        XCTAssertNotNil(registry.runtime(for: editor.id))

        registry.synchronize(with: [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell],
                    focusedPaneID: shell.id
                )
            )
        ])

        XCTAssertNil(registry.runtime(for: editor.id))
        XCTAssertNotNil(registry.runtime(for: shell.id))
    }

    func test_registry_prepares_local_split_pane_from_config_inheritance_source_before_starting() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let split = PaneState(
            id: PaneID("worklane-main-pane-1"),
            title: "pane 1",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                configInheritanceSourcePaneID: shell.id
            )
        )

        registry.synchronize(with: [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell, split],
                    focusedPaneID: split.id
                )
            )
        ])

        registry.updateSurfaceActivities(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("worklane-main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [shell, split],
                        focusedPaneID: split.id
                    )
                )
            ],
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        let shellAdapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[shell.id])
        let splitAdapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[split.id])

        XCTAssertTrue(splitAdapter.prepareSourceAdapter === shellAdapter)
        XCTAssertEqual(splitAdapter.eventLog, ["prepare", "start"])
        XCTAssertEqual(splitAdapter.preparedContexts, [.split])
    }

    func test_registry_prepares_new_worklane_pane_from_local_config_inheritance_source_using_tab_context() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let newWorklaneShell = PaneState(
            id: PaneID("worklane-2-shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                configInheritanceSourcePaneID: shell.id,
                surfaceContext: .tab
            )
        )

        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell],
                    focusedPaneID: shell.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: "WS 2",
                paneStripState: PaneStripState(
                    panes: [newWorklaneShell],
                    focusedPaneID: newWorklaneShell.id
                )
            ),
        ]

        registry.synchronize(with: worklanes)
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-2"),
            windowIsVisible: true,
            windowIsKey: true
        )

        let shellAdapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[shell.id])
        let worklaneAdapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[newWorklaneShell.id])

        XCTAssertTrue(worklaneAdapter.prepareSourceAdapter === shellAdapter)
        XCTAssertEqual(worklaneAdapter.eventLog, ["prepare", "start"])
        XCTAssertEqual(worklaneAdapter.preparedContexts, [.tab])
    }

    func test_registry_destroyAll_removes_all_runtimes() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let editor = PaneState(id: PaneID("worklane-main-editor"), title: "editor")

        registry.synchronize(with: [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell, editor],
                    focusedPaneID: editor.id
                )
            )
        ])
        XCTAssertNotNil(registry.runtime(for: shell.id))
        XCTAssertNotNil(registry.runtime(for: editor.id))

        registry.destroyAll()

        XCTAssertNil(registry.runtime(for: shell.id))
        XCTAssertNil(registry.runtime(for: editor.id))

        registry.destroyAll()
        XCTAssertNil(registry.runtime(for: shell.id), "second destroyAll must be safe")
    }

    func test_registry_starts_local_session_with_working_directory_without_inheritance() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(
            id: PaneID("worklane-main-shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project space")
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [shell],
                focusedPaneID: shell.id
            )
        )

        registry.synchronize(with: [worklane])
        registry.updateSurfaceActivities(
            worklanes: [worklane],
            activeWorklaneID: worklane.id,
            windowIsVisible: true,
            windowIsKey: true
        )

        let adapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[shell.id])
        XCTAssertEqual(adapter.eventLog, ["prepare", "start"])
    }

    func test_runtime_blur_hides_search_hud_but_keeps_remembered_query() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.showSearch()
        runtime.updateSearchNeedle("build")
        runtime.handleTerminalFocusChange(false)

        XCTAssertEqual(adapter.bindingActions, ["start_search", "search:build"])
        XCTAssertEqual(
            runtime.snapshot.search,
            PaneSearchState(
                needle: "build",
                selected: -1,
                total: 0,
                hasRememberedSearch: true,
                isHUDVisible: false,
                hudCorner: .topTrailing
            )
        )
    }

    func test_runtime_find_next_reopens_hidden_search_without_restarting_search_session() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.showSearch()
        runtime.updateSearchNeedle("build")
        runtime.handleTerminalFocusChange(false)

        runtime.findNext()

        XCTAssertEqual(adapter.bindingActions, ["start_search", "search:build", "navigate_search:next"])
        XCTAssertTrue(runtime.snapshot.search.isHUDVisible)
        XCTAssertTrue(runtime.snapshot.search.hasRememberedSearch)
    }

    func test_runtime_ignores_terminal_blur_during_search_field_focus_transfer() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.showSearch()
        runtime.prepareSearchFieldFocusTransfer()
        runtime.handleTerminalFocusChange(false)

        XCTAssertTrue(runtime.snapshot.search.isHUDVisible)

        runtime.handleTerminalFocusChange(false)

        XCTAssertFalse(runtime.snapshot.search.isHUDVisible)
    }

    func test_runtime_use_selection_for_find_opens_search_and_dispatches_selection_search() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.useSelectionForFind()

        XCTAssertEqual(adapter.bindingActions, ["search_selection"])
        XCTAssertEqual(runtime.snapshot.search.isHUDVisible, true)
        XCTAssertEqual(runtime.snapshot.search.hasRememberedSearch, true)
    }

    func test_runtime_global_search_routes_events_to_global_sink_without_mutating_local_search_state() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        var receivedEvents: [TerminalSearchEvent] = []

        runtime.beginGlobalSearch { _, event in
            receivedEvents.append(event)
        }
        runtime.updateGlobalSearchNeedle("build")
        adapter.searchDidChange?(.total(2))
        adapter.searchDidChange?(.selected(1))

        XCTAssertEqual(
            receivedEvents,
            [
                .started(needle: nil),
                .total(2),
                .selected(1),
            ]
        )
        XCTAssertEqual(adapter.bindingActions, ["start_search", "search:build"])
        XCTAssertEqual(runtime.snapshot.search, PaneSearchState())
    }

    func test_runtime_reset_global_search_selection_reissues_search_for_current_global_needle() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.beginGlobalSearch { _, _ in }
        runtime.updateGlobalSearchNeedle("build")
        runtime.resetGlobalSearchSelection()

        XCTAssertEqual(adapter.bindingActions, ["start_search", "search:build", "search:build"])
        XCTAssertEqual(runtime.snapshot.search, PaneSearchState())
    }

    func test_runtime_end_global_search_dispatches_end_search_and_clears_global_session() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        var receivedEvents: [TerminalSearchEvent] = []

        runtime.beginGlobalSearch { _, event in
            receivedEvents.append(event)
        }
        runtime.updateGlobalSearchNeedle("build")

        runtime.endGlobalSearch()
        adapter.searchDidChange?(.total(2))

        XCTAssertEqual(adapter.bindingActions, ["start_search", "search:build", "end_search"])
        XCTAssertEqual(receivedEvents, [.started(needle: nil)])
        XCTAssertEqual(runtime.snapshot.search, PaneSearchState())
    }

    func test_runtime_sends_initial_command_after_prompt_metadata_settles() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                command: "drift --showcase"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let sent = expectation(description: "startup command sent")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.01
        )
        adapter.onSendText = { _ in sent.fulfill() }

        runtime.ensureStarted()
        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project"))
        XCTAssertEqual(adapter.sentTexts, [])

        adapter.metadataDidChange?(TerminalMetadata(title: "shell", currentWorkingDirectory: "/tmp/project"))
        XCTAssertEqual(adapter.sentTexts, [])

        wait(for: [sent], timeout: 0.2)
        XCTAssertEqual(adapter.sentTexts, ["drift --showcase\n"])
    }

    func test_runtime_waits_for_shell_ready_before_prefilling_restore_draft() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                prefillText: "claude --resume session-123"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let prematurePrefill = expectation(description: "restore draft should not prefill before shell ready")
        prematurePrefill.isInverted = true
        let prefilled = expectation(description: "restore draft prefilled")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.01,
            restoreDraftSettleDelay: 0.01
        )
        adapter.onSendText = { _ in prematurePrefill.fulfill() }

        runtime.ensureStarted()
        adapter.metadataDidChange?(TerminalMetadata(title: "shell", currentWorkingDirectory: "/tmp/project"))

        wait(for: [prematurePrefill], timeout: 0.03)
        XCTAssertEqual(adapter.sentTexts, [])

        adapter.onSendText = { _ in prefilled.fulfill() }
        adapter.eventDidOccur?(.shellReady)

        wait(for: [prefilled], timeout: 0.2)
        XCTAssertEqual(adapter.sentTexts, ["claude --resume session-123"])
    }

    func test_runtime_prefills_restore_draft_when_shell_ready_arrives_before_title() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                prefillText: "codex resume session-123"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let prefilled = expectation(description: "restore draft prefilled")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.01,
            restoreDraftSettleDelay: 0.01
        )
        adapter.onSendText = { _ in prefilled.fulfill() }

        runtime.ensureStarted()
        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project"))
        adapter.eventDidOccur?(.shellReady)
        XCTAssertEqual(adapter.sentTexts, [])

        wait(for: [prefilled], timeout: 0.2)
        XCTAssertEqual(adapter.sentTexts, ["codex resume session-123"])
    }

    func test_runtime_does_not_prefill_restore_draft_from_process_name_alone() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                prefillText: "codex resume session-123"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let prematurePrefill = expectation(description: "restore draft should not prefill from process name alone")
        prematurePrefill.isInverted = true
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.01,
            restoreDraftSettleDelay: 0.01
        )
        adapter.onSendText = { _ in prematurePrefill.fulfill() }

        runtime.ensureStarted()
        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project", processName: "zsh"))

        wait(for: [prematurePrefill], timeout: 0.03)
        XCTAssertEqual(adapter.sentTexts, [])
    }

    func test_runtime_prefills_restore_draft_only_once_after_shell_ready() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                prefillText: "codex resume session-123"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let sent = expectation(description: "restore draft sent once")
        sent.expectedFulfillmentCount = 1
        let duplicateSend = expectation(description: "restore draft should not send twice")
        duplicateSend.isInverted = true
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.01,
            restoreDraftSettleDelay: 0.01
        )
        var sendCount = 0
        adapter.onSendText = { _ in
            sendCount += 1
            if sendCount == 1 {
                sent.fulfill()
            } else {
                duplicateSend.fulfill()
            }
        }

        runtime.ensureStarted()
        adapter.metadataDidChange?(TerminalMetadata(title: "shell", currentWorkingDirectory: "/tmp/project"))
        XCTAssertEqual(adapter.sentTexts, [])

        adapter.eventDidOccur?(.shellReady)
        wait(for: [sent], timeout: 0.2)
        XCTAssertEqual(adapter.sentTexts, ["codex resume session-123"])

        adapter.metadataDidChange?(TerminalMetadata(title: "shell", currentWorkingDirectory: "/tmp/project", processName: "zsh"))
        wait(for: [duplicateSend], timeout: 0.03)
        XCTAssertEqual(adapter.sentTexts, ["codex resume session-123"])
    }

    func test_runtime_sends_initial_command_when_shell_ready_arrives_before_title() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                command: "echo ready"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let sent = expectation(description: "startup command sent")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.01
        )
        adapter.onSendText = { _ in sent.fulfill() }

        runtime.ensureStarted()
        adapter.metadataDidChange?(TerminalMetadata(currentWorkingDirectory: "/tmp/project"))
        adapter.eventDidOccur?(.shellReady)
        XCTAssertEqual(adapter.sentTexts, [])

        wait(for: [sent], timeout: 0.2)
        XCTAssertEqual(adapter.sentTexts, ["echo ready\n"])
    }

    func test_runtime_reschedules_startup_text_until_metadata_settles() {
        let pane = PaneState(
            id: PaneID("shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                command: "codex"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let sent = expectation(description: "startup command sent once")
        sent.expectedFulfillmentCount = 1
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            startupTextSettleDelay: 0.03
        )
        adapter.onSendText = { _ in sent.fulfill() }

        runtime.ensureStarted()
        adapter.eventDidOccur?(.shellReady)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            adapter.metadataDidChange?(TerminalMetadata(title: "prompt", currentWorkingDirectory: "/tmp/project"))
        }

        wait(for: [sent], timeout: 0.2)
        XCTAssertEqual(adapter.sentTexts, ["codex\n"])
    }
}

@MainActor
private final class PaneRuntimeAdapterFactorySpy {
    private(set) var adaptersByPaneID: [PaneID: PaneRuntimeTerminalAdapterSpy] = [:]
    private(set) var adapters: [PaneRuntimeTerminalAdapterSpy] = []

    func makeAdapter(for paneID: PaneID) -> any TerminalAdapter {
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: paneID)
        adapters.append(adapter)
        adaptersByPaneID[adapter.paneID] = adapter
        return adapter
    }

    func activity(for paneID: PaneID) -> TerminalSurfaceActivity? {
        adaptersByPaneID[paneID]?.lastSurfaceActivity
    }
}

@MainActor
private final class PaneRuntimeTerminalAdapterSpy: TerminalAdapter, TerminalSessionInheritanceConfiguring, TerminalSearchControlling {
    let paneID: PaneID
    let terminalView = NSView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: true, isFocused: false)
    private(set) weak var prepareSourceAdapter: PaneRuntimeTerminalAdapterSpy?
    private(set) var eventLog: [String] = []
    private(set) var preparedContexts: [TerminalSurfaceContext] = []
    private(set) var bindingActions: [String] = []
    private(set) var sentTexts: [String] = []
    var onSendText: ((String) -> Void)?

    init(paneID: PaneID) {
        self.paneID = paneID
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        eventLog.append("start")
        startSessionCallCount += 1
    }

    func close() {
        eventLog.append("close")
    }

    func sendText(_ text: String) {
        sentTexts.append(text)
        onSendText?(text)
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }

    func showSearch() {
        bindingActions.append("start_search")
        searchDidChange?(.started(needle: nil))
    }

    func useSelectionForFind() {
        bindingActions.append("search_selection")
        searchDidChange?(.started(needle: nil))
    }

    func updateSearch(needle: String) {
        bindingActions.append("search:\(needle)")
    }

    func findNext() {
        bindingActions.append("navigate_search:next")
    }

    func findPrevious() {
        bindingActions.append("navigate_search:previous")
    }

    func endSearch() {
        bindingActions.append("end_search")
        searchDidChange?(.ended)
    }

    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    ) {
        eventLog.append("prepare")
        prepareSourceAdapter = sourceAdapter as? PaneRuntimeTerminalAdapterSpy
        preparedContexts.append(context)
    }
}
