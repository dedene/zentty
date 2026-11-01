import AppKit
import OSLog
import XCTest
@testable import Zentty

/// The Agent History palette in a real main window, with fake services injected through
/// `MainWindowController.agentHistoryServices`. Nothing reads the real agent folders, the
/// index or the system pasteboard.
@MainActor
final class AgentHistoryPaletteHostedTests: XCTestCase {
    private var controller: MainWindowController?
    private var defaultsSuiteNames: [String] = []
    private var temporaryDirectories: [URL] = []
    private let recorder = TerminalKeyRecorder()
    private let control = FakeAgentHistoryControl()
    private let search = FakeAgentHistorySearch()
    private let launch = FakeAgentHistoryLaunch()
    private var excludedFolders: [String] = []

    override func tearDown() {
        if let controller {
            controller.rootViewControllerForTesting.agentHistoryCoordinatorForTesting.close(restoreFocus: false)
            controller.closeWindowBypassingConfirmation()
        }
        controller = nil
        for name in defaultsSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        defaultsSuiteNames.removeAll()
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Opening and closing

    func test_shortcut_opens_child_panel_and_second_press_closes_it() throws {
        let controller = makeWindow()
        let event = try XCTUnwrap(HostedKey.shortcut.event(in: controller.window))
        let shortcut = try XCTUnwrap(KeyboardShortcut(event: event))
        let commandID = try XCTUnwrap(ShortcutManager(shortcuts: .default).commandID(for: shortcut))
        XCTAssertEqual(commandID, .showAgentHistory, "⌘⇧H is the Agent History shortcut")

        // What the window's shortcut monitor does with a resolved command.
        root.handle(AppCommandRegistry.definition(for: commandID).action)

        let panel = try XCTUnwrap(panelController.panelForTesting)
        XCTAssertTrue(panel is CommandPalettePanel)
        XCTAssertTrue(panel.parent === controller.window, "the palette is a child panel of its window")
        XCTAssertTrue(controller.window.childWindows?.contains(panel) == true)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.accessibilityLabel(), "Agent History")
        XCTAssertEqual(coordinator.modelForTesting?.context.entryPoint, .shortcutOrMenu)
        XCTAssertEqual(coordinator.modelForTesting?.body, .results)

        // While the panel is key the press reaches the View menu's key equivalent, so the
        // palette's own key routing must let it through.
        let secondPress = try XCTUnwrap(HostedKey.shortcut.event(in: panel))
        XCTAssertFalse(panelController.handleKeyEvent(secondPress))
        XCTAssertEqual(
            AppCommandRegistry.commandID(forMenuAction: #selector(MainWindowController.showAgentHistory(_:))),
            .showAgentHistory
        )
        controller.showAgentHistory(nil)

        XCTAssertFalse(coordinator.isShown)
        waitUntil("the panel leaves the window") { controller.window.childWindows?.contains(panel) != true }
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(control.observerCount, 0, "closing stops the model")
    }

    func test_toolbar_button_toggles_palette_shows_pressed_state_and_is_click_exempt() throws {
        let controller = makeWindow()
        let contentView = try XCTUnwrap(controller.window.contentView)
        let button = try XCTUnwrap(contentView.agentHistoryDescendant(ofType: HistoryToolbarButton.self))
        XCTAssertEqual(button.accessibilityLabel(), "Agent History")
        XCTAssertFalse(button.isPalettePresentedForTesting)

        button.performClick(nil)

        XCTAssertTrue(coordinator.isShown)
        XCTAssertEqual(coordinator.modelForTesting?.context.entryPoint, .toolbar)
        XCTAssertTrue(button.isPalettePresentedForTesting, "the button shows pressed while the palette is open")

        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let onButton = try mouseDown(at: center, in: controller.window)
        XCTAssertTrue(panelController.isExemptClickForTesting(onButton), "the button's own click must not dismiss first")
        let elsewhere = try mouseDown(at: NSPoint(x: controller.window.frame.width / 2, y: 40), in: controller.window)
        XCTAssertFalse(panelController.isExemptClickForTesting(elsewhere))

        button.performClick(nil)

        XCTAssertFalse(coordinator.isShown, "a second click closes the palette")
        XCTAssertFalse(button.isPalettePresentedForTesting)

        // Any other click in the window dismisses it.
        button.performClick(nil)
        XCTAssertTrue(coordinator.isShown)
        let terminal = try XCTUnwrap(recorder.views.first { $0.window === controller.window })
        let terminalCenter = terminal.convert(NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: nil)
        NSApp.sendEvent(try mouseDown(at: terminalCenter, in: controller.window))
        XCTAssertFalse(coordinator.isShown, "a click outside the palette closes it")
        XCTAssertFalse(button.isPalettePresentedForTesting)
    }

    // MARK: - Keys

    func test_keyboard_navigation_and_return_route_primary_and_secondary_to_launcher() throws {
        _ = makeWindow()
        launch.outcome = .failed(message: "No such session", offerCopySessionID: false)
        root.handle(.showAgentHistory)
        let panel = try XCTUnwrap(panelController.panelForTesting)
        let model = try XCTUnwrap(coordinator.modelForTesting)
        let rows = model.rows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(model.selectedKey, rows[0].key, "the newest session starts selected")

        try press(.down, in: panel)
        try press(.down, in: panel)
        try press(.up, in: panel)
        XCTAssertEqual(model.selectedKey, rows[1].key)

        try press(.return, in: panel)
        try press(.commandReturn, in: panel)

        XCTAssertEqual(launch.launches.map(\.intent), [.primary, .secondary])
        XCTAssertEqual(launch.launches.map(\.source.key), [rows[1].key, rows[1].key])
        XCTAssertEqual(launch.launches.map(\.folderChoice), [nil, nil])
        XCTAssertTrue(coordinator.isShown, "a failed launch keeps the palette open")

        launch.outcome = .recreatingWorktree
        try press(.up, in: panel)
        try press(.return, in: panel)

        XCTAssertEqual(launch.launches.last?.source.key, rows[0].key)
        XCTAssertFalse(coordinator.isShown, "a started launch closes the palette")
    }

    /// The `.prohibited` test host never reports a key window, so whether the panel really
    /// becomes key can't be observed here, and keys sent to the panel could never reach the
    /// main window's terminal anyway. This pins what can be checked: the panel can become key,
    /// its search field takes the panel's focus away from the terminal, and the panel's key
    /// routing claims ↑/↓/↩ before the field editor sees them.
    func test_palette_takes_focus_from_terminal_and_claims_navigation_keys() throws {
        let controller = makeWindow()
        launch.outcome = .failed(message: "No such session", offerCopySessionID: false)
        root.focusFocusedTerminalForTesting()
        XCTAssertTrue(
            controller.window.firstResponder is KeyRecordingTerminalView,
            "the terminal has focus before the palette opens"
        )

        root.handle(.showAgentHistory)
        let panel = try XCTUnwrap(panelController.panelForTesting)
        let model = try XCTUnwrap(coordinator.modelForTesting)
        XCTAssertTrue(panel.canBecomeKey)
        waitUntil("the search field takes the panel's focus") { panel.firstResponder is NSTextView }

        for key in [HostedKey.down, .down, .up] {
            let event = try XCTUnwrap(key.event(in: panel))
            XCTAssertTrue(panelController.handleKeyEvent(event), "the palette claims \(key)")
        }
        XCTAssertEqual(model.selectedKey, model.rows[1].key)
        try press(.return, in: panel)
        try press(.commandReturn, in: panel)

        XCTAssertEqual(launch.launches.count, 2, "↩ and ⌘↩ went to the palette")
        XCTAssertEqual(model.query, "", "no navigation key was typed into the search field")
        XCTAssertTrue(coordinator.isShown)
    }

    func test_escape_ladder_closes_panel_last() throws {
        let controller = makeWindow()
        launch.outcome = .needsFolderChoice(
            options: [.homeFolder("\(AgentHistoryHostedFixtures.root)/home"), .copyResumeCommand],
            defaultChoice: .homeFolder("\(AgentHistoryHostedFixtures.root)/home")
        )
        root.handle(.showAgentHistory)
        let panel = try XCTUnwrap(panelController.panelForTesting)
        let model = try XCTUnwrap(coordinator.modelForTesting)
        model.updateQuery("crash")
        try press(.commandY, in: panel)
        XCTAssertNotEqual(model.detail, .none, "⌘Y opens the transcript")
        try press(.return, in: panel)
        XCTAssertNotNil(model.folderSheet, "↩ on a session whose folder is gone asks where to resume")

        try press(.escape, in: panel)
        XCTAssertNil(model.folderSheet, "esc closes the sheet first")
        XCTAssertNotEqual(model.detail, .none)
        XCTAssertEqual(model.query, "crash")

        try press(.escape, in: panel)
        XCTAssertEqual(model.detail, .none, "then the transcript")
        XCTAssertEqual(model.query, "crash")

        try press(.escape, in: panel)
        XCTAssertEqual(model.query, "", "then the query")
        XCTAssertTrue(coordinator.isShown)

        try press(.escape, in: panel)
        XCTAssertFalse(coordinator.isShown, "the palette closes last")
        waitUntil("the panel leaves the window") { controller.window.childWindows?.contains(panel) != true }
    }

    // MARK: - Entry points

    func test_worklane_context_menu_opens_scoped_to_worklane_repository() throws {
        let controller = makeWindow()
        let base = try makeTemporaryDirectory()
        let repo = base.appendingPathComponent("checkout", isDirectory: true)
        let subfolder = repo.appendingPathComponent("Sources/App", isDirectory: true)
        let other = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let repoLane = WorklaneID("agent-history-repo")
        let otherLane = WorklaneID("agent-history-other")
        root.replaceWorklanes([
            worklane(repoLane, title: "REPO", paneID: PaneID("repo-pane"), folder: subfolder.path),
            worklane(otherLane, title: "OTHER", paneID: PaneID("other-pane"), folder: other.path),
        ], activeWorklaneID: otherLane)
        waitForMainQueue()

        let contentView = try XCTUnwrap(controller.window.contentView)
        let sidebar = try XCTUnwrap(contentView.agentHistoryDescendant(ofType: SidebarView.self))
        let row = try XCTUnwrap(
            sidebar.agentHistoryDescendants(ofType: SidebarWorklaneRowButton.self).first { $0.worklaneID == repoLane }
        )
        let menu = try XCTUnwrap(row.menu(for: try rightMouseDown(in: controller.window)))
        let item = try XCTUnwrap(menu.item(withTitle: "Agent History for This Project"))
        menu.performActionForItem(at: menu.index(of: item))

        // The panel opens at once; the repository lookups (disk) run off main and land after.
        XCTAssertTrue(coordinator.isShown)
        let model = try XCTUnwrap(coordinator.modelForTesting)
        XCTAssertNil(model.context.currentProject, "the pane's project resolves off main, after the panel opens")
        XCTAssertEqual(model.body, .loading, "results wait briefly for the worklane's project")
        waitUntil("worklane project resolved") { model.body == .results }
        let expectedKey = AgentHistoryPath.canonical(repo.path)
        XCTAssertEqual(model.context.entryPoint, .worklaneContextMenu(repoLane))
        guard case .project(let scope) = model.scope else {
            return XCTFail("the worklane menu opens on the worklane's project, got \(model.scope)")
        }
        XCTAssertEqual(scope.key, expectedKey, "a subfolder scopes to its repository root")
        XCTAssertEqual(scope.displayName, "checkout")
        XCTAssertEqual(search.recentScopes.last, .project(scope))
        XCTAssertEqual(
            model.context.currentProject?.key, AgentHistoryPath.canonical(other.path),
            "the focused pane's project stays the window's current project"
        )

        try press(.escape, in: try XCTUnwrap(panelController.panelForTesting))
        XCTAssertFalse(coordinator.isShown)
    }

    func test_opening_command_palette_closes_agent_history() throws {
        _ = makeWindow()
        root.handle(.showAgentHistory)
        XCTAssertTrue(coordinator.isShown)

        root.handle(.showCommandPalette)

        XCTAssertFalse(coordinator.isShown, "the command palette replaces Agent History")
        XCTAssertTrue(root.isCommandPaletteShownForTesting)

        root.handle(.showAgentHistory)

        XCTAssertTrue(coordinator.isShown)
        XCTAssertFalse(root.isCommandPaletteShownForTesting, "and Agent History replaces the command palette")
    }

    // MARK: - Focus

    func test_add_folder_panel_returns_key_focus_to_history_field() throws {
        var status = AgentHistoryHostedFixtures.readyStatus
        status.hasConsented = false
        status.isEnabled = false
        status.state = .off
        let controller = makeWindow(status: status)
        root.handle(.showAgentHistory)
        let panel = try XCTUnwrap(panelController.panelForTesting)
        let model = try XCTUnwrap(coordinator.modelForTesting)
        XCTAssertEqual(model.body, .consent)
        let focusRequestsBefore = model.queryFocusRequest

        // Like `NSOpenPanel`: takes key focus, then hands it to the parent window on close.
        let picked = URL(fileURLWithPath: "\(AgentHistoryHostedFixtures.root)/secrets", isDirectory: true)
        var pickerParent: NSWindow?
        var dismissSuspendedWhilePicking = false
        panelController.folderPicker = { [unowned self] parent, completion in
            pickerParent = parent
            dismissSuspendedWhilePicking = self.panelController.isDismissMonitorSuspendedForTesting
            parent?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                completion([picked])
            }
        }

        model.requestAddExcludedFolder()
        XCTAssertTrue(pickerParent === controller.window, "the picker is attached to the main window")
        waitUntil("the picker completes") { model.queryFocusRequest != focusRequestsBefore }

        // The `.prohibited` test host never reports key windows, so this checks what the panel
        // controller does about it: it calls `makeKey()` on the panel and asks the history field
        // for focus, after the picker's clicks were kept from dismissing the palette.
        XCTAssertTrue(dismissSuspendedWhilePicking, "clicks in the picker must not dismiss the palette")
        XCTAssertFalse(panelController.isDismissMonitorSuspendedForTesting, "dismissal works again afterwards")
        XCTAssertTrue(coordinator.isShown, "picking a folder doesn't dismiss the palette")
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(model.consent?.excludedFolders, AgentHistoryConsentModel.normalizedFolders([picked.path]))
        XCTAssertGreaterThan(model.queryFocusRequest, focusRequestsBefore, "the history field asks for focus back")
    }

    // MARK: - Budget

    func test_palette_first_frame_signpost_under_80ms() throws {
        _ = makeWindow()
        let signposter = OSSignposter(subsystem: "be.zenjoy.zentty", category: .pointsOfInterest)
        let clock = ContinuousClock()
        let state = signposter.beginInterval("AgentHistoryPaletteFirstFrame")
        let start = clock.now

        root.handle(.showAgentHistory)
        let panel = try XCTUnwrap(panelController.panelForTesting)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        let elapsed = clock.now - start
        signposter.endInterval("AgentHistoryPaletteFirstFrame", state)
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        let attachment = XCTAttachment(string: String(format: "Agent History first frame: %.1f ms", milliseconds))
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(coordinator.modelForTesting?.rows.count, 3, "the first frame shows the recent sessions")
        if ProcessInfo.processInfo.environment["ZENTTY_HISTORY_BENCH"] == "1" {
            XCTAssertLessThan(milliseconds, 80, "palette first frame budget (§10)")
        }
    }

    // MARK: - Helpers

    private var root: RootViewController {
        controller!.rootViewControllerForTesting
    }

    private var coordinator: AgentHistoryPaletteCoordinator {
        root.agentHistoryCoordinatorForTesting
    }

    private var panelController: AgentHistoryPanelController {
        coordinator.panelControllerForTesting
    }

    private func makeWindow(status: AgentHistoryStatus = AgentHistoryHostedFixtures.readyStatus) -> MainWindowController {
        let suiteName = "ZenttyTests.AgentHistoryPaletteHostedTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        SidebarVisibilityPreference.persist(.pinnedOpen, in: defaults)

        control.status = status
        control.detectedSources = [AgentHistoryHostedFixtures.claudeDetected]
        search.recent = [
            AgentHistoryHostedFixtures.session(1, title: "Fix the crash on launch", minutesAgo: 5),
            AgentHistoryHostedFixtures.session(2, title: "Add the history palette", minutesAgo: 60),
            AgentHistoryHostedFixtures.session(3, title: "Tidy the sidebar", minutesAgo: 600),
        ]
        search.sessionCount = search.recent.count
        let crash = search.recent[0]
        search.metadataResults = { query in
            query.isEmpty ? [] : [HistoryMetadataResult(
                session: crash, score: 1, isWordLevel: true,
                titleHighlights: [NSRange(location: 8, length: 5)], note: nil
            )]
        }

        let recorder = recorder
        let controller = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in KeyRecordingTerminalAdapter(recorder: recorder) }),
            sidebarWidthDefaults: defaults,
            sidebarVisibilityDefaults: defaults,
            paneLayoutDefaults: defaults
        ).prepareForHostedTesting()
        self.controller = controller
        controller.agentHistoryServices = makeServices()
        controller.showWindow(nil)
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private func makeServices() -> AgentHistoryPaletteServices {
        let pasteboard = AgentHistoryTestPasteboard.make()
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        return AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: launch,
            excludedFolders: { [unowned self] in self.excludedFolders },
            setExcludedFolders: { [unowned self] in self.excludedFolders = $0 },
            claudeRetention: { $0(AgentHistoryHostedFixtures.retention) },
            raiseClaudeRetention: { $0(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: pasteboard,
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_100) }
        )
    }

    /// Delivers a key the way AppKit does: through the app, its event monitors, then the window.
    private func press(_ key: HostedKey, in panel: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let event = try XCTUnwrap(key.event(in: panel), file: file, line: line)
        NSApp.sendEvent(event)
    }

    private func worklane(_ id: WorklaneID, title: String, paneID: PaneID, folder: String) -> WorklaneState {
        WorklaneState(
            id: id,
            title: title,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell", sessionRequest: TerminalSessionRequest(workingDirectory: folder))],
                focusedPaneID: paneID
            ),
            paneContextByPaneID: [
                paneID: PaneShellContext(scope: .local, path: folder, home: NSHomeDirectory(), user: "tester", host: "mbp"),
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyAgentHistoryHosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func mouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }

    private func rightMouseDown(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 12, y: 12), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }

    private func waitForMainQueue() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// Polls on the main queue until `condition` holds (or fails after `timeout`).
    private func waitUntil(_ description: String, timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline {
                done.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                MainActor.assumeIsolated { poll() }
            }
        }
        poll()
        wait(for: [done], timeout: timeout + 1)
        XCTAssertTrue(condition(), description)
    }
}
