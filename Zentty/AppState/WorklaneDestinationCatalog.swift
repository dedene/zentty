import Foundation

struct WorklaneDestinationSummary: Equatable, Sendable {
    let windowID: WindowID
    let worklaneID: WorklaneID
    let color: WorklaneColor?
    /// The worklane's own title, trimmed, or nil when the worklane is untitled.
    /// Callers prefer this over `primaryPaneTitle` when labelling a destination.
    let worklaneTitle: String?
    let primaryPaneTitle: String
    let additionalPaneCount: Int
}

struct WorklaneDestinationGroup: Equatable, Sendable {
    let windowID: WindowID
    let summaries: [WorklaneDestinationSummary]
}

struct WorklaneDestinationCatalog: Equatable, Sendable {
    let groups: [WorklaneDestinationGroup]
    let canCreateNewWorklane: Bool

    var hasAnyDestination: Bool {
        !groups.isEmpty || canCreateNewWorklane
    }
}

struct MovePaneToWorklaneRequest: Equatable, Sendable {
    let sourcePaneID: PaneID
    let destinationWindowID: WindowID
    let destinationWorklaneID: WorklaneID
}

@MainActor
extension WorklaneStore {
    func destinationSummaries(
        windowID: WindowID,
        excluding excluded: WorklaneID?
    ) -> [WorklaneDestinationSummary] {
        worklanes.compactMap { worklane in
            guard worklane.id != excluded else { return nil }
            // A float-only worklane is a valid destination; the moved pane lands as a tile.
            let panes = worklane.allPanes
            guard !panes.isEmpty else { return nil }
            let primary = destinationPrimaryTitle(for: worklane)
            return WorklaneDestinationSummary(
                windowID: windowID,
                worklaneID: worklane.id,
                color: worklane.color,
                worklaneTitle: WorklaneContextFormatter.trimmed(worklane.title),
                primaryPaneTitle: primary,
                additionalPaneCount: panes.count - 1
            )
        }
    }

    private func destinationPrimaryTitle(for worklane: WorklaneState) -> String {
        let sidebarSummary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false)
        if let contextualTitle = WorklaneContextFormatter.trimmed(sidebarSummary.primaryText),
           contextualTitle.caseInsensitiveCompare("Shell") != .orderedSame {
            return contextualTitle
        }

        let firstTitle = worklane.allPanes.first?.title ?? ""
        return firstTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : firstTitle
    }
}
