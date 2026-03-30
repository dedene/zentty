import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneRuntimeRegistryTests: XCTestCase {
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
private final class PaneRuntimeTerminalAdapterSpy: TerminalAdapter, TerminalSessionInheritanceConfiguring {
    let paneID: PaneID
    let terminalView = NSView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: true, isFocused: false)
    private(set) weak var prepareSourceAdapter: PaneRuntimeTerminalAdapterSpy?
    private(set) var eventLog: [String] = []
    private(set) var preparedContexts: [TerminalSurfaceContext] = []

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

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
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
