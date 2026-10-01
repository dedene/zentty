import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalOverlaySessionTests: XCTestCase {
    func test_overlay_is_embedded_in_worklane_or_pane_with_inset() throws {
        let controller = MainWindowController().prepareForHostedTesting()
        addTeardownBlock { controller.closeWindowBypassingConfirmation() }
        controller.showWindow(nil)
        let paneID = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)

        for placement in PaneOverlayIPCOptions.Placement.allCases {
            let options = PaneOverlayIPCOptions(command: "/bin/sleep 5", workingDirectory: "/tmp",
                                                wait: true, follow: false, notify: false,
                                                sizePercent: 100, placement: placement)
            let id = try controller.openOverlay(on: paneID, options: options)
            let overlayView = try XCTUnwrap(findOverlay(id, in: try XCTUnwrap(controller.window.contentView)))
            let anchor = try XCTUnwrap(overlayView.superview)
            XCTAssertTrue(overlayView.window === controller.window)
            XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: overlayView) == true)
            XCTAssertEqual(overlayView.frame, anchor.bounds.insetBy(dx: 16, dy: 16))
            if placement == .worklane {
                XCTAssertTrue(anchor is QuickActionOverlayContainerView)
            } else {
                XCTAssertTrue(anchor is PaneContainerView)
            }
            try controller.closeOverlay(on: paneID)
        }
    }

    // Controller lifecycle tests use fake surfaces; the embedding test above covers real Ghostty.
    private func mockController(adapterFactory: @escaping (PaneID) -> any TerminalAdapter = { _ in OverlayTestAdapter() }) -> MainWindowController {
        let controller = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            overlayAdapterFactory: adapterFactory
        ).prepareForHostedTesting()
        addTeardownBlock { controller.closeWindowBypassingConfirmation() }
        controller.showWindow(nil)
        return controller
    }

    private func options(placement: PaneOverlayIPCOptions.Placement = .worklane,
                         cwd: String? = "/tmp", follow: Bool = false, wait: Bool = true) -> PaneOverlayIPCOptions {
        PaneOverlayIPCOptions(command: "test command", workingDirectory: cwd, wait: wait,
                              follow: follow, notify: false, sizePercent: 100, placement: placement)
    }

    private func entries(_ controller: MainWindowController, on paneID: PaneID? = nil) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try controller.overlayListJSON(on: paneID).utf8)) as? [[String: Any]])
    }

    func test_open_show_and_close_report_missing_panes_and_sessions() throws {
        let controller = mockController()
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertThrowsError(try controller.openOverlay(on: PaneID("unknown"), options: options())) {
            XCTAssertEqual($0 as? TerminalOverlayError, .paneNotFound)
        }
        for action in [controller.showOverlay(on:), controller.closeOverlay(on:)] {
            XCTAssertThrowsError(try action(pane)) {
                XCTAssertEqual($0 as? TerminalOverlayError, .notOpen)
            }
        }
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_invalid_working_directories_do_not_register_sessions() throws {
        let controller = mockController()
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for path in [file.path, file.appendingPathComponent("missing").path] {
            XCTAssertThrowsError(try controller.openOverlay(on: pane, options: options(cwd: path))) {
                XCTAssertEqual($0 as? TerminalOverlayError, .invalidWorkingDirectory(path))
            }
            XCTAssertTrue(try self.entries(controller).isEmpty)
        }
    }

    func test_start_failure_closes_adapter_and_removes_registered_session() throws {
        let adapter = OverlayTestAdapter()
        adapter.startError = OverlayTestAdapter.Failure.start
        let controller = mockController(adapterFactory: { _ in adapter })
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertThrowsError(try controller.openOverlay(on: pane, options: options())) {
            XCTAssertTrue($0 is OverlayTestAdapter.Failure)
        }
        XCTAssertEqual(adapter.closeCount, 1)
        XCTAssertTrue(try self.entries(controller).isEmpty)
        XCTAssertNil(controller.overlaySessionForTesting(on: pane))
    }

    func test_close_callback_removes_session_and_repeated_close_is_noop() throws {
        let adapter = OverlayTestAdapter()
        let controller = mockController(adapterFactory: { _ in adapter })
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options())
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        let removeSession = session.onClose
        var closeCallbacks = 0
        session.onClose = { closeCallbacks += 1; removeSession?() }
        session.close()
        session.close()
        XCTAssertEqual(closeCallbacks, 1)
        XCTAssertEqual(adapter.closeCount, 1)
        XCTAssertNil(session.view.superview)
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_surface_closed_event_removes_session() throws {
        let adapter = OverlayTestAdapter()
        let controller = mockController(adapterFactory: { _ in adapter })
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options())
        adapter.eventDidOccur?(.surfaceClosed)
        XCTAssertEqual(adapter.closeCount, 1)
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_command_finished_without_wait_records_exit_code_in_list() throws {
        let adapter = OverlayTestAdapter()
        let controller = mockController(adapterFactory: { _ in adapter })
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options(wait: false))
        XCTAssertEqual(adapter.request?.waitAfterNativeCommand, false)
        adapter.eventDidOccur?(.commandFinished(exitCode: 17, durationNanoseconds: 123))
        XCTAssertEqual(try self.entries(controller).first?["exitCode"] as? Int, 17)
        XCTAssertEqual(adapter.closeCount, 0)
    }

    func test_window_close_closes_all_overlays_without_restoring_focus() throws {
        var adapters: [OverlayTestAdapter] = []
        let controller = mockController(adapterFactory: { _ in
            let adapter = OverlayTestAdapter(); adapters.append(adapter); return adapter
        })
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options())
        let worklaneOverlay = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        _ = try controller.openOverlay(on: pane, options: options(placement: .pane))
        let paneOverlay = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        var restores = 0
        worklaneOverlay.onRestoreFocus = { restores += 1 }
        paneOverlay.onRestoreFocus = { restores += 1 }
        XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: paneOverlay.view) == true)
        controller.closeWindowBypassingConfirmation()
        XCTAssertEqual(restores, 0)
        XCTAssertEqual(adapters.map(\.closeCount), [1, 1])
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_closing_owning_pane_closes_pane_overlay() throws {
        let adapter = OverlayTestAdapter()
        let controller = mockController(adapterFactory: { _ in adapter })
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try XCTUnwrap(controller.splitWithLayout(placement: .afterFocused, isHorizontal: true, layout: .equal))
        _ = try controller.openOverlay(on: pane, options: options(placement: .pane))
        _ = controller.worklaneStore.closePane(id: pane)
        XCTAssertEqual(adapter.closeCount, 1)
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_moving_pane_updates_pane_overlay_worklane() throws {
        let controller = mockController()
        let source = controller.worklaneStore.activeWorklaneID
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options(placement: .pane))
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        controller.newWorklane(nil)
        let destination = controller.worklaneStore.activeWorklaneID
        controller.focusWorklane(id: source)
        controller.transferPaneToWorklaneInThisWindow(paneID: pane, targetWorklaneID: destination)
        XCTAssertEqual(session.worklaneID, destination)
        XCTAssertEqual(try self.entries(controller).first?["worklaneID"] as? String, destination.rawValue)
        XCTAssertTrue(controller.overlaySessionForTesting(on: pane) === session)
    }

    func test_deleting_worklane_closes_its_shared_overlay() throws {
        let adapter = OverlayTestAdapter()
        let controller = mockController(adapterFactory: { _ in adapter })
        let source = controller.worklaneStore.activeWorklaneID
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options())
        controller.newWorklane(nil)
        controller.focusWorklane(id: source)
        controller.worklaneStore.closeActiveWorklane()
        XCTAssertEqual(adapter.closeCount, 1)
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_hide_restores_focus_only_when_overlay_holds_focus() throws {
        let controller = mockController()
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: options())
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        let restore = session.onRestoreFocus
        var restores = 0
        session.onRestoreFocus = { restores += 1; restore?() }
        session.hide()
        XCTAssertEqual(restores, 1)
        XCTAssertFalse((controller.window.firstResponder as? NSView)?.isDescendant(of: session.view) == true)
        session.hide()
        XCTAssertEqual(restores, 1)
        try controller.showOverlay(on: pane)
        _ = controller.window.makeFirstResponder(nil)
        session.hide()
        XCTAssertEqual(restores, 1)
    }

    func test_show_selects_overlay_worklane_and_follow_selects_and_focuses() throws {
        let controller = mockController()
        let source = controller.worklaneStore.activeWorklaneID
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        controller.newWorklane(nil)
        let destination = controller.worklaneStore.activeWorklaneID
        _ = try controller.openOverlay(on: pane, options: options())
        XCTAssertEqual(controller.worklaneStore.activeWorklaneID, destination)
        try controller.showOverlay(on: pane)
        XCTAssertEqual(controller.worklaneStore.activeWorklaneID, source)
        try controller.closeOverlay(on: pane)
        controller.focusWorklane(id: destination)
        _ = try controller.openOverlay(on: pane, options: options(follow: true))
        XCTAssertEqual(controller.worklaneStore.activeWorklaneID, source)
        let session = try XCTUnwrap(controller.overlaySessionForTesting(on: pane))
        XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: session.view) == true)
    }

    func test_overlay_handler_does_not_implicitly_focus_target_pane() throws {
        let controller = mockController()
        let lane = controller.worklaneStore.activeWorklaneID
        let paneA = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        let paneB = try XCTUnwrap(controller.splitWithLayout(placement: .afterFocused, isHorizontal: true, layout: .equal))
        controller.focusPane(id: paneA, in: lane)
        let delegate = AppDelegate(shouldOpenMainWindow: false)
        let target = AgentIPCTarget(windowID: controller.windowID, worklaneID: lane, paneID: paneB)
        func dispatch(_ subcommand: PaneIPCSubcommand, arguments: [String] = []) throws {
            let request = AgentIPCRequest(kind: .pane, arguments: arguments, standardInput: nil,
                                          environment: [:], expectsResponse: true, subcommand: subcommand.rawValue)
            _ = try PaneIPCHandler.dispatch(subcommand: subcommand, request: request, target: target,
                                            windowController: controller, appDelegate: delegate)
        }
        try dispatch(.overlayOpen, arguments: ["--command-json", "[\"test\"]"])
        XCTAssertEqual(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID, paneA)
        try dispatch(.overlayList)
        XCTAssertEqual(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID, paneA)
        try dispatch(.overlayClose)
        XCTAssertEqual(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID, paneA)
        // Show intentionally focuses the target; a missing overlay must not focus it preemptively.
        XCTAssertThrowsError(try dispatch(.overlayShow))
        XCTAssertEqual(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID, paneA)
    }

    private func findOverlay(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.findOverlay(id, in: $0) }.first
    }

    func test_shortcut_hides_and_restores_the_same_focused_shell_overlay() throws {
        let controller = mockController()
        controller.toggleQuickActionOverlay(nil)
        let list = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try controller.overlayListJSON().utf8)) as? [[String: Any]]
        )
        let id = try XCTUnwrap(list.first?["id"] as? String)
        let overlayView = try XCTUnwrap(findOverlay(id, in: try XCTUnwrap(controller.window.contentView)))
        XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: overlayView) == true)

        controller.toggleQuickActionOverlay(nil)
        XCTAssertTrue(overlayView.isHidden)
        XCTAssertNotNil(overlayView.superview)
        XCTAssertTrue(try controller.overlayListJSON().contains(id))
        XCTAssertFalse((controller.window.firstResponder as? NSView)?.isDescendant(of: overlayView) == true)

        controller.toggleQuickActionOverlay(nil)
        XCTAssertFalse(overlayView.isHidden)
        XCTAssertTrue(try controller.overlayListJSON().contains(id))
        XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: overlayView) == true)
    }

    func test_worklane_switch_hides_overlay_and_return_keeps_it_hidden() throws {
        let controller = mockController()
        let firstWorklaneID = controller.worklaneStore.activeWorklaneID
        controller.toggleQuickActionOverlay(nil)
        let firstList = try controller.overlayListJSON()
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstList.utf8)) as? [[String: Any]])
        let firstID = try XCTUnwrap(entries.first?["id"] as? String)
        let firstView = try XCTUnwrap(findOverlay(firstID, in: try XCTUnwrap(controller.window.contentView)))

        controller.newWorklane(nil)
        XCTAssertTrue(firstView.isHidden)
        controller.toggleQuickActionOverlay(nil)
        let bothEntries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try controller.overlayListJSON().utf8)) as? [[String: Any]])
        XCTAssertEqual(bothEntries.count, 2)
        let secondID = try XCTUnwrap(bothEntries.first { $0["id"] as? String != firstID }?["id"] as? String)
        let secondView = try XCTUnwrap(findOverlay(secondID, in: try XCTUnwrap(controller.window.contentView)))
        XCTAssertFalse(secondView.isHidden)

        controller.focusWorklane(id: firstWorklaneID)
        XCTAssertTrue(firstView.isHidden)
        XCTAssertTrue(secondView.isHidden)
        controller.toggleQuickActionOverlay(nil)
        XCTAssertFalse(firstView.isHidden)
        XCTAssertTrue(secondView.isHidden)
        XCTAssertTrue((controller.window.firstResponder as? NSView)?.isDescendant(of: firstView) == true)
    }

    func test_worklane_overlay_survives_focus_changes_and_its_original_pane_closing() throws {
        let controller = mockController()
        let worklaneID = controller.worklaneStore.activeWorklaneID
        let originalPaneID = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        controller.toggleQuickActionOverlay(nil)
        let originalList = try controller.overlayListJSON()
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(originalList.utf8)) as? [[String: Any]])
        let id = try XCTUnwrap(entries.first?["id"] as? String)
        let overlayView = try XCTUnwrap(findOverlay(id, in: try XCTUnwrap(controller.window.contentView)))
        controller.toggleQuickActionOverlay(nil)

        let secondPaneID = try XCTUnwrap(controller.splitWithLayout(placement: .afterFocused, isHorizontal: true, layout: .equal))
        controller.focusPane(id: secondPaneID, in: worklaneID)
        controller.toggleQuickActionOverlay(nil)
        XCTAssertFalse(overlayView.isHidden)
        XCTAssertEqual(try controller.overlayListJSON(), originalList)
        controller.toggleQuickActionOverlay(nil)

        _ = controller.worklaneStore.closePane(id: originalPaneID)
        controller.toggleQuickActionOverlay(nil)
        XCTAssertFalse(overlayView.isHidden)
        XCTAssertTrue(try controller.overlayListJSON().contains(id))
        XCTAssertFalse(try controller.overlayListJSON().contains(originalPaneID.rawValue))
        try controller.closeOverlay(on: secondPaneID)
        XCTAssertNil(overlayView.superview)
        XCTAssertTrue(try self.entries(controller).isEmpty)
    }

    func test_overlay_cannot_open_or_restore_while_worklane_preview_is_active() throws {
        for hasExistingSession in [false, true] {
            let controller = mockController()
            let root = controller.rootViewControllerForTesting
            var overlayView: NSView?
            if hasExistingSession {
                controller.toggleQuickActionOverlay(nil)
                let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try controller.overlayListJSON().utf8)) as? [[String: Any]])
                let id = try XCTUnwrap(entries.first?["id"] as? String)
                overlayView = try XCTUnwrap(findOverlay(id, in: try XCTUnwrap(controller.window.contentView)))
                controller.toggleQuickActionOverlay(nil)
            }
            let originalList = try controller.overlayListJSON()

            root.routeNextWorklane()
            XCTAssertTrue(root.isWorklanePeekActive)
            controller.toggleQuickActionOverlay(nil)
            XCTAssertEqual(try controller.overlayListJSON(), originalList)
            root.routeNextWorklane()
            controller.toggleQuickActionOverlay(nil)
            XCTAssertEqual(try controller.overlayListJSON(), originalList)
            if let overlayView { XCTAssertTrue(overlayView.isHidden) }

            var overlayRequests = 0
            root.onToggleQuickActionOverlayRequested = { overlayRequests += 1 }
            root.routeToggleQuickActionOverlay()
            XCTAssertEqual(overlayRequests, 0)
            controller.closeWindowBypassingConfirmation()
        }
    }

    func test_overlay_placement_limits_targeted_list_and_close_precedence() throws {
        let controller = mockController()
        let laneID = controller.worklaneStore.activeWorklaneID
        let paneA = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        let paneB = try XCTUnwrap(controller.splitWithLayout(placement: .afterFocused, isHorizontal: true, layout: .equal))
        let shared = PaneOverlayIPCOptions(command: "/bin/sleep 30", workingDirectory: "/tmp", wait: true,
                                           follow: false, notify: false, sizePercent: 100)
        var paneOptions = shared
        paneOptions.placement = .pane
        let sharedID = try controller.openOverlay(on: paneA, options: shared)
        XCTAssertThrowsError(try controller.openOverlay(on: paneB, options: shared))
        let paneAID = try controller.openOverlay(on: paneA, options: paneOptions)
        let paneBID = try controller.openOverlay(on: paneB, options: paneOptions)
        XCTAssertThrowsError(try controller.openOverlay(on: paneB, options: paneOptions))

        let listA = try controller.overlayListJSON(on: paneA)
        XCTAssertTrue(listA.contains(sharedID))
        XCTAssertTrue(listA.contains(paneAID))
        XCTAssertFalse(listA.contains(paneBID))
        let listB = try controller.overlayListJSON(on: paneB)
        XCTAssertTrue(listB.contains(sharedID))
        XCTAssertTrue(listB.contains(paneBID))
        XCTAssertFalse(listB.contains(paneAID))

        controller.newWorklane(nil)
        let otherPane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        XCTAssertTrue(try self.entries(controller, on: otherPane).isEmpty)
        try controller.closeOverlay(on: paneB)
        XCTAssertFalse(try controller.overlayListJSON().contains(paneBID))
        XCTAssertTrue(try controller.overlayListJSON().contains(sharedID))
        try controller.showOverlay(on: paneB)
        XCTAssertEqual(controller.worklaneStore.activeWorklaneID, laneID)
        try controller.closeOverlay(on: paneB)
        XCTAssertFalse(try controller.overlayListJSON().contains(sharedID))
        XCTAssertTrue(try controller.overlayListJSON().contains(paneAID))
    }

    func test_background_overlay_stays_on_source_worklane_without_stealing_selection() throws {
        let controller = mockController()

        let sourceWorklaneID = try XCTUnwrap(controller.worklaneStore.activeWorklaneID)
        let sourcePaneID = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        controller.newWorklane(nil)
        let selectedWorklaneID = try XCTUnwrap(controller.worklaneStore.activeWorklaneID)
        XCTAssertNotEqual(sourceWorklaneID, selectedWorklaneID)

        let options = PaneOverlayIPCOptions(
            command: "/bin/sleep 5",
            workingDirectory: "/tmp",
            wait: true,
            follow: false,
            notify: false,
            sizePercent: 70
        )
        let id = try controller.openOverlay(on: sourcePaneID, options: options)
        addTeardownBlock { try? controller.closeOverlay(on: sourcePaneID) }

        XCTAssertEqual(controller.worklaneStore.activeWorklaneID, selectedWorklaneID)
        XCTAssertTrue(try controller.overlayListJSON().contains(id))
        XCTAssertTrue(try controller.overlayListJSON().contains(sourceWorklaneID.rawValue))
    }
}

@MainActor
private final class OverlayTestAdapter: TerminalAdapter {
    enum Failure: Error { case start }
    let surface = TerminalSurfaceMockView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var startError: Error?
    private(set) var request: TerminalSessionRequest?
    private(set) var closeCount = 0
    func makeTerminalView() -> NSView { surface }
    func startSession(using request: TerminalSessionRequest) throws {
        self.request = request
        if let startError { throw startError }
    }
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func sendText(_ text: String) {}
    func close() { closeCount += 1 }
}
