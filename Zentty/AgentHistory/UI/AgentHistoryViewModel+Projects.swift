import Foundation

/// The panes' projects. Resolving one walks the disk and reads git metadata, so the coordinator
/// does it off main after the panel opens and hands the result here.
extension AgentHistoryViewModel {
    /// How long the first results wait for the worklane's project before opening on all projects.
    static let projectsWait: TimeInterval = 0.25

    /// Call before `start()` when the opening scope is a project still being resolved (the
    /// worklane menu): results hold back until it lands or `projectsWait` runs out, so the list
    /// doesn't flash all projects first.
    func awaitProjects() {
        isAwaitingProjects = true
        projectsWaitToken = scheduler.schedule(after: Self.projectsWait) { [weak self] in
            self?.finishAwaitingProjects()
        }
    }

    /// In time, a worklane entry opens on its project. Late, nothing moves under the user: the
    /// project only becomes the one ⇥ switches to.
    func projectsResolved(current: AgentHistoryProjectScope?, worklane: AgentHistoryProjectScope?) {
        let currentChanged = current != context.currentProject
        context.currentProject = current
        if case .worklaneContextMenu = context.entryPoint, let worklane {
            projectScope = worklane
            if isAwaitingProjects {
                context.initialScope = .project(worklane)
                scope = .project(worklane)
            }
        } else {
            projectScope = current
        }

        if isAwaitingProjects {
            finishAwaitingProjects()
        } else if currentChanged, body == .results, !parsedQuery.isEmpty {
            // Typed results rank the focused pane's project first.
            runSearch(resetSelection: false)
        }
    }

    private func finishAwaitingProjects() {
        guard isAwaitingProjects else { return }
        isAwaitingProjects = false
        projectsWaitToken?.cancel()
        projectsWaitToken = nil
        guard resultsAwaitProjects else { return }
        resultsAwaitProjects = false
        if body == .loading {
            showResults()
        }
    }
}
