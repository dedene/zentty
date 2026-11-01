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
        let host = StubPaletteHost()
        let coordinator = AgentHistoryPaletteCoordinator(host: host)

        coordinator.show(entryPoint: .toolbar)

        XCTAssertFalse(coordinator.isShown)
        XCTAssertTrue(host.toolbarStates.isEmpty)
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

    func test_view_lays_out_results_preview_and_footer_without_a_window() throws {
        let model = try makeModel()
        model.layout = AgentHistoryPanelLayout.resolve(
            windowFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            mode: .results
        )
        model.start()
        model.updateQuery("crash")
        model.showTransientMessage("Copied resume command")

        let hosting = NSHostingView(rootView: AgentHistoryView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 1010, height: 580)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.frame.size, NSSize(width: 1010, height: 580))
        XCTAssertNotNil(model.selectedRow)
    }

    // MARK: - Helpers

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
            claudeRetention: {
                ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-tests/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                )
            },
            raiseClaudeRetention: { .alreadySufficient(currentDays: 365) },
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
    private(set) var toolbarStates: [Bool] = []

    var agentHistoryWindow: NSWindow? { nil }
    var agentHistoryBackdropView: CommandPaletteBackdropView { backdrop }
    var agentHistoryTheme: ZenttyTheme { ZenttyTheme.fallback(for: nil) }
    var agentHistoryWindowID: WindowID { WindowID("window") }
    func agentHistoryCurrentProject() -> AgentHistoryProjectScope? { nil }
    func agentHistoryProject(forWorklane id: WorklaneID) -> AgentHistoryProjectScope? { nil }
    func agentHistoryShowSettings() {}
    func agentHistoryRestoreFocus() {}
    func agentHistorySetToolbarPresented(_ presented: Bool) { toolbarStates.append(presented) }
    func agentHistoryExemptClickViews() -> [NSView] { [] }
}
