import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneRuntimeRegistryTests: XCTestCase {
    func test_registry_creates_runtime_once_and_reuses_existing_session_across_workspace_switches() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let mainShell = PaneState(id: PaneID("workspace-main-shell"), title: "shell")
        let webShell = PaneState(id: PaneID("workspace-2-shell"), title: "shell")
        let workspaces = [
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [mainShell],
                    focusedPaneID: mainShell.id
                )
            ),
            WorkspaceState(
                id: WorkspaceID("workspace-2"),
                title: "WS 2",
                paneStripState: PaneStripState(
                    panes: [webShell],
                    focusedPaneID: webShell.id
                )
            ),
        ]

        registry.synchronize(with: workspaces)
        let initialMainRuntime = try XCTUnwrap(registry.runtime(for: mainShell.id))
        let initialWebRuntime = try XCTUnwrap(registry.runtime(for: webShell.id))
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [0, 0])

        registry.updateSurfaceActivities(
            workspaces: workspaces,
            activeWorkspaceID: WorkspaceID("workspace-main"),
            windowIsVisible: true,
            windowIsKey: true
        )
        registry.updateSurfaceActivities(
            workspaces: workspaces,
            activeWorkspaceID: WorkspaceID("workspace-2"),
            windowIsVisible: true,
            windowIsKey: true
        )
        registry.updateSurfaceActivities(
            workspaces: workspaces,
            activeWorkspaceID: WorkspaceID("workspace-main"),
            windowIsVisible: true,
            windowIsKey: true
        )
        registry.synchronize(with: workspaces)

        let finalMainRuntime = try XCTUnwrap(registry.runtime(for: mainShell.id))
        let finalWebRuntime = try XCTUnwrap(registry.runtime(for: webShell.id))

        XCTAssertTrue(initialMainRuntime === finalMainRuntime)
        XCTAssertTrue(initialWebRuntime === finalWebRuntime)
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])
    }

    func test_registry_updates_surface_activity_for_visible_focused_and_hidden_workspaces() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let mainShell = PaneState(id: PaneID("workspace-main-shell"), title: "shell")
        let mainEditor = PaneState(id: PaneID("workspace-main-editor"), title: "editor")
        let hiddenShell = PaneState(id: PaneID("workspace-2-shell"), title: "shell")
        let workspaces = [
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [mainShell, mainEditor],
                    focusedPaneID: mainEditor.id
                )
            ),
            WorkspaceState(
                id: WorkspaceID("workspace-2"),
                title: "WS 2",
                paneStripState: PaneStripState(
                    panes: [hiddenShell],
                    focusedPaneID: hiddenShell.id
                )
            ),
        ]

        registry.synchronize(with: workspaces)
        registry.updateSurfaceActivities(
            workspaces: workspaces,
            activeWorkspaceID: WorkspaceID("workspace-main"),
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
            TerminalSurfaceActivity(isVisible: false, isFocused: false)
        )
    }

    func test_registry_removes_runtime_for_closed_pane() {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("workspace-main-shell"), title: "shell")
        let editor = PaneState(id: PaneID("workspace-main-editor"), title: "editor")

        registry.synchronize(with: [
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell, editor],
                    focusedPaneID: editor.id
                )
            )
        ])
        XCTAssertNotNil(registry.runtime(for: editor.id))

        registry.synchronize(with: [
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
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

    func test_registry_prepares_split_pane_from_source_runtime_before_starting() throws {
        let adapterFactory = PaneRuntimeAdapterFactorySpy()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let shell = PaneState(id: PaneID("workspace-main-shell"), title: "shell")
        let split = PaneState(
            id: PaneID("workspace-main-pane-1"),
            title: "pane 1",
            sessionRequest: TerminalSessionRequest(
                workingDirectory: "/tmp/project",
                inheritFromPaneID: shell.id
            )
        )

        registry.synchronize(with: [
            WorkspaceState(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                paneStripState: PaneStripState(
                    panes: [shell, split],
                    focusedPaneID: split.id
                )
            )
        ])

        registry.updateSurfaceActivities(
            workspaces: [
                WorkspaceState(
                    id: WorkspaceID("workspace-main"),
                    title: "MAIN",
                    paneStripState: PaneStripState(
                        panes: [shell, split],
                        focusedPaneID: split.id
                    )
                )
            ],
            activeWorkspaceID: WorkspaceID("workspace-main"),
            windowIsVisible: true,
            windowIsKey: true
        )

        let shellAdapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[shell.id])
        let splitAdapter = try XCTUnwrap(adapterFactory.adaptersByPaneID[split.id])

        XCTAssertTrue(splitAdapter.prepareSourceAdapter === shellAdapter)
        XCTAssertEqual(splitAdapter.eventLog, ["prepare", "start"])
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
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: true, isFocused: false)
    private(set) weak var prepareSourceAdapter: PaneRuntimeTerminalAdapterSpy?
    private(set) var eventLog: [String] = []

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

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }

    func prepareSessionStart(from sourceAdapter: (any TerminalAdapter)?) {
        eventLog.append("prepare")
        prepareSourceAdapter = sourceAdapter as? PaneRuntimeTerminalAdapterSpy
    }
}
