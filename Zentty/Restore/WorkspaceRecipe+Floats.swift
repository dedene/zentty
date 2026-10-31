import CoreGraphics
import Foundation
import os

private let recipeFloatsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorkspaceRecipe")

extension WorkspaceRecipe {
    /// A pane that lived outside the strip (schema v5). Temporary
    /// (overlay-style) floats are never exported: they end with their command.
    struct FloatingPane: Codable, Equatable, Sendable {
        var pane: Pane
        /// `FloatingPaneMode.wireName`: `floating`, `pip` or `minimized`.
        var mode: String
        /// Normalized float frame as `[x, y, width, height]` (canvas fractions).
        var frame: [Double]
        var stackOrder: Int
        /// `FloatCorner.rawValue`; PiP only.
        var corner: String? = nil
        /// Dense per-corner order (PiP) or pill-bar order (minimized).
        var order: Int? = nil
        var originColumnIndex: Int? = nil
        /// `FloatingPaneState.sequence` (creation order). Optional: early v5
        /// recipes lack it and fall back to `stackOrder` on import.
        var sequence: Int? = nil
    }
}

// MARK: - Recipe <-> state mapping

extension WorkspaceRecipe.FloatingPane {
    init(state: FloatingPaneState, pane: WorkspaceRecipe.Pane) {
        let corner: String?
        let order: Int?
        switch state.mode {
        case .floating:
            corner = nil
            order = nil
        case .pip(let pipCorner, let pipOrder):
            corner = pipCorner.rawValue
            order = pipOrder
        case .minimized(let minimizedOrder):
            corner = nil
            order = minimizedOrder
        }
        self.init(
            pane: pane,
            mode: state.mode.wireName,
            frame: [state.floatFrame.x, state.floatFrame.y, state.floatFrame.width, state.floatFrame.height],
            stackOrder: state.stackOrder,
            corner: corner,
            order: order,
            originColumnIndex: state.origin?.columnIndex,
            sequence: state.sequence
        )
    }

    /// Decodes leniently: an unknown mode reads as `.floating`, an unknown
    /// corner as bottom-right, a missing order as 0. A bad entry should cost
    /// the user its placement, never the pane.
    var floatingMode: FloatingPaneMode {
        switch mode {
        case "floating":
            return .floating
        case "pip":
            let pipCorner = corner.flatMap(FloatCorner.init(rawValue:)) ?? {
                recipeFloatsLogger.warning("Recipe PiP corner missing or unknown; using bottomRight")
                return .bottomRight
            }()
            return .pip(corner: pipCorner, order: max(order ?? 0, 0))
        case "minimized":
            return .minimized(order: max(order ?? 0, 0))
        default:
            recipeFloatsLogger.warning("Recipe float mode \(mode, privacy: .public) unknown; restoring as floating")
            return .floating
        }
    }

    /// The stored frame, or the default centred frame when the entry is
    /// malformed (wrong length, non-finite, empty).
    var normalizedFrame: NormalizedRect {
        guard frame.count == 4,
              frame.allSatisfy(\.isFinite),
              frame[2] > 0,
              frame[3] > 0 else {
            recipeFloatsLogger.warning("Recipe float frame malformed; using the default centred frame")
            return Self.defaultFrame
        }
        return NormalizedRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }

    static var defaultFrame: NormalizedRect {
        let fraction = Double(FloatLayout.defaultCanvasFraction)
        let inset = (1 - fraction) / 2
        return NormalizedRect(x: inset, y: inset, width: fraction, height: fraction)
    }
}

// MARK: - Walkers

extension WorkspaceRecipe.Worklane {
    /// Tiles in column order, then floats in stored order. Every walker that
    /// asks "which panes does this recipe save" must use this, or a float's
    /// agent draft and saved output get dropped.
    var allPanes: [WorkspaceRecipe.Pane] {
        columns.flatMap(\.panes) + (floatingPanes ?? []).map(\.pane)
    }

    mutating func updateAllPanes(_ update: (inout WorkspaceRecipe.Pane) -> Void) {
        for columnIndex in columns.indices {
            for paneIndex in columns[columnIndex].panes.indices {
                update(&columns[columnIndex].panes[paneIndex])
            }
        }
        guard var floats = floatingPanes else {
            return
        }
        for floatIndex in floats.indices {
            update(&floats[floatIndex].pane)
        }
        floatingPanes = floats
    }
}

extension WorkspaceRecipe {
    mutating func updateAllPanes(_ update: (inout Pane) -> Void) {
        for windowIndex in windows.indices {
            for worklaneIndex in windows[windowIndex].worklanes.indices {
                windows[windowIndex].worklanes[worklaneIndex].updateAllPanes(update)
            }
        }
    }
}

// MARK: - Export

extension WorkspaceRecipeExporter {
    struct ExportedFloats: Equatable {
        var floatingPanes: [WorkspaceRecipe.FloatingPane]?
        var floatsHidden: Bool?
        var focusedFloatID: String?
    }

    /// Persistent floats of `worklane`, or all-nil when it has none (so a
    /// worklane without floats exports exactly like v4).
    static func makeFloats(_ worklane: WorklaneState) -> ExportedFloats {
        let floats = worklane.floatingPanes.filter { worklane.isPersistent($0.pane.id) }
        guard !floats.isEmpty else {
            return ExportedFloats(floatingPanes: nil, floatsHidden: nil, focusedFloatID: nil)
        }
        let focusedFloatID = worklane.focusedFloatID.flatMap { id in
            floats.contains { $0.pane.id == id } ? id.rawValue : nil
        }
        return ExportedFloats(
            floatingPanes: floats.map { float in
                WorkspaceRecipe.FloatingPane(state: float, pane: makePane(float.pane, worklane: worklane))
            },
            floatsHidden: worklane.floatsHidden,
            focusedFloatID: focusedFloatID
        )
    }
}

// MARK: - Import

extension WorkspaceRecipeImporter {
    /// Builds the worklane's floats, sharing `auxiliaryStateByPaneID` and the
    /// restore drafts with the tiles. A float whose pane ID is already taken
    /// (by a tile or an earlier float) is dropped. PiP and pill orders come
    /// back dense even when the saved ones have gaps.
    static func makeFloatingPanes(
        _ recipe: WorkspaceRecipe.Worklane,
        tiledPaneIDs: Set<PaneID>,
        restoreDraftWindow: SessionRestoreDraftWindow?,
        windowID: WindowID,
        worklaneID: WorklaneID,
        layoutContext: PaneLayoutContext,
        auxiliaryStateByPaneID: inout [PaneID: PaneAuxiliaryState],
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool
    ) -> [FloatingPaneState] {
        var takenPaneIDs = tiledPaneIDs
        var floats: [FloatingPaneState] = []
        for recipeFloat in recipe.floatingPanes ?? [] {
            let paneID = PaneID(recipeFloat.pane.id)
            guard takenPaneIDs.insert(paneID).inserted else {
                recipeFloatsLogger.warning("Recipe float \(paneID.rawValue, privacy: .public) duplicates a pane ID; dropping it")
                continue
            }
            // A float is a lone surface: never the window's own, never a split.
            let pane = makePane(
                recipeFloat.pane,
                surfaceContext: .tab,
                restoreDraftWindow: restoreDraftWindow,
                windowID: windowID,
                worklaneID: worklaneID,
                columnWidth: layoutContext.singlePaneWidth,
                auxiliaryStateByPaneID: &auxiliaryStateByPaneID,
                processEnvironment: processEnvironment,
                agentTeamsEnabled: agentTeamsEnabled
            )
            floats.append(
                FloatingPaneState(
                    pane: pane,
                    mode: recipeFloat.floatingMode,
                    floatFrame: recipeFloat.normalizedFrame,
                    stackOrder: recipeFloat.stackOrder,
                    origin: recipeFloat.originColumnIndex.map { FloatOrigin(columnIndex: max($0, 0)) },
                    sequence: recipeFloat.sequence ?? recipeFloat.stackOrder
                )
            )
        }
        return densifiedOrders(floats)
    }

    /// The saved focused float when it is still a `.floating` float; for a
    /// worklane without tiles, the front-most `.floating` float, so a
    /// float-only worklane never comes back with no focus.
    static func focusedFloatID(
        _ recipe: WorkspaceRecipe.Worklane,
        floats: [FloatingPaneState],
        hasTiles: Bool,
        floatsHidden: Bool
    ) -> PaneID? {
        if let saved = recipe.focusedFloatID.map(PaneID.init),
           floats.contains(where: { $0.pane.id == saved && $0.mode.isFloating }) {
            return saved
        }
        guard !hasTiles, !floatsHidden else {
            return nil
        }
        return floats.filter(\.mode.isFloating).max { $0.stackOrder < $1.stackOrder }?.pane.id
    }

    static func densifiedOrders(_ floats: [FloatingPaneState]) -> [FloatingPaneState] {
        var result = floats
        for corner in FloatCorner.allCases {
            let ranked = result.indices.compactMap { index -> (index: Int, order: Int)? in
                guard case .pip(corner, let order) = result[index].mode else { return nil }
                return (index, order)
            }
            for (dense, entry) in ranked.sorted(by: Self.byOrderThenIndex).enumerated() {
                result[entry.index].mode = .pip(corner: corner, order: dense)
            }
        }
        let minimized = result.indices.compactMap { index -> (index: Int, order: Int)? in
            guard case .minimized(let order) = result[index].mode else { return nil }
            return (index, order)
        }
        for (dense, entry) in minimized.sorted(by: Self.byOrderThenIndex).enumerated() {
            result[entry.index].mode = .minimized(order: dense)
        }
        return result
    }

    private static func byOrderThenIndex(_ lhs: (index: Int, order: Int), _ rhs: (index: Int, order: Int)) -> Bool {
        lhs.order == rhs.order ? lhs.index < rhs.index : lhs.order < rhs.order
    }
}
