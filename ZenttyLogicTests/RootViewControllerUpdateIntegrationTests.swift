import AppKit
import XCTest
@testable import Zentty

@MainActor
final class RootViewControllerUpdateIntegrationTests: AppKitTestCase {
    private func makeController(
        appUpdateStateStore: AppUpdateStateStore = AppUpdateStateStore(),
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() })
    ) -> RootViewController {
        let controller = RootViewController(
            configStore: AppConfigStore(
                fileURL: AppConfigStore.temporaryFileURL(prefix: "Zentty.RootViewController.UpdateRow")
            ),
            appUpdateStateStore: appUpdateStateStore,
            runtimeRegistry: runtimeRegistry
        )
        addTeardownBlock {
            MainActor.assumeIsolated {
                controller.prepareForTestingTearDown()
            }
        }
        return controller
    }

    func test_root_controller_hides_update_row_when_no_update_is_available() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)

        XCTAssertTrue(sidebarView.debugSnapshotForTesting.isUpdateRowHidden)
        XCTAssertEqual(sidebarView.debugSnapshotForTesting.updateAvailableRowHeight, 0, accuracy: 0.001)
    }

    func test_root_controller_shows_update_row_when_update_becomes_available() throws {
        let appUpdateStateStore = AppUpdateStateStore()
        let controller = makeController(appUpdateStateStore: appUpdateStateStore)
        controller.loadViewIfNeeded()

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        appUpdateStateStore.setUpdateAvailable(true)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(sidebarView.debugSnapshotForTesting.isUpdateRowHidden)
        XCTAssertEqual(sidebarView.debugSnapshotForTesting.updateAvailableRowHeight, 28, accuracy: 0.001)
    }

    func test_root_controller_routes_update_row_click_to_update_callback() throws {
        let appUpdateStateStore = AppUpdateStateStore()
        let controller = makeController(appUpdateStateStore: appUpdateStateStore)
        controller.loadViewIfNeeded()

        var callCount = 0
        controller.onCheckForUpdatesRequested = {
            callCount += 1
        }
        appUpdateStateStore.setUpdateAvailable(true)

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        sidebarView.performDebugActionForTesting(.performUpdateAvailableRowClick)

        XCTAssertEqual(callCount, 1)
    }

    func test_root_controller_ignores_update_row_click_when_no_update_is_available() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()

        var callCount = 0
        controller.onCheckForUpdatesRequested = {
            callCount += 1
        }

        let sidebarView = try XCTUnwrap(controller.view.subviews.first { $0 is SidebarView } as? SidebarView)
        sidebarView.performDebugActionForTesting(.performUpdateAvailableRowClick)

        XCTAssertEqual(callCount, 0)
    }

    func test_runLastCommandAgain_sendsSubmittedTextAndConsumesRestoredCommand() {
        let adapter = RecordingRootTerminalAdapter()
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        let controller = makeController(runtimeRegistry: registry)
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-main")
        let command = "pnpm start:staging\nnpm run smoke"
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    raw: PaneRawState(
                        shellActivityState: .promptIdle,
                        restoredRerunnableCommand: command
                    )
                )
            ]
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        XCTAssertTrue(controller.runLastCommandAgain(in: paneID))
        // RecordingRootTerminalAdapter inherits the default protocol implementation
        // of submitCommand, which appends \r and forwards through sendText.
        XCTAssertEqual(adapter.sentTexts, [command + "\r"])

        XCTAssertFalse(controller.runLastCommandAgain(in: paneID))
        XCTAssertEqual(adapter.sentTexts.count, 1)
    }

    func test_runTaskRunnerAtIdlePrompt_cancelsPromptAndSubmitsInFocusedPane() throws {
        let adapter = RecordingRootTerminalAdapter()
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        let controller = makeController(runtimeRegistry: registry)
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-main")
        let worklane = makeTaskRunnerWorklane(
            paneID: paneID,
            shellActivityState: .promptIdle
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        controller.runTaskRunnerForTesting(makeTaskRunnerAction(command: "pnpm run dev"))

        XCTAssertEqual(adapter.cancelPromptInputCallCount, 1)
        XCTAssertEqual(adapter.submittedCommands, ["pnpm run dev"])
        XCTAssertEqual(controller.paneStripStateForTesting.panes.map(\.id), [paneID])
    }

    func test_runTaskRunnerWhileCommandRunning_opensNewPane() throws {
        let adapter = RecordingRootTerminalAdapter()
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        let controller = makeController(runtimeRegistry: registry)
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-main")
        let worklane = makeTaskRunnerWorklane(
            paneID: paneID,
            shellActivityState: .commandRunning
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        controller.runTaskRunnerForTesting(makeTaskRunnerAction(command: "pnpm run dev"))

        XCTAssertEqual(adapter.cancelPromptInputCallCount, 0)
        XCTAssertEqual(adapter.submittedCommands, [])
        let panes = controller.paneStripStateForTesting.panes
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.last?.sessionRequest.command, "pnpm run dev")
    }

    func test_runTaskRunnerWithUnknownShellState_opensNewPane() throws {
        let adapter = RecordingRootTerminalAdapter()
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        let controller = makeController(runtimeRegistry: registry)
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-main")
        let worklane = makeTaskRunnerWorklane(
            paneID: paneID,
            shellActivityState: .unknown
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        controller.runTaskRunnerForTesting(makeTaskRunnerAction(command: "pnpm run dev"))

        XCTAssertEqual(adapter.cancelPromptInputCallCount, 0)
        XCTAssertEqual(adapter.submittedCommands, [])
        XCTAssertEqual(controller.paneStripStateForTesting.panes.count, 2)
    }

    func test_runTaskRunnerAtIdlePromptWithActiveTerminalProgress_opensNewPane() throws {
        let adapter = RecordingRootTerminalAdapter()
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        let controller = makeController(runtimeRegistry: registry)
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-main")
        let worklane = makeTaskRunnerWorklane(
            paneID: paneID,
            shellActivityState: .promptIdle,
            terminalProgress: TerminalProgressReport(state: .indeterminate, progress: nil)
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        controller.runTaskRunnerForTesting(makeTaskRunnerAction(command: "pnpm run dev"))

        XCTAssertEqual(adapter.cancelPromptInputCallCount, 0)
        XCTAssertEqual(adapter.submittedCommands, [])
        XCTAssertEqual(controller.paneStripStateForTesting.panes.count, 2)
    }

    func test_runTaskRunnerAtIdlePromptWithEnvironment_opensNewPanePreservingEnvironment() throws {
        let adapter = RecordingRootTerminalAdapter()
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in adapter })
        let controller = makeController(runtimeRegistry: registry)
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-main")
        let worklane = makeTaskRunnerWorklane(
            paneID: paneID,
            shellActivityState: .promptIdle
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)

        controller.runTaskRunnerForTesting(
            makeTaskRunnerAction(
                command: "npm run build",
                environment: ["NODE_ENV": "production"]
            )
        )

        XCTAssertEqual(adapter.cancelPromptInputCallCount, 0)
        XCTAssertEqual(adapter.submittedCommands, [])
        let panes = controller.paneStripStateForTesting.panes
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.last?.sessionRequest.environmentVariables["NODE_ENV"], "production")
    }

    func test_remoteImageUploadTaskIsCancelledWhenPaneIsClosed() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-upload")
        let siblingPaneID = PaneID("pane-sibling")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID, title: "upload"),
                    PaneState(id: siblingPaneID, title: "sibling"),
                ],
                focusedPaneID: paneID
            )
        )
        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        controller.insertRemoteImageUploadTaskForTesting(task, for: paneID)

        controller.closePaneByID(paneID)

        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(controller.hasRemoteImageUploadTaskForTesting(for: paneID))
    }

    func test_remoteImageUploadTasksAreCancelledOnControllerTeardown() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let firstPaneID = PaneID("pane-upload-1")
        let secondPaneID = PaneID("pane-upload-2")
        let firstTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let secondTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        controller.insertRemoteImageUploadTaskForTesting(firstTask, for: firstPaneID)
        controller.insertRemoteImageUploadTaskForTesting(secondTask, for: secondPaneID)

        controller.cancelAllRemoteImageUploads()

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertTrue(secondTask.isCancelled)
        XCTAssertFalse(controller.hasRemoteImageUploadTaskForTesting(for: firstPaneID))
        XCTAssertFalse(controller.hasRemoteImageUploadTaskForTesting(for: secondPaneID))
    }

    func test_root_controller_global_search_aggregates_results_across_worklanes() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let worklane1 = WorklaneState(
            id: WorklaneID("worklane-1"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-1"), title: "shell")],
                focusedPaneID: PaneID("pane-1")
            )
        )
        let worklane2 = WorklaneState(
            id: WorklaneID("worklane-2"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: PaneID("pane-2"), title: "shell")],
                focusedPaneID: PaneID("pane-2")
            )
        )

        controller.replaceWorklanes([worklane1, worklane2], activeWorklaneID: worklane1.id)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")

        XCTAssertTrue(controller.isGlobalSearchPresentedForTesting)
        XCTAssertEqual(
            controller.globalSearchStateForTesting,
            GlobalSearchState(
                needle: "build",
                selected: -1,
                total: 2,
                hasRememberedSearch: true,
                isHUDVisible: true
            )
        )
    }

    func test_root_controller_find_ends_global_search_and_reopens_local_search_on_focused_pane() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-1")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-1"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )

        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")
        controller.handle(.find)

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertEqual(
            controller.focusedPaneSearchStateForTesting,
            PaneSearchState(
                needle: "",
                selected: -1,
                total: 0,
                hasRememberedSearch: true,
                isHUDVisible: true,
                hudCorner: .topTrailing
            )
        )
    }

    func test_root_controller_use_selection_for_find_ends_global_search_and_reopens_local_search_on_focused_pane() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID = PaneID("pane-1")
        let worklane = WorklaneState(
            id: WorklaneID("worklane-1"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            )
        )

        controller.replaceWorklanes([worklane], activeWorklaneID: worklane.id)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")
        controller.handle(.useSelectionForFind)

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertEqual(
            controller.focusedPaneSearchStateForTesting,
            PaneSearchState(
                needle: "",
                selected: -1,
                total: 0,
                hasRememberedSearch: true,
                isHUDVisible: true,
                hudCorner: .topTrailing
            )
        )
    }

    func test_root_controller_invalidates_global_search_when_pane_structure_changes() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        let paneID1 = PaneID("pane-1")
        let paneID2 = PaneID("pane-2")
        let worklaneID = WorklaneID("worklane-1")

        let initialWorklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID1, title: "shell")],
                focusedPaneID: paneID1
            )
        )
        let updatedWorklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(id: paneID1, title: "shell"),
                    PaneState(id: paneID2, title: "shell 2"),
                ],
                focusedPaneID: paneID1
            )
        )

        controller.replaceWorklanes([initialWorklane], activeWorklaneID: worklaneID)
        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")

        XCTAssertTrue(controller.isGlobalSearchPresentedForTesting)
        XCTAssertTrue(controller.globalSearchStateForTesting.hasRememberedSearch)

        controller.replaceWorklanes([updatedWorklane], activeWorklaneID: worklaneID)

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertFalse(controller.isGlobalSearchPresentedForTesting)
    }

    func test_root_controller_escape_from_sidebar_global_search_ends_search() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        controller.handle(.globalFind)
        controller.updateGlobalSearchQueryForTesting("build")
        controller.closeGlobalSearchForTesting()

        XCTAssertEqual(controller.globalSearchStateForTesting, GlobalSearchState())
        XCTAssertFalse(controller.isGlobalSearchPresentedForTesting)
    }

}

private func makeTaskRunnerWorklane(
    paneID: PaneID,
    shellActivityState: PaneShellActivityState,
    terminalProgress: TerminalProgressReport? = nil
) -> WorklaneState {
    WorklaneState(
        id: WorklaneID("worklane-main"),
        title: nil,
        paneStripState: PaneStripState(
            panes: [PaneState(id: paneID, title: "shell")],
            focusedPaneID: paneID
        ),
        auxiliaryStateByPaneID: [
            paneID: PaneAuxiliaryState(
                raw: PaneRawState(
                    shellActivityState: shellActivityState,
                    terminalProgress: terminalProgress
                )
            )
        ]
    )
}

private func makeTaskRunnerAction(
    command: String,
    environment: [String: String] = [:]
) -> TaskRunnerAction {
    TaskRunnerAction(
        id: "package|/repo/package.json|dev",
        title: "dev",
        description: nil,
        sourceKind: .packageScript,
        sourcePath: "/repo/package.json",
        sourceRoot: "/repo",
        workingDirectory: "/repo",
        executionCommand: command,
        commandPreview: command,
        environment: environment,
        disabledReason: nil
    )
}

private final class RecordingRootTerminalAdapter: TerminalAdapter {
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    let hasScrollback = false
    let cellWidth: CGFloat = 8
    let cellHeight: CGFloat = 16
    private(set) var sentTexts: [String] = []
    private(set) var cancelPromptInputCallCount = 0
    private(set) var submittedCommands: [String] = []

    func makeTerminalView() -> NSView {
        NSView()
    }

    func startSession(using request: TerminalSessionRequest) throws {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}

    func sendText(_ text: String) {
        sentTexts.append(text)
    }

    func cancelPromptInput() {
        cancelPromptInputCallCount += 1
    }

    func submitCommand(_ command: String) {
        submittedCommands.append(command)
        sendText(command + "\r")
    }

    func close() {}
}
