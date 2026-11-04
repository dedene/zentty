import Foundation

/// What the float layer draws for the active worklane.
struct FloatLayerContent: Equatable {
    /// The worklane the floats belong to (mode-change motion only runs
    /// between two renders of the same one).
    var worklaneID: WorklaneID?
    var floats: [FloatingPaneState]
    var floatsHidden: Bool
    /// The float that owns keyboard focus (`WorklaneState.floatOwnsFocus`), else nil.
    var focusedFloatID: PaneID?
    var borderContextByPaneID: [PaneID: PaneBorderContextDisplayModel]
    var worklaneColor: WorklaneColor?
    /// Name and status of each PiP (its bottom status strip).
    var pipStatusByPaneID: [PaneID: PillBarItem]

    static let empty = FloatLayerContent(
        floats: [],
        floatsHidden: false,
        focusedFloatID: nil,
        borderContextByPaneID: [:],
        worklaneColor: nil
    )

    init(
        floats: [FloatingPaneState],
        floatsHidden: Bool,
        focusedFloatID: PaneID?,
        borderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        worklaneColor: WorklaneColor? = nil,
        pipStatusByPaneID: [PaneID: PillBarItem] = [:],
        worklaneID: WorklaneID? = nil
    ) {
        self.worklaneID = worklaneID
        self.floats = floats
        self.floatsHidden = floatsHidden
        self.focusedFloatID = focusedFloatID
        self.borderContextByPaneID = borderContextByPaneID
        self.worklaneColor = worklaneColor
        self.pipStatusByPaneID = pipStatusByPaneID
    }

    init(
        worklane: WorklaneState,
        borderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:]
    ) {
        self.init(
            floats: worklane.floatingPanes,
            floatsHidden: worklane.floatsHidden,
            focusedFloatID: worklane.floatOwnsFocus ? worklane.focusedFloatID : nil,
            borderContextByPaneID: Self.floatBorderContexts(worklane: worklane, base: borderContextByPaneID),
            worklaneColor: worklane.color,
            pipStatusByPaneID: Self.pipStatuses(worklane: worklane),
            worklaneID: worklane.id
        )
    }

    /// Status strip items for the worklane's PiPs.
    static func pipStatuses(worklane: WorklaneState) -> [PaneID: PillBarItem] {
        var result: [PaneID: PillBarItem] = [:]
        for float in worklane.floatingPanes {
            guard case .pip = float.mode else { continue }
            result[float.pane.id] = PillBarContent.item(for: float, in: worklane)
        }
        return result
    }

    /// Border legends for the worklane's floats, each with its bold name
    /// (`name · cwd`). When the base label already is the name (a custom
    /// title), the cwd takes its place so the name isn't shown twice.
    private static func floatBorderContexts(
        worklane: WorklaneState,
        base: [PaneID: PaneBorderContextDisplayModel]
    ) -> [PaneID: PaneBorderContextDisplayModel] {
        var result = base.filter { worklane.isFloating($0.key) }
        for float in worklane.floatingPanes {
            let paneID = float.pane.id
            let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
            guard let name = FloatDisplayName.resolve(
                pane: float.pane,
                presentation: auxiliaryState?.presentation,
                metadata: auxiliaryState?.metadata
            ) else {
                continue
            }
            var model = result[paneID] ?? PaneBorderContextDisplayModel(text: "")
            if model.text == name {
                var replacement = PaneBorderContextDisplayModel(
                    text: auxiliaryState?.shellContext?.borderContextDisplayText ?? ""
                )
                replacement.isAgentTeamLeader = model.isAgentTeamLeader
                replacement.isAgentTeamMember = model.isAgentTeamMember
                model = replacement
            }
            model.displayName = name
            result[paneID] = model
        }
        return result
    }

    var ownsFocus: Bool {
        focusedFloatID != nil
    }
}
