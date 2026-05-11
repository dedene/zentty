import Foundation

struct WorklaneDestinationSummary: Equatable, Sendable {
    let windowID: WindowID
    let worklaneID: WorklaneID
    let color: WorklaneColor?
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
            let panes = worklane.paneStripState.panes
            guard let firstTitle = panes.first?.title else { return nil }
            let primary = firstTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled"
                : firstTitle
            return WorklaneDestinationSummary(
                windowID: windowID,
                worklaneID: worklane.id,
                color: worklane.color,
                primaryPaneTitle: primary,
                additionalPaneCount: panes.count - 1
            )
        }
    }
}
