import AppKit
import SwiftUI
import XCTest
@testable import Zentty

/// Window-less checks for the palette's coordinator, panel helpers and SwiftUI body.
@MainActor
final class AgentHistoryPaletteCoordinatorTests: XCTestCase {
    private let worklaneProject = AgentHistoryProjectScope(
        key: "/tmp/agent-history-tests/worklane", displayName: "worklane", allowsCWDPrefix: true
    )
    private let focusedProject = AgentHistoryProjectScope(
        key: "/tmp/agent-history-tests/focused", displayName: "focused", allowsCWDPrefix: true
    )

    func test_worklane_entry_opens_on_its_project_and_falls_back_to_all() {
        let scoped = AgentHistoryPaletteCoordinator.openContext(
            entryPoint: .worklaneContextMenu(WorklaneID("lane")),
            currentProject: focusedProject,
            worklaneProject: worklaneProject,
            windowID: WindowID("window")
        )
        XCTAssertEqual(scoped.initialScope, .project(worklaneProject))
        XCTAssertEqual(scoped.currentProject, focusedProject)

        let fallback = AgentHistoryPaletteCoordinator.openContext(
            entryPoint: .worklaneContextMenu(WorklaneID("lane")),
            currentProject: focusedProject,
            worklaneProject: nil,
            windowID: WindowID("window")
        )
        XCTAssertEqual(fallback.initialScope, .all)
    }

    /// The palette's "Settings" link opens Settings › Agent History, not another section.
    func test_root_controller_settings_link_requests_the_agent_history_section() {
        let controller = RootViewController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            sidebarWidthDefaults: SidebarWidthPreference.userDefaults(),
            sidebarVisibilityDefaults: SidebarVisibilityPreference.userDefaults()
        )
        controller.loadViewIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                controller.prepareForTestingTearDown()
            }
        }
        var requested: [SettingsSection] = []
        controller.onShowSettingsSectionRequested = { requested.append($0) }

        (controller as AgentHistoryPaletteHost).agentHistoryShowSettings()

        XCTAssertEqual(requested, [.agentHistory])
    }

    func test_other_entries_open_on_all_projects_with_focused_project_one_tab_away() {
        for entry in [AgentHistoryEntryPoint.shortcutOrMenu, .toolbar, .commandPalette] {
            let context = AgentHistoryPaletteCoordinator.openContext(
                entryPoint: entry,
                currentProject: focusedProject,
                worklaneProject: worklaneProject,
                windowID: WindowID("window")
            )
            XCTAssertEqual(context.initialScope, .all)
            XCTAssertEqual(context.currentProject, focusedProject)
            XCTAssertEqual(context.hostWindowID, WindowID("window"))
        }
    }

    func test_show_without_services_does_nothing() {
        // A real (never shown) window, so `show` gets past the window guard to the services one.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        let host = StubPaletteHost(window: window)
        let coordinator = AgentHistoryPaletteCoordinator(host: host)
        XCTAssertNil(coordinator.services)

        coordinator.show(entryPoint: .toolbar)

        XCTAssertFalse(coordinator.isShown)
        XCTAssertTrue(host.toolbarStates.isEmpty, "the toolbar button never shows pressed without a palette")
        XCTAssertEqual(host.currentProjectRequests, 0, "nothing is built before the services check")
        XCTAssertNil(window.childWindows?.first)
    }

    func test_key_context_reads_caret_selection_and_marked_text_from_field_editor() throws {
        let model = try makeModel()
        model.start()
        let editor = NSTextView()
        editor.string = "crash"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        var context = AgentHistoryPanelController.keyContext(editor: editor, model: model)
        XCTAssertTrue(context.caretAtEndOfQuery)
        XCTAssertFalse(context.hasTextSelection)
        XCTAssertFalse(context.hasMarkedText)
        XCTAssertTrue(context.bodyIsResults)

        editor.setSelectedRange(NSRange(location: 1, length: 2))
        context = AgentHistoryPanelController.keyContext(editor: editor, model: model)
        XCTAssertFalse(context.caretAtEndOfQuery)
        XCTAssertTrue(context.hasTextSelection)

        context = AgentHistoryPanelController.keyContext(editor: nil, model: model)
        XCTAssertTrue(context.caretAtEndOfQuery, "without a field editor the caret counts as at the end")
    }

    func test_plain_typing_is_swallowed_only_while_the_folder_sheet_is_shown() {
        var context = AgentHistoryKeyContext()
        XCTAssertFalse(AgentHistoryPanelController.swallowsUnroutedKey(modifiers: [], context: context))

        context.isSheetShown = true
        XCTAssertTrue(AgentHistoryPanelController.swallowsUnroutedKey(modifiers: [], context: context))
        XCTAssertTrue(AgentHistoryPanelController.swallowsUnroutedKey(modifiers: .shift, context: context))
        XCTAssertFalse(AgentHistoryPanelController.swallowsUnroutedKey(modifiers: .command, context: context))
        XCTAssertFalse(AgentHistoryPanelController.swallowsUnroutedKey(modifiers: .control, context: context))
        context.hasMarkedText = true
        XCTAssertFalse(AgentHistoryPanelController.swallowsUnroutedKey(modifiers: [], context: context))
    }

    func test_announcement_and_rebuild_copy() {
        XCTAssertEqual(AgentHistoryPanelController.announcement(forResultCount: 0), "No sessions found")
        XCTAssertEqual(AgentHistoryPanelController.announcement(forResultCount: 1), "1 session found")
        XCTAssertEqual(AgentHistoryPanelController.announcement(forResultCount: 12), "12 sessions found")
        XCTAssertTrue(AgentHistoryIndexUnavailableView.offersRebuild(.corrupt, isDiskFullPause: false))
        XCTAssertFalse(AgentHistoryIndexUnavailableView.offersRebuild(.corrupt, isDiskFullPause: true))
        XCTAssertFalse(AgentHistoryIndexUnavailableView.offersRebuild(.removalsUnreadable, isDiskFullPause: false))
        XCTAssertEqual(
            AgentHistoryNoAgentsView.title,
            "No conversations from Claude Code, Codex, Grok or OpenCode found on this Mac."
        )
    }

    /// SwiftUI exposes no accessibility tree without an assistive client, and its text is
    /// drawn, not views; so this checks the AppKit views the body chose to build: the search
    /// field and the scroll areas of the list and the preview. The footer and the transient
    /// message are drawn text and only covered by the hosted tests.
    func test_view_wide_layout_shows_query_list_and_preview_side_by_side() throws {
        let model = try makeModel()
        let layout = AgentHistoryPanelLayout.resolve(
            windowFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            mode: .results
        )
        model.layout = layout
        model.start()
        model.updateQuery("crash")
        model.showTransientMessage("Copied resume command")

        let rendered = render(model, size: layout.frame.size)

        XCTAssertEqual(rendered.queryFields, ["crash"], "the search field shows the query")
        XCTAssertEqual(rendered.scrollFrames.count, 2, "list and preview columns: \(rendered.scrollFrames)")
        let list = try XCTUnwrap(rendered.scrollFrames.first)
        let preview = try XCTUnwrap(rendered.scrollFrames.last)
        XCTAssertEqual(list.width, layout.listWidth, accuracy: 0.5, "the list takes the layout's list width")
        XCTAssertGreaterThan(preview.minX, list.maxX, "the preview sits right of the list")
        XCTAssertEqual(preview.maxX, layout.frame.width, accuracy: 0.5)
    }

    func test_view_compact_layout_swaps_list_for_preview() throws {
        let model = try makeModel()
        let layout = AgentHistoryPanelLayout.resolve(
            windowFrame: NSRect(x: 0, y: 0, width: 600, height: 900),
            mode: .results
        )
        XCTAssertTrue(layout.isCompact)
        model.layout = layout
        model.start()
        model.updateQuery("crash")

        var rendered = render(model, size: layout.frame.size)
        XCTAssertEqual(rendered.scrollFrames.count, 1, "compact shows the list only")
        XCTAssertEqual(rendered.scrollFrames.first?.width ?? 0, layout.frame.width, accuracy: 0.5)

        model.toggleTranscript()
        XCTAssertNotEqual(model.detail, .none)
        rendered = render(model, size: layout.frame.size)
        XCTAssertEqual(rendered.scrollFrames.count, 1, "the detail replaces the list instead of joining it")
        XCTAssertEqual(rendered.queryFields, ["crash"])
    }

    // MARK: - Helpers

    private struct RenderedView {
        var queryFields: [String] = []
        /// Scroll areas in hosting-view coordinates, left to right.
        var scrollFrames: [NSRect] = []
    }

    /// Lays the view out in a never-shown window and reads back the AppKit views it built.
    private func render(_ model: AgentHistoryViewModel, size: NSSize) -> RenderedView {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AgentHistoryView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }
        var rendered = RenderedView()
        var stack: [NSView] = [hosting]
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView {
                rendered.scrollFrames.append(scroll.convert(scroll.bounds, to: hosting))
            } else if let field = view as? NSTextField, field.isEditable {
                rendered.queryFields.append(field.stringValue)
            }
            stack.append(contentsOf: view.subviews)
        }
        rendered.scrollFrames.sort { $0.minX < $1.minX }
        return rendered
    }

    private func makeModel() throws -> AgentHistoryViewModel {
        let control = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isEnabled = true
        status.hasConsented = true
        status.state = .watching
        status.indexedSessions = 2
        control.status = status
        let search = FakeAgentHistorySearch()
        let summary = AgentHistorySessionSummary(
            id: 1, sourceID: 1, sourceRoot: "/tmp/agent-history-tests/root", agent: .claude,
            nativeID: "7f3c9a2e-41d0-4b6a-9c11-2b8e5d0f6a31", title: "Fix the crash on launch", titleKind: .generated,
            cwd: "/tmp/agent-history-tests/zentty", branch: "main", model: "opus",
            createdAtMs: 1_800_000_000_000, updatedAtMs: 1_800_000_000_000, turnCount: 3
        )
        search.recent = [summary]
        search.metadataResults = { _ in
            [HistoryMetadataResult(
                session: summary, score: 1, isWordLevel: true,
                titleHighlights: [NSRange(location: 12, length: 5)], note: .field(.branch, value: "main")
            )]
        }
        let launch = FakeAgentHistoryLaunch()
        let pasteboard = AgentHistoryTestPasteboard.make()
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: launch,
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { completion in
                completion(ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                ))
            },
            raiseClaudeRetention: { $0(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: pasteboard,
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_100) }
        )
        let model = AgentHistoryViewModel(
            context: AgentHistoryOpenContext(
                entryPoint: .shortcutOrMenu, currentProject: nil, initialScope: .all, hostWindowID: WindowID("window")
            ),
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: ManualAgentHistoryScheduler()
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }
}

@MainActor
private final class StubPaletteHost: AgentHistoryPaletteHost {
    let backdrop = CommandPaletteBackdropView()
    private let window: NSWindow?
    private(set) var toolbarStates: [Bool] = []
    private(set) var currentProjectRequests = 0

    init(window: NSWindow? = nil) {
        self.window = window
    }

    var agentHistoryWindow: NSWindow? { window }
    var agentHistoryBackdropView: CommandPaletteBackdropView { backdrop }
    var agentHistoryTheme: ZenttyTheme { ZenttyTheme.fallback(for: nil) }
    var agentHistoryWindowID: WindowID { WindowID("window") }
    func agentHistoryCurrentPane() -> AgentHistoryPaneLocation? {
        currentProjectRequests += 1
        return nil
    }
    func agentHistoryPane(forWorklane id: WorklaneID) -> AgentHistoryPaneLocation? { nil }
    func agentHistoryShowSettings() {}
    func agentHistoryRestoreFocus() {}
    func agentHistorySetToolbarPresented(_ presented: Bool) { toolbarStates.append(presented) }
    func agentHistoryExemptClickViews() -> [NSView] { [] }
}
