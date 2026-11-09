import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneRuntimeRegistryTests: AppKitTestCase {
    private func waitForMainQueueTick() {
        let tick = expectation(description: "main queue tick")
        DispatchQueue.main.async {
            tick.fulfill()
        }
        wait(for: [tick], timeout: 2)
    }

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
                title: nil,
                paneStripState: PaneStripState(
                    panes: [mainShell],
                    focusedPaneID: mainShell.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
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

    func test_registry_queues_inactive_worklane_panes_for_deferred_start() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let deferredScheduler = PaneRuntimeDeferredStartSchedulerSpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        }, deferredStartScheduler: deferredScheduler.schedule)
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let mainEditor = PaneState(id: PaneID("worklane-main-editor"), title: "editor")
        let hiddenShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: nil,
                paneStripState: PaneStripState(
                    panes: [mainShell, mainEditor],
                    focusedPaneID: mainEditor.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
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
        XCTAssertEqual(adapterFactory.adaptersByPaneID[hiddenShell.id]?.startSessionCallCount, 0)
        XCTAssertEqual(deferredScheduler.scheduledDelays, [0.1])

        deferredScheduler.fireNext()

        XCTAssertEqual(adapterFactory.adaptersByPaneID[hiddenShell.id]?.startSessionCallCount, 1)
    }

    func test_registry_promotes_peek_visible_pane_to_immediate_start() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let deferredScheduler = PaneRuntimeDeferredStartSchedulerSpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        }, deferredStartScheduler: deferredScheduler.schedule)
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let peekShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: nil,
                paneStripState: PaneStripState(
                    panes: [mainShell],
                    focusedPaneID: mainShell.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
                paneStripState: PaneStripState(
                    panes: [peekShell],
                    focusedPaneID: peekShell.id
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

        XCTAssertEqual(adapterFactory.adaptersByPaneID[mainShell.id]?.startSessionCallCount, 1)
        XCTAssertEqual(adapterFactory.adaptersByPaneID[peekShell.id]?.startSessionCallCount, 0)

        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true,
            peekVisibleWorklaneIDs: [WorklaneID("worklane-2")]
        )

        XCTAssertEqual(
            adapterFactory.activity(for: peekShell.id),
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: true,
                isFocused: false
            )
        )
        XCTAssertEqual(adapterFactory.adaptersByPaneID[peekShell.id]?.startSessionCallCount, 1)

        deferredScheduler.fireNext()

        XCTAssertEqual(adapterFactory.adaptersByPaneID[peekShell.id]?.startSessionCallCount, 1)
    }

    func test_registry_invalidates_stale_deferred_start_when_queue_is_cleared() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let deferredScheduler = PaneRuntimeDeferredStartSchedulerSpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        }, deferredStartScheduler: deferredScheduler.schedule)
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let peekShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let nextShell = PaneState(id: PaneID("worklane-3-shell"), title: "shell")
        let initialWorklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: nil,
                paneStripState: PaneStripState(panes: [mainShell], focusedPaneID: mainShell.id)
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
                paneStripState: PaneStripState(panes: [peekShell], focusedPaneID: peekShell.id)
            ),
        ]

        registry.synchronize(with: initialWorklanes)
        registry.updateSurfaceActivities(
            worklanes: initialWorklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        XCTAssertEqual(deferredScheduler.scheduledDelays, [0.1])
        XCTAssertEqual(adapterFactory.adaptersByPaneID[peekShell.id]?.startSessionCallCount, 0)

        registry.updateSurfaceActivities(
            worklanes: initialWorklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true,
            peekVisibleWorklaneIDs: [WorklaneID("worklane-2")]
        )
        XCTAssertEqual(adapterFactory.adaptersByPaneID[peekShell.id]?.startSessionCallCount, 1)

        let nextWorklanes = initialWorklanes + [
            WorklaneState(
                id: WorklaneID("worklane-3"),
                title: nil,
                paneStripState: PaneStripState(panes: [nextShell], focusedPaneID: nextShell.id)
            ),
        ]
        registry.synchronize(with: nextWorklanes)
        registry.updateSurfaceActivities(
            worklanes: nextWorklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        XCTAssertEqual(deferredScheduler.scheduledDelays, [0.1, 0.1])
        deferredScheduler.fireNext()
        XCTAssertEqual(adapterFactory.adaptersByPaneID[nextShell.id]?.startSessionCallCount, 0)

        deferredScheduler.fireNext()
        XCTAssertEqual(adapterFactory.adaptersByPaneID[nextShell.id]?.startSessionCallCount, 1)
    }

    func test_runtime_applies_surface_activity_before_starting_session() {
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: PaneID("shell"))
        let runtime = PaneRuntime(
            pane: PaneState(id: PaneID("shell"), title: "shell"),
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        XCTAssertEqual(adapter.activityAndStartLog, ["activity:visible:focused", "start"])
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
                title: nil,
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
                title: nil,
                paneStripState: PaneStripState(
                    panes: [shell],
                    focusedPaneID: shell.id
                )
            )
        ])

        XCTAssertNil(registry.runtime(for: editor.id))
        XCTAssertNotNil(registry.runtime(for: shell.id))
    }

    func test_registry_detaches_runtime_without_closing_terminal_session() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let pane = PaneState(id: PaneID("pn_live"), title: "agent")
        registry.synchronize(with: [
            WorklaneState(
                id: WorklaneID("wl_source"),
                title: "Source",
                paneStripState: PaneStripState(panes: [pane], focusedPaneID: pane.id)
            )
        ])
        let originalRuntime = try XCTUnwrap(registry.runtime(for: pane.id))

        let detachedRuntime = try XCTUnwrap(registry.detachRuntime(for: pane.id))

        XCTAssertTrue(detachedRuntime === originalRuntime)
        XCTAssertNil(registry.runtime(for: pane.id))
        XCTAssertEqual(adapterFactory.adaptersByPaneID[pane.id]?.eventLog, ["prepare"])
    }

    func test_registry_adopts_detached_runtime_and_rebinds_event_sinks() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let sourceRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        var sourceMetadataEvents: [PaneID] = []
        var destinationMetadataEvents: [PaneID] = []
        var sourceTerminalEvents: [PaneID] = []
        var destinationTerminalEvents: [PaneID] = []
        sourceRegistry.onMetadataDidChange = { paneID, _ in sourceMetadataEvents.append(paneID) }
        sourceRegistry.onEventDidOccur = { paneID, _ in sourceTerminalEvents.append(paneID) }
        let pane = PaneState(id: PaneID("pn_live"), title: "agent")
        sourceRegistry.synchronize(with: [
            WorklaneState(
                id: WorklaneID("wl_source"),
                title: "Source",
                paneStripState: PaneStripState(panes: [pane], focusedPaneID: pane.id)
            )
        ])
        let originalRuntime = try XCTUnwrap(sourceRegistry.runtime(for: pane.id))
        let detachedRuntime = try XCTUnwrap(sourceRegistry.detachRuntime(for: pane.id))

        let destinationRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        destinationRegistry.onMetadataDidChange = { paneID, _ in destinationMetadataEvents.append(paneID) }
        destinationRegistry.onEventDidOccur = { paneID, _ in destinationTerminalEvents.append(paneID) }
        destinationRegistry.adoptRuntime(detachedRuntime, for: pane.id)

        XCTAssertTrue(destinationRegistry.runtime(for: pane.id) === originalRuntime)
        XCTAssertEqual(adapterFactory.adapters.count, 1)

        let adapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[pane.id])
        adapter.metadataDidChange?(TerminalMetadata(title: "moved"))
        adapter.eventDidOccur?(.shellReady)

        XCTAssertEqual(sourceMetadataEvents, [])
        XCTAssertEqual(sourceTerminalEvents, [])
        XCTAssertEqual(destinationMetadataEvents, [pane.id])
        XCTAssertEqual(destinationTerminalEvents, [pane.id])
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
                title: nil,
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
                    title: nil,
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
                title: nil,
                paneStripState: PaneStripState(
                    panes: [shell],
                    focusedPaneID: shell.id
                )
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
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

    func test_synchronize_keeps_runtime_for_floated_pane() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let editor = PaneState(id: PaneID("worklane-main-editor"), title: "editor")
        let worklaneID = WorklaneID("worklane-main")

        registry.synchronize(with: [
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(panes: [shell, editor], focusedPaneID: editor.id)
            )
        ])
        let editorRuntime = try XCTUnwrap(registry.runtime(for: editor.id))

        // The editor leaves the strip as a float; its runtime must survive.
        registry.synchronize(with: [
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(panes: [shell], focusedPaneID: shell.id),
                floatingPanes: [makeFloat(editor, mode: .floating)],
                focusedFloatID: editor.id
            )
        ])

        XCTAssertTrue(registry.runtime(for: editor.id) === editorRuntime)
        XCTAssertFalse(adapterFactory.adaptersByPaneID[editor.id]?.eventLog.contains("close") ?? true)

        // Float-only worklane (every tile closed) still keeps the float alive.
        registry.synchronize(with: [
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(panes: [], focusedPaneID: nil),
                floatingPanes: [makeFloat(editor, mode: .minimized(order: 0))]
            )
        ])

        XCTAssertTrue(registry.runtime(for: editor.id) === editorRuntime)
        XCTAssertNil(registry.runtime(for: shell.id))
        XCTAssertEqual(adapterFactory.adaptersByPaneID[shell.id]?.eventLog.last, "close")
        XCTAssertFalse(adapterFactory.adaptersByPaneID[editor.id]?.eventLog.contains("close") ?? true)
    }

    func test_updateSurfaceActivities_occludes_minimized_float() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let floating = PaneState(id: PaneID("worklane-main-float"), title: "float")
        let pip = PaneState(id: PaneID("worklane-main-pip"), title: "pip")
        let minimized = PaneState(id: PaneID("worklane-main-min"), title: "min")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: nil,
                paneStripState: PaneStripState(panes: [shell], focusedPaneID: shell.id),
                floatingPanes: [
                    makeFloat(floating, mode: .floating, stackOrder: 0),
                    makeFloat(pip, mode: .pip(corner: .bottomRight, order: 0), stackOrder: 1),
                    makeFloat(minimized, mode: .minimized(order: 0), stackOrder: 2),
                ],
                focusedFloatID: floating.id
            )
        ]

        registry.synchronize(with: worklanes)
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        XCTAssertEqual(
            adapterFactory.activity(for: shell.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: false)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: floating.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: true)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: pip.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: false)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: minimized.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
        // Active-worklane floats start immediately, like tiles.
        XCTAssertEqual(adapterFactory.adaptersByPaneID[minimized.id]?.startSessionCallCount, 1)

        // Window becomes key again with floats hidden: focus falls back to the strip.
        var hiddenWorklanes = worklanes
        hiddenWorklanes[0].floatsHidden = true
        registry.updateSurfaceActivities(
            worklanes: hiddenWorklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        XCTAssertEqual(
            adapterFactory.activity(for: shell.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: true)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: floating.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: pip.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: minimized.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
    }

    func test_updateSurfaceActivities_occludes_floats_while_peek_open() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let floating = PaneState(id: PaneID("worklane-main-float"), title: "float")
        let pip = PaneState(id: PaneID("worklane-main-pip"), title: "pip")
        let neighbourShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: nil,
                paneStripState: PaneStripState(panes: [shell], focusedPaneID: shell.id),
                floatingPanes: [
                    makeFloat(floating, mode: .floating, stackOrder: 0),
                    makeFloat(pip, mode: .pip(corner: .bottomRight, order: 0), stackOrder: 1),
                ],
                focusedFloatID: floating.id
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
                paneStripState: PaneStripState(panes: [neighbourShell], focusedPaneID: neighbourShell.id)
            ),
        ]

        registry.synchronize(with: worklanes)
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true,
            peekVisibleWorklaneIDs: [WorklaneID("worklane-main"), WorklaneID("worklane-2")]
        )

        XCTAssertEqual(
            adapterFactory.activity(for: floating.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
        XCTAssertEqual(
            adapterFactory.activity(for: pip.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
        XCTAssertEqual(adapterFactory.activity(for: shell.id)?.isVisible, true)
        XCTAssertEqual(adapterFactory.activity(for: neighbourShell.id)?.isVisible, true)

        // Peek closes: the floats are drawn again and the focused one takes focus.
        registry.updateSurfaceActivities(
            worklanes: worklanes,
            activeWorklaneID: WorklaneID("worklane-main"),
            windowIsVisible: true,
            windowIsKey: true,
            peekVisibleWorklaneIDs: []
        )
        XCTAssertEqual(
            adapterFactory.activity(for: floating.id),
            TerminalSurfaceActivity(isVisible: true, isFocused: true)
        )
        XCTAssertEqual(adapterFactory.activity(for: pip.id)?.isVisible, true)
    }

    func test_updateSurfaceActivities_defers_floats_of_inactive_worklane() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let deferredScheduler = PaneRuntimeDeferredStartSchedulerSpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        }, deferredStartScheduler: deferredScheduler.schedule)
        let mainShell = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let otherShell = PaneState(id: PaneID("worklane-2-shell"), title: "shell")
        let otherFloat = PaneState(id: PaneID("worklane-2-float"), title: "float")
        let worklanes = [
            WorklaneState(
                id: WorklaneID("worklane-main"),
                title: nil,
                paneStripState: PaneStripState(panes: [mainShell], focusedPaneID: mainShell.id)
            ),
            WorklaneState(
                id: WorklaneID("worklane-2"),
                title: nil,
                paneStripState: PaneStripState(panes: [otherShell], focusedPaneID: otherShell.id),
                floatingPanes: [makeFloat(otherFloat, mode: .floating)],
                focusedFloatID: otherFloat.id
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
            adapterFactory.activity(for: otherFloat.id),
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
        XCTAssertEqual(adapterFactory.adaptersByPaneID[otherFloat.id]?.startSessionCallCount, 0)

        // Deferred order: strip panes first, then floats.
        deferredScheduler.fireNext()
        XCTAssertEqual(adapterFactory.adaptersByPaneID[otherShell.id]?.startSessionCallCount, 1)
        XCTAssertEqual(adapterFactory.adaptersByPaneID[otherFloat.id]?.startSessionCallCount, 0)
        deferredScheduler.fireNext()
        XCTAssertEqual(adapterFactory.adaptersByPaneID[otherFloat.id]?.startSessionCallCount, 1)
    }

    private struct RemotePasteFixture {
        let paneID: PaneID
        let adapter: PaneRuntimeTerminalAdapterSpy
        let registry: PaneRuntimeRegistry
        let controller: RemoteImagePasteController
    }

    private func makeRemotePasteFixture(
        prefillText: String? = nil,
        uploadProcess: any RemoteImageUploadProcess & RemoteImageUploadProcessFactory = RemotePasteUploadProcessStub()
    ) throws -> RemotePasteFixture {
        let pane = PaneState(
            id: PaneID("worklane-main-remote"),
            title: "ssh",
            sessionRequest: TerminalSessionRequest(prefillText: prefillText)
        )
        let worklaneID = WorklaneID("worklane-main")
        let raw = PaneRawState(
            shellContext: PaneShellContext(
                scope: .remote,
                path: "/srv/app",
                home: "/home/peter",
                user: "peter",
                host: "prod-box"
            )
        )
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(panes: [pane], focusedPaneID: pane.id),
                    auxiliaryStateByPaneID: [
                        pane.id: PaneAuxiliaryState(
                            raw: raw,
                            presentation: PanePresentationNormalizer.normalize(paneTitle: "zsh", raw: raw, previous: nil)
                        ),
                    ]
                ),
            ],
            activeWorklaneID: worklaneID
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        _ = registry.runtime(for: pane)
        let controller = RemoteImagePasteController(
            worklaneStore: store,
            runtimeRegistry: registry,
            uploader: RemoteImageUploader(
                processFactory: uploadProcess,
                remotePathProvider: { _ in "/tmp/zentty-paste-test.png" },
                fileRemotePathProvider: { _ in "/tmp/zentty-paste-test.txt" }
            ),
            sshProcessProbe: PaneSSHProcessProbe(),
            toasts: WindowToastPresenter(
                hostViewProvider: { nil },
                themeProvider: { ZenttyTheme.fallback(for: nil) }
            )
        )
        return RemotePasteFixture(paneID: pane.id, adapter: adapter, registry: registry, controller: controller)
    }

    private func makeImagePasteboard() throws -> NSPasteboard {
        let image = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )?.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(image, forType: .png)
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func makeFileURLPasteboard() throws -> NSPasteboard {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: fileURL)
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    /// A runtime with a restore draft, and a short enough settle delay to wait past.
    private func makeDraftRuntime(
        command: String? = nil,
        restoreDraftSettleDelay: TimeInterval = 0.02,
        eventSink: @escaping (PaneID, TerminalEvent) -> Void = { _, _ in }
    ) -> (PaneRuntime, PaneRuntimeTerminalAdapterSpy) {
        let pane = PaneState(
            id: PaneID("worklane-main-shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(
                command: command,
                prefillText: "claude --resume session-123"
            )
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: eventSink,
            startupTextSettleDelay: 0.02,
            restoreDraftSettleDelay: restoreDraftSettleDelay
        )
        runtime.ensureStarted()
        return (runtime, adapter)
    }

    private func waitPastSettleDelay(_ delay: TimeInterval = 0.12) {
        let elapsed = expectation(description: "settle delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: delay + 2)
    }

    private func makeSearchRuntime() -> (PaneRuntime, PaneRuntimeTerminalAdapterSpy) {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        return (runtime, adapter)
    }

    private func makeFloat(
        _ pane: PaneState,
        mode: FloatingPaneMode,
        stackOrder: Int = 0
    ) -> FloatingPaneState {
        FloatingPaneState(
            pane: pane,
            mode: mode,
            floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            stackOrder: stackOrder,
            origin: nil
        )
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
                title: nil,
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
            title: nil,
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
        waitForMainQueueTick()

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
        waitForMainQueueTick()

        runtime.findNext()

        XCTAssertEqual(adapter.bindingActions, ["start_search", "search:build", "navigate_search:next"])
        XCTAssertTrue(runtime.snapshot.search.isHUDVisible)
        XCTAssertTrue(runtime.snapshot.search.hasRememberedSearch)
    }

    func test_runtime_keeps_search_hud_when_blur_hands_focus_to_search_field() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        addTeardownBlock {
            window.close()
        }
        window.contentView = runtime.hostView

        runtime.showSearch()
        runtime.hostView.applySearchHUD(runtime.snapshot.search)
        runtime.hostView.focusSearchField(selectAll: false)
        runtime.handleTerminalFocusChange(false)
        waitForMainQueueTick()

        XCTAssertTrue(runtime.snapshot.search.isHUDVisible)

        window.makeFirstResponder(nil)
        runtime.handleTerminalFocusChange(false)
        waitForMainQueueTick()

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

    func test_runtime_started_with_needle_submits_search() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.showSearch()
        runtime.updateSearchNeedle("older")
        adapter.searchDidChange?(.total(7))
        adapter.searchDidChange?(.selected(2))

        runtime.useSelectionForFind()
        adapter.searchDidChange?(.started(needle: "build"))

        XCTAssertEqual(
            adapter.bindingActions,
            ["start_search", "search:older", "search_selection", "search:build"]
        )
        XCTAssertEqual(
            runtime.snapshot.search,
            PaneSearchState(
                needle: "build",
                selected: -1,
                total: 0,
                hasRememberedSearch: true,
                isHUDVisible: true,
                hudCorner: .topTrailing
            )
        )
    }

    func test_runtime_reusing_the_selection_needle_keeps_results_ghostty_will_not_resend() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.useSelectionForFind()
        adapter.searchDidChange?(.started(needle: "build"))
        adapter.searchDidChange?(.total(4))
        adapter.searchDidChange?(.selected(1))

        // Ghostty drops an unchanged needle and re-emits neither count.
        runtime.useSelectionForFind()
        adapter.searchDidChange?(.started(needle: "build"))

        XCTAssertEqual(
            adapter.bindingActions,
            ["search_selection", "search:build", "search_selection"]
        )
        XCTAssertEqual(runtime.snapshot.search.needle, "build")
        XCTAssertEqual(runtime.snapshot.search.total, 4)
        XCTAssertEqual(runtime.snapshot.search.selected, 1)
    }

    func test_runtime_case_only_needle_change_keeps_results_ghostty_will_not_resend() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("build")
        adapter.searchDidChange?(.total(4))
        adapter.searchDidChange?(.selected(1))

        runtime.updateSearchNeedle("BUILD")

        XCTAssertEqual(adapter.bindingActions, ["search:build"])
        XCTAssertEqual(runtime.snapshot.search.needle, "BUILD")
        XCTAssertEqual(runtime.snapshot.search.total, 4)
        XCTAssertEqual(runtime.snapshot.search.selected, 1)
    }

    func test_runtime_non_ascii_case_change_is_a_new_needle_for_ghostty() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("café")
        adapter.searchDidChange?(.total(4))

        runtime.updateSearchNeedle("CAFÉ")

        XCTAssertEqual(adapter.bindingActions, ["search:café", "search:CAFÉ"])
        XCTAssertEqual(runtime.snapshot.search.total, 0)
    }

    func test_runtime_returning_to_the_active_needle_before_the_debounce_restores_its_results() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("abc")
        adapter.searchDidChange?(.total(4))
        adapter.searchDidChange?(.selected(1))

        runtime.updateSearchNeedle("ab")
        XCTAssertEqual(runtime.snapshot.search.total, 0)

        runtime.updateSearchNeedle("abc")

        XCTAssertEqual(runtime.snapshot.search.total, 4)
        XCTAssertEqual(runtime.snapshot.search.selected, 1)

        let debounceElapsed = expectation(description: "debounce window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { debounceElapsed.fulfill() }
        wait(for: [debounceElapsed], timeout: 2)
        XCTAssertEqual(adapter.bindingActions, ["search:abc"], "the debounced ab must not reach Ghostty")
    }

    func test_runtime_changed_needle_is_submitted_and_resets_results() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("build")
        adapter.searchDidChange?(.total(4))
        runtime.updateSearchNeedle("test")
        adapter.searchDidChange?(.total(2))
        runtime.updateSearchNeedle("build")

        XCTAssertEqual(adapter.bindingActions, ["search:build", "search:test", "search:build"])
        XCTAssertEqual(runtime.snapshot.search.total, 0)
    }

    func test_runtime_resubmits_the_same_needle_once_its_session_ended() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("build")
        adapter.searchDidChange?(.total(4))
        runtime.endSearch()
        runtime.updateSearchNeedle("build")

        XCTAssertEqual(adapter.bindingActions, ["search:build", "end_search", "search:build"])
        XCTAssertEqual(runtime.snapshot.search.total, 0)

        adapter.searchDidChange?(.total(4))
        adapter.searchDidChange?(.ended)
        runtime.updateSearchNeedle("build")

        XCTAssertEqual(adapter.bindingActions.last, "search:build")
        XCTAssertEqual(adapter.bindingActions.count, 4, "an engine-side end drops the query too")
    }

    func test_runtime_resubmits_the_same_needle_after_clearing_the_query() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("build")
        adapter.searchDidChange?(.total(4))
        runtime.updateSearchNeedle("")
        runtime.updateSearchNeedle("build")

        XCTAssertEqual(adapter.bindingActions, ["search:build", "search:", "search:build"])
    }

    func test_runtime_local_needle_matching_a_global_query_is_submitted_again() {
        let (runtime, adapter) = makeSearchRuntime()

        runtime.updateSearchNeedle("build")
        adapter.searchDidChange?(.total(4))
        runtime.beginGlobalSearch { _, _ in }
        runtime.updateGlobalSearchNeedle("test")
        runtime.endGlobalSearch()
        runtime.updateSearchNeedle("build")

        XCTAssertEqual(adapter.bindingActions.last, "search:build")
        XCTAssertEqual(runtime.snapshot.search.total, 0, "the old count belongs to an ended engine session")
    }

    func test_runtime_user_paste_counts_as_editing_a_pending_restore_draft() {
        let pane = PaneState(
            id: PaneID("worklane-main-shell"),
            title: "shell",
            sessionRequest: TerminalSessionRequest(prefillText: "claude --resume session-123")
        )
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        var events: [TerminalEvent] = []
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, event in events.append(event) },
            startupTextSettleDelay: 0.01,
            restoreDraftSettleDelay: 0.01
        )
        runtime.ensureStarted()

        runtime.sendUserPaste("/tmp/upload.png")
        adapter.eventDidOccur?(.shellReady)

        let settled = expectation(description: "draft settle delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(adapter.sentTexts, ["/tmp/upload.png"], "the draft must not land after the paste")
        XCTAssertEqual(events, [.userEditedInput, .shellReady])
    }

    func test_remote_paste_counts_as_user_input_only_once_its_path_is_sent() throws {
        let fixture = try makeRemotePasteFixture()
        let reported = expectation(description: "paste reported as user input")
        fixture.registry.onEventDidOccur = { _, event in
            XCTAssertEqual(event, .userEditedInput)
            XCTAssertEqual(fixture.adapter.sentTexts.count, 1, "the text goes first")
            reported.fulfill()
        }

        XCTAssertTrue(fixture.controller.handlePaste(paneID: fixture.paneID, pasteboard: try makeImagePasteboard()))
        XCTAssertEqual(fixture.adapter.sentTexts, [], "the upload has not finished")

        wait(for: [reported], timeout: 5)
        XCTAssertEqual(fixture.adapter.sentTexts, ["/tmp/zentty-paste-test.png"])
    }

    func test_rejected_remote_paste_reports_nothing() throws {
        let fixture = try makeRemotePasteFixture()
        fixture.registry.onEventDidOccur = { _, event in
            XCTFail("a rejected paste delivered nothing, got \(event)")
        }
        _ = fixture.controller.insertUploadTaskForTesting(Task {}, for: fixture.paneID)

        XCTAssertTrue(fixture.controller.handlePaste(paneID: fixture.paneID, pasteboard: try makeImagePasteboard()))

        XCTAssertEqual(fixture.adapter.sentTexts, [])
    }

    func test_paste_held_past_the_draft_timer_keeps_the_draft_out_of_the_shell() {
        let (runtime, adapter) = makeDraftRuntime(restoreDraftSettleDelay: 0.05)
        withExtendedLifetime(runtime) {
            adapter.eventDidOccur?(.shellReady)
            let held = LibghosttyHeldUserPaste(
                delivered: { adapter.eventDidOccur?(.userEditedInput) },
                report: { adapter.eventDidOccur?($0) }
            )

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, [], "the draft must not land beneath the prompt")

            adapter.sendText("pasted")
            held.settle(delivered: true)

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["pasted"], "delivery consumes the draft")
        }
    }

    func test_refused_paste_lets_the_suspended_draft_land_once() {
        let (runtime, adapter) = makeDraftRuntime(restoreDraftSettleDelay: 0.05)
        withExtendedLifetime(runtime) {
            adapter.eventDidOccur?(.shellReady)
            let held = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, [])

            held.settle(delivered: false)

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["claude --resume session-123"], "released once, and only once")
        }
    }

    func test_paste_refused_before_the_shell_is_ready_leaves_the_draft_for_it() {
        let (runtime, adapter) = makeDraftRuntime()
        withExtendedLifetime(runtime) {
            let held = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })
            held.settle(delivered: false)

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, [], "the shell has not come up yet")

            adapter.eventDidOccur?(.shellReady)
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["claude --resume session-123"])
        }
    }

    func test_shell_ready_during_a_held_paste_does_not_send_the_draft() {
        let (runtime, adapter) = makeDraftRuntime()
        withExtendedLifetime(runtime) {
            let held = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })

            adapter.eventDidOccur?(.shellReady)
            adapter.metadataDidChange?(TerminalMetadata(title: "shell"))
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, [])

            held.settle(delivered: false)
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["claude --resume session-123"])
        }
    }

    func test_overlapping_pastes_suspend_the_draft_until_the_last_one_settles() {
        let (runtime, adapter) = makeDraftRuntime()
        withExtendedLifetime(runtime) {
            adapter.eventDidOccur?(.shellReady)
            let first = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })
            let second = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })

            first.settle(delivered: false)
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, [], "the other paste may still arrive")

            second.settle(delivered: false)
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["claude --resume session-123"])
        }
    }

    func test_typing_during_a_held_paste_still_consumes_the_draft() {
        let (runtime, adapter) = makeDraftRuntime()
        withExtendedLifetime(runtime) {
            adapter.eventDidOccur?(.shellReady)
            let held = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })

            adapter.eventDidOccur?(.userEditedInput)
            held.settle(delivered: false)

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, [])
        }
    }

    func test_paste_hold_stays_private_to_the_runtime() {
        var events: [TerminalEvent] = []
        let (runtime, adapter) = makeDraftRuntime(eventSink: { _, event in events.append(event) })
        withExtendedLifetime(runtime) {
            let held = LibghosttyHeldUserPaste(
                delivered: { adapter.eventDidOccur?(.userEditedInput) },
                report: { adapter.eventDidOccur?($0) }
            )
            held.settle(delivered: true)

            XCTAssertEqual(events, [.userEditedInput])
        }
    }

    func test_held_paste_does_not_stall_an_initial_command() {
        let (runtime, adapter) = makeDraftRuntime(command: "echo ready")
        withExtendedLifetime(runtime) {
            let held = LibghosttyHeldUserPaste(delivered: {}, report: { adapter.eventDidOccur?($0) })
            adapter.eventDidOccur?(.shellReady)

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["echo ready\r"])

            held.settle(delivered: false)
            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["echo ready\r"], "not sent again, and no draft after it")
        }
    }

    func test_delivered_paste_does_not_cancel_the_initial_command_sharing_its_work_item() {
        let (runtime, adapter) = makeDraftRuntime(command: "echo ready")
        withExtendedLifetime(runtime) {
            let held = LibghosttyHeldUserPaste(
                delivered: { adapter.eventDidOccur?(.userEditedInput) },
                report: { adapter.eventDidOccur?($0) }
            )
            adapter.eventDidOccur?(.shellReady)

            held.settle(delivered: true)

            waitPastSettleDelay()
            XCTAssertEqual(adapter.sentTexts, ["echo ready\r"])
        }
    }

    func test_upload_spanning_the_draft_timer_keeps_the_draft_out_of_the_shell() throws {
        let upload = GatedRemotePasteUploadProcess()
        let fixture = try makeRemotePasteFixture(prefillText: "claude --resume session-123", uploadProcess: upload)
        fixture.adapter.eventDidOccur?(.shellReady)

        XCTAssertTrue(fixture.controller.handlePaste(paneID: fixture.paneID, pasteboard: try makeImagePasteboard()))
        waitPastSettleDelay(0.4)
        XCTAssertEqual(fixture.adapter.sentTexts, [], "the upload has not finished")

        let delivered = expectation(description: "uploaded path sent")
        fixture.adapter.onSendText = { _ in delivered.fulfill() }
        upload.finish(exitStatus: 0)
        wait(for: [delivered], timeout: 5)

        fixture.adapter.onSendText = nil
        waitPastSettleDelay(0.4)
        XCTAssertEqual(fixture.adapter.sentTexts, ["/tmp/zentty-paste-test.png"])
    }

    func test_file_upload_spanning_the_draft_timer_keeps_the_draft_out_of_the_shell() throws {
        let upload = GatedRemotePasteUploadProcess()
        let fixture = try makeRemotePasteFixture(prefillText: "claude --resume session-123", uploadProcess: upload)
        fixture.adapter.eventDidOccur?(.shellReady)

        XCTAssertTrue(fixture.controller.handlePaste(paneID: fixture.paneID, pasteboard: try makeFileURLPasteboard()))
        waitPastSettleDelay(0.4)
        XCTAssertEqual(fixture.adapter.sentTexts, [], "the upload has not finished")

        let delivered = expectation(description: "uploaded path sent")
        fixture.adapter.onSendText = { _ in delivered.fulfill() }
        upload.finish(exitStatus: 0)
        wait(for: [delivered], timeout: 5)

        fixture.adapter.onSendText = nil
        waitPastSettleDelay(0.4)
        XCTAssertEqual(fixture.adapter.sentTexts, ["/tmp/zentty-paste-test.txt"])
    }

    func test_failed_upload_lets_the_suspended_draft_land() throws {
        let upload = GatedRemotePasteUploadProcess()
        let fixture = try makeRemotePasteFixture(prefillText: "claude --resume session-123", uploadProcess: upload)
        fixture.adapter.eventDidOccur?(.shellReady)
        XCTAssertTrue(fixture.controller.handlePaste(paneID: fixture.paneID, pasteboard: try makeImagePasteboard()))
        waitPastSettleDelay(0.4)
        XCTAssertEqual(fixture.adapter.sentTexts, [])

        let landed = expectation(description: "draft sent after the failure")
        fixture.adapter.onSendText = { _ in landed.fulfill() }
        upload.finish(exitStatus: 1)

        wait(for: [landed], timeout: 5)
        XCTAssertEqual(fixture.adapter.sentTexts, ["claude --resume session-123"])
    }

    func test_cancelled_upload_lets_the_suspended_draft_land() throws {
        let upload = GatedRemotePasteUploadProcess()
        let fixture = try makeRemotePasteFixture(prefillText: "claude --resume session-123", uploadProcess: upload)
        fixture.adapter.eventDidOccur?(.shellReady)
        XCTAssertTrue(fixture.controller.handlePaste(paneID: fixture.paneID, pasteboard: try makeImagePasteboard()))
        waitPastSettleDelay(0.4)
        XCTAssertEqual(fixture.adapter.sentTexts, [])

        let landed = expectation(description: "draft sent after the cancellation")
        fixture.adapter.onSendText = { _ in landed.fulfill() }
        fixture.controller.cancelAll()

        wait(for: [landed], timeout: 5)
        XCTAssertEqual(fixture.adapter.sentTexts, ["claude --resume session-123"])
    }

    func test_runtime_started_with_empty_needle_does_not_submit_search() {
        let pane = PaneState(id: PaneID("worklane-main-shell"), title: "shell")
        let adapter = PaneRuntimeTerminalAdapterSpy(paneID: pane.id)
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )

        runtime.useSelectionForFind()
        adapter.searchDidChange?(.started(needle: ""))

        XCTAssertEqual(adapter.bindingActions, ["search_selection"])
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
        XCTAssertEqual(adapter.sentTexts, ["drift --showcase\r"])
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
        XCTAssertEqual(adapter.sentTexts, ["echo ready\r"])
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
        XCTAssertEqual(adapter.sentTexts, ["codex\r"])
    }
}

private final class RemotePasteUploadProcessStub: RemoteImageUploadProcess, RemoteImageUploadProcessFactory, @unchecked Sendable {
    func makeProcess(executableURL: URL, arguments: [String]) -> any RemoteImageUploadProcess { self }
    func run() throws {}
    func write(_ data: Data) throws {}
    func closeStandardInput() {}
    func waitUntilExit(timeout: TimeInterval) -> RemoteImageUploadProcessResult {
        RemoteImageUploadProcessResult(exitStatus: 0, stderr: "", timedOut: false)
    }
    func terminate() {}
}

/// Stays in flight until the test finishes it, as a real upload spanning the draft timer would.
private final class GatedRemotePasteUploadProcess: RemoteImageUploadProcess, RemoteImageUploadProcessFactory, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exitStatus: Int32 = 1

    func makeProcess(executableURL: URL, arguments: [String]) -> any RemoteImageUploadProcess { self }
    func run() throws {}
    func write(_ data: Data) throws {}
    func closeStandardInput() {}
    func waitUntilExit(timeout: TimeInterval) -> RemoteImageUploadProcessResult {
        _ = gate.wait(timeout: .now() + 10)
        lock.lock()
        defer { lock.unlock() }
        return RemoteImageUploadProcessResult(exitStatus: exitStatus, stderr: "", timedOut: false)
    }
    func terminate() { gate.signal() }

    func finish(exitStatus: Int32) {
        lock.lock()
        self.exitStatus = exitStatus
        lock.unlock()
        gate.signal()
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
private final class PaneRuntimeDeferredStartSchedulerSpy {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var operations: [@MainActor () -> Void] = []

    func schedule(delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delay)
        operations.append(operation)
    }

    func fireNext() {
        guard !operations.isEmpty else { return }
        let operation = operations.removeFirst()
        operation()
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
    private(set) var activityAndStartLog: [String] = []
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
        activityAndStartLog.append("start")
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
        let visibility = activity.isVisible ? "visible" : "hidden"
        let focus = activity.isFocused ? "focused" : "unfocused"
        activityAndStartLog.append("activity:\(visibility):\(focus)")
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
