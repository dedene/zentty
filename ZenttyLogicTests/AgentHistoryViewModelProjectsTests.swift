import XCTest
@testable import Zentty

/// The panes' projects resolve off main after the panel opens (`+Projects`): a worklane entry
/// holds its first results for its project, briefly; anything late only enables ⇥.
@MainActor
final class AgentHistoryViewModelProjectsTests: XCTestCase {
    private let worklaneProject = AgentHistoryProjectScope(
        key: "/tmp/agent-history-projects/worklane", displayName: "worklane", allowsCWDPrefix: true
    )
    private let focusedProject = AgentHistoryProjectScope(
        key: "/tmp/agent-history-projects/focused", displayName: "focused", allowsCWDPrefix: true
    )
    private var search: FakeAgentHistorySearch!
    private var scheduler: ManualAgentHistoryScheduler!

    override func setUp() {
        super.setUp()
        search = FakeAgentHistorySearch()
        scheduler = ManualAgentHistoryScheduler()
    }

    func test_worklane_entry_waits_for_its_project_then_opens_on_it() {
        let model = makeModel(entryPoint: .worklaneContextMenu(WorklaneID("lane")))
        model.awaitProjects()
        model.start()

        XCTAssertEqual(model.body, .loading, "no results on all projects before the worklane's project lands")
        XCTAssertTrue(search.recentScopes.isEmpty)
        XCTAssertFalse(model.canToggleScope)

        model.projectsResolved(current: focusedProject, worklane: worklaneProject)

        XCTAssertEqual(model.body, .results)
        XCTAssertEqual(model.scope, .project(worklaneProject))
        XCTAssertEqual(search.recentScopes, [.project(worklaneProject)])
        XCTAssertEqual(model.context.currentProject, focusedProject)
        XCTAssertEqual(model.projectScope, worklaneProject)

        scheduler.advance(by: AgentHistoryViewModel.projectsWait)
        XCTAssertEqual(search.recentScopes, [.project(worklaneProject)], "the wait timer doesn't search again")
    }

    func test_worklane_entry_opens_on_all_projects_when_its_project_is_slow() {
        let model = makeModel(entryPoint: .worklaneContextMenu(WorklaneID("lane")))
        model.awaitProjects()
        model.start()

        scheduler.advance(by: AgentHistoryViewModel.projectsWait)
        XCTAssertEqual(model.body, .results)
        XCTAssertEqual(model.scope, .all)

        model.projectsResolved(current: focusedProject, worklane: worklaneProject)
        XCTAssertEqual(model.scope, .all, "a late project doesn't move the list under the user")
        XCTAssertTrue(model.canToggleScope)
        model.toggleScope()
        XCTAssertEqual(model.scope, .project(worklaneProject))
    }

    func test_other_entries_show_results_at_once_and_gain_the_focused_project() {
        let model = makeModel(entryPoint: .shortcutOrMenu)
        model.start()

        XCTAssertEqual(model.body, .results)
        XCTAssertFalse(model.canToggleScope)

        model.projectsResolved(current: focusedProject, worklane: nil)
        XCTAssertEqual(model.scope, .all)
        XCTAssertEqual(model.projectScope, focusedProject)
        XCTAssertEqual(model.searchContext.currentRepositoryKey, focusedProject.key)
        XCTAssertTrue(model.canToggleScope)
    }

    func test_closing_while_waiting_cancels_the_wait() {
        let model = makeModel(entryPoint: .worklaneContextMenu(WorklaneID("lane")))
        model.awaitProjects()
        model.start()
        model.stop()

        scheduler.advance(by: AgentHistoryViewModel.projectsWait)
        XCTAssertEqual(model.body, .loading, "a closed palette doesn't search when the wait runs out")
        XCTAssertTrue(search.recentScopes.isEmpty)
    }

    // MARK: - Helpers

    private func makeModel(entryPoint: AgentHistoryEntryPoint) -> AgentHistoryViewModel {
        let control = FakeAgentHistoryControl()
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = true
        status.hasConsented = true
        status.state = .watching
        status.indexedSessions = 1
        control.status = status
        let services = AgentHistoryPaletteServices(
            control: control,
            search: search,
            launch: FakeAgentHistoryLaunch(),
            excludedFolders: { [] },
            setExcludedFolders: { _ in },
            claudeRetention: { completion in
                completion(ClaudeRetentionStatus(
                    configDirectory: URL(fileURLWithPath: "/tmp/agent-history-projects/.claude"),
                    settingsFileURL: URL(fileURLWithPath: "/tmp/agent-history-projects/.claude/settings.json"),
                    effectiveDays: 365, source: .userSettings, readError: nil
                ))
            },
            raiseClaudeRetention: { $0(.success(.alreadySufficient(currentDays: 365))) },
            pasteboard: AgentHistoryTestPasteboard.make(),
            revealInFinder: { _ in },
            fileExists: { _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let model = AgentHistoryViewModel(
            context: AgentHistoryPaletteCoordinator.openContext(
                entryPoint: entryPoint, currentProject: nil, worklaneProject: nil, windowID: WindowID("window")
            ),
            services: services,
            theme: AgentHistoryTheme(zenttyTheme: ZenttyTheme.fallback(for: nil)),
            scheduler: scheduler
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }
}
