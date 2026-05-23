import Foundation

struct MenuBarStatusPresentation: Equatable, Sendable {
    let fleetState: MenuBarFleetState
    let fleetSummary: MenuBarFleetSummary
    let accessibilityLabel: String

    static func resolve(
        fleetState: MenuBarFleetState,
        fleetSummary: MenuBarFleetSummary
    ) -> MenuBarStatusPresentation {
        let hasAgentPanes = fleetSummary.totalCount > 0
        return MenuBarStatusPresentation(
            fleetState: fleetState,
            fleetSummary: fleetSummary,
            accessibilityLabel: fleetSummary.accessibilityLabel(
                fleetState: fleetState,
                hasAgentPanes: hasAgentPanes
            )
        )
    }
}
